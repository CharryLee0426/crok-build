#!/usr/bin/env python3
"""Writes a Crok Desktop state file holding one long task, for launch and task-switch tests.

    make-long-state.py <out-dir> [rounds=3000] [short-tasks=30] [--select long|short]

<out-dir> gets `state.json` (CROK_DESKTOP_STATE_FILE), `history.json` (CROK_FIXTURE_HISTORY:
the same transcript as harness history, so `session/load` replays what the app already has)
and `project/`, the task's folder. The rounds are the ones `fixture:long` streams, so a saved
task and a streamed one look alike.
"""

import importlib.util
import json
import os
import subprocess
import sys
import uuid

here = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("mock", os.path.join(here, "../../Tests/Fixtures/mock-grok.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

args = [a for a in sys.argv[1:] if not a.startswith("--")]
out = os.path.abspath(args[0])
rounds = int(args[1]) if len(args) > 1 else 3000
short_tasks = int(args[2]) if len(args) > 2 else 30
select = sys.argv[sys.argv.index("--select") + 1] if "--select" in sys.argv else "long"

os.makedirs(os.path.join(out, "project"), exist_ok=True)
if not os.path.isdir(os.path.join(out, "project", ".git")):
    subprocess.run(["git", "init", "-q", os.path.join(out, "project")], check=True)

def uid():
    return str(uuid.uuid4()).upper()

# Swift's default Date encoding: seconds since 2001-01-01.
reference = 978307200.0
now = 812_000_000.0
project_id = uid()

def message(kind, text, **extra):
    value = {"id": uid(), "kind": kind, "text": text}
    value.update(extra)
    return value

def long_task(session_id, rounds):
    messages = [message("user", "fixture:long:{} Run the whole test suite, fix what fails, repeat.".format(rounds), createdAt=now - 7200)]
    history = [{"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": messages[0]["text"]}}]
    for index in range(rounds):
        thought, title, output, reply = mock.MockHarness.long_round(index)
        at = now - 7200 + index * 2.4
        messages.append(message("thought", thought, createdAt=at))
        messages.append(message("tool", title, toolID="long-tool-{}".format(index), status="completed", detail=output, createdAt=at + 1))
        messages.append(message("assistant", reply, createdAt=at + 2))
        history += [
            {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": thought}},
            {"sessionUpdate": "tool_call", "toolCallId": "long-tool-{}".format(index), "title": title, "status": "completed",
             "content": [{"type": "content", "content": {"type": "text", "text": output}}]},
            {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": reply}},
        ]
    return messages, history

def conversation(title, session_id, messages, updated):
    return {"id": uid(), "projectID": project_id, "title": title, "sessionID": session_id, "messages": messages,
            "updatedAt": updated, "isArchived": False, "isPinned": False}

history = {}
long_messages, history["perf-long"] = long_task("perf-long", rounds)
conversations = [conversation("Long task ({} rounds)".format(rounds), "perf-long", long_messages, now)]
for index in range(short_tasks):
    session = "perf-short-{}".format(index)
    messages, history[session] = long_task(session, 3)
    conversations.append(conversation("Short task {}".format(index + 1), session, messages, now - 60 * (index + 1)))

state = {
    "projects": [{"id": project_id, "path": os.path.join(out, "project")}],
    "conversations": conversations,
    "selectedProjectID": project_id,
    "selectedConversationID": conversations[0 if select == "long" else 1]["id"],
    "deletedSessionIDs": [],
    "collapsedProjectIDs": [],
}
with open(os.path.join(out, "state.json"), "w") as f:
    json.dump(state, f)
with open(os.path.join(out, "history.json"), "w") as f:
    json.dump(history, f)
print("{}: {} messages in the long task, {:.1f} MB state".format(out, len(long_messages), os.path.getsize(os.path.join(out, "state.json")) / 1e6))
