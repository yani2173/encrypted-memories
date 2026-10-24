"""Loopback-only fixture service with a durable upload oracle outside the app."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import struct
import threading
import zlib

from journey import JourneyError

MODEL = bytes([0xA7]) * 16384


def png(asset):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    color = int(asset.removeprefix("asset-"))
    if not 0 <= color < 8:
        raise ValueError("Unknown synthetic photo")
    pixels = (b"\0" + bytes([32 + color * 25, 80, 180]) * 32) * 32
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


class BurstHTTPServer(ThreadingHTTPServer):
    # The app requests its synthetic thumbnails in parallel. On a loaded runner the accept loop falls behind, and
    # macOS resets connections beyond the listen backlog; the default of 5 lost requests the server never saw.
    request_queue_size = 128


class FixtureServer:
    def __init__(self, directory, point):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.point = point
        self.phase = "old"
        self.hold_phase = "old"
        self.links = []
        self.duplicates = 0
        self.requests = []
        self.lock = threading.Lock()
        self.reached = threading.Event()
        self.release = threading.Event()
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def send(self, data, status=200, headers=None):
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                for key, value in (headers or {}).items():
                    self.send_header(key, value)
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # The selected checkpoint intentionally outlives the killed app.

            def do_GET(self):
                with fixture.lock:
                    fixture.requests.append({"phase": fixture.phase, "path": self.path,
                                             "range": self.headers.get("Range")})
                    fixture.save()
                    hold = fixture.phase == fixture.hold_phase and self.path == "/checkpoint/" + fixture.point
                if self.path.startswith("/checkpoint/"):
                    if hold:
                        fixture.reached.set()
                        if not fixture.release.wait(240):
                            self.send(b"Checkpoint was not released", 500)
                            return
                    self.send(b"OK")
                elif self.path == "/links":
                    with fixture.lock:
                        self.send(json.dumps(fixture.links).encode())
                elif self.path.startswith("/thumbnail/"):
                    try:
                        self.send(png(self.path.rsplit("/", 1)[1]), headers={"Content-Type": "image/png"})
                    except ValueError:
                        self.send(b"Unknown photo", 404)
                elif self.path == "/model":
                    value = self.headers.get("Range")
                    match = re.fullmatch(r"bytes=(\d+)-(\d+)", value or "")
                    if value and not match:
                        self.send(b"Invalid range", 416)
                        return
                    if match:
                        start, end = map(int, match.groups())
                        if start > end or end >= len(MODEL):
                            self.send(b"Invalid range", 416)
                            return
                        self.send(MODEL[start:end + 1], 206, {
                            "Content-Range": f"bytes {start}-{end}/{len(MODEL)}",
                            "Content-Type": "application/octet-stream"})
                    else:
                        self.send(MODEL, headers={"Content-Type": "application/octet-stream"})
                else:
                    self.send(b"Unknown route", 404)

            def do_POST(self):
                if self.path != "/upload":
                    self.send(b"Unknown route", 404)
                    return
                try:
                    count = int(self.headers.get("Content-Length", "0"))
                    if not 0 < count <= 4096:
                        raise ValueError("Invalid upload")
                    payload = json.loads(self.rfile.read(count))
                    name, digest = payload["name"], payload["hash"]
                    if not isinstance(name, str) or not isinstance(digest, str):
                        raise ValueError("Invalid upload")
                except (ValueError, KeyError):
                    self.send(b"Invalid upload", 400)
                    return
                with fixture.lock:
                    if any(link["hash"] == digest for link in fixture.links):
                        fixture.duplicates += 1
                    link = {"id": f"link-{len(fixture.links)}", "name": name, "hash": digest}
                    fixture.links.append(link)
                    fixture.save()
                self.send(json.dumps(link).encode())

        self.http = BurstHTTPServer(("127.0.0.1", 0), Handler)
        self.http.daemon_threads = True
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.url = f"http://127.0.0.1:{self.http.server_port}"

    def save(self):
        # Only synthetic fields and routes enter this evidence file.
        path = self.directory / "oracle.json"
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps({"links": self.links, "duplicate_uploads": self.duplicates,
                                         "requests": self.requests}, indent=2) + "\n")
        temporary.replace(path)

    def wait_checkpoint(self, timeout=180, preparing=None):
        if preparing:
            def observe_preparation():
                if preparing.wait() != 0:
                    self.reached.set()
            threading.Thread(target=observe_preparation, daemon=True).start()
        if not self.reached.wait(timeout):
            raise JourneyError(f"The historical app did not reach {self.point}")
        with self.lock:
            observed = any(r['phase'] == 'old' and r['path'] == '/checkpoint/' + self.point
                           for r in self.requests)
        if not observed:
            raise JourneyError(f"UI preparation failed ({preparing.returncode}); see prepare-ui.log")

    def verify_model_resume(self):
        with self.lock:
            downloads = [r for r in self.requests if r['phase'] == 'new' and r['path'] == '/model']
            if not downloads or downloads[0]['range'] != 'bytes=8192-16383':
                raise JourneyError('The model did not resume from its saved partial file')

    def begin_upgrade(self):
        with self.lock:
            self.phase = "new"
        self.release.set()

    def verify_uploads(self, expected=8):
        with self.lock:
            if self.duplicates:
                raise JourneyError(f"The app made {self.duplicates} duplicate uploads")
            if len(self.links) != expected:
                raise JourneyError(f"Backup uploaded {len(self.links)} resources; expected {expected}")

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.release.set()
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()
