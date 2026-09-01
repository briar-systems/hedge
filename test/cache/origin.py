import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


lock = threading.Lock()
counts = {}
conditionals = {}


def record(path, conditional):
    with lock:
        counts[path] = counts.get(path, 0) + 1
        if conditional:
            conditionals[path] = conditionals.get(path, 0) + 1
        return counts[path]


class Origin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def send_body(self, body, cache_control, etag, extra=None):
        payload = body.encode("ascii")
        self.send_response(200)
        self.send_header("Cache-Control", cache_control)
        self.send_header("ETag", etag)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        for name, value in extra or []:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/counts":
            with lock:
                payload = json.dumps({
                    "requests": counts,
                    "conditionals": conditionals,
                }, sort_keys=True).encode("ascii")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        conditional = self.headers.get("If-None-Match")
        sequence = record(self.path, conditional is not None)
        if self.path == "/item":
            if sequence == 1:
                self.send_body("representation\n", "max-age=0", '"v1"', [
                    ("X-Refresh", "old"),
                    ("X-Preserve", "preserved"),
                    ("X-Remove", "old"),
                ])
                return
            if conditional == '"v1"':
                self.send_response(304)
                self.send_header("Cache-Control", 'private="x-remove", max-age=60')
                self.send_header("ETag", '"v1"')
                self.send_header("X-Refresh", "new")
                self.end_headers()
                return
        elif self.path == "/error-covered":
            if sequence == 1:
                self.send_body("covered stale\n",
                    "max-age=0, stale-if-error=600", '"covered"')
                return
            self.send_response(502)
            payload = b"origin error must not leak\n"
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        elif self.path == "/error-refused":
            if sequence == 1:
                self.send_body("refused stale\n", "max-age=0", '"refused"')
                return
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        elif self.path == "/multi":
            self.send_body("0123456789", "max-age=60", '"multi"')
            return
        elif self.path == "/leak":
            self.send_body("clean request\n", "no-store", '"leak"')
            return

        self.send_response(500)
        self.send_header("Content-Length", "0")
        self.end_headers()


server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Origin)
server.serve_forever()
