import json
import os
import platform
import pwd
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

START = time.time()


def service_info():
    return {
        "service": "render-ssh-service",
        "hostname": socket.gethostname(),
        "user": pwd.getpwuid(os.getuid()).pw_name,
        "python": platform.python_version(),
        "platform": platform.platform(),
        "uptime_seconds": round(time.time() - START, 1),
    }


class Handler(BaseHTTPRequestHandler):
    def send_json(self, payload, status=200):
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_json({"status": "ok"})
        elif self.path == "/":
            self.send_json(service_info())
        else:
            self.send_json({"error": "not found"}, 404)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def main():
    port = int(os.environ.get("PORT", "10000"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print("listening on 0.0.0.0:%d" % port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
