#!/usr/bin/env python3
"""LOCAL ONLY stand-in for Sentry's ingest endpoint, bound to 127.0.0.1.

Logs one line per envelope item that reaches it so a local run can prove which
processes reported. Point the API at it with
  SENTRY_DSN=http://localkey@127.0.0.1:3199/1
Usage: fake_sentry_sink.py [port] [logfile]
"""
import gzip
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 3199
LOG = sys.argv[2] if len(sys.argv) > 2 else "fake_sentry.log"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        lines = body.decode("utf-8", "replace").split("\n")
        # Envelope: header line, then (item header, payload) pairs.
        i = 1
        while i + 1 < len(lines):
            try:
                item = json.loads(lines[i])
                payload = json.loads(lines[i + 1]) if lines[i + 1].strip() else {}
            except ValueError:
                break
            if item.get("type") in ("event", "transaction"):
                tags = payload.get("tags", {}) or {}
                message = payload.get("message") or (payload.get("logentry") or {}).get("message") or payload.get("transaction", "")
                record = {
                    "t": time.strftime("%H:%M:%S"), "type": item["type"], "environment": payload.get("environment"),
                    "release": (payload.get("release") or "")[:12], "message": message,
                    "probe": tags.get("probe"), "worker_index": tags.get("worker_index"), "pid": tags.get("pid"),
                }
                with open(LOG, "a") as handle:
                    handle.write(json.dumps(record) + "\n")
            i += 2
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
