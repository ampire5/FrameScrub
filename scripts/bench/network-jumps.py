"""Serve a single MP4 on loopback with a repeatable byte-range response delay.

Usage: python3 scripts/bench/network-jumps.py VIDEO.mp4 DELAY_SECONDS
Prints the assigned port. Each response is paced at 8 MiB/s.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import re
import sys
import time

media = sys.argv[1]
delay = float(sys.argv[2])
size = os.stat(media).st_size

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path != "/av.mp4":
            self.send_error(404)
            return
        match = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        if not match:
            self.send_error(416)
            return
        start = int(match[1])
        end = min(size - 1, int(match[2]))
        if start > end:
            self.send_error(416)
            return
        time.sleep(delay)
        self.send_response(206)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        with open(media, "rb") as source:
            source.seek(start)
            remaining = end - start + 1
            try:
                while remaining:
                    data = source.read(min(remaining, 128 * 1024))
                    self.wfile.write(data)
                    remaining -= len(data)
                    time.sleep(len(data) / (8 * 1024 * 1024))
            except (BrokenPipeError, ConnectionResetError):
                pass

with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    print(server.server_port, flush=True)
    server.serve_forever()
