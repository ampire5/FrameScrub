"""Serve two deterministic, single-variant HLS VODs and exercise the probe."""

import functools
import http.server
import pathlib
import subprocess
import sys
import tempfile
import threading
import time


class Server(http.server.SimpleHTTPRequestHandler):
    requested = set()
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def do_GET(self):
        with self.lock:
            self.requested.add(self.path)
        if pathlib.PurePosixPath(self.path).name.startswith("segment"):
            time.sleep(0.08)
        super().do_GET()


def make_fixture(root, segment_type):
    directory = root / segment_type
    directory.mkdir()
    suffix = "ts" if segment_type == "mpegts" else "m4s"
    subprocess.run([
        "ffmpeg", "-nostdin", "-loglevel", "error", "-filter_threads", "1",
        "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-t", "7",
        "-c:v", "libx264", "-threads", "2", "-preset", "ultrafast",
        "-g", "30", "-sc_threshold", "0", "-pix_fmt", "yuv420p",
        "-f", "hls", "-hls_time", "1", "-hls_playlist_type", "vod",
        "-hls_segment_type", segment_type,
        "-hls_segment_filename", str(directory / f"segment%02d.{suffix}"),
        str(directory / "media.m3u8"),
    ], check=True)
    (directory / "master.m3u8").write_text(
        "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1280x720\nmedia.m3u8\n",
        encoding="utf-8",
    )


def main(probe):
    with tempfile.TemporaryDirectory(prefix="framescrub-hls-fixtures-") as path:
        root = pathlib.Path(path)
        for segment_type in ("mpegts", "fmp4"):
            make_fixture(root, segment_type)

        with http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), functools.partial(Server, directory=root)
        ) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                for segment_type in ("mpegts", "fmp4"):
                    url = f"http://127.0.0.1:{server.server_port}/{segment_type}/master.m3u8"
                    print(segment_type, flush=True)
                    subprocess.run([probe, url, "90"], check=True, timeout=20)
                    with Server.lock:
                        prefix = f"/{segment_type}/segment"
                        segments = sorted(path for path in Server.requested if path.startswith(prefix))
                    if not 3 <= len(segments) < 7:
                        raise RuntimeError(f"Expected incremental segment reads, received {segments}")
                    print(f"HTTP segments requested: {len(segments)}/7", flush=True)
            finally:
                server.shutdown()
                worker.join()


if __name__ == "__main__":
    main(sys.argv[1])
