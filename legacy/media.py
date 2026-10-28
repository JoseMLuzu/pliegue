"""Local HEVC video encoding. ZIP integrity and video validation stay distinct."""

import os
import re
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path

VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi"}
QUALITY = {"fast": 24, "balanced": 20, "maximum": 18}


class VideoError(Exception):
    pass


class VideoCancelled(Exception):
    pass


def find_ffmpeg():
    configured = os.environ.get("FFMPEG_BINARY")
    if configured:
        return shutil.which(configured)
    bundled = Path(__file__).parent / ".tools" / ("ffmpeg.exe" if os.name == "nt" else "ffmpeg")
    if bundled.is_file() and os.access(bundled, os.X_OK):
        return str(bundled)
    installed = shutil.which("ffmpeg")
    if installed:
        return installed
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except (ImportError, RuntimeError):
        return None


def run(ffmpeg, arguments, job, duration=0, progress=None):
    """Drain output while a separate watcher can stop even a stalled encoder."""
    if job.cancelled.is_set():
        raise VideoCancelled()
    finished = threading.Event()
    lines = []
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as errors:
        process = subprocess.Popen(
            [ffmpeg, "-nostdin", "-hide_banner", "-nostats", *map(str, arguments)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=errors,
            text=True, encoding="utf-8", errors="replace",
        )

        def cancel():
            while not finished.wait(0.1):
                if job.cancelled.is_set():
                    try:
                        process.terminate()
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                    except ProcessLookupError:
                        pass
                    return

        watcher = threading.Thread(target=cancel, daemon=True)
        watcher.start()
        try:
            for line in process.stdout:
                # Only checksums need retaining; progress can span hours.
                if re.match(r"^\d+,[av],SHA256=", line):
                    lines.append(line.strip())
                if progress and duration and line.startswith("out_time_us="):
                    try:
                        progress(max(0, min(1, int(line.split("=", 1)[1]) / 1_000_000 / duration)))
                    except ValueError:
                        pass
            status = process.wait()
            if job.cancelled.is_set():
                raise VideoCancelled()
            errors.seek(0)
            log = errors.read(128 * 1024)
            if status != 0:
                raise VideoError("FFmpeg no pudo procesar este video. Puede estar dañado o contener pistas incompatibles con el formato de salida.")
            return "\n".join(lines), log
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            finished.set()
            watcher.join()


def input_args(path):
    # Do not allow a disguised playlist to open network URLs.
    return ["-protocol_whitelist", "file,pipe", "-format_whitelist", "mov,matroska,webm,avi", "-noautorotate", "-i", path]


def parse_info(log):
    source = log.split("Stream mapping:", 1)[0]
    videos = re.findall(r"^  Stream #0:.*Video: (.+)$", source, re.M)
    if len(videos) != 1 or "attached pic" in videos[0]:
        raise VideoError("Selecciona un video con una sola pista de imagen. Para archivos con varias cámaras o pistas de video, usa ZIP sin pérdida.")
    line = videos[0]
    dimensions = re.search(r"\b(\d{2,6})x(\d{2,6})\b", line)
    pixel_format = re.search(r", (yuv(?:420|422|444)p(?:10le|12le)?)(?:[,( ])", line)
    duration = re.search(r"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)", source)
    if not dimensions or not pixel_format or not duration:
        raise VideoError("No se pudo identificar un video YUV compatible y su duración. Usa ZIP sin pérdida para este formato.")
    if re.search(r"smpte2084|arib-std-b67|DOVI|Dolby Vision|Mastering display|Content light", source, re.I):
        raise VideoError("Este video contiene HDR o Dolby Vision. Esta versión no lo recodifica para evitar perder sus datos de color; usa ZIP sin pérdida.")
    fps = re.search(r"([\d.]+) fps", line)
    rotation = re.search(r"rotation of ([-\d.]+) degrees", source)
    return {"width": int(dimensions[1]), "height": int(dimensions[2]),
            "pixelFormat": pixel_format[1], "fps": float(fps[1]) if fps else 0,
            "duration": int(duration[1]) * 3600 + int(duration[2]) * 60 + float(duration[3]),
            "rotation": float(rotation[1]) if rotation else 0,
            "audio": re.findall(r"^  Stream #0:.*Audio: (\w+)", source, re.M),
            "codec": line.split(" ", 1)[0]}


def probe(ffmpeg, path, job):
    _, log = run(ffmpeg, [*input_args(path), "-map", "0:V:0", "-frames:v", "0", "-f", "null", "-"], job)
    return parse_info(log)


def encode_video(job):
    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        raise VideoError("Falta FFmpeg. Instálalo con «brew install ffmpeg» o «python3 -m pip install imageio-ffmpeg» y reinicia Pliegue.")
    source = job.directory / "0"
    output = job.directory / "output.mp4"
    with job.lock:
        job.phase = "analyzing"
        job.current_file = job.files[0]["name"]
    original = probe(ffmpeg, source, job)
    # Matroska preserves audio codecs such as Opus/PCM/FLAC without transcoding.
    container = "mp4" if Path(job.files[0]["name"]).suffix.lower() in {".mp4", ".mov", ".m4v"} and all(codec in {"aac", "mp3", "alac", "ac3", "eac3"} for codec in original["audio"]) else "mkv"
    output = output.with_suffix("." + container)
    stem = Path(job.archive_name).stem
    with job.lock:
        job.archive_name = stem + "." + container
        job.video_details = {**original, "crf": QUALITY[job.profile], "container": container}
        job.phase = "encoding"

    def encoding_progress(value):
        with job.lock:
            job.video_progress = value

    arguments = ["-y", "-loglevel", "error", *input_args(source), "-map", "0", "-map_metadata", "0",
                 "-map_chapters", "0", "-c", "copy", "-c:v:0", "libx265", "-crf", str(QUALITY[job.profile]),
                 "-preset", "medium", "-pix_fmt:v:0", original["pixelFormat"], "-fps_mode:v:0", "passthrough",
                 "-x265-params", "pools=4:frame-threads=2:log-level=error"]
    if container == "mp4":
        arguments += ["-tag:v:0", "hvc1", "-movflags", "+faststart"]
    arguments += ["-progress", "pipe:1", output]
    run(ffmpeg, arguments, job, original["duration"], encoding_progress)
    with job.lock:
        job.state = "verifying"
        job.phase = "decoding"
        job.video_progress = 0
    result = probe(ffmpeg, output, job)
    if (result["width"], result["height"], result["pixelFormat"], result["rotation"]) != (original["width"], original["height"], original["pixelFormat"], original["rotation"]):
        raise VideoError("La resolución, orientación o formato de color cambió inesperadamente. Se descartó el resultado.")
    if abs(result["duration"] - original["duration"]) > max(0.15, 2 / (original["fps"] or 24)):
        raise VideoError("La duración del resultado no coincide con el original. Se descartó el resultado.")
    if result["audio"] != original["audio"]:
        raise VideoError("Las pistas de audio no coinciden con el original. Se descartó el resultado.")
    # Fully decode the result: a valid header alone does not prove the video works.
    run(ffmpeg, ["-loglevel", "error", "-xerror", *input_args(output), "-map", "0:V:0", "-map", "0:a?",
                 "-progress", "pipe:1", "-f", "null", "-"], job, original["duration"], encoding_progress)
    if original["audio"]:
        with job.lock:
            job.phase = "audio"
        hashes = []
        for path in (source, output):
            digest, _ = run(ffmpeg, ["-loglevel", "error", *input_args(path), "-map", "0:a", "-c", "copy",
                                     "-f", "streamhash", "-hash", "sha256", "-"], job)
            hashes.append(digest)
        if not hashes[0] or hashes[0] != hashes[1]:
            raise VideoError("La verificación del audio no coincide. Se descartó el resultado.")
    if job.cancelled.is_set():
        raise VideoCancelled()
    output_size = output.stat().st_size
    with job.lock:
        if output_size >= job.total:
            # Never offer a larger recoded video as a successful compression.
            job.original_used = True
            job.archive_name = job.files[0]["name"]
            job.result_file = "0"
            job.output_size = job.total
            output.unlink()
        else:
            job.result_file = output.name
            job.output_size = output_size
            source.unlink()
        job.processed = job.total
        job.state = "done"
        job.video_progress = 1
