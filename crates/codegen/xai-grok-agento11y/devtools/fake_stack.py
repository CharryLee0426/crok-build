#!/usr/bin/env python3
"""A local stand-in for an Agent Observability stack, to see exactly what crok sends.

It accepts what the bridge sends (generations, workflow steps, scores, ratings, hook evaluations,
and OTLP/HTTP JSON traces and metrics), answers like the real APIs, and appends every request to a
JSONL file. Point a crok home at it with an agento11y.env such as:

    AGENTO11Y_ENDPOINT=http://127.0.0.1:4318
    AGENTO11Y_PROTOCOL=http
    AGENTO11Y_AUTH_MODE=basic
    AGENTO11Y_AUTH_TENANT_ID=1
    AGENTO11Y_AUTH_TOKEN=local
    OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
    CROK_AGENTO11Y_IDLE_SECS=5

then `CROK_HOME=<that home> crok -p ...`, and read the file:

    fake_stack.py serve --port 4318 --out /tmp/stack.jsonl
    fake_stack.py summary /tmp/stack.jsonl        # turns with their generations, tools and steps

Only the standard library is used.
"""

from __future__ import annotations

import argparse
import gzip
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()


def answer(path: str, body) -> dict:
    if path.endswith("/generations:export"):
        return {"results": [{"generationId": g.get("id", ""), "accepted": True} for g in body.get("generations", [])]}
    if path.endswith("/workflow-steps:export") or "workflow" in path:
        steps = body.get("workflowSteps") or body.get("workflow_steps") or []
        return {"results": [{"stepId": s.get("id", ""), "accepted": True} for s in steps]}
    if path.endswith("/scores:export"):
        scores = body.get("scores", [])
        return {"results": [{"score_id": s.get("score_id", ""), "accepted": True, "status": "accepted"} for s in scores],
                "accepted": len(scores)}
    if path.endswith("/ratings"):
        return {"rating": {**body, "conversationId": path.split("/")[-2], "createdAt": "2026-01-01T00:00:00Z"},
                "summary": {"totalCount": 1, "goodCount": int(body.get("rating", "").endswith("GOOD")),
                            "badCount": int(body.get("rating", "").endswith("BAD")), "latestRatedAt": "2026-01-01T00:00:00Z",
                            "hasBadRating": body.get("rating", "").endswith("BAD")}}
    if path.endswith("/hooks:evaluate"):
        return {"action": "allow", "evaluations": []}
    return {}


class Handler(BaseHTTPRequestHandler):
    out = "stack.jsonl"

    def read_body(self) -> bytes:
        if self.headers.get("transfer-encoding", "").lower() == "chunked":
            raw = b""
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                raw += self.rfile.read(size)
                self.rfile.readline()
        else:
            raw = self.rfile.read(int(self.headers.get("content-length") or 0))
        if self.headers.get("content-encoding", "").lower() == "gzip":
            raw = gzip.decompress(raw)
        return raw

    def do_POST(self):  # noqa: N802 - http.server's name
        raw = self.read_body()
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            body = {"_bytes": len(raw), "_content_type": self.headers.get("content-type")}
        with LOCK, open(self.out, "a") as f:
            f.write(json.dumps({"method": "POST", "path": self.path, "body": body}) + "\n")
        reply = json.dumps(answer(self.path, body if isinstance(body, dict) else {})).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    do_PATCH = do_POST
    do_PUT = do_POST

    def log_message(self, *args):
        pass


def otlp_spans(body: dict):
    for resource in body.get("resourceSpans", []):
        for scope in resource.get("scopeSpans", []):
            for span in scope.get("spans", []):
                attrs = {a["key"]: next(iter(a.get("value", {}).values()), None) for a in span.get("attributes", [])}
                yield span, attrs


def summary(path: str) -> None:
    spans, steps, scores, ratings, guards, generations = [], [], [], [], 0, []
    for line in open(path):
        rec = json.loads(line)
        p, body = rec["path"], rec["body"]
        if p.endswith("/v1/traces"):
            spans.extend(otlp_spans(body))
        elif p.endswith("/generations:export"):
            generations.extend(body.get("generations", []))
        elif "workflow" in p:
            steps.extend(body.get("workflowSteps") or body.get("workflow_steps") or [])
        elif p.endswith("/scores:export"):
            scores.extend(body.get("scores", []))
        elif p.endswith("/ratings"):
            ratings.append(body)
        elif p.endswith("/hooks:evaluate"):
            guards += 1
    by_parent: dict[str, list] = {}
    for span, attrs in spans:
        by_parent.setdefault(span.get("parentSpanId") or "", []).append((span, attrs))
    roots = [(s, a) for s, a in spans if a.get("gen_ai.operation.name") == "invoke_agent"]
    print(f"{len(spans)} spans, {len(generations)} generations, {len(steps)} steps, {len(scores)} scores, "
          f"{len(ratings)} ratings, {guards} guard checks")

    def show(span, attrs, depth):
        dur = (int(span["endTimeUnixNano"]) - int(span["startTimeUnixNano"])) / 1e9
        extra = {k: v for k, v in attrs.items() if k.startswith("crok.") or k.startswith("agento11y.tag.")}
        print(f"{'  ' * depth}{span['name']}  {dur:.2f}s  {json.dumps(extra, sort_keys=True)}")
        for child, child_attrs in sorted(by_parent.get(span["spanId"], []), key=lambda c: int(c[0]["startTimeUnixNano"])):
            show(child, child_attrs, depth + 1)

    for span, attrs in roots:
        if not span.get("parentSpanId") or not any(s["spanId"] == span.get("parentSpanId") for s, _ in spans):
            print(f"trace {span['traceId']}")
            show(span, attrs, 1)
    for step in steps:
        print(f"step {step.get('stepName') or step.get('step_name')}: {json.dumps(step.get('outputState') or step.get('output_state'))}")
    for score in scores:
        print(f"score {score['evaluator_id']}/{score['score_key']} = {json.dumps(score['value'])} on {score['generation_id']}")


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int, default=4318)
    s.add_argument("--out", default="stack.jsonl")
    m = sub.add_parser("summary")
    m.add_argument("file")
    args = p.parse_args(argv)
    if args.cmd == "serve":
        Handler.out = args.out
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
        print(f"listening on http://127.0.0.1:{args.port}, writing {args.out}", flush=True)
        server.serve_forever()
    else:
        summary(args.file)


if __name__ == "__main__":
    main(sys.argv[1:])
