#!/usr/bin/env python3
"""A tiny OpenAI-compatible chat completions server for end-to-end tests.

Streams "Hi from mock: <prompt>" in a few chunks. A prompt containing "slow" streams 60 chunks 0.25 s apart, so a
test can stop the turn while it runs.
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18765


def last_user_text(body):
    for message in reversed(body.get("messages", [])):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        payload = json.dumps({"object": "list", "data": [{"id": "smoke-model", "object": "model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        prompt = last_user_text(body)
        # The prompt the model sees carries system reminders; the user's words come last.
        tail = prompt.strip().splitlines()[-1][:60] if prompt.strip() else ""
        slow = "slow" in prompt.lower()
        if slow:
            pieces = [f"word{i} " for i in range(60)]
            delay = 0.25
        else:
            text = f"Hi from mock: {tail}"
            pieces = [text[i : i + 6] for i in range(0, len(text), 6)]
            delay = 0.03
        if not body.get("stream"):
            payload = json.dumps(
                {
                    "id": "mock",
                    "object": "chat.completion", "created": int(time.time()),
                    "model": "smoke-model",
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": "".join(pieces)}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def send(obj):
            self.wfile.write(f"data: {json.dumps(obj)}\n\n".encode())
            self.wfile.flush()

        try:
            send({"id": "mock", "object": "chat.completion.chunk", "created": int(time.time()), "model": "smoke-model",
                  "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}]})
            for piece in pieces:
                time.sleep(delay)
                send({"id": "mock", "object": "chat.completion.chunk", "created": int(time.time()), "model": "smoke-model",
                      "choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}]})
            send({"id": "mock", "object": "chat.completion.chunk", "created": int(time.time()), "model": "smoke-model",
                  "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            send({"id": "mock", "object": "chat.completion.chunk", "created": int(time.time()), "model": "smoke-model", "choices": [],
                  "usage": {"prompt_tokens": 120, "completion_tokens": len(pieces), "total_tokens": 120 + len(pieces)}})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"mock llm on {PORT}", flush=True)
    server.serve_forever()
