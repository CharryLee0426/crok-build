#!/usr/bin/env python3
"""Offline ACP fixture for Crok Desktop tests and manual UI inspection.

Launch with CROK_DESKTOP_HARNESS pointing to this executable. It never runs tools, writes
project files, contacts a service, or reads credentials. Every response is marked
as fixture data. Prompts containing `fixture:permission`, `fixture:question`,
`fixture:plan`, or `fixture:trust` display the corresponding interaction;
`fixture:subagents` streams a simulated child agent lifecycle, and `fixture:think`
streams several seconds of reasoning (CROK_FIXTURE_THINK_SECONDS, default 8).
CROK_FIXTURE_LOAD_DELAY (seconds) slows session/load, as a large real session is, and
CROK_FIXTURE_HISTORY names a JSON file of {sessionId: [session updates]} to replay.
`fixture:wait` waits for Stop and `fixture:error` returns a protocol error.
`fixture:long[:N[:M]]` streams one long agentic turn for performance tests: N rounds
(default 3000) as fast as the client reads, then M rounds at a model's streaming pace (see
`stream_long_task`); `fixture:mixed[:N[:M]]` is the same with rows of a real task's varied heights
(see `mixed_round`). `fixture:replay` plays back a recorded session (a trace export or a
session's updates.jsonl, named by CROK_FIXTURE_REPLAY) at its recorded pace (see
`replay_session`).
The ordinary scenario streams Markdown, a plan, and a simulated tool result, and
names any image or resource-link attachments it received. Side questions
(`_x.ai/btw`), the command catalog, MCPs, skills, and goals are also simulated over ACP.
"""

import base64
import json
import os
import queue
import re
import struct
import sys
import tempfile
import threading
import time
import zlib


def fixture_png(width, height, hue):
    """A small gradient PNG, so image fixtures show something recognizable without Pillow."""
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            t = x / max(1, width - 1)
            u = y / max(1, height - 1)
            row += bytes([int(40 + 180 * t) ^ hue & 0xFF, int(60 + 150 * u), int(200 - 120 * t * u) ^ (hue >> 1) & 0xFF])
        rows.append(bytes(row))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")


class MockHarness:
    def __init__(self):
        self.output_lock = threading.Lock()
        self.state_lock = threading.RLock()
        self.authenticated = False
        self.sequence = 0
        self.reverse_sequence = 0
        self.pending = {}
        self.turns = {}
        self.sessions = {
            "fixture-history-001": {
                "sessionId": "fixture-history-001",
                "cwd": os.getcwd(),
                "title": "Explore the desktop harness (fixture)",
                "updatedAt": "2026-09-21T12:00:00Z",
            }
        }
        self.history = {
            "fixture-history-001": [
                {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "Show the desktop workflow."}},
                {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "This is **offline fixture history**. The real app connects to `crok agent stdio`."}},
            ]
        }
        history_file = os.environ.get("CROK_FIXTURE_HISTORY")
        if history_file:
            with open(history_file) as handle:
                self.history.update(json.load(handle))
        self.model_id = "fixture-grok-build"
        self.mode_id = "build"
        self.reasoning_id = "medium"
        self.skill_enabled = True
        self.plugin_skill_enabled = True
        self.mcp_enabled = True
        self.mcp_tool_enabled = True
        self.extra_mcps = {}
        self.deleted_mcps = set()
        self.extra_skills = []
        self.advertised_tools = ["read_fixture", "image_gen", "image_to_video"]
        self.rewind_conflicts = []
        self.goal = None
        self.subagents = {}

    def commands(self):
        commands = [
            {"name": "context", "description": "Inspect fixture context usage"},
            {"name": "fixture-echo", "description": "Echo a harness command offline"},
            {"name": "compact", "description": "Compact fixture context"},
            {"name": "clear", "description": "Clear fixture context"},
            {"name": "goal", "description": "Set or manage a fixture goal", "input": {"hint": "<objective> [--budget <tokens>] | status | pause | resume | clear"}},
            {"name": "mcp", "description": "Manage fixture MCP servers", "input": {"hint": "restart"}},
            {"name": "fixture-fail", "description": "Return a recoverable command error"},
        ]
        if self.skill_enabled:
            commands.append({"name": "fixture-review", "description": "Review a change using the offline skill", "input": {"hint": "change to review"}, "_meta": {"scope": "local", "path": "/fixture/skills/review/SKILL.md"}})
        if self.plugin_skill_enabled:
            commands.append({"name": "fixture-tools:review", "description": "Review with an offline plugin skill", "input": {"hint": "change to review"}, "_meta": {"scope": "plugin", "pluginName": "fixture-tools", "path": "/fixture/plugins/review/SKILL.md"}})
        commands.extend({"name": skill["name"], "description": skill["description"], "_meta": {"scope": skill["scope"], "path": skill["path"]}} for skill in self.extra_skills)
        return commands

    def skills(self):
        return [
            {"name": "fixture-review", "display_name": "Fixture review", "description": "Review a change using the offline skill", "short_description": "Offline review skill", "argument_hint": "change to review", "path": "/fixture/skills/review/SKILL.md", "scope": "local", "enabled": self.skill_enabled, "user_invocable": True, "disable_model_invocation": False, "has_user_specified_description": True},
            {"name": "review", "display_name": "Plugin review", "description": "Review with an offline plugin skill", "path": "/fixture/plugins/review/SKILL.md", "scope": "plugin", "plugin_name": "fixture-tools", "enabled": self.plugin_skill_enabled, "user_invocable": True, "disable_model_invocation": False, "has_user_specified_description": True},
        ] + self.extra_skills

    def mcp_servers(self, session_id):
        entry = {"name": "fixture-files", "displayName": "Fixture files", "source": "local", "type": "stdio", "command": "/fixture/never-executed", "args": []}
        if session_id:
            entry["session"] = {"enabled": self.mcp_enabled, "status": "ready", "tools": [{"name": "read_fixture", "description": "Read offline fixture data", "enabled": self.mcp_tool_enabled}]}
        return [server for name, server in {"fixture-files": entry, **self.extra_mcps}.items() if name not in self.deleted_mcps]

    def extended_update(self, session_id, update):
        with self.state_lock:
            self.history.setdefault(session_id, []).append(update)
        self.emit({"method": "_x.ai/session/update", "params": {"sessionId": session_id, "update": update}})

    def goal_update(self, session_id):
        self.extended_update(session_id, {"sessionUpdate": "goal_updated", **self.goal})

    def slash_prompt(self, session_id, prompt):
        """The real harness resolves advertised slash commands inside session/prompt."""
        name, _, arguments = prompt[1:].partition(" ")
        if name not in [command["name"] for command in self.commands()]:
            raise ValueError("Unknown fixture command: /" + name)
        if name == "fixture-fail":
            raise ValueError("Offline fixture: command execution failed.")
        if name == "goal":
            action = arguments.strip()
            if action not in ("", "status", "pause", "resume", "clear"):
                budget = re.search(r"\s+--budget\s+([1-9][0-9]*)$", action)
                self.goal = {"goal_id": "fixture-goal", "objective": action[:budget.start()] if budget else action,
                             "status": "active", "phase": "executing", "tokens_used": 256, "elapsed_ms": 120,
                             "total_deliverables": 1, "completed_deliverables": 0, "total_worker_rounds": 1,
                             "total_verify_rounds": 0, "token_baseline": 0, "finished_subagent_tokens": 0}
                if budget:
                    self.goal["token_budget"] = int(budget.group(1))
            elif self.goal and action in ("pause", "resume", "clear"):
                self.goal["status"] = {"pause": "user_paused", "resume": "active", "clear": "cleared"}[action]
            if self.goal:
                self.goal_update(session_id)
        self.update(session_id, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Offline fixture command: " + prompt}})

    def spawn_fixture_subagent(self, session_id):
        child = "fixture-child-1"
        self.subagents[child] = {"subagentId": child, "parentSessionId": session_id, "childSessionId": child,
                                "subagentType": "explore", "description": "Inspect offline fixtures",
                                "startedAtEpochMs": 1790000000000, "durationMs": 120, "turnCount": 1,
                                "toolCallCount": 2, "tokensUsed": 480, "contextWindowTokens": 128000,
                                "contextUsagePct": 1, "toolsUsed": ["read_fixture"], "errorCount": 0}
        self.extended_update(session_id, {"sessionUpdate": "subagent_spawned", "subagent_id": child,
            "parent_session_id": session_id, "child_session_id": child, "subagent_type": "explore",
            "description": "Inspect offline fixtures", "agentAddress": "fixture-child-address"})
        self.extended_update(session_id, {"sessionUpdate": "subagent_progress", "subagent_id": child,
            "parent_session_id": session_id, "child_session_id": child, "duration_ms": 120,
            "turn_count": 1, "tool_call_count": 2, "tokens_used": 480, "context_window_tokens": 128000,
            "context_usage_pct": 1, "tools_used": ["read_fixture"], "error_count": 0})

    def finish_fixture_subagent(self, session_id, status="completed"):
        if self.subagents.pop("fixture-child-1", None) is not None:
            self.extended_update(session_id, {"sessionUpdate": "subagent_finished", "subagent_id": "fixture-child-1",
                "child_session_id": "fixture-child-1", "status": status, "tool_calls": 2, "turns": 1,
                "duration_ms": 240, "tokens_used": 480, "output": "Offline fixture inspection completed."})

    @staticmethod
    def mixed_round(index):
        """A round of `fixture:mixed`: like `long_round`, but its rows vary in height as a real
        task's do. Most are a line or two; every few rounds a long plan of reasoning, a reply with a
        table and code, or a tool with a large output comes through."""
        thought, title, output, reply = MockHarness.long_round(index)
        if index % 4 == 0:
            thought = "\n\n".join("**Step {0}.** {1}".format(step + 1, thought) for step in range(12))
        else:
            thought = thought.split(";")[0] + "."
        if index % 7 == 3:
            rows = "\n".join("| module_{0} | {1} | {2} ms | ok |".format(row, (index + row) % 13, (index * row) % 400) for row in range(30))
            code = "\n".join("    let value_{0} = compute({0}, {1});".format(line, index) for line in range(40))
            reply = ("## Round {0} report\n\n{1}\n\n| Module | Warnings | Time | Result |\n|---|---|---|---|\n{2}\n\n"
                     "```rust\nfn round_{0}() {{\n{3}\n}}\n```\n\n{1}").format(index + 1, reply.split("\n")[0], rows, code)
        elif index % 3 == 1:
            reply = reply.split("\n")[0]
        if index % 5 == 2:
            output = "\n".join(output for _ in range(30))
        return thought, title, output, reply

    @staticmethod
    def long_round(index):
        """One agent round of a long task: reasoning, a tool call with output, and a reply."""
        crate = "crate_{}".format(index % 37)
        thought = ("Round {0}: the last run of `{1}` left {2} warnings. Checking whether the change in "
                   "`src/lib.rs` explains them before touching the tests; if not, the fixture's "
                   "constraints point at module {3}, so I will read that next.").format(index + 1, crate, index % 5, index % 11)
        output = "\n".join("test {0}::case_{1:03} ... ok ({2} ms)".format(crate, line, (index * 7 + line) % 90)
                           for line in range(40))
        output += "\n\ntest result: ok. 40 passed; 0 failed; finished in 0.{0:02}s".format(index % 100)
        reply = ("Round {0} passed: **40 tests** in `{1}`. Next I will look at `module_{2}.rs`:\n\n"
                 "- keep the fixture offline\n- compare the warning count\n\n"
                 "```rust\nfn round_{0}() -> usize {{ {0} }}\n```").format(index + 1, crate, index % 11)
        return thought, "Run `cargo test -p {}`".format(crate), output, reply

    def stream_long_task(self, session_id, rounds, paced_rounds, stop, mixed=False):
        """`fixture:long[:N[:M]]`: a long agentic turn. N rounds (3000 by default) stream as fast
        as the client reads them, or each followed by CROK_FIXTURE_ROUND_SECONDS; then M more
        rounds stream at a model's pace, one chunk every CROK_FIXTURE_CHUNK_SECONDS (0.02). Each
        round is three messages: reasoning, a tool call, a reply. With CROK_FIXTURE_DONE_FILE
        set, `<file>.fill` records when the N rounds were sent and `<file>` when all were."""
        done = os.environ.get("CROK_FIXTURE_DONE_FILE")
        def mark(path):
            if done:
                with open(path, "w") as handle:
                    handle.write("{:.3f}\n".format(time.time()))
        pause = float(os.environ.get("CROK_FIXTURE_ROUND_SECONDS", "0"))
        chunk_pause = float(os.environ.get("CROK_FIXTURE_CHUNK_SECONDS", "0.02"))
        for index in range(rounds + paced_rounds):
            if index == rounds and done:
                mark(done + ".fill")
            paced = index >= rounds
            def send(update):
                if paced and stop.wait(chunk_pause):
                    return False
                self.update(session_id, update)
                return not stop.is_set()
            thought, title, output, reply = self.mixed_round(index) if mixed else self.long_round(index)
            tool_id = "long-tool-{}".format(index)
            updates = [{"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": thought[offset:offset + 24]}}
                       for offset in range(0, len(thought), 24)]
            updates.append({"sessionUpdate": "tool_call", "toolCallId": tool_id, "title": title, "kind": "execute", "status": "in_progress", "rawInput": {"round": index}})
            updates.append({"sessionUpdate": "tool_call_update", "toolCallId": tool_id, "status": "completed",
                            "content": [{"type": "content", "content": {"type": "text", "text": output}}]})
            updates += [{"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": reply[offset:offset + 24]}}
                        for offset in range(0, len(reply), 24)]
            for update in updates:
                if not send(update):
                    return False
            if not paced and pause and stop.wait(pause):
                return False
        if paced_rounds == 0 and done:
            mark(done + ".fill")
        mark(done)
        return True

    @staticmethod
    def recorded_updates(path):
        """The session updates a recording holds, in order: a session folder's `updates.jsonl`, a
        JSON list of its records, or a trace export (`/trace` HTML), whose updates.jsonl events
        carry the records as `raw`."""
        with open(path) as handle:
            text = handle.read()
        if path.endswith(".html"):
            found = re.search(r'<script type="application/json" id="trace-data">(.*?)</script>', text, re.S)
            events = json.loads(found.group(1))["events"] if found else []
            records = [event["raw"] for event in sorted(events, key=lambda event: event["index"]) if event.get("source") == "updates.jsonl"]
        elif text.lstrip().startswith("["):
            records = json.loads(text)
        else:
            records = [json.loads(line) for line in text.splitlines() if line.strip()]
        return [record for record in records if isinstance(record.get("params", {}).get("update"), dict)]

    def replay_session(self, session_id, stop):
        """`fixture:replay`: plays a recorded session back as one turn. CROK_FIXTURE_REPLAY names
        the recording (see `recorded_updates`). Updates keep their recorded spacing divided by
        CROK_FIXTURE_REPLAY_SPEED (1 by default; 0 sends them as fast as the client reads), with
        gaps cut to CROK_FIXTURE_REPLAY_MAX_GAP seconds (30). A recording keeps each reply and
        reasoning block as one chunk, so they stream in 24-character pieces, one every
        CROK_FIXTURE_CHUNK_SECONDS (0.02), as a model's output does. The first
        CROK_FIXTURE_REPLAY_FAST_TURNS turns (0) are sent at once, so the recorded pace starts on
        a transcript that is already long. Prompts after the first are left out: the client shows
        the prompts it sends. With CROK_FIXTURE_DONE_FILE set, `<file>` records when the replay ended."""
        records = self.recorded_updates(os.environ["CROK_FIXTURE_REPLAY"])
        speed = float(os.environ.get("CROK_FIXTURE_REPLAY_SPEED", "1"))
        max_gap = float(os.environ.get("CROK_FIXTURE_REPLAY_MAX_GAP", "30"))
        fast_turns = int(os.environ.get("CROK_FIXTURE_REPLAY_FAST_TURNS", "0"))
        def recorded_at(record):
            meta = record["params"].get("_meta") or {}
            return (meta.get("agentTimestampMs") or record.get("timestamp", 0) * 1000) / 1000
        started = time.time()
        schedule = 0.0
        previous = recorded_at(records[0]) if records else 0
        turns = 0
        for record in records:
            update = dict(record["params"]["update"])
            kind = update.get("sessionUpdate")
            if kind == "turn_completed":
                turns += 1
            if kind == "user_message_chunk":
                continue
            at = recorded_at(record)
            fast = turns < fast_turns
            if fast or not at:
                previous = at or previous
                started = time.time() - schedule / speed if speed > 0 else started
            else:
                schedule += min(max(0.0, at - previous), max_gap)
                previous = at
            if speed > 0 and not fast and stop.wait(max(0.0, started + schedule / speed - time.time())):
                return False
            chunk_pause = float(os.environ.get("CROK_FIXTURE_CHUNK_SECONDS", "0.02")) if speed > 0 and not fast else 0
            method = "_x.ai/session/update" if record.get("method", "").startswith("_") else "session/update"
            text = (update.get("content") or {}).get("text") if kind in ("agent_message_chunk", "agent_thought_chunk") else None
            pieces = [text[offset:offset + 24] for offset in range(0, len(text), 24)] if text and not fast else [None]
            for piece in pieces:
                if piece is not None:
                    update = dict(update, content={"type": "text", "text": piece})
                with self.state_lock:
                    self.history.setdefault(session_id, []).append(update)
                self.emit({"method": method, "params": {"sessionId": session_id, "update": update}})
                if stop.wait(chunk_pause) if chunk_pause else stop.is_set():
                    return False
        done = os.environ.get("CROK_FIXTURE_DONE_FILE")
        if done:
            with open(done, "w") as handle:
                handle.write("{:.3f}\n".format(time.time()))
        return True

    def emit(self, message):
        with self.output_lock:
            try:
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False) + "\n")
                sys.stdout.flush()
            except BrokenPipeError:
                os._exit(0)

    def result(self, request_id, value):
        self.emit({"id": request_id, "result": value})

    def error(self, request_id, code, message):
        self.emit({"id": request_id, "error": {"code": code, "message": message}})

    def update(self, session_id, update, remember=True):
        if remember:
            with self.state_lock:
                self.history.setdefault(session_id, []).append(update)
        self.emit({"method": "session/update", "params": {"sessionId": session_id, "update": update}})

    def models(self):
        return {
            "currentModelId": self.model_id,
            "availableModels": [
                {"modelId": "fixture-grok-build", "name": "Grok Build (fixture)", "_meta": {"supportsReasoningEffort": True, "reasoningEffort": self.reasoning_id, "reasoningEfforts": ["low", "medium", "high"]}},
                {"modelId": "fixture-grok-fast", "name": "Grok Fast (fixture)", "_meta": {"supportsReasoningEffort": True, "reasoningEffort": self.reasoning_id, "reasoningEfforts": ["low", "medium", "high"]}},
            ],
        }

    def config_options(self):
        return [
            {"id": "model", "type": "select", "currentValue": self.model_id, "options": [
                {"value": model["modelId"], "name": model["name"]} for model in self.models()["availableModels"]]},
            {"id": "reasoning_effort", "type": "select", "currentValue": self.reasoning_id, "options": [
                {"value": value, "name": value.title()} for value in ["low", "medium", "high"]]},
        ]

    def session_state(self):
        return {
            "models": self.models(),
            "configOptions": self.config_options(),
            "modes": {"currentModeId": self.mode_id, "availableModes": [
                {"id": "build", "name": "Build"}, {"id": "plan", "name": "Plan"},
            ]},
        }

    def ask(self, session_id, method, params, stop):
        with self.state_lock:
            self.reverse_sequence += 1
            request_id = "fixture-request-{}".format(self.reverse_sequence)
            replies = queue.Queue(maxsize=1)
            self.pending[request_id] = replies
        self.emit({"id": request_id, "method": method, "params": {"sessionId": session_id, **params}})
        try:
            while not stop.is_set():
                try:
                    reply = replies.get(timeout=0.05)
                    if "error" in reply:
                        return {"outcome": "unsupported"}
                    return reply.get("result", {})
                except queue.Empty:
                    pass
            return {"outcome": "cancelled"}
        finally:
            with self.state_lock:
                self.pending.pop(request_id, None)

    def stream_image_fixture(self, session_id, request_id):
        """A read of an image file (image content), then a generated image (a saved file)."""
        folder = tempfile.mkdtemp(prefix="crok-fixture-images-")
        screenshot = os.path.join(folder, "screenshot.png")
        with open(screenshot, "wb") as handle:
            handle.write(fixture_png(240, 160, 0))
        generated = os.path.join(folder, "1.png")
        with open(generated, "wb") as handle:
            handle.write(fixture_png(320, 320, 0x5A))
        read_id = "fixture-read-image-{}".format(request_id)
        self.update(session_id, {"sessionUpdate": "tool_call", "toolCallId": read_id, "title": "Read `screenshot.png`", "kind": "read", "status": "in_progress",
                                 "rawInput": {"target_file": screenshot}})
        image = {"type": "image", "data": base64.b64encode(fixture_png(240, 160, 0)).decode("ascii"), "mimeType": "image/png", "uri": "file://" + screenshot}
        self.update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": read_id, "status": "completed", "content": [{"type": "content", "content": image}]})
        gen_id = "fixture-image-gen-{}".format(request_id)
        self.update(session_id, {"sessionUpdate": "tool_call", "toolCallId": gen_id, "title": "Generate image", "kind": "other", "status": "in_progress",
                                 "rawInput": {"prompt": "A calm gradient"}})
        self.update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": gen_id, "status": "completed",
                                 "content": [{"type": "content", "content": {"type": "text", "text": "Image generated and saved to {}.".format(generated)}}],
                                 "rawOutput": {"type": "ImageGen", "path": generated, "filename": "1.png", "session_folder": "images"}})

    def prompt(self, request_id, params, stop):
        session_id = params["sessionId"]
        blocks = params.get("prompt", [])
        prompt = "".join(block.get("text", "") for block in blocks if block.get("type") == "text")
        attachments = [block for block in blocks if block.get("type") in ("image", "resource_link")]
        def finish(stop_reason):
            # Remove the old turn before replying so an immediate next prompt is
            # never rejected merely because the worker is finishing its cleanup.
            with self.state_lock:
                if self.turns.get(session_id) is stop:
                    self.turns.pop(session_id, None)
            self.result(request_id, {"stopReason": stop_reason})
        try:
            if prompt.startswith("/"):
                try:
                    self.slash_prompt(session_id, prompt)
                    finish("end_turn")
                except ValueError as error:
                    self.error(request_id, -32602, str(error))
                return
            if "fixture:error" in prompt:
                self.error(request_id, -32000, "Offline fixture: a recoverable harness error.")
                return
            # Like the harness, echo each prompt block so session/load replays attachments.
            for block in blocks:
                self.update(session_id, {"sessionUpdate": "user_message_chunk", "content": block})
            self.update(session_id, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Preparing the offline desktop fixture."}})
            long_run = re.search(r"fixture:(long|mixed)(?::(\d+))?(?::(\d+))?", prompt)
            if long_run:
                if self.stream_long_task(session_id, int(long_run.group(2) or 3000), int(long_run.group(3) or 0), stop,
                                         mixed=long_run.group(1) == "mixed"):
                    finish("end_turn")
                else:
                    finish("cancelled")
                return
            if "fixture:replay" in prompt:
                finish("end_turn" if self.replay_session(session_id, stop) else "cancelled")
                return
            if "fixture:think" in prompt:
                seconds = float(os.environ.get("CROK_FIXTURE_THINK_SECONDS", "8"))
                lines = max(1, int(seconds / 0.2))
                for line in range(lines):
                    text = "\n\n**Step {}.** Weighing option {} against the fixture's constraints; checking the next file and noting what changes.".format(line + 1, line % 7 + 1)
                    for offset in range(0, len(text), 16):
                        if stop.wait(0.2 * 16 / len(text)):
                            finish("cancelled")
                            return
                        self.update(session_id, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": text[offset:offset + 16]}})
            if "fixture:image" in prompt:
                self.stream_image_fixture(session_id, request_id)
            self.update(session_id, {"sessionUpdate": "plan", "entries": [
                {"content": "Inspect the fixture", "priority": "medium", "status": "in_progress"},
                {"content": "Summarize the result", "priority": "medium", "status": "pending"},
            ]})
            tool_id = "fixture-tool-{}".format(request_id)
            self.update(session_id, {"sessionUpdate": "tool_call", "toolCallId": tool_id, "title": "Preview desktop fixture", "kind": "read", "status": "in_progress", "rawInput": {"fixture": True}})
            if "fixture:subagents" in prompt:
                self.spawn_fixture_subagent(session_id)
            interaction = None
            if "fixture:permission" in prompt:
                interaction = self.ask(session_id, "session/request_permission", {
                    "toolCall": {"toolCallId": tool_id, "title": "Allow the simulated fixture tool?", "rawInput": {"fixture": True, "command": "No command will execute"}},
                    "options": [
                        {"optionId": "deny", "name": "Decline", "kind": "reject_once"},
                        {"optionId": "allow", "name": "Allow once", "kind": "allow_once"},
                    ],
                }, stop)
            if "fixture:question" in prompt and not stop.is_set():
                interaction = self.ask(session_id, "x.ai/ask_user_question", {
                    "toolCallId": tool_id, "mode": "default",
                    "questions": [{"question": "Which fixture should we explore?", "header": "Preview", "multiSelect": False, "options": [
                        {"label": "Conversation", "description": "Review the streamed conversation."},
                        {"label": "Changes", "description": "Review the workspace inspector."},
                    ]}],
                }, stop)
            if "fixture:plan" in prompt and not stop.is_set():
                interaction = self.ask(session_id, "x.ai/exit_plan_mode", {
                    "toolCallId": tool_id,
                    "planContent": "# Offline fixture plan\n\n1. Show the approval UI.\n2. Return a simulated result.\n\nNo project files will change.",
                }, stop)
            if "fixture:trust" in prompt and not stop.is_set():
                cwd = self.sessions[session_id]["cwd"]
                interaction = self.ask(session_id, "x.ai/folder_trust/request", {"cwd": cwd, "workspace": cwd, "configKinds": ["mcp", "hooks"]}, stop)
            if "fixture:wait" in prompt:
                stop.wait(30)
            if stop.is_set():
                self.finish_fixture_subagent(session_id, "cancelled")
                self.update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": tool_id, "status": "failed"})
                finish("cancelled")
                return
            detail = "Offline fixture completed. No commands were executed and no files were changed."
            if interaction is not None:
                detail += "\nClient reply: " + json.dumps(interaction, sort_keys=True)
            self.update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": tool_id, "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": detail}}]})
            answer = "## Ready to build\n\nThis is an **offline test fixture**, connected over the same ACP transport as Crok Build.\n\n- Streamed conversation and tool activity\n- Project-scoped tasks and session history\n- Native approvals, model selection, and workspace changes\n\n```swift\nlet nextStep = \"Build something useful\"\n```\n\nThe installed app uses its bundled Crok runtime automatically."
            if attachments:
                names = ", ".join(block.get("name") or block.get("mimeType", "image") for block in attachments)
                answer += "\n\nReceived {} attachment(s): {}.".format(len(attachments), names)
            for offset in range(0, len(answer), 28):
                if stop.wait(0.012):
                    finish("cancelled")
                    return
                self.update(session_id, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": answer[offset:offset + 28]}})
            self.update(session_id, {"sessionUpdate": "plan", "entries": [
                {"content": "Inspect the fixture", "priority": "medium", "status": "completed"},
                {"content": "Summarize the result", "priority": "medium", "status": "completed"},
            ]})
            self.finish_fixture_subagent(session_id)
            finish("end_turn")
        finally:
            with self.state_lock:
                if self.turns.get(session_id) is stop:
                    self.turns.pop(session_id, None)

    def handle(self, message):
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params", {})
        if method is None:
            with self.state_lock:
                replies = self.pending.get(request_id)
            if replies is not None:
                replies.put_nowait(message)
            return
        if method == "initialize":
            self.result(request_id, {"protocolVersion": 1, "agentInfo": {"name": "grok-desktop-fixture", "version": "1.0.0"}, "agentCapabilities": {"loadSession": True, "sessionCapabilities": {"list": {}}}, "authMethods": [{"id": "xai.api_key", "name": "Provider credentials"}], "_meta": {"defaultAuthMethodId": "xai.api_key", "modelState": self.models()}})
        elif method == "authenticate":
            # Like the harness, only the provider-credential method is accepted.
            if params.get("methodId") != "xai.api_key":
                self.error(request_id, -32602, "Unsupported auth method: %s" % params.get("methodId"))
                return
            self.authenticated = True
            self.result(request_id, {})
        elif method == "session/cancel":
            with self.state_lock:
                stop = self.turns.get(params.get("sessionId"))
            if stop is not None:
                if self.goal and self.goal["status"] == "active":
                    self.goal["status"] = "user_paused"
                    self.goal_update(params["sessionId"])
                stop.set()
        elif not self.authenticated:
            self.error(request_id, -32000, "Authenticate the offline fixture first.")
        elif method == "_x.ai/models/list":
            self.result(request_id, {"result": self.models()})
        elif method == "_x.ai/commands/list":
            if params.get("sessionId") and params["sessionId"] not in self.sessions:
                self.error(request_id, -32602, "Unknown fixture session.")
                return
            self.result(request_id, {"commands": self.commands(), "tools": self.advertised_tools})
        elif method == "_x.ai/skills/list":
            if not os.path.isabs(params.get("cwd", "")):
                self.error(request_id, -32602, "skills/list requires an absolute cwd.")
                return
            self.result(request_id, {"result": {"skills": self.skills()}})
        elif method == "_x.ai/skills/toggle":
            if params.get("name") not in ("fixture-review", "review") or not isinstance(params.get("enabled"), bool):
                self.error(request_id, -32602, "Unknown skill or missing enabled value.")
                return
            if params["name"] == "fixture-review":
                self.skill_enabled = params["enabled"]
            else:
                self.plugin_skill_enabled = params["enabled"]
            for session_id in self.sessions:
                self.update(session_id, {"sessionUpdate": "available_commands_update", "availableCommands": self.commands(), "_meta": {"tools": self.advertised_tools}}, remember=False)
            self.result(request_id, {"result": {"skills": self.skills()}})
        elif method == "_x.ai/skills/add":
            path = params.get("path", "")
            if not path or not os.path.isabs(params.get("cwd", "")):
                self.error(request_id, -32602, "skills/add requires a path and absolute cwd.")
                return
            skill_path = path if path.endswith("SKILL.md") else os.path.join(path, "SKILL.md")
            name = os.path.basename(os.path.dirname(skill_path))
            self.extra_skills.append({"name": name, "description": "Added offline fixture skill", "path": skill_path, "scope": "user", "enabled": True, "user_invocable": True})
            self.result(request_id, {"result": {"addedCount": 1, "total": len(self.skills()), "path": path, "skills": self.skills(), "message": "Offline fixture skill added."}})
        elif method == "_x.ai/mcp/list":
            session_id = params.get("sessionId")
            if session_id and session_id not in self.sessions:
                self.error(request_id, -32602, "Unknown fixture session.")
                return
            self.result(request_id, {"result": {"servers": self.mcp_servers(session_id), "sessionMcpResolved": bool(session_id)}})
        elif method == "_x.ai/mcp/toggle":
            # Unlike list, the Rust toggle request deliberately uses snake_case.
            session_id = params.get("session_id")
            if session_id not in self.sessions or params.get("server_name") != "fixture-files" or not isinstance(params.get("enabled"), bool):
                self.error(request_id, -32602, "mcp/toggle requires session_id, server_name, and enabled.")
                return
            self.mcp_enabled = params["enabled"]
            self.emit({"method": "_x.ai/mcp/servers_updated", "params": {"sessionId": session_id}})
            self.result(request_id, {"result": {"ok": True}})
        elif method == "_x.ai/mcp/toggle_tool":
            if params.get("session_id") not in self.sessions or params.get("server_name") != "fixture-files" or params.get("tool_name") != "read_fixture" or not isinstance(params.get("enabled"), bool):
                self.error(request_id, -32602, "mcp/toggle_tool requires session_id, server_name, tool_name, and enabled.")
                return
            self.mcp_tool_enabled = params["enabled"]
            self.result(request_id, {"result": {"ok": True}})
        elif method == "_x.ai/mcp/upsert":
            name = params.get("server_name")
            if params.get("session_id") not in self.sessions or not name or not (params.get("command") or params.get("url")):
                self.error(request_id, -32602, "mcp/upsert requires session_id, server_name, and flattened connection details.")
                return
            server = {"name": name, "source": "local", "session": {"enabled": params.get("enabled", True), "status": "ready", "tools": []}}
            if params.get("url"):
                server.update({"type": "http", "url": params["url"]})
            else:
                server.update({"type": "stdio", "command": params["command"], "args": params.get("args", [])})
            self.extra_mcps[name] = server
            self.deleted_mcps.discard(name)
            self.result(request_id, {"result": {"ok": True}})
        elif method == "_x.ai/mcp/delete":
            name = params.get("server_name")
            if params.get("session_id") not in self.sessions or not name:
                self.error(request_id, -32602, "mcp/delete requires session_id and server_name.")
                return
            self.deleted_mcps.add(name)
            self.result(request_id, {"result": {"ok": True}})
        elif method == "_x.ai/subagent/list_running":
            if params.get("sessionId") not in self.sessions:
                self.error(request_id, -32602, "subagent/list_running requires a sessionId.")
                return
            self.result(request_id, {"result": {"subagents": [row for row in self.subagents.values() if row["parentSessionId"] == params["sessionId"]]}})
        elif method == "_x.ai/subagent/cancel":
            child = self.subagents.get(params.get("subagentId"))
            if child:
                self.finish_fixture_subagent(child["parentSessionId"], "cancelled")
            self.result(request_id, {"result": {"subagentId": params.get("subagentId"), "cancelled": child is not None, "outcome": {"kind": "cancelled" if child else "not_found"}}})
        elif method == "_x.ai/subagent/message":
            if params.get("sessionId") not in self.sessions or params.get("agentAddress") != "fixture-child-address":
                self.result(request_id, {"result": {"kind": "rejected"}})
            else:
                self.result(request_id, {"result": {"kind": "accepted", "messageId": "fixture-steering-message"}})
        elif method == "_x.ai/bundle/status":
            self.result(request_id, {"result": {"hasCache": True, "version": "fixture-1", "agents": ["fixture-explorer"],
                "personas": ["fixture-researcher"], "roles": [], "skills": [],
                "personaDetails": [{"name": "fixture-researcher", "description": "Investigate offline fixture data", "hasInputs": False, "hasOutputs": False}]}})
        elif method == "_x.ai/bundle/entry/get":
            if (params.get("kind"), params.get("name")) not in [("agent", "fixture-explorer"), ("persona", "fixture-researcher")]:
                self.result(request_id, {"result": None, "error": "Unknown fixture bundle entry."})
                return
            self.result(request_id, {"result": {"kind": params["kind"], "name": params["name"], "content": "# Offline fixture agent\n\nInspect simulated data only."}})
        elif method == "_x.ai/btw":
            if params.get("sessionId") not in self.sessions or not params.get("question"):
                self.error(request_id, -32602, "btw requires a sessionId and a question.")
                return
            question = params["question"].rsplit("New side question: ", 1)[-1]
            self.result(request_id, {"result": {"answer": "Offline fixture side answer to: " + question}})
        elif method == "_x.ai/recap":
            session_id = params.get("sessionId")
            if session_id not in self.sessions:
                self.error(request_id, -32602, "recap requires a sessionId.")
                return
            self.result(request_id, {"result": {"ok": True}})
            self.extended_update(session_id, {"sessionUpdate": "session_recap", "summary": "Offline fixture recap: reviewed the desktop command workflow.", "auto": params.get("auto", False)})
        elif method == "_x.ai/rewind/points":
            if params.get("sessionId") not in self.sessions:
                self.error(request_id, -32602, "rewind/points requires a sessionId.")
                return
            self.result(request_id, {"rewind_points": [{"prompt_index": 0, "created_at": "2026-09-22T12:00:00Z", "num_file_snapshots": 1, "has_file_changes": True, "prompt_preview": "Original fixture prompt"}]})
        elif method == "_x.ai/rewind/execute":
            session_id = params.get("sessionId")
            mode = params.get("mode")
            if session_id not in self.sessions or params.get("targetPromptIndex") != 0 or mode not in ("conversation_only", "files_only", "all"):
                self.error(request_id, -32602, "rewind/execute requires sessionId, targetPromptIndex, and a supported mode.")
                return
            if not params.get("force", False):
                conflicts = [] if mode == "conversation_only" else self.rewind_conflicts
                self.result(request_id, {"success": False, "target_prompt_index": 0, "mode": mode, "reverted_files": [], "clean_files": [] if mode == "conversation_only" or conflicts else ["fixture.txt"], "conflicts": conflicts, "prompt_text": None, "error": "External modifications detected. Confirm to revert anyway." if conflicts else None})
                return
            if mode != "files_only":
                self.history[session_id] = [{"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "Original fixture prompt"}}]
            self.result(request_id, {"success": True, "target_prompt_index": 0, "mode": mode, "reverted_files": [], "clean_files": [], "conflicts": [], "prompt_text": "Original fixture prompt", "error": None})
        elif method == "session/list":
            sessions = [session for session in self.sessions.values() if not params.get("cwd") or params["cwd"] == session["cwd"]]
            self.result(request_id, {"sessions": sessions})
        elif method in ("session/new", "session/load"):
            if method == "session/new":
                self.sequence += 1
                session_id = "fixture-session-{}-{}".format(os.getpid(), self.sequence)
            else:
                session_id = params.get("sessionId")
            if not session_id or not os.path.isabs(params.get("cwd", "")):
                self.error(request_id, -32602, "An absolute cwd and session ID are required.")
                return
            self.sessions.setdefault(session_id, {"sessionId": session_id, "cwd": params["cwd"], "title": "Desktop task (fixture)", "updatedAt": "2026-09-21T12:00:00Z"})
            if method == "session/load":
                time.sleep(float(os.environ.get("CROK_FIXTURE_LOAD_DELAY", "0")))
                for update in list(self.history.get(session_id, [])):
                    self.update(session_id, update, remember=False)
            self.update(session_id, {"sessionUpdate": "available_commands_update", "availableCommands": self.commands(), "_meta": {"tools": self.advertised_tools}}, remember=False)
            self.result(request_id, {"sessionId": session_id, **self.session_state()})
        elif method in ("session/set_model", "session/set_mode", "session/set_config_option", "session/prompt"):
            session_id = params.get("sessionId")
            if session_id not in self.sessions:
                self.error(request_id, -32602, "Unknown fixture session.")
                return
            if method == "session/set_config_option":
                config_id = params.get("configId")
                value = params.get("value")
                option = next((item for item in self.config_options() if item["id"] == config_id), None)
                if option is None or value not in [choice["value"] for choice in option["options"]]:
                    self.error(request_id, -32602, "Unsupported fixture setting.")
                    return
                if config_id == "model":
                    self.model_id = value
                else:
                    self.reasoning_id = value
                self.update(session_id, {"sessionUpdate": "config_option_update", "configOptions": self.config_options()}, remember=False)
                self.result(request_id, {"configOptions": self.config_options()})
            elif method == "session/set_model":
                self.model_id = params["modelId"]
                self.result(request_id, {})
            elif method == "session/set_mode":
                self.mode_id = params["modeId"]
                self.update(session_id, {"sessionUpdate": "current_mode_update", "currentModeId": self.mode_id}, remember=False)
                self.result(request_id, {})
            else:
                with self.state_lock:
                    if session_id in self.turns:
                        self.error(request_id, -32600, "A fixture turn is already running.")
                        return
                    stop = threading.Event()
                    self.turns[session_id] = stop
                threading.Thread(target=self.prompt, args=(request_id, params, stop), daemon=True).start()
        elif request_id is not None:
            self.error(request_id, -32601, "Unsupported fixture method: " + method)

    def run(self):
        for line in sys.stdin:
            try:
                self.handle(json.loads(line))
            except (ValueError, KeyError, TypeError) as error:
                self.error(None, -32600, "Invalid fixture request: " + str(error))


if __name__ == "__main__":
    if sys.argv[1:] == ["agent", "stdio"]:
        MockHarness().run()
    elif sys.argv[1:] and sys.argv[1] == "login":
        print("Offline fixture: authentication is simulated. No credentials were used.")
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
