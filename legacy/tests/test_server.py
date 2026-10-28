import hashlib
import http.client
import io
import json
import os
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import server


class MemoryConnection:
    """Run the real HTTP handler with byte streams, without binding a port."""

    def __init__(self, data):
        self.input = io.BytesIO(data)
        self.output = io.BytesIO()

    def makefile(self, *args, **kwargs):
        return self.input

    def sendall(self, data):
        self.output.write(data)

    def settimeout(self, timeout):
        pass


class PliegueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = server.Store(self.temp.name)
        self.http = SimpleNamespace(store=self.store, server_port=8765)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def request(self, method, path, body=b"", headers=None):
        supplied = headers or {}
        fields = {"Host": "127.0.0.1:8765", "Content-Length": str(len(body)), **supplied}
        if isinstance(body, dict) or isinstance(body, list):
            body = json.dumps(body).encode()
            fields["Content-Length"] = str(len(body))
            fields["Content-Type"] = "application/json"
        raw = f"{method} {path} HTTP/1.1\r\n".encode()
        raw += "".join(f"{name}: {value}\r\n" for name, value in fields.items()).encode()
        connection = MemoryConnection(raw + b"\r\n" + body)
        server.Handler(connection, ("127.0.0.1", 55555), self.http)
        response = http.client.HTTPResponse(MemoryConnection(connection.output.getvalue()))
        response.begin()
        return response.status, dict(response.getheaders()), response.read()

    def json_request(self, *args, **kwargs):
        status, headers, data = self.request(*args, **kwargs)
        return status, json.loads(data)

    def create(self, files, level="balanced", name="prueba"):
        status, data = self.json_request("POST", "/api/jobs", {
            "files": [{"name": name, "size": len(content), "modified": 1700000000000} for name, content in files],
            "level": level, "name": name,
        })
        self.assertEqual(status, 201)
        return data["id"]

    def upload(self, job_id, files):
        for index, (_, content) in enumerate(files):
            status, data = self.json_request("PUT", f"/api/jobs/{job_id}/files/{index}", content)
            self.assertEqual((status, data), (200, {"ok": True}))

    def wait_done(self, job_id):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            _, job = self.json_request("GET", f"/api/jobs/{job_id}")
            if job["state"] in ("done", "error", "cancelled"):
                self.assertEqual(job["state"], "done", job)
                return job
            time.sleep(0.01)
        self.fail("La compresión no terminó a tiempo")

    def test_end_to_end_mixed_files_are_byte_identical(self):
        files = [("notas.txt", ("Mis recuerdos, intactos.\n" * 50000).encode()),
                 ("foto.jpg", b"\xff\xd8\xff\xe0" + os.urandom(10240)),
                 ("video.mp4", b"\x00\x00\x00\x18ftypmp42" + os.urandom(10240)),
                 ("música.flac", os.urandom(10240)), ("vacío.txt", b""),
                 ("datos.desconocidos", bytes(range(256)) * 30)]
        job_id = self.create(files, name="mis recuerdos")
        self.upload(job_id, files)
        status, _ = self.json_request("POST", f"/api/jobs/{job_id}/start")
        self.assertEqual(status, 202)
        job = self.wait_done(job_id)
        status, headers, output = self.request("GET", f"/api/jobs/{job_id}/download")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "application/zip")
        self.assertIn("mis%20recuerdos.zip", headers["Content-Disposition"])
        self.assertEqual(len(output), job["outputSize"])
        self.assertLess(job["outputSize"], job["total"])
        self.assertEqual(job["verified"], job["total"])
        self.assertEqual(job["processed"], job["total"])
        with zipfile.ZipFile(io.BytesIO(output)) as archive:
            self.assertIsNone(archive.testzip())
            for name, original in files:
                recovered = archive.read(name)
                self.assertEqual(recovered, original)
                self.assertEqual(hashlib.sha256(recovered).digest(), hashlib.sha256(original).digest())
        # Only the verified ZIP remains, not copies of the selected files.
        self.assertEqual([p.name for p in (Path(self.temp.name) / job_id).iterdir()], ["output.zip"])

    def test_all_compression_levels_preserve_content(self):
        content = (b"compressible content\n" * 2000) + os.urandom(2048)
        for level in server.LEVELS:
            with self.subTest(level=level):
                files = [("archivo.bin", content)]
                job_id = self.create(files, level)
                self.upload(job_id, files)
                self.json_request("POST", f"/api/jobs/{job_id}/start")
                self.wait_done(job_id)
                _, _, output = self.request("GET", f"/api/jobs/{job_id}/download")
                with zipfile.ZipFile(io.BytesIO(output)) as archive:
                    self.assertEqual(archive.read("archivo.bin"), content)

    def test_duplicate_names_do_not_overwrite(self):
        files = [("foto.JPG", b"one"), ("foto.JPG", b"two"), ("FOTO.jpg", b"three")]
        job_id = self.create(files)
        self.upload(job_id, files)
        self.json_request("POST", f"/api/jobs/{job_id}/start")
        job = self.wait_done(job_id)
        self.assertEqual([f["name"] for f in job["files"]], ["foto.JPG", "foto (2).JPG", "FOTO (3).jpg"])
        with zipfile.ZipFile(Path(self.temp.name) / job_id / "output.zip") as archive:
            self.assertEqual([archive.read(name) for name in archive.namelist()], [b"one", b"two", b"three"])

    def test_only_empty_files_still_create_valid_zip(self):
        files = [("vacío", b"")]
        job_id = self.create(files)
        self.upload(job_id, files)
        self.json_request("POST", f"/api/jobs/{job_id}/start")
        job = self.wait_done(job_id)
        self.assertEqual(job["total"], 0)
        self.assertGreater(job["outputSize"], 0)
        with zipfile.ZipFile(Path(self.temp.name) / job_id / "output.zip") as archive:
            self.assertEqual(archive.read("vacío"), b"")

    def test_incompressible_content_reports_real_increase(self):
        files = [("random.bin", os.urandom(16384))]
        job_id = self.create(files)
        self.upload(job_id, files)
        self.json_request("POST", f"/api/jobs/{job_id}/start")
        job = self.wait_done(job_id)
        self.assertGreater(job["outputSize"], job["total"])

    def test_names_are_safe_and_portable(self):
        used = set()
        cases = {"../../secreto.txt": "secreto.txt", "..\\..\\datos.txt": "datos.txt",
                 "CON.txt": "_CON.txt", "a\x00b?.txt": "a_b_.txt", "..": "archivo"}
        for name, expected in cases.items():
            self.assertEqual(server.safe_name(name, used), expected)

    def test_reject_invalid_manifests(self):
        cases = [[], {}, {"files": []}, {"files": [{"name": "a", "size": -1}]},
                 {"files": [{"name": "a", "size": True}]}, {"files": [None]},
                 {"files": [{"name": "", "size": 0}]},
                 {"files": [{"name": "a", "size": 0}], "level": []},
                 {"files": [{"name": "a", "size": 0}], "name": None}]
        for manifest in cases:
            with self.subTest(manifest=manifest):
                status, _ = self.json_request("POST", "/api/jobs", manifest)
                self.assertEqual(status, 400)

    def test_reject_wrong_length_and_incomplete_upload(self):
        job_id = self.create([("a.txt", b"abc")])
        status, _ = self.json_request("PUT", f"/api/jobs/{job_id}/files/0", b"ab")
        self.assertEqual(status, 400)
        status, _ = self.json_request("PUT", f"/api/jobs/{job_id}/files/0", b"ab", headers={"Content-Length": "3"})
        self.assertEqual(status, 400)
        self.assertFalse((Path(self.temp.name) / job_id / "0").exists())
        self.upload(job_id, [("a.txt", b"abc")])  # An interrupted upload can be retried.

    def test_cannot_start_before_all_files_arrive(self):
        job_id = self.create([("a.txt", b"abc")])
        status, _ = self.json_request("POST", f"/api/jobs/{job_id}/start")
        self.assertEqual(status, 409)
        status, _ = self.json_request("GET", f"/api/jobs/{job_id}/download")
        self.assertEqual(status, 409)

    def test_cannot_overwrite_uploaded_file(self):
        job_id = self.create([("a.txt", b"abc")])
        self.upload(job_id, [("a.txt", b"abc")])
        status, _ = self.json_request("PUT", f"/api/jobs/{job_id}/files/0", b"xyz")
        self.assertEqual(status, 409)
        self.assertEqual((Path(self.temp.name) / job_id / "0").read_bytes(), b"abc")

    def test_delete_cleans_up_copies(self):
        job_id = self.create([("a.txt", b"abc")])
        self.upload(job_id, [("a.txt", b"abc")])
        status, _ = self.json_request("DELETE", f"/api/jobs/{job_id}")
        self.assertEqual(status, 200)
        self.assertFalse((Path(self.temp.name) / job_id).exists())
        status, _ = self.json_request("GET", f"/api/jobs/{job_id}")
        self.assertEqual(status, 404)

    def test_cancelled_compression_removes_partial_zip(self):
        job_id = self.create([("a.txt", b"abc")])
        self.upload(job_id, [("a.txt", b"abc")])
        job = self.store.get(job_id)
        job.state = "compressing"
        job.cancelled.set()
        server.compress_job(job)
        self.assertEqual(job.state, "cancelled")
        self.assertFalse(job.directory.exists())

    def test_integrity_mismatch_never_exposes_download(self):
        files = [("a.txt", b"correct content")]
        job_id = self.create(files)
        self.upload(job_id, files)
        job = self.store.get(job_id)
        job.state = "compressing"
        original_open = zipfile.ZipFile.open

        def corrupt_read(archive, name, mode="r", *args, **kwargs):
            if mode == "r":
                return io.BytesIO(b"corrupted content")
            return original_open(archive, name, mode, *args, **kwargs)

        with patch.object(zipfile.ZipFile, "open", corrupt_read), self.assertLogs("pliegue", level="ERROR"):
            server.compress_job(job)
        self.assertEqual(job.state, "error")
        self.assertFalse((job.directory / "output.zip").exists())
        status, _ = self.json_request("GET", f"/api/jobs/{job_id}/download")
        self.assertEqual(status, 409)

    def test_external_origins_and_hosts_are_rejected(self):
        for headers in [{"Origin": "https://other.example"}, {"Host": "evil.example:8765"},
                        {"Sec-Fetch-Site": "cross-site"}]:
            with self.subTest(headers=headers):
                status, _ = self.json_request("POST", "/api/jobs", {"files": [{"name": "a", "size": 0}]}, headers)
                self.assertEqual(status, 403)
        self.assertEqual(len(self.store.jobs), 0)

    def test_static_files_and_traversal(self):
        for path, content_type in [("/", "text/html"), ("/app.js", "text/javascript"),
                                   ("/style.css", "text/css"), ("/favicon.svg", "image/svg+xml")]:
            status, headers, body = self.request("GET", path)
            self.assertEqual(status, 200)
            self.assertTrue(headers["Content-Type"].startswith(content_type))
            self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
            self.assertTrue(body)
        status, _ = self.json_request("GET", "/../server.py")
        self.assertEqual(status, 404)

    def test_request_body_validation(self):
        status, _ = self.json_request("POST", "/api/jobs", b"plain text")
        self.assertEqual(status, 415)
        status, _ = self.json_request("POST", "/api/jobs", b"{", {"Content-Type": "application/json"})
        self.assertEqual(status, 400)
        status, _ = self.json_request("POST", "/api/jobs", b"{}", {"Content-Type": "application/json", "Content-Length": str(5 * server.CHUNK)})
        self.assertEqual(status, 413)


if __name__ == "__main__":
    unittest.main()
