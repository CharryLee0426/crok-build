#!/usr/bin/env python3
"""Offline ACP fixture for Grok Desktop tests and manual UI inspection.

Launch with GROK_DESKTOP_HARNESS pointing to this executable. It never runs tools, writes
project files, contacts a service, or reads credentials. Every response is marked
as fixture data. Prompts containing `fixture:permission`, `fixture:question`,
`fixture:plan`, or `fixture:trust` display the corresponding interaction;
`fixture:subagents` streams a simulated child agent lifecycle.
`fixture:wait` waits for Stop and `fixture:error` returns a protocol error.
The ordinary scenario streams Markdown, a plan, and a simulated tool result, and
names any image or resource-link attachments it received. Side questions
(`_x.ai/btw`), the command catalog, MCPs, skills, and goals are also simulated over ACP.
"""

import json
import os
import queue
import re
import sys
import threading


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
                {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "This is **offline fixture history**. The real app connects to `grok agent stdio`."}},
            ]
        }
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
            answer = "## Ready to build\n\nThis is an **offline test fixture**, connected over the same ACP transport as Grok Build.\n\n- Streamed conversation and tool activity\n- Project-scoped tasks and session history\n- Native approvals, model selection, and workspace changes\n\n```swift\nlet nextStep = \"Build something useful\"\n```\n\nThe installed app uses its bundled Grok runtime automatically."
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
