#!/usr/bin/env python3
"""Local E2E server for static media, torrent, and Stremio account contracts."""

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import json
import re
import sys
import time


class RangeRequestHandler(SimpleHTTPRequestHandler):
    range_to_send = None

    def send_json(self, value, status=200):
        payload = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/heartbeat":
            self.send_json({"success": True})
            return
        if self.path.split("?", 1)[0] == "/provider-network-alias.ts":
            self.send_response(307)
            self.send_header("Location", "/provider-network-isolation.mp4")
            self.end_headers()
            return
        if re.match(r"/hlsv2/[^/]+/master\.m3u8(?:\?.*)?$", self.path):
            self.send_response(307)
            self.send_header("Location", "/sample.m3u8")
            self.end_headers()
            return
        if self.path == "/settings":
            self.send_json({
                "values": {
                    "transcodeProfile": None,
                    "allTranscodeProfiles": [],
                    "transcodeMaxWidth": 1920,
                }
            })
            return
        super().do_GET()

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(size) or b"{}")
        with open(Path(self.directory) / "requests.log", "a", encoding="utf-8") as log:
            log.write(json.dumps({"path": self.path, "body": body}, sort_keys=True) + "\n")

        if self.path == "/api/login":
            if body.get("email") != "e2e@example.test" or body.get("password") != "fixture-only":
                self.send_json({"error": {"message": "Invalid fixture credentials", "code": 1}})
                return
            self.send_json({
                "result": {
                    "authKey": "fixture-auth-key",
                    "user": {"_id": "fixture-user", "email": body["email"]},
                }
            })
            return

        if self.path == "/api/datastoreGet":
            self.send_json({"result": [{
                "_id": "tt1254207",
                "name": "Big Buck Bunny",
                "type": "movie",
                "poster": None,
                "posterShape": "poster",
                "removed": False,
                "temp": False,
                "_ctime": "2026-08-20T00:00:00Z",
                "_mtime": "2026-08-20T00:00:00Z",
                "state": {
                    "lastWatched": None, "timeWatched": 0, "timeOffset": 0,
                    "overallTimeWatched": 0, "timesWatched": 0,
                    "flaggedWatched": 0, "duration": 0, "video_id": None,
                    "watched": None, "noNotif": False,
                },
                "behaviorHints": {
                    "defaultVideoId": None, "featuredVideoId": None,
                    "hasScheduledVideos": False,
                },
            }]})
            return

        if self.path == "/api/addonCollectionGet":
            manifest = json.loads((Path(self.directory) / "manifest.json").read_text())
            self.send_json({"result": {
                "addons": [{
                    "manifest": manifest,
                    "transportUrl": f"http://127.0.0.1:{self.server.server_port}/manifest.json",
                    "flags": {"official": False, "protected": False},
                }],
                "lastModified": "2026-08-20T00:00:00Z",
            }})
            return

        if self.path in ("/api/datastorePut", "/api/addonCollectionSet"):
            self.send_json({"result": {"success": True}})
            return

        if re.fullmatch(r"/[0-9a-fA-F]{40}/create", self.path):
            self.send_json({"torrent": {"infoHash": self.path.split("/")[1]}})
            return

        self.send_json({"error": "Unknown fixture endpoint"}, status=404)

    def translate_path(self, path):
        if re.fullmatch(r"/[0-9a-fA-F]{40}/-?\d+(?:\?.*)?", path):
            path = "/sample.mp4"
        elif path.split("?", 1)[0] == "/ambiguous-media":
            # Extensionless provider-style route used to verify AVPlayer's
            # bounded MIME probe without exposing a real signed URL.
            path = "/sample.mp4"
        return super().translate_path(path)

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            source = open(path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None

        size = os.fstat(source.fileno()).st_size
        start, end = 0, max(size - 1, 0)
        requested = self.headers.get("Range")
        if requested:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", requested.strip())
            if not match:
                source.close()
                self.send_error(416, "Invalid byte range")
                return None
            if match.group(1):
                start = int(match.group(1))
            if match.group(2):
                end = min(int(match.group(2)), end)
            if start > end or start >= size:
                source.close()
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return None

        self.send_response(206 if requested else 200)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if requested:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        self.range_to_send = (start, end)
        return source

    def copyfile(self, source, outputfile):
        start, end = self.range_to_send or (0, os.fstat(source.fileno()).st_size - 1)
        source.seek(start)
        remaining = end - start + 1
        sent = 0
        started_at = time.monotonic()
        throttle = int(os.environ.get("SKELETON_RANGE_THROTTLE_BPS", "0"))
        stall_every = int(os.environ.get("SKELETON_RANGE_STALL_EVERY_BYTES", "0"))
        stall_seconds = float(os.environ.get("SKELETON_RANGE_STALL_SECONDS", "0"))
        next_stall = stall_every
        while remaining > 0:
            chunk = source.read(min(64 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            sent += len(chunk)
            remaining -= len(chunk)
            if stall_every > 0 and stall_seconds > 0 and sent >= next_stall:
                time.sleep(stall_seconds)
                next_stall += stall_every
            if throttle > 0:
                expected_elapsed = sent / throttle
                delay = expected_elapsed - (time.monotonic() - started_at)
                if delay > 0:
                    time.sleep(delay)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: range_server.py PORT DIRECTORY")
    port = int(sys.argv[1])
    directory = str(Path(sys.argv[2]).resolve())
    handler = lambda *args, **kwargs: RangeRequestHandler(
        *args, directory=directory, **kwargs
    )
    server = ThreadingHTTPServer(("127.0.0.1", port), handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
