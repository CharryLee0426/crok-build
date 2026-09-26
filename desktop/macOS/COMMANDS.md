# Grok Build command inventory and desktop routing

Audited against this checkout on 2026-09-23. This is a source inventory and
integration contract. The running harness remains authoritative for feature,
tool, account, project-trust, plugin, and skill availability.

## Sources of truth

- [Shell slash catalog and resolver](../../crates/codegen/xai-grok-shell/src/session/slash_commands.rs): built-ins, gates, aliases, skill collision handling, saved workflows, and `commands/list` types.
- [Pager command registration](../../crates/codegen/xai-grok-pager/src/slash/commands/mod.rs): every registered terminal slash action; individual modules supply syntax and aliases.
- [Pager slash guide](../../crates/codegen/xai-grok-pager/docs/user-guide/04-slash-commands.md): user-facing terminal semantics.
- [CLI command tree](../../crates/codegen/xai-grok-pager/src/app/cli.rs): process-level commands, distinct from conversation slash commands.
- [ACP extension dispatch](../../crates/codegen/xai-grok-shell/src/agent/mvp_agent/acp_agent.rs), [extension result envelope](../../crates/codegen/xai-grok-shell/src/session/result.rs), and [session notifications](../../crates/codegen/xai-grok-shell/src/extensions/notification.rs).

## Desktop routing contract

The composer should merge native actions with the live harness command catalog.
Typing `/` opens a searchable list with descriptions, argument hints, and source
badges. Selecting a command with arguments inserts it into the composer; execution
is a separate submit action. Native management commands open their corresponding
panels. Only recognized harness commands and explicitly authored ordinary prompts
go to `session/prompt`; pager-only commands must not silently become model prompts.

Fetch `_x.ai/commands/list` with `{ "cwd": "/project" }` before session creation
and `{ "sessionId": "id" }` afterward. The response is **raw**
`{ "commands": [...], "tools": [...] }`, unlike many wrapped extension responses.
Consume `session/update` with `sessionUpdate: "available_commands_update"` as a
full catalog replacement, including commands removed by a model or skill change.
That update's `_meta.tools` is the current tool set. Each command supplies
`name`, `description`, optional `input.hint`, and optional `_meta` provenance:
`scope`, `path`, `bareName`, `pluginName`, or `workflowSource`.

Rust extension method names omit the leading underscore. Their JSON-RPC wire
names use `_x.ai/...`; standard ACP methods such as `session/set_mode` do not.
Most management methods return JSON-RPC `result` containing another
`{ "result": <payload>, "error": <optional string or object> }` envelope. Check
both error layers. Do not manufacture success on empty or unsupported responses.

Native action names take precedence over conflicting unqualified names; keep
qualified skill entries usable. Shell built-ins reserve their names and the
pager's names, so a skill named `compact` is advertised as e.g. `local:compact`.
Use the advertised name verbatim when invoking a skill or workflow.

## Shell commands available through `session/prompt`

The catalog contains the following potential built-ins. Entries with a gate are
only available when advertised by the current harness. Aliases are accepted by
the resolver but are not separate advertised entries.

| Command and aliases | Arguments / effect | Availability |
| --- | --- | --- |
| `/compact` | Optional instructions about context to preserve | Always |
| `/always-approve`, `/yolo` | `on` or `off`; enables or disables permission bypass | Always |
| `/flush` | Flush conversation memory to disk | Memory enabled |
| `/dream` | Consolidate stored memory | Memory enabled |
| `/memory`, `/mem` | Browse memory; desktop may open a native memory panel | Memory configured |
| `/context` | No-op in the shell; the desktop shows context natively from `_x.ai/session/info` | Always |
| `/hooks-trust` | Trust current project for hook execution | Hooks |
| `/hooks-list` | List loaded hooks | Hooks |
| `/hooks-add` | Hook file or directory path | Hooks |
| `/hooks-remove` | Previously configured hook path | Hooks |
| `/hooks-untrust` | Remove current project trust | Hooks |
| `/plugins`, `/plugin` | `list`, `reload`, `trust`, `add <path>`, `remove <path>` | Plugins |
| `/plugins install` | `<source> [--trust]` | Plugins |
| `/plugins uninstall` | `<name> [--confirm]` | Plugins |
| `/plugins update` | Optional plugin name; omission updates all | Plugins |
| `/reload-plugins` | Alias action for `/plugins reload` | Plugins |
| `/session-info`, `/status`, `/info` | Model, turns, context, session details | Always |
| `/feedback` | Feedback text | Feedback |
| `/deep-research` | Research query | Workflow launches |
| `/workflow` | `<name> [input]`; or `runs`, `pause <run>`, `resume <run>`, `stop <run>`, `save <run>` | Workflow launch or retained-run management |
| `/goal` | `<objective> [--budget <positive tokens>]`; or `status`, `pause`, `resume`, `clear` | Goal |
| `/loop` | `[interval] <prompt>`; transformed into scheduler instructions | Scheduler |
| `/<advertised-skill>` | Skill arguments; supports qualified scopes/plugins | Enabled, user-invocable skill |
| `/<advertised-workflow>` | Workflow launch arguments | Workflow launches |

The plugin resolver recognizes install/uninstall/update even though its advertised
argument hint only lists the first five operations. A budget flag is parsed only
as a valid positive integer at the end of a goal objective. Bare `/goal` is status.
Named workflows accept `--agent-budget N` and `--effort LEVEL`; the shell validates
launch input. A bare workflow resume cannot increase an exhausted agent budget.

## Pager command inventory and desktop behavior

This table enumerates every registered pager command, including hidden and debug
entries and the two screen-mode commands. Every command has a desktop
implementation: native windows and sheets for panels and pickers, native toggles
for preferences, and the same harness methods, files, and messages the terminal
uses. **Harness** means the command is forwarded as a prompt because the shell
implements it. Desktop preferences that the terminal also reads (`[ui]` keys,
`[models]` defaults, `[agent]`, `[subagents.toggle]`, `[hints]`) are written to
`$GROK_HOME/config.toml` one key at a time, keeping the rest of the file intact.

While a turn is streaming, native panels and toggles still open at once;
prompts, skills, and harness commands wait in the queue (see `/queue`); and the
few commands that need an idle task (`/plan`, `/imagine`, `/imagine-video`,
`/flush`, `/dream`, `/rewind`, `/fork`, `/delete`, and `/model` or `/effort`
with an argument) keep your draft and ask you to wait or stop the turn.

The registry contains 72 pager commands. `/login` is desktop-only: the terminal
signs in with `grok login <provider>` instead. xAI accounts are not supported, so
there is no `/logout` or `/privacy`, and `/usage` has no billing.

| Command (source) | Aliases | Syntax | Desktop behavior |
| --- | --- | --- | --- |
| [`/always-approve`](../../crates/codegen/xai-grok-pager/src/slash/commands/always_approve.rs) | `/yolo` (shell) | `/always-approve [on\|off]` | Native: composer permission menu; sends `_x.ai/yolo_mode_changed` to every task, saves `[ui].permission_mode`, answers waiting permission requests once enabled |
| [`/announcements`](../../crates/codegen/xai-grok-pager/src/slash/commands/announcements.rs) | — | `/announcements hide \| show` | Native: banner from `_x.ai/announcements/update` with CTA and Hide; hidden ids shared through `$GROK_HOME/announcements.json`; listed only while announcements exist |
| [`/auto`](../../crates/codegen/xai-grok-pager/src/slash/commands/auto.rs) | — | `/auto` | Native: toggles Auto ↔ Ask via the permission menu; honours the Auto gate from env, config, and `x.ai/settings/update` |
| [`/btw`](../../crates/codegen/xai-grok-pager/src/slash/commands/btw.rs) | — | `/btw <question>` | Asks in the side panel's Side chat over `_x.ai/btw`; runs while the main turn continues, and each task keeps its thread. Bare `/btw` opens the Side chat |
| [`/cd`](../../crates/codegen/xai-grok-pager/src/slash/commands/cd.rs) | — | `/cd [path]` | Native: chooses the project for new tasks (folder picker without a path); running tasks stay put |
| [`/compact`](../../crates/codegen/xai-grok-pager/src/slash/commands/compact.rs) | — | `/compact [instructions]` | Native: `_x.ai/compact_conversation` with an inline status row; queued behind a running turn |
| [`/compact-mode`](../../crates/codegen/xai-grok-pager/src/slash/commands/compact_mode.rs) | — | `/compact-mode` | Native conversation density toggle |
| [`/config-agents`](../../crates/codegen/xai-grok-pager/src/slash/commands/config_agents.rs) | `/agents` | `/config-agents` | Native agents panel: definitions from every source the pager reads, Set/Clear default (`[agent] name`), per-agent enable (`[subagents.toggle]`), active-agent badge |
| [`/context`](../../crates/codegen/xai-grok-pager/src/slash/commands/context.rs) | — | `/context` | Native: Context usage tab of the Usage sheet from `_x.ai/session/info` (never forwarded; the shell route is a no-op) |
| [`/copy`](../../crates/codegen/xai-grok-pager/src/slash/commands/copy.rs) | — | `/copy [N] [file]` | Native: pager parsing and counting; clipboard plus `$GROK_HOME/last-copy.txt` backup, or a 0600 file |
| [`/dashboard`](../../crates/codegen/xai-grok-pager/src/slash/commands/dashboard.rs) | `/agents-dashboard`, `/sessions` | `/dashboard` | Native roster of every desktop task grouped by state (Needs input, Working, Idle, …) with Open, Stop, Reply, Rename, Delete |
| [`/debug`](../../crates/codegen/xai-grok-pager/src/slash/commands/debug.rs) | — | `/debug [scroll\|fps\|log]` | Native (hidden): FPS and scroll HUDs over the conversation; `log` writes `$GROK_HOME/logs/scroll-log-*.jsonl` |
| [`/delete`](../../crates/codegen/xai-grok-pager/src/slash/commands/delete.rs) | — | `/delete` | Native: confirmation, then `session/cancel`, `_x.ai/task/kill`, `_x.ai/session/delete`; the local task is removed after the harness succeeds (sidebar Delete uses the same path) |
| [`/docs`](../../crates/codegen/xai-grok-pager/src/slash/commands/docs.rs) | `/howto`, `/guides` | `/docs [web\|title]` | Native Guides window over `$GROK_HOME/docs/user-guide` with search and in-guide links; `web` opens the online docs; a title opens that guide |
| [`/doctor`](../../crates/codegen/xai-grok-pager/src/slash/commands/doctor.rs) | `/terminal-setup`, `/terminal-check`, `/terminal-info` | `/doctor [fix [FIX]]` | Native Diagnostics sheet from `grok doctor --json` plus desktop checks (runtime, sign-in, microphone, notifications); fixes run in Terminal |
| [`/edit-prompt`](../../crates/codegen/xai-grok-pager/src/slash/commands/edit_prompt.rs) | — | `/edit-prompt` | Native large editor sheet; "Open in External Editor…" uses `$VISUAL`/`$EDITOR` with the pager's read-back rules |
| [`/effort`](../../crates/codegen/xai-grok-pager/src/slash/commands/effort.rs) | — | `/effort <level>` | Native: accepts ids, labels, and standard level names; bare opens the picker; saves `[models].default_reasoning_effort` |
| [`/quit`](../../crates/codegen/xai-grok-pager/src/slash/commands/exit.rs) | `/exit` | `/quit` | Native application quit |
| [`/expand`](../../crates/codegen/xai-grok-pager/src/slash/commands/expand.rs) | — | `/expand` | Native: opens the newest folded reasoning or tool output and scrolls to it; repeating walks back |
| [`/export`](../../crates/codegen/xai-grok-pager/src/slash/commands/export.rs) | — | `/export [filename]` | Native: `grok export <session>` Markdown (local renderer fallback) to a file, or to the clipboard plus backup file |
| [`/feedback`](../../crates/codegen/xai-grok-pager/src/slash/commands/feedback.rs) | — | `/feedback [text]` | Native: inline send via `_x.ai/feedback`, or the Feedback sheet (Write and Drafts tabs, taxonomy, images, optional trace upload) |
| [`/find`](../../crates/codegen/xai-grok-pager/src/slash/commands/find.rs) | — | `/find [text]` | Native find bar (⌘F) with regex smart case, match count, next/previous, and message highlight |
| [`/fork`](../../crates/codegen/xai-grok-pager/src/slash/commands/fork.rs) | — | `/fork [--worktree\|--no-worktree] [directive]` | Native: in place via `_x.ai/session/fork` or in a git worktree via `_x.ai/git/worktree/resume_session`; the ask sheet honours `[hints].fork_worktree_mode`; the directive is the child's first prompt |
| [`/gboom`](../../crates/codegen/xai-grok-pager/src/slash/commands/gboom.rs) | — | `/gboom` | Native (hidden): a bit-exact port of the raycasting game in its own window; with arguments the text goes to the model unchanged |
| [`/help`](../../crates/codegen/xai-grok-pager/src/slash/commands/help.rs) | — | `/help` | Native command palette with the pager's grouped actions, plus a Keyboard Shortcuts sheet (⌘/) |
| [`/history`](../../crates/codegen/xai-grok-pager/src/slash/commands/history.rs) | — | `/history` | Native fuzzy prompt history from `_x.ai/prompt_history` (all tasks or this task) |
| [`/home`](../../crates/codegen/xai-grok-pager/src/slash/commands/home.rs) | `/welcome` | `/home` | Native: new-task screen without stopping the current task |
| [`/imagine`](../../crates/codegen/xai-grok-pager/src/slash/commands/imagine.rs) | — | `/imagine <description>` | Adapted: explicit image-generation prompt when the `image_gen` tool is advertised |
| [`/imagine-video`](../../crates/codegen/xai-grok-pager/src/slash/commands/imagine_video.rs) | — | `/imagine-video <description>` | Adapted: the pager's video workflow prompt when `image_to_video` is advertised |
| [`/import-claude`](../../crates/codegen/xai-grok-pager/src/slash/commands/import_claude.rs) | — | `/import-claude` | Native: scans Claude settings, MCP servers, hooks, and skill/rule folders; the sheet merges selected items into Grok's configuration as the pager does, keeping comments |
| [`/jump`](../../crates/codegen/xai-grok-pager/src/slash/commands/jump.rs) | — | `/jump` | Native turn picker with live scrolling; Escape restores the previous position |
| `/login` (desktop only) | — | `/login` | Native Accounts settings: sign in to OpenRouter or OpenAI Codex (browser sign-in through `grok login openrouter` or `grok login openai-codex`) |
| [`/loop`](../../crates/codegen/xai-grok-pager/src/slash/commands/loop_cmd.rs) | — | `/loop [interval] <prompt>` | Harness: forwarded; scheduled runs appear in `/tasks` with Delete |
| [`/mcps`](../../crates/codegen/xai-grok-pager/src/slash/commands/mcps.rs) | — | `/mcps` | Native servers panel: status, tools, add (one URL-or-command field), toggle, restart, authorize, remove |
| [`/memory`](../../crates/codegen/xai-grok-pager/src/slash/commands/memory.rs) | `/mem` | `/memory` | Native Memory panel: grouped notes with preview, search, enable toggle with reasons, Delete via `memory/forget` (BLAKE3 hash), Flush and Dream |
| [`/flush`](../../crates/codegen/xai-grok-pager/src/slash/commands/memory_ops.rs) | — | `/flush` | Native: `_x.ai/memory/flush` with the shell's summary |
| [`/dream`](../../crates/codegen/xai-grok-pager/src/slash/commands/memory_ops.rs) | — | `/dream` | Native: `_x.ai/memory/dream` with the shell's summary |
| [`/model`](../../crates/codegen/xai-grok-pager/src/slash/commands/model.rs) | `/m` | `/model <name> [effort]` | Native: the pager's name/prefix/effort resolution; bare opens the picker; saves `[models].default` |
| [`/multiline`](../../crates/codegen/xai-grok-pager/src/slash/commands/multiline.rs) | `/ml` | `/multiline` | Native preference: Return inserts a line and ⌘Return sends |
| [`/new`](../../crates/codegen/xai-grok-pager/src/slash/commands/new.rs) | `/clear` | `/new` | Native new task |
| [`/personas`](../../crates/codegen/xai-grok-pager/src/slash/commands/personas.rs) | — | `/personas` | Native: bundled, project, and user personas; create, edit, and delete user/project personas as TOML |
| [`/plan`](../../crates/codegen/xai-grok-pager/src/slash/commands/plan.rs) | — | `/plan [description]` | Native ACP plan mode; the description is sent after acknowledgment |
| [`/hooks`](../../crates/codegen/xai-grok-pager/src/slash/commands/plugin.rs) | — | `/hooks` | Native: hooks grouped by source with per-source and per-hook toggles, add/remove source, trust banner, load errors |
| [`/plugins`](../../crates/codegen/xai-grok-pager/src/slash/commands/plugin.rs) | `/plugin` | `/plugins` | Native panel: filter, badges, install, update (one or all), uninstall with confirmation, reload |
| [`/marketplace`](../../crates/codegen/xai-grok-pager/src/slash/commands/plugin.rs) | — | `/marketplace` | Native: marketplace sources and plugins with install, update, uninstall, refresh, add and remove source |
| [`/skills`](../../crates/codegen/xai-grok-pager/src/slash/commands/plugin.rs) | — | `/skills` | Native: filter, toggles, add folder, discovery sources with remove and reset, exact advertised invocation |
| [`/queue`](../../crates/codegen/xai-grok-pager/src/slash/commands/queue.rs) | — | `/queue` | Native queue panel above the composer: prompts sent during a turn are queued and sent in order; edit, reorder, copy, remove, Send now; harness-owned entries shown with Remove |
| [`/recap`](../../crates/codegen/xai-grok-pager/src/slash/commands/recap.rs) | `/summarize` | `/recap` | Native session recap through `_x.ai/recap` and its notification |
| [`/release-notes`](../../crates/codegen/xai-grok-pager/src/slash/commands/release_notes.rs) | `/changelog` | `/release-notes` | Native window: the version's changelog from x.ai, cached in `$GROK_HOME/CHANGELOG.md` |
| [`/remember`](../../crates/codegen/xai-grok-pager/src/slash/commands/remember.rs) | — | `/remember [text]` | Native sheet: Raw/Enhanced via `_x.ai/memory/rewrite`, saved locally like the pager (legacy `MEMORY.md` or v2 inbox note) |
| [`/rename`](../../crates/codegen/xai-grok-pager/src/slash/commands/rename.rs) | `/title` | `/rename <title> \| --auto` | Native: `_x.ai/session/rename` (and `resetToAuto`) with the pager's validation; bare opens the rename sheet |
| [`/resume`](../../crates/codegen/xai-grok-pager/src/slash/commands/resume.rs) | — | `/resume` | Native sheet over `_x.ai/session/list` and `_x.ai/session/search` with paging; resumes into the sidebar |
| [`/rewind`](../../crates/codegen/xai-grok-pager/src/slash/commands/rewind.rs) | `/undo` | `/rewind` | Native checkpoint picker, affected-file preview, and confirmed conversation/files/both restore; external conflicts block restore |
| [`/scroll-debug`](../../crates/codegen/xai-grok-pager/src/slash/commands/scroll_debug.rs) | — | `/scroll-debug` | Native (hidden): toggles the scroll HUD; with arguments the text goes to the model |
| [`/session-info`](../../crates/codegen/xai-grok-pager/src/slash/commands/session_info.rs) | `/status`, `/info` (shell) | `/session-info` | Native: Session info tab of the Usage sheet with click-to-copy rows |
| [`/settings`](../../crates/codegen/xai-grok-pager/src/slash/commands/settings_cmd.rs) | `/config`, `/preferences`, `/prefs` | `/settings` | Native Settings: themes, accounts (OpenRouter and OpenAI Codex), conversation display, permissions, input, and voice |
| [`/share`](../../crates/codegen/xai-grok-pager/src/slash/commands/share.rs) | — | `/share` | Same as the terminal: "Session sharing is temporarily disabled" |
| [`/tasks`](../../crates/codegen/xai-grok-pager/src/slash/commands/tasks.rs) | — | `/tasks` | Native sheet: workflows, subagents, background tasks, and scheduled tasks with Stop/Delete |
| [`/theme`](../../crates/codegen/xai-grok-pager/src/slash/commands/theme.rs) | `/t` | `/theme [name]` | Native: the terminal's themes (auto, groknight, grokday, tokyonight, rosepine-moon, oscura-midnight) with live preview; saved to `[ui].theme` |
| [`/timeline`](../../crates/codegen/xai-grok-pager/src/slash/commands/timeline.rs) | — | `/timeline` | Native turn tick rail beside the conversation with previews; saved to `[ui].show_timeline` |
| [`/timestamps`](../../crates/codegen/xai-grok-pager/src/slash/commands/timestamps.rs) | — | `/timestamps` | Native message timestamps (on by default); saved to `[ui].show_timestamps` |
| [`/toggle-mouse-reporting`](../../crates/codegen/xai-grok-pager/src/slash/commands/toggle_mouse_reporting.rs) | — | `/toggle-mouse-reporting` | Not applicable: explains that the desktop always receives mouse input |
| [`/transcript`](../../crates/codegen/xai-grok-pager/src/slash/commands/transcript.rs) | `/log` | `/transcript` | Native Transcript window with the export Markdown, find, copy, and Save As… |
| [`/trace`](../../crates/codegen/xai-grok-pager/src/slash/commands/trace.rs) | — | `/trace` | Native Trace window: `grok trace view <session> --format html` shown in a web view, with reload and Save As… |
| [`/tutorial`](../../crates/codegen/xai-grok-pager/src/slash/commands/tutorial.rs) | `/tour`, `/onboarding` | `/tutorial` | Native tutorial window with the nine topics, progress, and links into the guides |
| [`/usage`](../../crates/codegen/xai-grok-pager/src/slash/commands/usage.rs) | `/cost` | `/usage` | Native Usage sheet (Session usage tab): the session's tokens and cost from `_x.ai/session/usage`; takes no arguments (no xAI billing, so no `show` or `manage`) |
| [`/view-plan`](../../crates/codegen/xai-grok-pager/src/slash/commands/view_plan.rs) | `/show-plan`, `/plan-view` | `/view-plan` | Native saved Markdown plan preview plus ACP steps and pending plan approval |
| [`/vim-mode`](../../crates/codegen/xai-grok-pager/src/slash/commands/vim_mode.rs) | — | `/vim-mode` | Native transcript keys (j/k, g/G, y, i); saved to `[ui].vim_mode` |
| [`/voice`](../../crates/codegen/xai-grok-pager/src/slash/commands/voice.rs) | — | `/voice` | Native dictation (mic button, ⇧⌘D): each utterance transcribed by an OpenRouter model with the OpenRouter key, or on-device recognition without one |
| [`/workflow`](../../crates/codegen/xai-grok-pager/src/slash/commands/workflow.rs) | — | `/workflow <name> [input] \| runs \| …` | `runs` opens the native Workflow Runs sheet (pause, resume, stop, save); other forms go to the harness |
| [`/workflows`](../../crates/codegen/xai-grok-pager/src/slash/commands/workflows.rs) | — | `/workflows` | Native saved-workflow browser with when-to-use, source, path, and launch |
| [`/minimal`](../../crates/codegen/xai-grok-pager/src/slash/commands/screen_mode_switch.rs) | — | `/minimal` | Adapted: minimal window mode (conversation only; sidebar, inspector, and toolbar hidden) |
| [`/fullscreen`](../../crates/codegen/xai-grok-pager/src/slash/commands/screen_mode_switch.rs) | `/full` | `/fullscreen` | Adapted: leaves minimal mode, otherwise toggles macOS full screen |

## Management ACP contracts

The tables use actual wire names and JSON key spelling. Optional fields are marked
with `?`; placeholders are types rather than literal JSON values.

### MCP servers and tools

Source: [extensions/mcp.rs](../../crates/codegen/xai-grok-shell/src/extensions/mcp.rs).

| Method | Request | Payload / behavior |
| --- | --- | --- |
| `_x.ai/mcp/list` | `{sessionId?: string, cache?: bool}` | `servers`, `sessionMcpResolved`; refresh with `cache:false` after enrollment |
| `_x.ai/mcp/toggle` | `{session_id, server_name, enabled}` | Toggle a server; harness enforces policy |
| `_x.ai/mcp/toggle_tool` | `{session_id, server_name, tool_name, enabled}` | Toggle an individual tool |
| `_x.ai/mcp/auth_status` | `{session_id}` | Servers with snake_case `server_name` and status |
| `_x.ai/mcp/auth_trigger` | `{session_id, server_name}` | Start auth; may return setup requirements or error |
| `_x.ai/mcp/setup` | `{sessionId, serverName, values: {key: value}}` | Complete a server's declared setup schema |
| `_x.ai/mcp/upsert` | `{session_id, server_name, ...config}` | Add/update user config, then reload; config is flattened harness `McpServerConfig` |
| `_x.ai/mcp/delete` | `{session_id, server_name}` | Remove a locally configured server; managed entries cannot be deleted here |
| `_x.ai/mcp/call` | `{sessionId?, server, serverUrl?, tool, arguments}` | Explicit MCP tool execution |
| `_x.ai/mcp/read_resource` | `{sessionId?, server, uri}` | Resource content |

List entries have `name`, optional `displayName`, `source` (`local`/`managed`),
transport `type` (`stdio`/`http`/`managedGateway`), and optional session state:
`enabled`, `status`, `tools`, `authRequired`, `setupRequired`, `blockedReason`.
The session tool list contains `name`, optional description, and `enabled`.
Treat `_x.ai/mcp/tools_changed`, `_x.ai/mcp/servers_updated`, and initialization
notifications as triggers to refresh the relevant task's catalog. Toggle calls
deliberately use snake_case; setup and list deliberately use camelCase.

### Skills, plugins, hooks, and saved workflows

Sources: [skills](../../crates/codegen/xai-grok-shell/src/extensions/skills.rs),
[skill schema](../../crates/codegen/xai-grok-tools/src/implementations/skills/types.rs),
[plugins](../../crates/codegen/xai-grok-shell/src/extensions/plugins.rs),
[hooks](../../crates/codegen/xai-grok-shell/src/extensions/hooks.rs),
[marketplace](../../crates/codegen/xai-grok-shell/src/extensions/marketplace.rs).

| Method | Request | Payload / behavior |
| --- | --- | --- |
| `_x.ai/skills/list` | `{cwd}` | `skills` |
| `_x.ai/skills/config` | `{cwd?}` | Configured paths, ignore paths, total, skills, message |
| `_x.ai/skills/add` | `{cwd?, path}` | Persist discovery path, reload, return skills |
| `_x.ai/skills/remove` | `{cwd?, path}` | Remove configured path; does not delete source files |
| `_x.ai/skills/reset` | `{cwd?}` | Restore default skills configuration |
| `_x.ai/skills/toggle` | `{cwd?, name, enabled}` | Update disabled-name list and return skills |
| `_x.ai/skills/refresh-baseline` | `{}` | Refresh live session skill baselines after changes |
| `_x.ai/workflows/list` | `{sessionId}` | Saved workflow definitions in this session |
| `_x.ai/plugins/reload` | `{}` | Rebuild registry and fan out to live sessions |

`SkillInfo` fields are **snake_case**, including `display_name`, `plugin_name`,
`argument_hint`, and `user_invocable`; `name`, `description`, `path`, `scope`,
and `enabled` are always useful. Skills can be `local`, `repo`, `user`, `server`,
`bundled`, or `plugin` scoped. The toggle endpoint currently matches bare `name`
across scopes; it is not an independently scoped per-plugin toggle. The slash
catalog, rather than a reconstructed name from the list, is invocation authority.

### Live subagents, background tasks, and agent definitions

Sources: [task handlers](../../crates/codegen/xai-grok-shell/src/extensions/task.rs),
[child messaging](../../crates/codegen/xai-grok-shell/src/extensions/subagent_message.rs),
[bundle catalog](../../crates/codegen/xai-grok-shell/src/extensions/bundle.rs).

| Method | Request | Payload / behavior |
| --- | --- | --- |
| `_x.ai/subagent/list_running` | `{sessionId}` | `subagents` with IDs, description, type, timing and progress |
| `_x.ai/subagent/get` | `{subagentId, block?: false, timeoutMs?}` | `snapshot` including status and finished output/error |
| `_x.ai/subagent/cancel` | `{subagentId}` | Cancellation outcome; may already be finished |
| `_x.ai/subagent/message` | `{sessionId, agentAddress, queue?: false, content:[{type:"text",text}]}` | Feature-gated literal human steering; opaque address from spawn notification |
| `_x.ai/task/list` | `{sessionId}` | Background task snapshots |
| `_x.ai/task/kill` | `{sessionId, taskId, source?: "clientUi"}` | Typed stop outcome |
| `_x.ai/scheduler/delete` | `{sessionId, taskId}` | Delete a scheduled task |
| `_x.ai/bundle/status` | `{}` | `hasCache`, `version`, persona/role/agent/skill names and details |
| `_x.ai/bundle/entry/get` | `{kind: "agent"/"persona"/"role", name}` | Source content for an entry; kind is singular |
| `_x.ai/bundle/sync` | `{force?: true}` | Refresh cache for future construction; does not replace the running agent |

There is no public `subagent/spawn` extension in the audited dispatch. Model tools
and workflow launches create subagents. A desktop **Delegate** action can submit
an explicit delegation prompt and render actual spawn events; it must not claim
that a child exists until the harness reports it. Agent definitions (`/agents`)
are separate from live children and the multi-session dashboard.

`subagent_spawned`, `subagent_progress`, and `subagent_finished` arrive through
`_x.ai/session/update` with `{sessionId, update:{sessionUpdate,...}}`. Their fields
are mostly snake_case, while list/get snapshots are camelCase. Route child session
events using the spawn parent/child mapping. Preserve completed children when
refreshing a list that contains only running children.

### Plan, goal, and other native actions

Sources: [mode dispatch](../../crates/codegen/xai-grok-pager/src/app/dispatch/modes.rs),
[config options](../../crates/codegen/xai-grok-shell/src/agent/handlers/config_option.rs),
[goal updates](../../crates/codegen/xai-grok-shell/src/extensions/notification.rs),
[side questions](../../crates/codegen/xai-grok-shell/src/extensions/btw.rs),
[recap](../../crates/codegen/xai-grok-shell/src/extensions/recap.rs),
[rewind dispatch](../../crates/codegen/xai-grok-shell/src/extensions/rewind.rs),
[rewind actor implementation](../../crates/codegen/xai-grok-shell/src/session/acp_session_impl/rewind.rs).

- Enter plan mode with `session/set_mode {sessionId, modeId:"plan"}`. Await its
  acknowledgment before sending a `/plan <description>` description as a normal
  prompt. Use the advertised non-plan mode to leave. `plan` is not a config-option
  ID. The saved plan preview is the session artifact `plan.md`; ACP plan-progress
  entries alone are not the full plan document. Preserve reverse permission
  requests for `exit_plan_mode` plan approval.
- Change the model or thinking level through advertised `session/set_config_option`
  IDs `model` and `reasoning_effort` (or the existing model setter). Only offer
  supported values; await acknowledgment.
- Goal controls send the exact recognized `/goal ...` prompt. There is no separate
  goal RPC. Render `goal_updated` fields such as `objective`, `status`, `phase`,
  `token_budget`, `tokens_used`, `elapsed_ms`, and `pause_message`. Recognize active,
  complete, cleared, budget-limited, blocked, and multiple paused states. User pause
  and stop behavior belong to the harness; do not infer success from button clicks.
- `_x.ai/btw {sessionId, question}` returns `result.answer` independently of the
  main turn. It can run while the main turn is active; it is not a normal queued
  message. Additional optional `content` supports ACP text and image blocks. Each
  call is answered on its own, so the desktop's Side chat sends the task's recent
  answered exchanges ahead of a follow-up question.
- Prompt attachments travel in `session/prompt` after the text block: images as
  `{type:"image", data, mimeType}` (PNG, JPEG, GIF, or WebP; larger images are
  downscaled to 2048 px and about 3.5 MB), files as `resource_link` blocks with a
  `file://` URI, and folders as `resource_link` blocks with
  `_meta: {"x.ai/kind": "directory"}` so the harness lists them without trying to
  inline them. The harness echoes each block as `user_message_chunk`, which the
  desktop replays as attachments.
- `_x.ai/recap {sessionId,auto:false}` acknowledges with wrapped `{ok:true}`;
  `{ok:true,disabled:true}` means the feature is disabled. The result arrives via
  `session_recap {summary,auto:false}` or `session_recap_unavailable`. The desktop
  binds these asynchronous results to the requested task and ignores automatic
  recaps when displaying a manually opened panel.
- `_x.ai/rewind/points {sessionId}` returns raw `{rewind_points:[...]}` with
  `prompt_index`, `created_at`, `num_file_snapshots`, `has_file_changes`, and
  `prompt_preview`. `_x.ai/rewind/execute` takes `{sessionId,targetPromptIndex,mode,
  force}`, where `mode` is `conversation_only`, `files_only`, or `all`. Its raw
  response uses `target_prompt_index`, `clean_files`, `conflicts`, `reverted_files`,
  `prompt_text`, `success`, and optional `error`.
  **`force:false` is always a pure preview and returns `success:false` even when
  there are no conflicts. `force:true` performs the restore.** The desktop first
  previews, requires explicit confirmation, then re-previews immediately before
  committing; conflicts or a changed file list require a fresh review. Conversation
  restores reload authoritative history and place the original prompt in the
  composer. The desktop does not offer an external-conflict override.
- `_x.ai/session/state {sessionId,cwd}` returns persisted metadata, including
  `summary.grok_home` and `summary.info.cwd`. The desktop uses those paths to read
  the local saved `plan.md`, including `.cwd` sidecars for long hashed workspace
  directories. It limits preview reads to 1 MiB. This RPC's `plan` column is a
  separate JSON state file, not the Markdown plan.
- `_x.ai/session/usage {sessionId}` returns raw `{usage}`. Token fields are
  camelCase; `costUsdTicks` uses 10 billion ticks per USD. A missing cost or
  `costIsPartial`/`usageIsIncomplete` flag must not be presented as zero cost.
  These in-memory totals reset with a new runtime process. CLI `grok usage` reads
  persisted totals.

## Process-level CLI inventory

These commands configure or launch Grok itself. They are not slash commands and
should not be inserted into `session/prompt`. Native account, project, extensions,
and task controls can cover applicable operations; process maintenance and
terminal transport commands remain available in the side panel's **Terminal**.

| CLI family | Subcommands / primary operation | Source |
| --- | --- | --- |
| `grok agent` | `stdio`, `headless`, `serve`, `leader`; desktop uses `stdio` | `app/cli.rs` |
| `grok inspect` | Show discovered configuration; `--json` | `app/cli.rs` |
| `grok doctor` | Report; `fix [id]` | `doctor_cmd/mod.rs` |
| `grok leader` | `list`, `info`, `kill` | `app/cli.rs` |
| `grok login`, `logout` | `login openrouter` or `login openai-codex`; `logout [provider]` (all providers when omitted); xAI accounts are not supported | `app/cli.rs` |
| `grok mcp` | `list`, `add`, `remove`, `enable`, `disable`, `doctor` | `mcp_cmd.rs` |
| `grok plugin` | `list`, `install`, `uninstall` (`rm`/`remove`), `update`, `enable`, `disable`, `details`, `validate`, `tag` | `plugin_cmd.rs` |
| `grok plugin marketplace` | `list`, `add`, `remove`, `update` | `plugin_cmd.rs` |
| `grok memory` | `clear` with workspace/global/all scope | `memory_cmd.rs` |
| `grok models` | List models; optional `--refresh` | `app/cli.rs` |
| `grok sessions` | `list`, `search`, `delete` | `sessions_cmd.rs` |
| `grok usage` | Persisted session/turn token and cost totals | `usage_cmd.rs` |
| `grok setup` | Fetch/install managed configuration; `--json` is read-only | `app/cli.rs` |
| `grok share` | Share session URL; hidden CLI entry | `share_cmd.rs` |
| `grok wrap` | Run another command in PTY with clipboard forwarding | `app/cli.rs` |
| `grok export` | Export a session transcript as Markdown | `export_cmd.rs` |
| `grok trace` | Export/upload trace; `view` opens viewer or exports HTML | `trace_cmd.rs` |
| `grok update` | Check/install version; channel selection | `app/cli.rs` |
| `grok version`, `v` | Version information; `--json` | `app/cli.rs` |
| `grok completions` | Generate shell completions | `app/cli.rs` |
| `grok worktree` | `list` (`ls`), `show`, `rm`, `gc` (`prune`), `db rebuild/stats/path` | `worktree_cmd/mod.rs` |
| `grok du`, `disk-usage` | Grok home disk usage | `disk_usage_cmd.rs` |
| `grok workspace` | `start`, `pause`, `resume`, `stop`, `restart`, `status` (`list`); feature-gated | `app/cli.rs` |
| `grok dashboard` | Launch terminal multi-session dashboard | `app/cli.rs` |

Source paths in this table are relative to
[`crates/codegen/xai-grok-pager/src`](../../crates/codegen/xai-grok-pager/src).
Argument flags are defined alongside each command; the live executable's
`grok <family> --help` is the final authority for a packaged version.
