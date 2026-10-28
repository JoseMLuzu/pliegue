#!/usr/bin/env python3
"""Pliegue: local lossless ZIP compression and high-quality video encoding."""

import argparse
import hashlib
import json
import logging
import mimetypes
import os
import re
import shutil
import tempfile
import threading
import time
import webbrowser
import zipfile
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from secrets import token_urlsafe
from urllib.parse import quote, urlsplit

from media import VIDEO_EXTENSIONS, VideoCancelled, VideoError, encode_video, find_ffmpeg

STATIC = Path(__file__).parent / "static"
CHUNK = 1024 * 1024
TTL = 60 * 60
LEVELS = {"fast": 1, "balanced": 6, "maximum": 9}
LOG = logging.getLogger("pliegue")


class APIError(Exception):
    def __init__(self, message, status=400):
        self.message = message
        self.status = status


def safe_name(name, used):
    """Flatten paths and keep archive names portable and unique."""
    name = re.split(r"[/\\]", name)[-1]
    name = re.sub(r'[\x00-\x1f<>:"|?*]', "_", name).strip(" .")[:200] or "archivo"
    if re.match(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", name, re.I):
        name = "_" + name
    stem, suffix = Path(name).stem, Path(name).suffix
    candidate, number = name, 2
    while candidate.casefold() in used:
        candidate = f"{stem} ({number}){suffix}"
        number += 1
    used.add(candidate.casefold())
    return candidate


@dataclass
class Job:
    id: str
    directory: Path
    files: list
    level: int
    archive_name: str
    state: str = "uploading"
    processed: int = 0
    verified: int = 0
    output_size: int = 0
    current_file: str = ""
    error: str = ""
    touched: float = field(default_factory=time.monotonic)
    cancelled: threading.Event = field(default_factory=threading.Event)
    lock: threading.RLock = field(default_factory=threading.RLock)
    readers: int = 0
    worker: threading.Thread | None = field(default=None, repr=False)
    mode: str = "zip"
    profile: str = "balanced"
    phase: str = ""
    video_progress: float = 0
    video_details: dict = field(default_factory=dict)
    original_used: bool = False
    result_file: str = "output.zip"

    @property
    def total(self):
        return sum(item["size"] for item in self.files)

    def snapshot(self):
        with self.lock:
            self.touched = time.monotonic()
            return {
                "id": self.id, "state": self.state, "total": self.total,
                "processed": self.processed, "verified": self.verified,
                "outputSize": self.output_size, "currentFile": self.current_file,
                "error": self.error, "archiveName": self.archive_name,
                "mode": self.mode, "phase": self.phase, "videoProgress": self.video_progress,
                "videoDetails": self.video_details, "originalUsed": self.original_used,
                "files": [{"name": f["name"], "size": f["size"]} for f in self.files],
            }


class Store:
    def __init__(self, root):
        self.root = Path(root)
        self.jobs = {}
        self.lock = threading.RLock()
        self.stopping = threading.Event()
        self.cleaner = threading.Thread(target=self._cleanup_loop, daemon=True)
        self.cleaner.start()

    def create(self, data):
        if not isinstance(data, dict):
            raise APIError("La solicitud debe ser un objeto JSON.")
        files, level = data.get("files"), data.get("level", "balanced")
        mode = data.get("mode", "zip")
        if mode not in ("zip", "video"):
            raise APIError("Elige ZIP sin pérdida o Reducir video.")
        if not isinstance(level, str) or level not in LEVELS:
            raise APIError("El nivel de compresión no es válido.")
        if not isinstance(files, list) or not 1 <= len(files) <= 10000:
            raise APIError("Selecciona entre 1 y 10.000 archivos.")
        used, entries = set(), []
        for item in files:
            if not isinstance(item, dict):
                raise APIError("La lista de archivos no es válida.")
            name, size = item.get("name"), item.get("size")
            if not isinstance(name, str) or not name or type(size) is not int or size < 0:
                raise APIError("Un archivo tiene un nombre o tamaño no válido.")
            modified = item.get("modified", 0)
            if type(modified) not in (int, float) or not 0 <= modified <= 4354819199000:
                modified = 0
            entries.append({"name": safe_name(name, used), "size": size,
                            "modified": modified, "uploaded": False, "busy": False})
        if mode == "video":
            if len(entries) != 1 or Path(entries[0]["name"]).suffix.lower() not in VIDEO_EXTENSIONS:
                raise APIError("Para reducir video, selecciona un solo MP4, MOV, M4V, MKV, WebM o AVI.")
            if not find_ffmpeg():
                raise APIError("Falta FFmpeg. Instálalo con «brew install ffmpeg» o «python3 -m pip install imageio-ffmpeg» y reinicia Pliegue.", 503)
        archive = data.get("name", "pliegue")
        if not isinstance(archive, str):
            raise APIError("El nombre del resultado no es válido.")
        archive = safe_name(archive, set())
        extension = ".mp4" if mode == "video" else ".zip"
        if not archive.lower().endswith(extension):
            archive += extension
        with self.lock:
            if len(self.jobs) >= 24:
                raise APIError("Hay demasiadas tareas abiertas. Limpia una tarea o inténtalo más tarde.", 429)
            job_id = token_urlsafe(24)
            directory = self.root / job_id
            directory.mkdir()
            job = Job(job_id, directory, entries, LEVELS[level], archive)
            job.mode, job.profile = mode, level
            self.jobs[job_id] = job
            return job

    def get(self, job_id):
        with self.lock:
            job = self.jobs.get(job_id)
        if job is None:
            raise APIError("Esta tarea ya no está disponible. Vuelve a seleccionar tus archivos.", 404)
        with job.lock:
            job.touched = time.monotonic()
        return job

    def remove(self, job):
        with job.lock:
            job.cancelled.set()
            active = job.state in ("compressing", "verifying") or job.readers or any(f["busy"] for f in job.files)
            if active:
                return
            with self.lock:
                self.jobs.pop(job.id, None)
            shutil.rmtree(job.directory, ignore_errors=True)

    def _cleanup_loop(self):
        while not self.stopping.wait(30):
            with self.lock:
                jobs = list(self.jobs.values())
            for job in jobs:
                if job.cancelled.is_set() or time.monotonic() - job.touched > TTL:
                    self.remove(job)

    def close(self):
        self.stopping.set()
        with self.lock:
            jobs = list(self.jobs.values())
        # Let compression leave its open ZIP context before deleting temp files.
        for job in jobs:
            job.cancelled.set()
        for job in jobs:
            if job.worker is not None:
                job.worker.join()
        for job in jobs:
            self.remove(job)
        self.cleaner.join()


def compress_job(job):
    """Stream to disk, then independently check every decompressed SHA-256."""
    try:
        if job.mode == "video":
            encode_video(job)
            return
        with zipfile.ZipFile(job.directory / "output.zip", "w", zipfile.ZIP_DEFLATED,
                             compresslevel=job.level, allowZip64=True) as archive:
            for index, item in enumerate(job.files):
                if job.cancelled.is_set():
                    return
                source = job.directory / str(index)
                if item["modified"]:
                    # Clamp timestamps to the range representable by the ZIP format.
                    modified = max(315532800, item["modified"] / 1000)
                    os.utime(source, (modified, modified))
                info = zipfile.ZipInfo.from_file(source, arcname=item["name"], strict_timestamps=False)
                info.compress_type = zipfile.ZIP_DEFLATED
                # ZipFile.open honors the level carried by ZipInfo (also on Python 3.10).
                info._compresslevel = job.level
                digest = hashlib.sha256()
                with job.lock:
                    job.current_file = item["name"]
                with source.open("rb") as src, archive.open(info, "w", force_zip64=item["size"] >= (2**31 - 1)) as dst:
                    while chunk := src.read(CHUNK):
                        if job.cancelled.is_set():
                            return
                        digest.update(chunk)
                        dst.write(chunk)
                        with job.lock:
                            job.processed += len(chunk)
                item["sha256"] = digest.digest()
        with job.lock:
            job.state = "verifying"
        with zipfile.ZipFile(job.directory / "output.zip") as archive:
            for item in job.files:
                digest = hashlib.sha256()
                with job.lock:
                    job.current_file = item["name"]
                with archive.open(item["name"]) as src:
                    while chunk := src.read(CHUNK):
                        if job.cancelled.is_set():
                            return
                        digest.update(chunk)
                        with job.lock:
                            job.verified += len(chunk)
                if digest.digest() != item["sha256"]:
                    raise ValueError("La verificación de integridad no coincide.")
        with job.lock:
            if job.cancelled.is_set():
                return
            job.output_size = (job.directory / "output.zip").stat().st_size
            job.state = "done"
            job.touched = time.monotonic()
        # The verified archive is sufficient for downloading; discard input copies.
        for index in range(len(job.files)):
            (job.directory / str(index)).unlink(missing_ok=True)
    except VideoCancelled:
        pass
    except Exception as exc:
        LOG.exception("Error al comprimir")
        with job.lock:
            job.state = "error"
            job.error = str(exc) if isinstance(exc, VideoError) else "No se pudo crear o verificar el resultado. Comprueba el espacio disponible e inténtalo de nuevo."
        (job.directory / "output.zip").unlink(missing_ok=True)
        for path in job.directory.glob("output.*"):
            path.unlink(missing_ok=True)
    finally:
        if job.cancelled.is_set():
            with job.lock:
                job.state = "cancelled"
            shutil.rmtree(job.directory, ignore_errors=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "Pliegue/2.0"

    def log_message(self, fmt, *args):
        LOG.debug(fmt, *args)

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
        super().end_headers()

    def respond(self, data, status=200):
        content = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def check_origin(self):
        port = self.server.server_port
        hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
        if self.headers.get("Host") not in hosts:
            raise APIError("Host no permitido. Abre la dirección local de Pliegue.", 403)
        origin = self.headers.get("Origin")
        if origin and origin not in {f"http://{host}" for host in hosts}:
            raise APIError("Origen no permitido.", 403)
        if self.headers.get("Sec-Fetch-Site") == "cross-site":
            raise APIError("Solicitud externa no permitida.", 403)

    def read_json(self):
        if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            raise APIError("Se esperaba JSON.", 415)
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            raise APIError("El tamaño de la solicitud no es válido.")
        if not 0 < length <= 4 * CHUNK:
            raise APIError("La solicitud es demasiado grande o está vacía.", 413)
        try:
            return json.loads(self.rfile.read(length))
        except (ValueError, UnicodeDecodeError):
            raise APIError("El JSON no es válido.")

    def dispatch(self):
        try:
            self.connection.settimeout(120)
            self.check_origin()
            parts = urlsplit(self.path).path.strip("/").split("/")
            if self.command == "GET" and parts[0] != "api":
                return self.serve_static(parts)
            if parts == ["api", "capabilities"] and self.command == "GET":
                return self.respond({"video": bool(find_ffmpeg())})
            if parts == ["api", "jobs"] and self.command == "POST":
                job = self.server.store.create(self.read_json())
                return self.respond(job.snapshot(), 201)
            if len(parts) < 3 or parts[:2] != ["api", "jobs"]:
                raise APIError("Ruta no encontrada.", 404)
            job = self.server.store.get(parts[2])
            if len(parts) == 3:
                if self.command == "GET":
                    return self.respond(job.snapshot())
                if self.command == "DELETE":
                    self.server.store.remove(job)
                    return self.respond({"ok": True})
            if len(parts) == 5 and parts[3] == "files" and self.command == "PUT":
                return self.upload(job, parts[4])
            if parts[3:] == ["start"] and self.command == "POST":
                with job.lock:
                    if job.state != "uploading" or job.cancelled.is_set():
                        raise APIError("Esta tarea ya ha comenzado.", 409)
                    if not all(item["uploaded"] for item in job.files):
                        raise APIError("Todavía faltan archivos por recibir.", 409)
                    job.state = "compressing"
                    job.worker = threading.Thread(target=compress_job, args=(job,), daemon=True)
                    job.worker.start()
                return self.respond(job.snapshot(), 202)
            if parts[3:] == ["download"] and self.command == "GET":
                return self.download(job)
            raise APIError("Ruta no encontrada.", 404)
        except APIError as exc:
            self.respond({"error": exc.message}, exc.status)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except Exception:
            LOG.exception("Error en la solicitud")
            self.respond({"error": "No se pudo completar la operación. Comprueba el espacio disponible y vuelve a intentarlo."}, 500)

    def upload(self, job, index):
        try:
            index = int(index)
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            raise APIError("Archivo o tamaño no válido.")
        with job.lock:
            if job.state != "uploading" or job.cancelled.is_set():
                raise APIError("La tarea no acepta más archivos.", 409)
            if not 0 <= index < len(job.files):
                raise APIError("Archivo no encontrado.", 404)
            item = job.files[index]
            if length != item["size"]:
                raise APIError("El tamaño del archivo no coincide.")
            if item["busy"] or item["uploaded"]:
                raise APIError("Este archivo ya fue recibido o se está recibiendo.", 409)
            item["busy"] = True
        path = job.directory / str(index)
        try:
            remaining = length
            with path.open("wb") as output:
                while remaining:
                    if job.cancelled.is_set():
                        raise APIError("Tarea cancelada.", 409)
                    chunk = self.rfile.read(min(CHUNK, remaining))
                    if not chunk:
                        raise APIError("La transferencia se interrumpió. Inténtalo de nuevo.")
                    output.write(chunk)
                    remaining -= len(chunk)
                    with job.lock:
                        job.touched = time.monotonic()
            with job.lock:
                item["uploaded"] = True
            self.respond({"ok": True})
        finally:
            with job.lock:
                item["busy"] = False
                if not item["uploaded"]:
                    path.unlink(missing_ok=True)
            if job.cancelled.is_set():
                self.server.store.remove(job)

    def download(self, job):
        with job.lock:
            if job.state != "done" or job.cancelled.is_set():
                raise APIError("El resultado todavía no está disponible.", 409)
            job.readers += 1
        try:
            with (job.directory / job.result_file).open("rb") as source:
                self.send_response(200)
                self.send_header("Content-Type", mimetypes.guess_type(job.archive_name)[0] or "application/octet-stream")
                fallback_name = "pliegue" + Path(job.archive_name).suffix
                self.send_header("Content-Disposition", f"attachment; filename={fallback_name}; filename*=UTF-8''{quote(job.archive_name)}")
                self.send_header("Content-Length", str(job.output_size))
                self.end_headers()
                while chunk := source.read(CHUNK):
                    self.wfile.write(chunk)
                    with job.lock:
                        job.touched = time.monotonic()
        finally:
            with job.lock:
                job.readers -= 1
            if job.cancelled.is_set():
                self.server.store.remove(job)

    def serve_static(self, parts):
        name = "/".join(parts)
        allowed = {"": ("index.html", "text/html; charset=utf-8"),
                   "app.js": ("app.js", "text/javascript; charset=utf-8"),
                   "style.css": ("style.css", "text/css; charset=utf-8"),
                   "favicon.svg": ("favicon.svg", "image/svg+xml")}
        if name not in allowed:
            raise APIError("Archivo no encontrado.", 404)
        filename, content_type = allowed[name]
        content = (STATIC / filename).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    do_GET = dispatch
    do_POST = dispatch
    do_PUT = dispatch
    do_DELETE = dispatch


def make_server(port, store):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.store = store
    return server


def main():
    parser = argparse.ArgumentParser(description="Pliegue · Videos de alta calidad y ZIP sin pérdida")
    parser.add_argument("--port", type=int, default=8765, help="Puerto local (8765 por defecto)")
    parser.add_argument("--no-browser", action="store_true", help="No abrir el navegador automáticamente")
    args = parser.parse_args()
    logging.basicConfig(level=logging.WARNING)
    with tempfile.TemporaryDirectory(prefix="pliegue-") as root:
        store = Store(root)
        try:
            server = make_server(args.port, store)
        except OSError as exc:
            store.close()
            parser.exit(1, f"No se pudo abrir el puerto {args.port}: {exc}\nPrueba con --port 8766.\n")
        url = f"http://127.0.0.1:{server.server_port}"
        print(f"\n  Pliegue · Compresión local de videos y archivos.\n  {url}\n\n  Ctrl+C para cerrar y borrar los archivos temporales.\n", flush=True)
        if not args.no_browser:
            webbrowser.open(url)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nCerrando Pliegue…", flush=True)
        finally:
            store.close()
            server.server_close()


if __name__ == "__main__":
    main()
