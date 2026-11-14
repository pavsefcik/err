#!/usr/bin/env python3
"""Minimal OpenAI-compatible streaming server used by tests/test_err.py.

Records every chat-completions request body in ``state.requests`` so the tests
can assert on the messages err.py built. No network access needed.
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class MockState:
    def __init__(self):
        self.requests = []
        self.reply = "OK."
        self.usage_total = None  # None => omit usage, forcing client-side estimate


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        log_message = lambda self, *args, **kwargs: None  # keep test output clean

        def _send_json(self, status, obj):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.split("?")[0] == "/v1/models":
                self._send_json(200, {"object": "list", "data": [{"id": "mock-model"}]})
            else:
                self._send_json(404, {"error": "not found"})

        def do_POST(self):
            if self.path.split("?")[0] != "/v1/chat/completions":
                self._send_json(404, {"error": "not found"})
                return
            length = int(self.headers.get("Content-Length", "0") or 0)
            raw = self.rfile.read(length)
            try:
                body = json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError:
                body = {"_raw": raw.decode("utf-8", "replace")}
            state.requests.append(body)

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

            def send(payload):
                self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
                self.wfile.flush()

            reply = state.reply
            for start in range(0, len(reply), 4):
                send({"choices": [{"delta": {"content": reply[start:start + 4]}, "index": 0}]})
            if state.usage_total is not None:
                send({"choices": [], "usage": {"total_tokens": state.usage_total}})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()

    return Handler


def start(state=None):
    """Start the mock on an ephemeral port. Returns (state, server, base_url)."""
    state = state or MockState()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address[:2]
    return state, server, f"http://{host}:{port}"
