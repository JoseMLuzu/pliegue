import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import media
import server
import test_server


@unittest.skipUnless(media.find_ffmpeg(), "FFmpeg no está instalado")
class VideoTests(unittest.TestCase):
    request = test_server.PliegueTests.request
    json_request = test_server.PliegueTests.json_request

    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory()
        cls.ffmpeg = media.find_ffmpeg()
        cls.source = Path(cls.fixtures.name) / "source.mp4"
        cls.small = Path(cls.fixtures.name) / "small.mp4"
        subprocess.run([cls.ffmpeg, "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "2",
                        "-c:v", "libx264", "-crf", "8", "-c:a", "aac", str(cls.source)], check=True, capture_output=True, timeout=30)
        subprocess.run([cls.ffmpeg, "-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=black:size=64x64:rate=24",
                        "-t", "0.25", "-c:v", "libx264", "-crf", "40", str(cls.small)], check=True, capture_output=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.fixtures.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = server.Store(self.temp.name)
        self.http = SimpleNamespace(store=self.store, server_port=8765)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def create_video(self, path, profile="balanced"):
        content = path.read_bytes()
        status, data = self.json_request("POST", "/api/jobs", {"mode": "video", "level": profile,
            "name": "reducido", "files": [{"name": path.name, "size": len(content)}]})
        self.assertEqual(status, 201, data)
        job_id = data["id"]
        status, data = self.json_request("PUT", f"/api/jobs/{job_id}/files/0", content)
        self.assertEqual(status, 200, data)
        return self.store.get(job_id)

    def complete(self, job):
        status, _ = self.json_request("POST", f"/api/jobs/{job.id}/start")
        self.assertEqual(status, 202)
        job.worker.join(timeout=15)
        self.assertFalse(job.worker.is_alive())
        self.assertEqual(job.state, "done", job.error)
        return job.snapshot()

    def test_api_delivers_smaller_playable_hevc_mp4_with_unchanged_audio(self):
        job = self.create_video(self.source)
        result = self.complete(job)
        self.assertLess(result["outputSize"], result["total"])
        self.assertFalse(result["originalUsed"])
        output = job.directory / job.result_file
        original = media.probe(self.ffmpeg, self.source, job)
        encoded = media.probe(self.ffmpeg, output, job)
        self.assertEqual(encoded["codec"], "hevc")
        for key in ("width", "height", "fps", "duration", "rotation", "pixelFormat", "audio"):
            self.assertEqual(original[key], encoded[key], key)
        hashes = []
        frames = []
        for path in (self.source, output):
            digest, _ = media.run(self.ffmpeg, [*media.input_args(path), "-map", "0:a", "-c", "copy", "-f", "streamhash", "-"], job)
            hashes.append(digest)
            decoded = subprocess.run([self.ffmpeg, "-v", "error", "-i", str(path), "-map", "0:v:0", "-f", "framemd5", "-"],
                                     check=True, capture_output=True, timeout=10).stdout
            frames.append([line for line in decoded.splitlines() if not line.startswith(b"#")])
        self.assertEqual(hashes[0], hashes[1])
        self.assertTrue(hashes[0])
        self.assertEqual(len(frames[0]), 48)
        self.assertEqual(len(frames[0]), len(frames[1]))
        self.assertNotEqual(frames[0], frames[1])  # Video is recoded, not byte-identical.
        status, headers, body = self.request("GET", f"/api/jobs/{job.id}/download")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "video/mp4")
        self.assertEqual(body, output.read_bytes())
        self.assertIn("reducido.mp4", headers["Content-Disposition"])
        self.assertFalse((job.directory / "0").exists())

    def test_no_saving_returns_original_bytes_not_a_larger_video(self):
        job = self.create_video(self.small, "maximum")
        result = self.complete(job)
        self.assertTrue(result["originalUsed"])
        self.assertEqual(result["outputSize"], result["total"])
        self.assertEqual(result["archiveName"], "small.mp4")
        _, _, body = self.request("GET", f"/api/jobs/{job.id}/download")
        self.assertEqual(body, self.small.read_bytes())
        self.assertFalse((job.directory / "output.mp4").exists())

    def test_mkv_keeps_flac_audio_without_recoding(self):
        source = Path(self.temp.name) / "flac-video.mkv"
        subprocess.run([self.ffmpeg, "-y", "-v", "error", "-i", str(self.source), "-c:v", "copy",
                        "-c:a", "flac", str(source)], check=True, capture_output=True, timeout=10)
        job = self.create_video(source)
        result = self.complete(job)
        self.assertFalse(result["originalUsed"])
        self.assertEqual(result["archiveName"], "reducido.mkv")
        self.assertEqual(result["videoDetails"]["audio"], ["flac"])
        self.assertLess(result["outputSize"], result["total"])
        status, headers, body = self.request("GET", f"/api/jobs/{job.id}/download")
        self.assertEqual(status, 200)
        self.assertEqual(body, (job.directory / job.result_file).read_bytes())
        self.assertNotEqual(headers["Content-Type"], "application/zip")

    def test_orientation_is_preserved(self):
        rotated = Path(self.temp.name) / "portrait.mp4"
        subprocess.run([self.ffmpeg, "-y", "-v", "error", "-display_rotation:v:0", "90", "-i", str(self.source),
                        "-map", "0", "-c", "copy", str(rotated)], check=True, capture_output=True, timeout=10)
        job = self.create_video(rotated)
        self.complete(job)
        result = media.probe(self.ffmpeg, job.directory / job.result_file, job)
        original = media.probe(self.ffmpeg, rotated, job)
        self.assertNotEqual(original["rotation"], 0)
        self.assertEqual(result["rotation"], original["rotation"])

    def test_invalid_video_does_not_offer_download(self):
        invalid = Path(self.temp.name) / "invalid.mp4"
        invalid.write_bytes(b"not a video")
        job = self.create_video(invalid)
        with self.assertLogs("pliegue", level="ERROR"):
            server.compress_job(job)
        self.assertEqual(job.state, "error")
        status, _ = self.json_request("GET", f"/api/jobs/{job.id}/download")
        self.assertEqual(status, 409)

    def test_cancellation_stops_running_ffmpeg(self):
        job = self.create_video(self.source)
        timer = threading.Timer(0.2, job.cancelled.set)
        timer.start()
        started = time.monotonic()
        try:
            with self.assertRaises(media.VideoCancelled):
                media.run(self.ffmpeg, ["-re", "-stream_loop", "-1", "-i", self.source, "-f", "null", "-"], job)
            self.assertLess(time.monotonic() - started, 5)
        finally:
            timer.cancel()


class VideoValidationTests(unittest.TestCase):
    def test_hdr_is_rejected_without_silent_color_conversion(self):
        log = "  Duration: 00:01:00.00\n  Stream #0:0: Video: hevc (Main 10), yuv420p10le(bt2020/smpte2084), 1920x1080, 30 fps\n"
        with self.assertRaisesRegex(media.VideoError, "HDR"):
            media.parse_info(log)

    def test_missing_engine_fails_before_upload(self):
        with tempfile.TemporaryDirectory() as temp:
            store = server.Store(temp)
            try:
                with patch("server.find_ffmpeg", return_value=None):
                    with self.assertRaises(server.APIError) as raised:
                        store.create({"mode": "video", "files": [{"name": "video.mp4", "size": 100}]})
                    self.assertEqual(raised.exception.status, 503)
                    self.assertEqual(len(store.jobs), 0)
            finally:
                store.close()

    def test_video_mode_requires_one_video(self):
        with tempfile.TemporaryDirectory() as temp:
            store = server.Store(temp)
            try:
                for files in ([{"name": "a.txt", "size": 0}], [{"name": "a.mp4", "size": 0}] * 2):
                    with self.subTest(files=files), self.assertRaises(server.APIError):
                        store.create({"mode": "video", "files": files})
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()
