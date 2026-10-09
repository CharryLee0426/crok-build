# Crok

A terminal-based AI coding assistant and agentic harness.

Use it interactively as a TUI, or integrate it into your own apps via headless mode and the Agent Client Protocol (ACP).

## Quick Start

```bash
# Install (from your grok-build checkout)
make deploy

# Interactive TUI
crok

# Headless (for scripts/automation)
crok -p "Explain this codebase"

# Agent mode (for IDE/app integration)
crok agent stdio
```

## Contents

- [Installation](#installation)
- [Authentication](#authentication) — OpenRouter and OpenAI Codex sign-in, Claude API, DeepSeek and GLM Coding Plan keys
- **Using Crok**
  - [Interactive TUI](#interactive-tui) — shortcuts, slash commands, file references
  - [Headless Mode](#headless-mode) — scripting, CI/CD, output formats
  - [Agent Mode](#agent-mode) — stdio, ACP integration
  - [SSH Passthrough](#ssh-passthrough-crok-ssh) — Apple Terminal clipboard support
- **Configuration**
  - [Config File](#configuration) — general settings, telemetry, LSP, enterprise deployment
  - [Custom Models](#custom-models) — BYOK, Ollama, OpenAI, custom endpoints
  - [MCP Servers](#mcp-servers) — external tool integrations
- **Customization**
  - [Project Rules (AGENTS.md)](#agentsmd) — per-project system prompt instructions
  - [Skills](#skills) — reusable prompt packages
  - [Agent Profiles](#agent-profiles) — custom agent definitions
  - [Subagents](#subagents) — parallel child sessions, roles, personas
  - [Plugins](#plugins) — external tool/skill packages
  - [Hooks](#hooks) — project lifecycle scripts
- **Features**
  - [Memory](#memory) — cross-session knowledge persistence
  - [Sandbox](#sandbox) — OS-level filesystem/network isolation
- **Reference**
  - [Introspection (`crok inspect`)](#introspection)
  - [Claude Code Compatibility](#claude-code-compatibility)
  - [Built-in Tools](#built-in-tools)
  - [Session Persistence](#session-persistence) — storage layout, resume
  - [File Locations](#file-locations)
  - [Environment Variables](#environment-variables)
  - [Troubleshooting](#troubleshooting)
- [Building with Crok](#building-with-crok) — headless API, ACP SDK integration

---

## Installation

Crok has no prebuilt release; build it from the repository checkout:

```bash
make deploy          # builds the release TUI and installs ~/.local/bin/crok
```

Put `~/.local/bin` on your `PATH`, then verify installation:

```bash
crok --version
```

Crok never updates itself, because the official updater would install grok over it. To update, pull the checkout and run `make deploy` again; `crok update` says the same.

Crok installs beside an official `grok` and keeps its state in `~/.crok`. To start with an existing grok's settings and sessions, run `make import-grok-config` once from the checkout.

---

## Authentication

Crok signs in to model providers: OpenAI Codex (ChatGPT subscription), OpenRouter, the Claude API, DeepSeek, and the GLM Coding Plan. xAI accounts are not supported.

### Provider Sign-In

On the first interactive launch without a provider credential, Crok asks which provider to sign in to. You can also sign in ahead of time:

```bash
# OpenRouter (opens your browser)
crok login openrouter

# OpenAI Codex (opens your browser; uses your ChatGPT subscription)
crok login openai-codex

# Claude API (asks for an API key from the Claude Console; billed per token)
crok login anthropic

# DeepSeek (asks for an API key from platform.deepseek.com)
crok login deepseek

# GLM Coding Plan (asks for the API key of your subscription)
crok login glm               # subscribed on z.ai
crok login glm-cn            # subscribed on bigmodel.cn
```

The Claude API, DeepSeek and the GLM Coding Plan have no browser sign-in: the key is typed into the terminal without being shown, checked with the provider, and saved only if it is accepted. The two GLM sites keep separate accounts, and a key from one is refused by the other. The GLM Coding Plan's terms limit it to the coding tools its provider lists, and Crok is not on that list; see the [authentication guide](../xai-grok-pager/docs/user-guide/02-authentication.md#glm-coding-plan).

Credentials are stored in `~/.crok/provider-auth/` and persist across sessions; Codex tokens refresh automatically. To remove them:

```bash
crok logout openrouter
crok logout openai-codex
crok logout anthropic
crok logout deepseek
crok logout glm              # or glm-cn
crok logout                  # sign out of every provider
```

### API Key

For CI/CD, automation, or environments without browser access, set a provider's API key (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, `ZAI_API_KEY` for a z.ai GLM Coding Plan, or `ZHIPU_API_KEY` for a bigmodel.cn one):

```bash
export OPENROUTER_API_KEY="sk-or-..."
crok
```

Or save the key once from stdin:

```bash
printenv OPENROUTER_API_KEY | crok login openrouter --with-api-key
printenv DEEPSEEK_API_KEY | crok login deepseek --with-api-key
```

An environment key takes precedence over that provider's saved credential. Codex sign-in needs a browser, so run `crok login openai-codex` on a machine with one.

### xAI Models

Models served by xAI's own API (such as `grok-4.5`) are hidden unless `XAI_API_KEY` is set in the environment. This is a plain API key from [console.x.ai](https://console.x.ai), not an account sign-in. Grok models are also available through OpenRouter:

```bash
crok --model openrouter/x-ai/grok-4
```

A custom model with its own `api_key` or `env_key` needs no sign-in; see [Custom Models](#custom-models).

### Per-Model Auth Providers

When a model routes through a gateway (LiteLLM, corporate proxy) whose bearer tokens rotate, use a named auth provider — the rotating-token analogue of a per-model `api_key`/`env_key`.

```toml
# ~/.crok/config.toml
[auth_provider.litellm]
command = "/usr/local/bin/litellm-token"   # run via `sh -c`
token_ttl_secs = 3600                      # optional: see below
timeout_secs = 10                          # optional: command timeout (default 30)

[model.proxied-claude]
model = "claude-sonnet-4-5"
base_url = "https://litellm.corp.example/v1"
context_window = 200000
auth_provider = "litellm"
```

**Contract** (the `issuer` field is accepted but unused, and `refresh_token`, when present, is handed back to the command on refresh):

- Without `args`, the command runs via POSIX `sh -c`, so it can be a binary path, a script, or a pipeline. With `args = ["..."]`, the command runs directly with those arguments and no shell: `command` is a program name resolved via `PATH`, or a path. Use `args` to avoid shell quoting, and on Windows, where there is no `sh`.
- stdout: the token and nothing else — a bare token, or JSON `{"access_token": "...", "expires_in": 3600}`.
- stderr: logged when the command fails; exit 0 = success.
- `GROK_AUTH_EXPIRED=1` is set whenever Crok re-mints over a token still cached in memory, whether from near-expiry rotation or a rejection. The first mint on a cold cache runs without it.

**Token lifecycle:**

- Tokens are cached in memory per provider and shared by every model referencing the provider; nothing is written to disk. The command is a credential helper: it owns durable storage and OAuth2 refresh (keychain, its own dotdir, etc.), exactly like `gcloud auth print-access-token` or a git credential helper. On an in-session re-mint the last credential is handed back via `GROK_AUTH_PROVIDER_ACCESS_TOKEN` (and, when present, `GROK_AUTH_PROVIDER_REFRESH_TOKEN` / `GROK_AUTH_PROVIDER_EXPIRES_AT`), so a refresh-grant command can refresh instead of re-authenticating. The command must be non-interactive and fast; do any interactive login out of band, and Crok re-runs the command on restart to re-mint.
- Crok runs the command before a chat turn when the token is missing or within about a minute of expiring, and once more after the server rejects a token. A token rejected within 30 seconds of being fetched is not refetched again, so a broken helper surfaces one clear error instead of looping.
- Token lifetime comes from `expires_in` in the command's JSON output, else `token_ttl_secs`, else the token's own JWT expiry claim. With none of these, tokens are only replaced after the server rejects one.
- Commands run with a `timeout_secs` bound (default 30, clamped to 1..=600) and are killed on timeout. A turn waits on the run, so keep helpers fast and non-interactive.
- Active sessions pick up edits or removal of a provider table at the next model switch or new session. Once picked up, an edit invalidates the cached token, so the edited command runs at the next use; removal drops the cached token.
- Helper models (web search, session summary, image description) read the shared cache and never run the command; point them at providers your chat model keeps warm. Subagents refresh tokens the same way their parent session does.

**Interaction with other credentials:** a literal `api_key`/`env_key` on the model wins over its `auth_provider`. Provider-backed models are BYOK: no other credential is sent to their endpoints, and a failing provider command fails the request rather than falling back to another credential.

**Security:** provider commands execute code, so they are honored only from trusted config layers (`~/.crok/config.toml`, managed config, requirements). A project's `.grok/config.toml` can never define one. Whatever layer sets a model's `base_url` decides where that model's minted token is sent, and `base_url` (unlike the provider table) is not stripped from remote or campaign patches, the same as for a static `env_key`. Keep provider tables and the model `base_url` in layers you trust. The command inherits Crok's environment (so it sees `PATH`, `HOME`, and any other secrets there), but Crok's own first-party credentials (`XAI_API_KEY`, `GROK_DEPLOYMENT_KEY`, and related keys) are removed so a BYOK helper never receives them; write helpers that read only what they need, and prefer the `GROK_AUTH_PROVIDER_*` handback for the prior credential.

---

## Interactive TUI

The TUI (Terminal User Interface) provides a full interactive coding environment.

### Launch

```bash
crok [OPTIONS]
```

### Options

| Flag                       | Description                                                            |
| -------------------------- | ---------------------------------------------------------------------- |
| `--cwd <PATH>`             | Set working directory (default: current directory)                     |
| `--prompt <TEXT>`          | Send an initial prompt immediately after startup                       |
| `--rules <TEXT>`           | Append custom rules to the system prompt                               |
| `--always-approve`         | Auto-approve all tool executions without confirmation                  |
| `--sandbox <PROFILE>`      | OS-level filesystem/network guardrails (see [Sandbox](#sandbox))       |
| `--light`                  | Use light theme (macOS Basic) instead of dark                          |
| `--single-turn`            | Exit after first response (requires `--prompt`)                        |
| `--subagents`              | Enable subagent/task tool support (see [Subagents](#subagents))        |
| `--disable-web-search`     | Remove web search tool from the agent toolset                          |
| `--agent-profile <PATH>`   | Load a custom agent definition file (see [Agent Profiles](#agent-profiles)) |
| `--allow <RULE>`           | Permission allow rule with glob patterns (repeatable). See [Permission Rules](#permission-rules-allow--deny). |
| `--deny <RULE>`            | Permission deny rule with glob patterns (repeatable). See [Permission Rules](#permission-rules-allow--deny). |

### Examples

```bash
# Start in a specific project
crok --cwd ~/projects/my-app

# Start with an initial task
crok --prompt "Review this codebase and suggest improvements"

# Add project-specific rules
crok --rules "Always use TypeScript. Prefer functional components."

# Auto-approve mode for trusted tasks
crok --always-approve --prompt "Format all files"
```

### Keyboard Shortcuts

| Key                          | Action                          |
| ---------------------------- | ------------------------------- |
| `Enter`                      | Send message                    |
| `Shift+Enter` or `Alt+Enter` | Insert newline                  |
| `Ctrl+M`                     | Toggle multiline input mode     |
| `Ctrl+C` or `Esc`            | Cancel current operation        |
| `Ctrl+D` or `Ctrl+Q`         | Quit (with confirmation)        |
| `Ctrl+O`                     | Toggle always-approve mode |
| `Ctrl+T`                     | Toggle TODO/task panel          |
| `Ctrl+R`                     | Search prompt history           |
| `Ctrl+V`                     | Paste from clipboard            |
| `Ctrl+U`                     | Undo last input change          |
| `Ctrl+G`                     | Move foreground task to background |
| `Ctrl+P`                     | Toggle debug panel              |

### Slash Commands

Type `/` in the input to access commands:

| Command                            | Alias     | Description                                              |
| ---------------------------------- | --------- | -------------------------------------------------------- |
| `/model <name>`                    | `/m`      | Switch to a different model                              |
| `/new`                             |           | Start a new session (clears context)                     |
| `/load [workspace] [session]`      | `/resume` | Load a previous session                                  |
| `/rewind <prompt>`                 |           | Rewind to a previous prompt (restores files)             |
| `/compact`                         |           | Compact conversation history                             |
| `/always-approve [on\|off]`        | `/yolo`   | Toggle auto-approve mode                                 |
| `/multiline`                       | `/ml`     | Toggle multiline input mode                              |
| `/memory [workspace\|global] <text>` |         | Append text to a memory file (requires memory enabled) |
| `/flush`                           |           | Save current session knowledge to memory now             |
| `/skills [name]`                   |           | List skills or inject a skill into context               |
| `/plugins [list\|reload\|trust]`   | `/plugin` | Manage plugins (list, reload, trust)                     |
| `/hooks-list`                      |           | Show hooks loaded in this session                        |
| `/hooks-trust`                     |           | Trust this folder for hooks (writes folder trust)        |
| `/hooks-add <path>`                |           | Add a custom hook file or directory                      |
| `/feedback [message]`              |           | Report an issue or send feedback                         |
| `/exit`                            | `/quit`   | Exit the TUI                                             |

```bash
# Example usage in TUI:
/model grok-build
/new
/rewind
/feedback Something isn't working
```

### Features

- **Syntax highlighting** for code blocks
- **Inline diffs** showing file changes before they're applied
- **Tool execution progress** with real-time output
- **TODO panel** tracking task progress
- **Session persistence** — conversations auto-save and can be resumed
- **History search** — `Ctrl+R` to search previous prompts

### File References (`@`)

Use the `@` operator in your prompt to attach file contents to your message. Type `@` followed by a filename or path to open a fuzzy file picker, then press `Tab` or `Enter` to select.

```
@src/main.rs              # Attach a file
@src/main.rs:10-50        # Attach lines 10–50 of a file
@src/                     # Browse a directory (end with /)
```

**Exposing hidden files with `!`**

By default, the `@` file picker respects `.gitignore` rules and hides dotfiles (files and directories starting with `.`). To search hidden files — such as `.github/`, `.vscode/`, `.env`, or other dotfiles — prefix your query with `!`:

```
@!.github                 # Search for .github/ and other hidden files
@!.vscode/settings.json   # Find .vscode/settings.json
@!.env                    # Attach a .env file
```

The `!` modifier allows you to attach any file in the project regardless of ignore rules.

---

## Headless Mode

Run Crok non-interactively from the command line. Use headless mode when you need to:

- **Automate tasks** — CI/CD pipelines, pre-commit hooks, cron jobs
- **Script workflows** — Batch process files, chain with other tools
- **Build integrations** — Spawn as a sub-agent, embed in larger systems
- **Parse output programmatically** — JSON output for downstream processing

Headless mode accepts a single prompt, executes it with full tool access, and returns the result.

### Basic Usage

```bash
crok -p "Your prompt here"
```

### Options

| Flag                    | Description                                           |
| ----------------------- | ----------------------------------------------------- |
| `-p, --single <PROMPT>` | The prompt to send (required)                         |
| `-m, --model <MODEL>`   | Model to use (e.g., `grok-build`)               |
| `-s, --session-id <ID>` | Create or resume a headless session with this ID      |
| `-r, --resume <ID_OR_TITLE>` | Resume an existing session by ID, or by title for the current directory, ignoring letter case (a sole explicitly renamed title wins among duplicates; remaining duplicates error with their IDs; UUID-shaped values are always treated as IDs) |
| `-c, --continue`        | Continue the most recent session in current directory |
| `--cwd <PATH>`          | Working directory                                     |
| `--output-format <FMT>` | Output format: `plain`, `json`, `streaming-json`      |
| `--always-approve`      | Auto-approve tool executions                          |
| `--rules <TEXT>`        | Custom rules for the system prompt                    |
| `--tools <TOOLS>`       | Allowlist of built-in tools (comma-separated). Only the listed tools will be available; all others are removed. Headless mode only. |
| `--disallowed-tools <TOOLS>` | Denylist of built-in tools to remove (comma-separated). Listed tools are stripped from the agent's toolset. Supports `Agent` / `Agent(type)` entries to restrict subagent spawning (see below). Headless mode only. |
| `--max-turns <N>`       | Maximum number of agentic turns before stopping       |
| `--reasoning-effort` / `--effort <LEVEL>` | Reasoning effort (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`; also per-model menu ids like `deep`). TUI and headless. |
| `--permission-mode <MODE>` | Permission mode for tool approvals                 |
| `--allow <RULE>`        | Permission allow rule with glob patterns (repeatable). See below. |
| `--deny <RULE>`         | Permission deny rule with glob patterns (repeatable). See below.  |

#### Tool Filtering (`--tools` / `--disallowed-tools`)

Use `--tools` to restrict the agent to an explicit set of tools (allowlist), or `--disallowed-tools` to remove specific tools from the default set (denylist). Both accept a comma-separated list of tool names.

Tool names correspond to the internal tool IDs shown below. For quick reference:

| Display Name   | Tool ID for `--tools` / `--disallowed-tools` |
| -------------- | --------------------------------------------- |
| bash           | `run_terminal_cmd`                            |
| grep           | `grep`                                        |
| read_file      | `read_file`                                   |
| search_replace | `search_replace`                              |
| list_dir       | `list_dir`                                    |
| web_search     | `web_search`                                  |
| web_fetch      | `web_fetch`                                   |
| todo_write     | `todo_write`                                  |
| task           | `task`                                        |

```bash
# Only allow read-only tools
crok -p "Explain this codebase" --tools "read_file,grep,list_dir"

# Remove web access and file editing
crok -p "Review this code" --disallowed-tools "web_search,web_fetch,search_replace"

# Remove shell access
crok -p "Review this code" --disallowed-tools "run_terminal_cmd"
```

`--disallowed-tools` also supports special `Agent` entries to control subagent spawning:

| Entry                          | Effect                                                  |
| ------------------------------ | ------------------------------------------------------- |
| `Agent`                        | Block **all** subagent spawning                         |
| `Agent(explore)`               | Block the `explore` subagent type only                  |
| `Agent(explore, plan)`         | Block multiple specific types                           |

```bash
# Allow tools but prevent the agent from spawning any subagents
crok -p "Fix this bug" --disallowed-tools "Agent"

# Block only the explore subagent
crok -p "Refactor this module" --disallowed-tools "Agent(explore)"
```

When `--tools` is set, only the listed tools are available and default tool injection is disabled. When both flags are present, `--disallowed-tools` runs after `--tools` — use this to start from an allowlist and then remove specific entries.

> **Note:** `--tools`, `--disallowed-tools`, and `--max-turns` are only supported in headless mode (`-p`). If used in the interactive TUI, a warning is printed and the flag is ignored. `--reasoning-effort`/`--effort` and `--permission-mode` work in both modes.

#### Permission Rules (`--allow` / `--deny`)

Permission rules control whether specific tool invocations are auto-approved, denied, or require confirmation. Unlike `--disallowed-tools` (which removes tools entirely from the agent's toolset), permission rules leave tools available but gate their execution.

Rules use `ToolPrefix(glob_pattern)` syntax. Supported prefixes:

| Prefix        | What it controls                   |
| ------------- | ---------------------------------- |
| `Bash(...)`   | Shell command execution            |
| `Edit(...)`   | File editing (path glob)           |
| `Write(...)`  | File writing (path glob)           |
| `Read(...)`   | File reading (path glob)           |
| `Grep(...)`   | Search operations (path glob)      |
| `WebFetch(...)` | URL fetching (glob or `domain:host`) |
| `MCPTool(...)` | MCP tool invocations              |

Glob patterns support `*` (single-level wildcard) and `**` (recursive). A bare prefix without parentheses matches all invocations of that type. Claude Code's `Bash(cmd:*)` rules are also accepted and are equivalent to prefix matching on `cmd`.

```bash
# Deny all shell commands matching "rm*"
crok -p "Clean up this project" --deny "Bash(rm*)"

# Allow npm commands, deny everything else dangerous
crok -p "Set up the project" --allow "Bash(npm*)" --deny "Bash(sudo*)"

# Deny edits outside src/
crok -p "Refactor the code" --deny "Edit(/etc/**)"

# Allow all bash commands (auto-approve without prompting)
crok -p "Build the project" --allow "Bash"

# Combine: allow fetching docs sites, deny other URLs
crok --allow "WebFetch(domain:docs.rs)" --deny "WebFetch(*)"
```

`--allow` and `--deny` can be repeated to add multiple rules. Deny rules take precedence over allow rules. These flags work in both TUI and headless mode.

### Examples

```bash
# Simple question
crok -p "What does this project do?"

# Use a specific model
crok -p "Optimize this function" -m grok-build

# Get JSON output for parsing
crok -p "List all TODO comments in the codebase" --output-format json

# Streaming JSON for real-time processing
crok -p "Explain the architecture" --output-format streaming-json

# Multi-turn conversation (session ID is returned in JSON output)
crok -p "Remember: the secret number is 42" --output-format json
crok -p "What's the secret number?" --resume <sessionId>

# Resume most recent session
crok -p "Continue where we left off" -c

# Run in a different directory
crok -p "Run the tests" --cwd ~/projects/other-app --always-approve
```

### Scripting with Named Sessions

For CI and automation, `-s/--session-id` lets you choose your own session ID:

```bash
# Start a session namespaced to a PR
crok -p "Review the changes in this PR" -s "critique-myrepo-pr-123"

# Continue in the same session
crok -p "Now check for security issues" -s "critique-myrepo-pr-123"
```

If the session exists it picks up where you left off; if not, a new one is created.
This differs from `--resume`, which errors when the session doesn't exist.

> **Note:** `-s/--session-id` is for headless mode (`-p/--single`) only.
> In the interactive TUI, use `/load` or `--resume`.

### Output Formats

**plain** (default) — Human-readable text:

```
Here's a summary of the codebase...
```

**json** — Single JSON object after completion:

```json
{
  "text": "Here's a summary of the codebase...",
  "stopReason": "EndTurn",
  "sessionId": "abc123",
  "requestId": "xyz789"
}
```

**streaming-json** — Newline-delimited JSON events:

```json
{"type":"text","data":"Here's"}
{"type":"text","data":" a summary"}
{"type":"thought","data":"Analyzing the directory structure..."}
{"type":"end","stopReason":"EndTurn","sessionId":"abc123","requestId":"xyz789"}
```

### Scripting Examples

```bash
# Pipe output to a file
crok -p "Generate a README" > README.md

# Parse JSON output with jq
crok -p "List files" --output-format json | jq -r '.text'

# CI/CD: automated code review
crok -p "Review changes for bugs and security issues." \
  --output-format json --always-approve | jq -r '.text' > review.md

# Pipeline: chain with other tools
git diff --staged | crok -p "Write a concise commit message for these changes"

# Batch: process multiple files
for file in src/*.js; do
  crok -p "Migrate $file from CommonJS to ES modules." --always-approve
done

# Pre-commit hook
crok -p "Review staged changes for obvious bugs. Reply OK if fine, or list issues." \
  --always-approve --output-format json | jq -r '.text' | grep -q "^OK" || exit 1
```

> **Note:** Headless mode starts a fresh session by default. Use `-s <id>` to maintain context across calls.

---

## Agent Mode

Run Crok as an ACP (Agent Client Protocol) agent for integration with IDEs, editors, and custom tooling.

### stdio Transport

For direct integration with ACP clients:

```bash
crok agent stdio
```

Communication happens via JSON-RPC over stdin/stdout. This mode is used by:

- IDE extensions (Zed, Neovim, Emacs, etc.)
- Custom automation tools
- ACP client libraries

### Options

| Flag                  | Description                                                                         |
| --------------------- | ----------------------------------------------------------------------------------- |
| `-m, --model <MODEL>` | Override the default model ID (e.g., `grok-build`)                           |
| `--always-approve`    | Start in always-approve mode (auto-approve all tool executions without confirmation) |

<details>
<summary><strong>Advanced: WebSocket Relay</strong></summary>

To expose the agent over the internet (instead of local network), run a WebSocket relay server and have the agent connect to it:

```bash
crok agent headless --grok-ws-url wss://your-relay.example.com/ws
```

The agent connects OUT to your relay, and your web clients connect to the same relay. Useful for building web UIs where browsers can't spawn local processes.

</details>

---

## SSH Passthrough (`crok ssh`)

Use `crok ssh` instead of plain `ssh` when connecting to remote hosts in terminals that lack native support (e.g. Apple Terminal) for local OSC 52 clipboard interception.

```bash
# Basic usage (same args as ssh)
crok ssh user@host

# With SSH flags
crok ssh -t user@host
crok ssh -L 8080:localhost:8080 user@host

# With remote command
crok ssh user@host -- tmux attach
```

On macOS, if the terminal doesn't natively handle OSC 52, `crok ssh` runs SSH inside a local PTY that intercepts clipboard sequences and writes them to `pbcopy`. Both plain OSC 52 and tmux DCS passthrough are handled. Terminals with native OSC 52 (iTerm2, Ghostty, Kitty, WezTerm, Alacritty) get a plain `ssh` exec with no wrapper.

This runs entirely locally.

---

## Building with Crok

Crok can be used as an OpenAI-compatible chat completion backend. Choose between two integration modes:

| Mode         | Use Case                                                           |
| ------------ | ------------------------------------------------------------------ |
| **Headless** | Simple chat API, scripts, automation, OpenAI SDK drop-in           |
| **ACP SDK**  | IDE integrations, tool visibility, thought streams, permission UIs |

---

### Headless Mode (Simple Chat Completion)

Use headless mode for simple integrations. Spawns `crok -p` and parses JSON output.

#### Python - Headless

```python
import asyncio
import json
import os

class CrokChat:
    """Simple OpenAI-compatible wrapper using headless mode."""

    def __init__(self, cwd="."):
        self.cwd = cwd
        self.env = {**os.environ}

    def _build_cmd(self, prompt, model, stream):
        return ["crok", "-p", prompt, "-m", model, "--cwd", self.cwd,
                "--output-format", "streaming-json" if stream else "json", "--always-approve"]

    async def create(self, messages, model="grok-build", stream=False):
        prompt = messages[-1]["content"] if len(messages) == 1 else "\n".join(
            f"{m['role']}: {m['content']}" for m in messages
        )
        cmd = self._build_cmd(prompt, model, stream)

        if stream:
            return self._stream(cmd)

        proc = await asyncio.create_subprocess_exec(
            *cmd, env=self.env, stdout=asyncio.subprocess.PIPE
        )
        stdout, _ = await proc.communicate()
        data = json.loads(stdout.decode()) if stdout else {"text": ""}
        return {
            "choices": [{
                "message": {"role": "assistant", "content": data.get("text", "")},
                "finish_reason": "stop"
            }]
        }

    async def _stream(self, cmd):
        proc = await asyncio.create_subprocess_exec(
            *cmd, env=self.env, stdout=asyncio.subprocess.PIPE
        )
        async for line in proc.stdout:
            if not line.strip():
                continue
            event = json.loads(line)
            if event.get("type") == "text":
                yield {"choices": [{"delta": {"content": event["data"]}}]}
            elif event.get("type") == "end":
                yield {"choices": [{"delta": {}, "finish_reason": "stop"}]}


# Usage
async def main():
    client = CrokChat(cwd=".")

    # Non-streaming
    response = await client.create([{"role": "user", "content": "What files are here?"}])
    print(response["choices"][0]["message"]["content"])

    # Streaming
    async for chunk in await client.create(
        [{"role": "user", "content": "List files"}], stream=True
    ):
        print(chunk["choices"][0]["delta"].get("content", ""), end="", flush=True)

asyncio.run(main())
```

#### TypeScript - Headless

```typescript
import { execa } from "execa";

class CrokChat {
  constructor(private cwd = ".") {}

  private buildArgs(prompt: string, model: string, stream: boolean) {
    return [
      "-p",
      prompt,
      "-m",
      model,
      "--cwd",
      this.cwd,
      "--output-format",
      stream ? "streaming-json" : "json",
      "--always-approve",
    ];
  }

  async create(
    messages: { role: string; content: string }[],
    { model = "grok-build", stream = false } = {},
  ) {
    const prompt =
      messages.length === 1
        ? messages[0].content
        : messages.map((m) => `${m.role}: ${m.content}`).join("\n");

    if (stream) return this.streamResponse(prompt, model);

    const { stdout } = await execa(
      "crok",
      this.buildArgs(prompt, model, false),
    );
    const data = JSON.parse(stdout || '{"text":""}');
    return {
      choices: [
        {
          message: { role: "assistant", content: data.text || "" },
          finish_reason: "stop",
        },
      ],
    };
  }

  async *streamResponse(prompt: string, model: string) {
    const proc = execa("crok", this.buildArgs(prompt, model, true));
    for await (const chunk of proc.stdout!) {
      for (const line of chunk.toString().split("\n").filter(Boolean)) {
        const event = JSON.parse(line);
        if (event.type === "text") {
          yield { choices: [{ delta: { content: event.data } }] };
        } else if (event.type === "end") {
          yield { choices: [{ delta: {}, finish_reason: "stop" }] };
        }
      }
    }
  }
}

// Usage
const client = new CrokChat(".");

// Non-streaming
const response = await client.create([
  { role: "user", content: "What files are here?" },
]);
console.log(response.choices[0].message.content);

// Streaming
for await (const chunk of await client.create(
  [{ role: "user", content: "List files" }],
  { stream: true },
)) {
  process.stdout.write(chunk.choices[0].delta?.content || "");
}
```

---

### ACP SDK (Rich Agent Integration)

Use the Agent Client Protocol for full access to tool calls, thoughts, plans, and permissions.

#### Python - ACP SDK

```python
import asyncio
import json

class CrokACPChat:
    """Rich OpenAI-compatible wrapper using ACP protocol."""

    def __init__(self, cwd="."):
        self.cwd = cwd
        self.proc = None
        self.session_id = None

    async def init(self):
        self.proc = await asyncio.create_subprocess_exec(
            "crok", "agent", "stdio",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE
        )

        # Initialize
        await self._request("initialize", {
            "protocolVersion": "1",
            "clientCapabilities": {
                "fs": {"readTextFile": True, "writeTextFile": True},
                "terminal": True
            }
        })

        # Create session
        result = await self._request("session/new", {
            "cwd": self.cwd,
            "mcpServers": []
        })
        self.session_id = result["sessionId"]
        return self

    async def _request(self, method, params):
        msg = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        self.proc.stdin.write(f"{msg}\n".encode())
        await self.proc.stdin.drain()

        line = await self.proc.stdout.readline()
        return json.loads(line).get("result", {})

    async def create(self, messages, model="grok-build", stream=False):
        prompt = [{"type": "text", "text": m["content"]} for m in messages]

        # For streaming, yield chunks as they arrive
        if stream:
            return self._stream(prompt)

        result = await self._request("session/prompt", {
            "sessionId": self.session_id,
            "prompt": prompt
        })
        return {
            "choices": [{
                "message": {"role": "assistant", "content": result.get("text", "")},
                "finish_reason": result.get("stopReason", "stop").lower()
            }]
        }

    async def _stream(self, prompt):
        # Send prompt request
        msg = json.dumps({
            "jsonrpc": "2.0", "id": 1,
            "method": "session/prompt",
            "params": {"sessionId": self.session_id, "prompt": prompt}
        })
        self.proc.stdin.write(f"{msg}\n".encode())
        await self.proc.stdin.drain()

        # Read streaming updates
        while True:
            line = await self.proc.stdout.readline()
            if not line:
                break

            data = json.loads(line)

            # Handle notifications
            if data.get("method") == "session/update":
                update = data["params"]["update"]
                session_update = update.get("sessionUpdate")

                if session_update == "agent_message_chunk":
                    yield {"choices": [{"delta": {"content": update["content"]["text"]}}]}
                elif session_update == "agent_thought_chunk":
                    yield {"choices": [{"delta": {"thought": update["content"]["text"]}}]}
                elif session_update == "tool_call":
                    yield {"choices": [{"delta": {"tool_call": {
                        "name": update["tool"],
                        "status": "pending"
                    }}}]}
                elif session_update == "plan":
                    yield {"choices": [{"delta": {"plan": update["entries"]}}]}

            # Handle final response
            elif "result" in data:
                yield {"choices": [{"delta": {}, "finish_reason": "stop"}]}
                break


# Usage
async def main():
    client = await CrokACPChat(cwd=".").init()

    # Streaming with rich updates
    async for chunk in await client.create(
        [{"role": "user", "content": "Refactor the main function"}],
        stream=True
    ):
        delta = chunk["choices"][0]["delta"]
        if "content" in delta:
            print(delta["content"], end="", flush=True)
        if "thought" in delta:
            print(f"\n[Thinking: {delta['thought']}]", end="")
        if "tool_call" in delta:
            print(f"\n[Tool: {delta['tool_call']}]")
        if "plan" in delta:
            print(f"\n[Plan: {delta['plan']}]")

asyncio.run(main())
```

#### TypeScript - ACP SDK

```typescript
import { spawn, ChildProcess } from "child_process";
import * as readline from "readline";

class CrokACPChat {
  private proc!: ChildProcess;
  private sessionId!: string;
  private rl!: readline.Interface;

  constructor(private cwd = ".") {}

  async init() {
    this.proc = spawn("crok", ["agent", "stdio"]);
    this.rl = readline.createInterface({ input: this.proc.stdout! });

    // Initialize
    await this.request("initialize", {
      protocolVersion: "1",
      clientCapabilities: {
        fs: { readTextFile: true, writeTextFile: true },
        terminal: true,
      },
    });

    // Create session
    const { sessionId } = await this.request("session/new", {
      cwd: this.cwd,
      mcpServers: [],
    });
    this.sessionId = sessionId;
    return this;
  }

  private async request(method: string, params: any): Promise<any> {
    return new Promise((resolve) => {
      const msg = JSON.stringify({ jsonrpc: "2.0", id: 1, method, params });
      this.proc.stdin!.write(msg + "\n");

      this.rl.once("line", (line) => {
        resolve(JSON.parse(line).result || {});
      });
    });
  }

  async create(
    messages: { role: string; content: string }[],
    { model = "grok-build", stream = false } = {},
  ) {
    const prompt = messages.map((m) => ({ type: "text", text: m.content }));

    if (stream) return this.streamResponse(prompt);

    const result = await this.request("session/prompt", {
      sessionId: this.sessionId,
      prompt,
    });

    return {
      choices: [
        {
          message: { role: "assistant", content: result.text || "" },
          finish_reason: result.stopReason?.toLowerCase() || "stop",
        },
      ],
    };
  }

  async *streamResponse(prompt: { type: string; text: string }[]) {
    const msg = JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "session/prompt",
      params: { sessionId: this.sessionId, prompt },
    });
    this.proc.stdin!.write(msg + "\n");

    for await (const line of this.rl) {
      const data = JSON.parse(line);

      if (data.method === "session/update") {
        const update = data.params.update;
        switch (update.sessionUpdate) {
          case "agent_message_chunk":
            yield { choices: [{ delta: { content: update.content?.text } }] };
            break;
          case "agent_thought_chunk":
            yield { choices: [{ delta: { thought: update.content?.text } }] };
            break;
          case "tool_call":
            yield {
              choices: [
                {
                  delta: {
                    tool_call: {
                      name: update.tool,
                      args: update.arguments,
                      status: "pending",
                    },
                  },
                },
              ],
            };
            break;
          case "plan":
            yield { choices: [{ delta: { plan: update.entries } }] };
            break;
        }
      } else if (data.result) {
        yield { choices: [{ delta: {}, finish_reason: "stop" }] };
        break;
      }
    }
  }
}

// Usage
const client = await new CrokACPChat(".").init();

// Streaming with rich updates
for await (const chunk of await client.create(
  [{ role: "user", content: "Refactor main" }],
  { stream: true },
)) {
  const delta = chunk.choices[0].delta;
  if (delta.content) process.stdout.write(delta.content);
  if (delta.thought) console.log(`\n[Thinking: ${delta.thought}]`);
  if (delta.tool_call)
    console.log(`\n[Tool: ${JSON.stringify(delta.tool_call)}]`);
  if (delta.plan) console.log(`\n[Plan: ${JSON.stringify(delta.plan)}]`);
}
```

---

### ACP Protocol Reference

Crok implements the [Agent Client Protocol (ACP)](https://agentclientprotocol.com), a standard for AI agent communication.

#### Architecture

```
┌─────────────────────────────────────────┐
│           ACP Client                    │
│  (IDE, Editor, Custom Application)      │
└──────────────────┬──────────────────────┘
                   │ JSON-RPC over stdio
┌──────────────────▼──────────────────────┐
│           crok agent stdio              │
│                                         │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  │
│  │ Session │  │  Tools  │  │   MCP   │  │
│  │ Manager │  │ Registry│  │ Servers │  │
│  └─────────┘  └─────────┘  └─────────┘  │
└─────────────────────────────────────────┘
```

#### SDKs

| Language   | Package                                                                                  |
| ---------- | ---------------------------------------------------------------------------------------- |
| TypeScript | [`@agentclientprotocol/sdk`](https://www.npmjs.com/package/@agentclientprotocol/sdk)     |
| Rust       | [`agent-client-protocol`](https://crates.io/crates/agent-client-protocol)                |
| Python     | [`agent-client-protocol-python`](https://github.com/PsiACE/agent-client-protocol-python) |
| Go         | [`acp-go-sdk`](https://github.com/coder/acp-go-sdk)                                      |
| Kotlin     | [`acp`](https://github.com/agentclientprotocol/kotlin-sdk)                               |

#### Resources

- [ACP Specification](https://agentclientprotocol.com/protocol/prompt-turn)
- [Protocol Introduction](https://agentclientprotocol.com/overview/introduction)

#### Compatible Clients

| Client                                                   | Status      |
| -------------------------------------------------------- | ----------- |
| [Zed](https://zed.dev/docs/ai/external-agents)           | ✓ Supported |
| [Neovim](https://neovim.io) (CodeCompanion, avante.nvim) | ✓ Supported |
| [Emacs](https://github.com/xenodium/agent-shell)         | ✓ Supported |
| [marimo notebook](https://github.com/marimo-team/marimo) | ✓ Supported |
| JetBrains                                                | Coming soon |

---

## Configuration

Crok reads configuration from `~/.crok/config.toml`. If the file doesn't exist, Crok uses sensible defaults. You only need to specify values you want to override.

Each feature section below documents its own config. This section covers the general-purpose settings that don't have their own top-level section.

### General Settings

```toml
[models]
default = "openrouter/x-ai/grok-4"     # model used for new sessions
web_search = "grok-4.6"                # model used by the web_search tool

[ui]
max_thoughts_width = 120               # max column width for reasoning display

[features]
support_permission = false             # prompt before tool execution
telemetry = false                      # anonymous usage telemetry (env: CROK_TELEMETRY_ENABLED)
feedback = false                       # feedback system (env: CROK_FEEDBACK_ENABLED)
lsp_tools = false                      # expose the lsp tool (see LSP Servers below)
codebase_indexing = true               # code graph indexing (true, false, or glob patterns)

[session]
auto_compact_threshold_percent = 85    # auto-compact at this % of context window
load_envrc = true                      # load .envrc environment variables into bash commands

[tools]
respect_gitignore = true               # filter gitignored files from tools (env: CROK_RESPECT_GITIGNORE)

[toolset.bash]
timeout_secs = 120.0                   # command timeout in seconds
output_byte_limit = 65536              # max output size (64KB)

[toolset.web_fetch]
proxy_endpoint = "https://proxy.example.com"   # egress proxy URL (all requests routed through it)
allowed_domains = ["docs.rs", "x.ai"]           # override the built-in ~84-domain allowlist
```

### Telemetry

Configure telemetry destinations and credentials. Empty values disable the corresponding sink. Env vars take precedence over config values. Builds from the public source tree carry no telemetry defaults: `events_url`, `events_api_key`, and `mixpanel_token` are unset and `mixpanel_enabled` is `false`, so nothing is sent unless you supply values here or via env.

```toml
[telemetry]
events_url = "https://example.com/events"  # env: CROK_TELEMETRY_EVENTS_URL
events_api_key = "..."                      # env: CROK_TELEMETRY_EVENTS_API_KEY
mixpanel_token = "..."                      # env: CROK_TELEMETRY_MIXPANEL_TOKEN
mixpanel_enabled = true                     # env: CROK_TELEMETRY_MIXPANEL_ENABLED
trace_upload = true                         # env: CROK_TELEMETRY_TRACE_UPLOAD
```

When building from source, defaults can also be baked into the binary at compile time by setting `GROK_TELEMETRY_BUILD_EVENTS_URL`, `GROK_TELEMETRY_BUILD_EVENTS_API_KEY`, and `GROK_TELEMETRY_BUILD_MIXPANEL_TOKEN` in the build environment (providing a Mixpanel token this way also enables Mixpanel by default). Config-file and runtime env values override build-time defaults.

### LSP Servers

Crok can connect to Language Server Protocol (LSP) servers configured in JSON files. LSP integration gives Crok language-aware code intelligence while it works in your repository.

LSP support is used in two ways:

- **Passive diagnostics** — after edits, Crok can surface language-server diagnostics such as errors and warnings.
- **The `lsp` tool** — Crok can actively query the language server for `goToDefinition`, `findReferences`, `hover`, `goToImplementation`, `documentSymbol`, and `workspaceSymbol`.

Reference: [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)

#### Config locations

Crok looks for server definitions in:

- project config: `<repo>/.grok/lsp.json`
- user config: `~/.crok/lsp.json`

If the same server name appears in both places, the project config wins.

#### Tool enablement

Having an `lsp.json` file is enough for passive diagnostics. The model-visible `lsp` tool is exposed when both of these are true:

- LSP tools are enabled (`CROK_LSP_TOOLS=1` or `[features] lsp_tools = true`)
- the merged LSP configuration is non-empty

Enable the tool for one run:

```bash
CROK_LSP_TOOLS=1 crok
```

Or enable it in config:

```toml
[features]
lsp_tools = true
```

If LSP tools are enabled but no usable server config is found, Crok emits a non-fatal warning in logs and continues without the `lsp` tool. If config exists but every server fails to start, the tool may still be present and will fail on first use with a startup error.

#### Example `lsp.json`

```json
{
  "typescript": {
    "command": "typescript-language-server",
    "args": ["--stdio"],
    "extensionToLanguage": {
      ".ts": "typescript",
      ".tsx": "typescriptreact"
    },
    "startupTimeout": 30000
  }
}
```

#### Required fields

| Field | Description |
|-------|-------------|
| `command` | Server binary to execute. For `stdio`, this must be available in `PATH` or be an absolute path. |
| `extensionToLanguage` | Maps file extensions to LSP language IDs. |

#### Optional fields

| Field | Description |
|-------|-------------|
| `args` | Command-line arguments for the server process. |
| `transport` | `stdio` (default) or `socket`. |
| `env` | Extra environment variables for the server process. |
| `initializationOptions` | JSON passed during LSP initialize. |
| `settings` | Configuration sent via workspace settings updates. |
| `workspaceFolder` | Override workspace folder path sent to the server. |
| `workspaceOpen` | Solution or projects to load, for servers that need to be told explicitly (see below). |
| `startupTimeout` | Max startup wait in milliseconds before startup is considered failed. |
| `shutdownTimeout` | Max graceful shutdown wait in milliseconds. |
| `restartOnCrash` | Whether to restart the server after a crash. |
| `maxRestarts` | Maximum restart attempts before giving up. |

#### Telling a server which solution to load (`workspaceOpen`)

Most servers work out what to analyze from the workspace folder. A few do not,
and instead load their workspace through a protocol extension. The C# server
(`Microsoft.CodeAnalysis.LanguageServer`, "Roslyn") is the notable one: on its
own it treats every file as a loose "miscellaneous file" and reports no
project-level diagnostics at all, until it is told to open a solution or a set
of projects.

```json
{
  "csharp": {
    "command": "dotnet",
    "args": [
      "/path/to/Microsoft.CodeAnalysis.LanguageServer.dll",
      "--stdio",
      "--logLevel", "Warning",
      "--extensionLogDirectory", "/tmp/roslyn-logs"
    ],
    "extensionToLanguage": { ".cs": "csharp" },
    "workspaceOpen": { "solution": "MyApp.sln" },
    "startupTimeout": 60000
  }
}
```

Use `"projects": ["src/App/App.csproj", "src/Lib/Lib.csproj"]` instead of
`"solution"` when there is no solution file. Paths may be absolute or relative
to the workspace root. Wrappers such as `roslyn-language-server` already send
these notifications themselves, in which case `workspaceOpen` can be omitted.

Note that `--logLevel` is required by that server, and that anything more
verbose than `Warning` makes it stream every internal log line to the client.

#### Installing language servers

Crok does not bundle language server binaries. You must install the server yourself and make sure the configured `command` is runnable on your machine.

Examples:

| Language | Server | Install example |
|----------|--------|-----------------|
| TypeScript | `typescript-language-server` | `npm install -g typescript-language-server typescript` |
| Python | `pyright` | `npm install -g pyright` or `pip install pyright` |
| Rust | `rust-analyzer` | Install `rust-analyzer` using your platform's recommended method |

#### Notes

- Passive diagnostics do **not** require `CROK_LSP_TOOLS=1`; they run whenever an applicable server is configured and starts successfully.
- Passive diagnostics are currently driven by `search_replace` edits; they are not a general watcher for arbitrary shell or git mutations in the workspace.
- The `lsp` tool is intentionally hidden when disabled or unconfigured so the model does not plan around unavailable capabilities.
- Same-workspace subagents reuse the parent session's live LSP runtime instead of starting a duplicate server pool.
- That reuse means the child inherits the parent's LSP server set for the shared workspace; child-local LSP config differences are not loaded in the reused-runtime path.

### Enterprise Deployment

A complete `config.toml` for an enterprise deployment with a corporate proxy, rotating gateway tokens, and telemetry disabled:

```toml
[auth_provider.corp]
command = "/usr/local/bin/my-company-token"
token_ttl_secs = 3600               # if your helper outputs bare tokens

[models]
default = "company-grok"

[model.company-grok]
model = "grok-build"
base_url = "https://grok-proxy.acme.com/"
name = "Grok Build Latest (Proxy)"
context_window = 256000
auth_provider = "corp"

[features]
support_permission = false
telemetry = false

[toolset.bash]
timeout_secs = 120.0
```

With this config, `crok` runs your token helper before a turn, keeps the token in memory, and routes inference through your corporate proxy. See [Per-Model Auth Providers](#per-model-auth-providers) for the helper contract.

---

## AGENTS.md

Add project-specific instructions by creating an agent rules file (e.g., `AGENTS.md`). Crok reads these files and appends their contents to the system prompt.

Crok scans for agent rules in this order:

1. `~/.crok/` (global rules)
2. If inside a git repo: every directory from the repo root → current working directory (inclusive)
3. If **not** inside a git repo: only the current working directory

Within each directory, Crok checks for these filenames:

- `Agents.md`, `Claude.md`, `AGENT.md`, `AGENTS.md`

Ordering matters: files found later (deeper directories) come last, so they effectively take precedence if instructions conflict. Files ignored by gitignore are skipped. Each file is capped at 10,000 characters (truncated with a warning if exceeded).

> **Note:** The `--rules` flag appends _additional_ rules on top of any discovered agent files, so you can combine both for session-specific customization.

---

## Skills

Skills are reusable prompt packages that extend Crok with specialized workflows, domain knowledge, and tool integrations. Use them to encode repeatable procedures that would otherwise require re-explaining each session.

### Skill Locations

Crok discovers skills from these directories (in priority order):

| Location                    | Scope | Priority |
| --------------------------- | ----- | -------- |
| `./.grok/skills/`           | Local | Highest  |
| `<repo_root>/.grok/skills/` | Repo  | Medium   |
| `~/.crok/skills/`           | User  | Lowest   |
| `~/.claude/skills/`         | User  | Lowest   |

Skills with the same name are deduplicated — higher priority locations override lower ones.

Repo-scoped skills (Local and Repo) respect `.gitignore` and are filtered out if ignored. User-scoped skills (`~/.crok/skills/`) are outside the repo and never filtered.

### Configuration

Add extra skill directories or exclude paths via `[skills]` in config.toml:

```toml
[skills]
paths = ["~/my-team-skills"]          # additional directories to scan
ignore = ["~/my-team-skills/wip"]     # paths to exclude
```

### Creating a Skill

Each skill lives in its own directory with a `SKILL.md` file:

```
~/.crok/skills/
└── commit/
    └── SKILL.md
```

**SKILL.md format:**

```markdown
---
name: commit
description: Create well-formatted git commits following conventional commit standards. Use when the user wants to commit changes or asks for /commit.
---

# Git Commit Skill

Review staged changes and create a commit with a clear, conventional message.

## Steps

1. Run `git diff --staged` to see changes
2. Summarize what changed and why
3. Create commit message following conventional commits format
4. Run `git commit -m "..."` with the message
```

**Required frontmatter fields:**

| Field         | Description                                                                  |
| ------------- | ---------------------------------------------------------------------------- |
| `name`        | Skill identifier (lowercase, hyphens, max 64 chars)                          |
| `description` | What the skill does and when to use it—this is how Crok decides to invoke it |

### Using Skills

**In the TUI:**

```bash
/skills              # List available skills
/skills commit       # Inject the "commit" skill into context
```

**The model can also invoke skills automatically** when it recognizes a relevant task. The skill's `description` field determines when this happens.

**Slash command shorthand:**

Users can reference skills as `/skill-name` (e.g., `/commit`). When you see this pattern, Crok invokes the corresponding skill.

> **Tip:** The `description` field is critical — it determines when Crok automatically invokes the skill. Be specific about trigger phrases and use cases.

---

## Agent Profiles

Agent profiles control the system prompt, toolset, and behavior of a session. A profile is a `.md` file with YAML frontmatter, or a named agent discovered from disk.

Crok discovers agent definitions from `.grok/agents/` (project), `~/.crok/agents/` (user), and built-in agents. Priority (highest wins):

1. `--agent-profile <PATH>` CLI flag
2. `[agent]` section in `config.toml`
3. `CROK_AGENT` env var
4. Default `grok-build` agent

```toml
# ~/.crok/config.toml
[agent]
name = "my-custom-agent"             # Discovered by name
# definition = "/path/to/agent.md"   # OR: explicit path
```

```bash
crok --agent-profile ./my-agent.md
# or
export CROK_AGENT="my-custom-agent"
```

---

## Subagents

Subagents spawn independent child sessions that handle tasks in parallel. Each child has its own context window and can optionally inherit the parent's conversation history. Enabled by default.

### Disabling

```bash
export CROK_SUBAGENTS=0              # Environment variable
```

```toml
# ~/.crok/config.toml
[subagents]
enabled = false
```

### Toggles and Model Overrides

Disable specific subagent types while keeping the system enabled, or route them to different models:

```toml
[subagents.toggle]
explore = true                       # default — omitted agents are enabled
plan = false                         # disable plan subagent

[subagents.models]
explore = "grok-build"              # route explore to a lighter model
```

By default a subagent inherits the parent session's model. Only an explicit
per-agent pin overrides that: `[subagents.models].<agent>` (highest priority),
then the agent definition's `model`. Both pins apply unconditionally,
regardless of which model the parent is on.

### Roles and Personas

Roles define reusable capability/model defaults. Personas layer tone and behavior instructions onto the child prompt.

```toml
[subagents.roles.researcher]
description = "Deep research agent"
default_capability_mode = "read-only"
model = "grok-build"
prompt_file = ".grok/prompts/researcher.md"

[subagents.personas.concise]
instructions = "Be extremely concise. No filler words."
# instructions_file = ".grok/personas/concise.md"  # or load from file
```

Both are also discovered from `.grok/roles/*.toml` and `.grok/personas/*.toml` files respectively. If a requested persona is not found, the spawn fails (fail-closed).

---

## Plugins

Plugins extend Crok with additional tools, skills, and MCP servers from external packages.

### Plugin Locations

| Location                    | Scope   |
| --------------------------- | ------- |
| `.grok/plugins/`            | Project |
| `~/.crok/plugins/`          | User    |
| `--plugin-dir <PATH>` (CLI) | Session |

### Configuration

```toml
# ~/.crok/config.toml
[plugins]
paths = ["~/my-plugins/custom-tools"]       # additional plugin directories
disabled = ["user/a1b2c3d4/noisy-plugin"]   # plugin IDs to skip
```

Manage plugins at runtime with `/plugins list`, `/plugins reload`, or `/plugins trust <path>`.

---

## Hooks

Hooks run project scripts on tool and session lifecycle events (pre/post-tool-use, session start/end). Projects must be explicitly trusted before their hooks execute.

Crok discovers hooks from `.grok/hooks/` in the project directory. Manage them with:

```
/hooks-list              # show hooks loaded in this session
/hooks-trust             # trust this project for hook execution
/hooks-add <path>        # add a custom hook file or directory
```

### Hooks in config files

Hooks can also be defined directly in the config layers, so they can be
distributed with your other configuration instead of as separate JSON files. Add
a `[[hooks.<Event>]]` table to `config.toml` (your own), `managed_config.toml`, or
`requirements.toml`:

```toml
[[hooks.PreToolUse]]
matcher = "Bash|Write|Edit"
  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = "/opt/guard/pretooluse.sh"   # use an absolute path
  timeout = 10
```

The schema matches the JSON `hooks` object used in hook files. Hooks are read from
every layer and combined additively: a lower-priority layer can add hooks but
never removes or replaces another layer's block. Each hook's `/hooks-list` name is
prefixed with the layer it came from (for example `managed:` or
`requirements/user:`).

Hooks from two kinds of layer are enforced: they cannot be disabled from the
hooks modal, the enable/disable APIs, or the `disabled-hooks` file, and a
byte-identical copy in a lower layer cannot take over their provenance.

- The **root-owned** system layers (`/etc/grok/requirements.toml`,
  `/etc/grok/managed_config.toml`). Enforcement relies on OS file ownership, so
  deploy these files root-owned (or via MDM).
- The **signed** `$CROK_HOME/requirements.toml` the deployment sync writes.
  Its hooks are enforced while the file's bytes match the server-signed
  envelope (`requirements/signed:` names); an edited copy, or one whose
  signature file is missing or unreadable, is the user's own file again
  (`requirements/user:` names, disableable); an unreadable `requirements.toml`
  contributes no hooks. Pair the policy with `fail_closed = true`, which
  refuses the session on an edited copy or a missing signature (an unreadable
  file is a read error, not tampering, and still starts).

Hooks in the other `$CROK_HOME` layers (`managed_config.toml`, `config.toml`)
remain convenience distribution, not an enforcement boundary: the user owns
that directory and can edit or repoint it.

`allow_managed_hooks_only = true` (also `allowManagedHooksOnly`) in any policy
layer is a tighten-only pin that skips every hook that is not managed policy:
user, project, plugin, agent-frontmatter, and vendor-compat hooks are left out of
dispatch and show `[disabled]` in the modal, and enabling them is refused.
ACP client-registered hooks are unaffected. A non-boolean value engages the pin.

---

## Custom Models

Add custom model endpoints to use alternative providers or self-hosted models. You can also override built-in models with custom settings.

### Model Configuration

The name in the TOML header (`my-model` in `[model.my-model]`) is what appears in the model picker. The `model` field is the identifier sent to the API. If `model` is omitted, the header name is sent to the API directly.

```toml
[model.my-model]
model = "model-id"                    # Model identifier sent to API
base_url = "https://api.example.com/v1"  # OpenAI-compatible endpoint
name = "Display Name"                 # Shown in model picker
description = "Model description"     # Optional description
api_key = "sk-..."                    # API key for this provider (optional)
env_key = "OPENAI_API_KEY"            # Env var(s) holding the API key (string or array; first set wins)
auth_provider = "corp-gateway"        # Named credential helper for rotating tokens (optional)
temperature = 0.7                     # Sampling temperature (0.0-2.0)
top_p = 0.95                          # Nucleus sampling parameter
max_completion_tokens = 8192          # Max tokens per response
context_window = 256000               # Total context window in tokens (for auto-compact)
```

**Credential resolution order:** `api_key` → `env_key` → cached `auth_provider` token (terminal: a cache miss resolves to no credential) → `XAI_API_KEY`. See [Per-Model Auth Providers](#per-model-auth-providers).

The `context_window` parameter is used to calculate when auto-compact should trigger. If not specified, Crok falls back to built-in defaults for known models. To offer a choice of windows, set `context_windows = [256000, 500000]`. `context_window` stays the default (the first listed window when unset), and older clients ignore the list.

### Overriding Built-in Models

You can override specific fields of built-in models without redefining everything. Only specify the fields you want to change:

```toml
# Override just the API key for a default model
[model.grok-build]
api_key = "my-api-key"

# Override temperature and add a custom API key
[model.grok-4.20-0309-reasoning]
temperature = 0.5
api_key = "sk-custom"
```

**How it works:** When you override a built-in model, Crok starts with the default configuration (including the correct `base_url` from your `[endpoints]` setting), then applies only the fields you specify. Unspecified fields inherit from the default.

**Priority order:**
1. Your config (`[model.*]`) — highest priority
2. Prefetched models from remote `/v1/models`
3. Hardcoded defaults — lowest priority

**Web search model:** Set `[models] web_search`, `CROK_WEB_SEARCH_MODEL`, or `--web-search-model` to point the `web_search` tool at a different model. The target endpoint must support the Responses API and web search.

> **Overriding with a custom model:** Setting `[models] web_search` alone is not
> enough if the model isn't already in the catalog (built-in defaults or
> `crok models` output). You also need a `[model.*]` entry so Crok knows
> how to reach it. Without both, web search is silently disabled.
>
> ```toml
> [models]
> web_search = "my-custom-model"       # 1. tell web search which model to use
>
> [model.my-custom-model]              # 2. tell Crok how to reach it
> model = "my-custom-model"
> api_backend = "responses"            # required — web search uses the Responses API
> # base_url, api_key, env_key optional — defaults to cli-chat-proxy
> ```

### Examples

**OpenAI-compatible endpoint:**

```toml
[model.local-llama]
model = "llama-3.1-70b"
base_url = "http://localhost:8080/v1"
name = "Local Llama"
temperature = 0.8
```

**Ollama:**

```toml
[model.ollama-codellama]
model = "codellama"
base_url = "http://localhost:11434/v1"
name = "CodeLlama (Ollama)"
```

**Together AI:**

```toml
[model.together-mixtral]
model = "mistralai/Mixtral-8x7B-Instruct-v0.1"
base_url = "https://api.together.xyz/v1"
name = "Mixtral 8x7B"
env_key = "TOGETHER_API_KEY"
```

**OpenAI:**

```toml
[model.gpt-4o]
model = "gpt-4o"
base_url = "https://api.openai.com/v1"
name = "GPT-4o"
env_key = "OPENAI_API_KEY"
```

### Using Custom Models

```bash
# List available models (including custom)
crok models

# Use in TUI via slash command
/model my-model

# Use in headless mode
crok -p "Hello" -m my-model

# Set as default
# In config.toml:
[models]
default = "my-model"
```

### Custom Models Endpoint

Point Crok at a custom OpenAI-compatible `/v1/models` endpoint instead of the default cli-chat-proxy. Useful when models are served behind a corporate gateway or self-hosted inference stack.

**Environment variables:**

| Variable | Required | Description |
|----------|----------|-------------|
| `CROK_MODELS_BASE_URL` | Yes | Base URL for inference / chat completions (e.g. `https://api.acme.com/v1`). The model list is fetched from `{base_url}/models` automatically |
| `XAI_API_KEY` | Yes | API key sent as `Authorization: Bearer` to the custom endpoint |
| `CROK_MODELS_LIST_URL` | No | Override the model list URL if it differs from `{base_url}/models` |

**Setup:**

```bash
export CROK_MODELS_BASE_URL="https://api.acme.com/v1"
export XAI_API_KEY="xai-..."
crok
```

Crok fetches the model list from `{CROK_MODELS_BASE_URL}/models` on startup and sends inference requests to `CROK_MODELS_BASE_URL`. This follows the standard OpenAI-compatible convention used by OpenAI, Anthropic, OpenRouter, Groq, Together.ai, and others.

If your model list endpoint differs from `{base_url}/models`, set `CROK_MODELS_LIST_URL` explicitly.

**Combining with `[endpoints]` config:** You can also set endpoints in `~/.crok/config.toml`:

```toml
[endpoints]
models_base_url = "https://api.acme.com/v1"

# Override just the API key for a specific model
[model.grok-build]
api_key = "my-api-key"
```

Each `[model.*]` section inherits `base_url` from the `[endpoints]` config. `XAI_API_KEY` is still required. A per-model `api_key`/`env_key` authenticates that model's inference requests. The startup model-list fetch still uses `XAI_API_KEY`.

**Auth behavior:** When `models_base_url` is set, Crok authenticates the model-list request with `XAI_API_KEY` (`Authorization: Bearer`). That request never uses a `crok login` session. With an external auth provider (`auth_provider_command`) and no `XAI_API_KEY`, it sends the provider's token instead. Otherwise, if `XAI_API_KEY` is unset, the fetch fails with an error asking you to set it. Inference requests to the custom host authenticate with each model's `api_key`/`env_key`.

---

## MCP Servers

Extend Crok's capabilities with [Model Context Protocol](https://modelcontextprotocol.io) servers.

### Configuration

MCP servers are configured in `~/.crok/config.toml`:

```toml
[mcp_servers.<name>]
command = "/path/to/server"           # Server executable
args = ["--flag", "value"]            # Command arguments
env = { VAR = "value" }               # Environment variables
headers = { "X-Header" = "value" }    # Optional HTTP headers (Streamable HTTP)
enabled = true                        # Enable/disable (default: true)
startup_timeout_sec = 30              # Init timeout (default: 30)
tool_timeout_sec = 60                 # Tool call timeout (default: 60)
tool_timeouts = { create_issue = 120, search = 30 }  # Per-tool timeout overrides (seconds)
```

### Project-Scoped MCP Servers

MCP servers can also be configured per-project in `.grok/config.toml`. Crok walks from the current directory up to the git repo root, loading `.grok/config.toml` at each level:

| Location                        | Scope             | Priority |
| ------------------------------- | ----------------- | -------- |
| `~/.crok/config.toml`           | All projects      | Lowest   |
| `<repo-root>/.grok/config.toml` | This repository   | ↑        |
| `<cwd>/.grok/config.toml`       | Current directory | Highest  |

If a project defines a server with the same name as a global one, the project version **replaces** it entirely (fields are not merged — omitted fields get defaults, not the global values). Servers defined only in the global config are unaffected.

**Example:** commit a `.grok/config.toml` in your repo to share MCP servers across the team:

```
my-project/
├── .grok/
│   └── config.toml
├── src/
└── ...
```

```toml
# .grok/config.toml
[mcp_servers.linear]
command = "npx"
args = ["-y", "mcp-remote", "https://mcp.linear.app/mcp"]
```

If you also have a `linear` server in `~/.crok/config.toml`, the project version replaces it entirely.

> **Note:** Only `[mcp_servers]` is supported in project-scoped `.grok/config.toml`. Other config sections (models, etc.) are only read from `~/.crok/config.toml`.

### Tool Naming

MCP tools are namespaced with the server name:

- Server `filesystem` with tool `read_file` → `filesystem__read_file`
- Server `github` with tool `create_issue` → `github__create_issue`

### Example Servers

**Filesystem access:**

```toml
[mcp_servers.filesystem]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/allowed/directory"]
```

**GitHub integration:**

```toml
[mcp_servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env = { GITHUB_PERSONAL_ACCESS_TOKEN = "ghp_xxxxxxxxxxxx" }
```

**Postgres database:**

```toml
[mcp_servers.postgres]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-postgres", "postgresql://user:pass@localhost/db"]
```

**Custom server:**

```toml
[mcp_servers.my-tools]
command = "/usr/local/bin/my-mcp-server"
args = ["--config", "/etc/my-mcp.json"]
startup_timeout_sec = 30
tool_timeout_sec = 120
```

**Streamable HTTP with session id header:**

```toml
[mcp_servers.my-http-mcp]
url = "http://localhost:5000/api/mcp"
headers = { "x-session-id" = "{{session_id}}" }
```

### Available MCP Servers

See the [MCP Server Registry](https://github.com/modelcontextprotocol/servers) for community servers:

- Filesystem, Git, GitHub, GitLab
- PostgreSQL, SQLite, Redis
- Slack, Discord, Linear
- Puppeteer, Playwright
- And many more

---

## Memory

> **Experimental:** enable with `CROK_MEMORY=1`, `[memory] enabled = true`, or managed remote settings.

Cross-session memory lets Crok remember facts, decisions, code patterns, and debugging workflows across separate sessions in the same project.

### How it works

Memory is stored as Markdown files under `~/.crok/memory/`:
- **Global** (`~/.crok/memory/MEMORY.md`) — facts that apply across all your projects
- **Workspace** (`~/.crok/memory/<project-slug>-<hash8>/MEMORY.md`) — project-specific conventions and context
- **Session logs** (`~/.crok/memory/<project-slug>-<hash8>/sessions/`) — per-session summaries

Workspace directories are suffixed with a short hash for uniqueness (e.g. `xai-a3f7b2c9/`). The hash is derived from the git remote URL so all clones and worktrees of the same repository share the same memory directory.

An SQLite index enables fast hybrid search (FTS5 keyword + optional vector KNN) across all memory files.

### Enabling memory

```bash
# Environment variable (persists for the shell session)
export CROK_MEMORY=1
crok

# Config file (persists permanently)
# ~/.crok/config.toml
[memory]
enabled = true
```

### What gets saved automatically

At the end of each session, Crok saves a **structured metadata summary** to the daily session log:
- Message counts (user / assistant / tool)
- Topics — the first few real user prompts from the session
- Tool-usage breakdown (e.g., `read_file: 4, search_replace: 3`)
- File paths that were read or edited
- Date and session ID

Shell commands are intentionally **not** recorded in automatic saves — command
strings often embed secrets (tokens, API keys, DSNs) and auto-save runs silently.
For command history, use `/flush`, which is user-initiated and produces an
LLM-generated summary rather than raw verbatim output.

This summary is searchable in future sessions but does **not** capture full content or reasoning.

### Capturing rich knowledge with `/flush`

For richer capture — decisions, patterns, debugging workflows, API discoveries — use `/flush` in the TUI. This triggers an LLM-generated summary of the current session's most important content and writes it to a dated session log under `~/.crok/memory/<project-slug>-<hash8>/sessions/`, where it is indexed and searchable in future sessions.

Use `/flush` when you want to preserve important context before compaction or at any point during a productive session.

```
/flush
```

### Appending to memory manually

You can append facts directly from the TUI without leaving the session:

```
/memory workspace Use Rust for all backend services.
/memory global Prefer 2-space indentation in TypeScript.
/memory global Preferred editor: VS Code with Vim keybindings.
```

Omit `workspace` or `global` and it defaults to workspace scope.

### Searching memory

Crok searches memory automatically on the first turn of each session and after compaction. The first-turn injection can be disabled or given its own score threshold under `[memory.initial_injection]`. You can also invoke `memory_search` and `memory_get` directly via the model prompt:

```
Search memory for "auth middleware patterns"
Read my workspace MEMORY.md
```

### CLI commands

```bash
# Open workspace MEMORY.md in $EDITOR / $VISUAL
crok memory edit

# Open global MEMORY.md
crok memory edit --global

# Show memory statistics: file count, chunk count, and index size
crok memory stats
```

### Configuration reference

Key options under `[memory]` in `~/.crok/config.toml`:

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `false` | Enable memory (can also be set via CLI flag or env var) |
| `session.save_on_end` | `true` | Write the lightweight metadata summary on session end |
| `watcher.enabled` | `true` | Watch `~/.crok/memory/` for external edits and reindex on search |
| `search.max_results` | `6` | Default number of memory results to return |
| `search.min_score` | `0.35` | Minimum relevance score threshold for explicit memory search and recovery paths |
| `initial_injection.enabled` | `true` | Enable automatic first-turn memory injection |
| `initial_injection.min_score` | `0.0` | Override score threshold for first-turn injection (`0.0` preserves historical no-filter behavior) |
| `embedding.model` | *(unset)* | Embedding model for vector search; unset disables embeddings |
| `embedding.dimensions` | `1024` | Embedding vector dimensions |

### Observability

When first-turn memory injection runs, Crok emits the `grok-shell-memory_injection`
telemetry event. It includes:
- whether the greeting fallback query path was used
- result counts and top score
- the configured first-turn threshold via `configured_min_score`

---

## Sandbox

Crok can restrict what the agent process and its spawned commands can access on
your filesystem and network using OS-level kernel primitives (Landlock on Linux,
Seatbelt on macOS). This is off by default.

### Quick Start

```bash
# Run with workspace sandbox (read everywhere, write only to CWD + /tmp)
crok --sandbox workspace

# Read-only mode (agent can read but not write anything)
crok --sandbox read-only

# Maximum isolation (read/write CWD only, no child network)
crok --sandbox strict
```

### Built-in Profiles

| Profile         | FS Read            | FS Write                  | Child Network | Use Case                 |
| --------------- | ------------------ | ------------------------- | ------------- | ------------------------ |
| `off` (default) | Unrestricted       | Unrestricted              | Unrestricted  | No sandbox               |
| `workspace`     | Everywhere         | CWD + `/tmp` + `~/.crok/` | Allowed       | Normal development       |
| `read-only`     | Everywhere         | `~/.crok/` only           | Blocked       | Exploration, code review |
| `strict`        | CWD + system paths | CWD + `/tmp` + `~/.crok/` | Blocked       | Untrusted code           |

Sensitive paths (`~/.ssh/`, `~/.aws/`, `~/.gnupg/`, `~/.crok/auth/`) are always
write-protected regardless of profile.

### Custom Profiles

Create `~/.crok/sandbox.toml` (global) or `.grok/sandbox.toml` (per-project):

```toml
[profiles.devbox]
# Start from a built-in profile, then add overrides
extends = "workspace"
restrict_network = true

# Paths the agent can read but NOT write/delete
read_only = ["/data"]

# Additional writable paths (literal directory grants — no globs;
# trailing /** is treated as the parent directory)
read_write = ["/tmp/scratch"]

# Paths denied entirely
deny = ["/data/shared-secrets"]
```

Use it:

```bash
crok --sandbox devbox
```

### How It Works

The sandbox is applied to the **entire crok process** at startup using kernel
primitives — not per-command wrapping. This means all tool operations are
covered:

- `read_file`, `search_replace`, `list_dir` — restricted by Landlock/Seatbelt in-process
- `bash` commands, `grep` (rg) — child processes inherit FS restrictions automatically
- Network — child processes can be blocked via seccomp (Linux)

The sandbox is **irreversible** once applied. This is a security feature — the
model cannot convince the agent to relax restrictions at runtime.

### Current Limitations

- **Platform support**: Sandbox enforcement uses Landlock on Linux (kernel ≥ 5.13)
  and Seatbelt on macOS. If the sandbox cannot be applied (e.g., unsupported
  kernel, missing entitlements), Crok logs a warning and continues without
  enforcement.

- **Network restrictions are partial**: Profiles with `restrict_network` block
  network in **child processes** (bash commands, scripts) via seccomp, but
  built-in tools that make HTTP requests in-process (web search, LLM API) are
  not affected. The agent needs network access to function, so process-level
  network cannot be blocked.

### Event Logging

Sandbox events (profile applied, violations) are logged to `~/.crok/sandbox-events.jsonl`
for telemetry and debugging.

---

## Introspection

Use `crok inspect` to see everything Crok discovers in the current directory:

```bash
crok inspect          # human-readable output
crok inspect --json   # machine-readable JSON
```

The output shows all loaded configuration organized by type:

- **Project Instructions** — AGENTS.md / CLAUDE.md files with token counts
- **Skills** — from `.grok/skills/`, `~/.crok/skills/`, plugins, and config paths
- **Agents** — built-in, user-defined, and plugin-provided subagents
- **Plugins** — discovered plugins with what each provides (skills, agents, hooks, MCPs)
- **MCP Servers** — from `config.toml`, plugins, `~/.claude.json`, and `.mcp.json`
- **LSP Servers** — language servers from `lsp.json` and plugins
- **Hooks** — project and plugin hooks
- **Permissions, Config Sources** — which config files are active

Plugin-provided components appear in their respective sections with a `[plugin: name]` tag, so you can see at a glance where each skill, MCP server, or agent originates.

---

## Claude Code Compatibility

Crok automatically discovers configuration from Claude Code directories alongside native `.grok/` paths. No extra setup is needed.

### What is picked up

| Component         | Claude Code location                                 | How Crok uses it                 |
| ----------------- | ---------------------------------------------------- | -------------------------------- |
| **Skills**        | `.claude/skills/`, `~/.claude/skills/`               | Loaded as skills (same as `.grok/skills/`) |
| **Agents**        | `.claude/agents/`, `~/.claude/agents/`               | Loaded as subagents              |
| **Plugins**       | `.claude/plugins/`, `~/.claude/plugins/`             | Discovered with all components   |
| **Installed plugins** | `~/.claude/plugins/installed_plugins.json`        | Each `installPath` is loaded     |
| **Marketplaces**  | `~/.claude/plugins/known_marketplaces.json`          | Plugin dirs from `installLocation` |
| **MCP servers**   | `~/.claude.json`, `.mcp.json`                        | Loaded alongside `config.toml`   |
| **Project rules** | `CLAUDE.md`, `.claude/CLAUDE.md`                     | Loaded as project instructions   |
| **Permissions**   | `.claude/settings.json`, `.claude/settings.local.json` | Fallback when no TOML config   |

### Plugin components

Claude Code plugins can provide skills (`skills/`), commands (`commands/`), agents (`agents/`), hooks (`hooks/hooks.json`), MCP servers (`.mcp.json`), and LSP servers (`.lsp.json`). All component types are discovered and used by Crok at runtime.

---

## Built-in Tools

Crok includes these tools by default:

| Tool             | Description                                                    |
| ---------------- | -------------------------------------------------------------- |
| `read_file`      | Read file contents with line numbers                           |
| `search_replace` | Make precise edits to files                                    |
| `grep_search`    | Search with regex patterns (ripgrep)                           |
| `list_dir`       | List directory contents                                        |
| `bash`           | Execute shell commands                                         |
| `web_search`     | Search the web for up-to-date information                      |
| `web_fetch`      | Fetch a specific URL and return its content as markdown        |
| `todo_write`     | Create and manage task lists                                   |
| `task`           | Launch subagent sessions (requires `--subagents`)              |
| `kill_task`      | Terminate a running background task or subagent                |
| `get_task_output` | Get output and status from a background task or subagent      |
| `memory_search`  | Search cross-session memory (requires memory enabled) |
| `memory_get`     | Read a memory file by path                                     |
| `search_tool`    | Discover available integration tools (MCP)                     |
| `use_tool`       | Call an integration tool discovered via `search_tool`           |
| `lsp`            | Code intelligence via language servers (requires `lsp_tools`)  |

### Controlling Available Tools

In headless mode, you can restrict or remove tools with the `--tools` (allowlist) and `--disallowed-tools` (denylist) flags. See [Headless Mode](#headless-mode) for details and examples.

In agent profiles, use the `tools` and `disallowedTools` frontmatter fields:

```yaml
---
tools:
  - read_file
  - grep_search
  - list_dir
disallowedTools:
  - web_search
  - Agent(explore)
---
```

### `web_fetch`

Fetch a specific URL and return its content as markdown. **Disabled by default** — enable with `CROK_WEB_FETCH=1`. 

When no custom `allowed_domains` is set, the tool permits a default allowlist of useful documentation sites (SpaceXAI, language docs, frameworks, cloud providers, databases, etc.). Domains not on the allowlist prompt the user for approval; `--always-approve` auto-approves all. Domain matching is case-insensitive, strips `www.` prefixes, and supports path-scoped entries (e.g. `x.ai/company`).

---

## Session Persistence

Crok automatically persists conversations to disk. This works across all modes: TUI, headless, and agent stdio.

### Storage Layout

Sessions are stored under `~/.crok/sessions/`, organized by URL-encoded working directory:

```
~/.crok/sessions/<encoded-cwd>/<session-id>/
  summary.json            # metadata: title, timestamps, model, message count
  updates.jsonl           # ACP session update stream (conversation + tool calls)
  chat_history.jsonl      # raw chat messages sent to the model
  plan.json               # TODO/task list state
  rewind_points.jsonl     # file snapshots for /rewind undo
  signals.json            # session signals (turn count, token usage)
  feedback.jsonl          # user feedback and ratings
  compaction_checkpoints/ # saved state from auto-compact
  subagents/              # child session directories (when subagents are enabled)
```

`summary.json` is the index entry — it contains the session title, model ID, creation/update timestamps, and parent session reference (for restored sessions). `updates.jsonl` is the authoritative conversation log that drives `/load` and session restore.

### TUI

Sessions persist automatically as you chat. To start fresh:

```
/new
```

The TUI creates a new session each time you launch unless you continue a previous one.

### Headless Mode

Control session behavior with flags:

```bash
# New session each time (default)
crok -p "Hello"

# Create or resume a named session
crok -p "Remember: X=42" -s my-session
crok -p "What is X?" -s my-session

# Resume existing session (errors if not found)
crok -p "Continue" -r my-session

# Continue most recent session in current directory
crok -p "What were we doing?" -c
```

Session ID is returned in JSON output:

```bash
crok -p "Hello" --output-format json | jq -r '.sessionId'
```

### Agent stdio (ACP)

When building with ACP, sessions are managed via protocol methods:

```typescript
// Create new session
const { sessionId } = await connection.request("session/new", {
  cwd: "/path/to/project",
  mcpServers: [],
});

// Load existing session
await connection.request("session/load", {
  sessionId: "existing-session-id",
  cwd: "/path/to/project",
  mcpServers: [],
});
```

The agent persists all session updates automatically. Clients can reconnect and load previous sessions by ID.

---

## File Locations

| Path                  | Description                                         |
| --------------------- | --------------------------------------------------- |
| `~/.crok/config.toml` | Configuration file                                  |
| `~/.crok/sessions/`   | Persisted sessions (organized by working directory) |
| `~/.crok/provider-auth/` | Provider credentials (`crok login` / `crok logout`) |
| `~/.crok/memory/`     | Cross-session memory files and index                |
| `~/.crok/skills/`     | User-scoped skill definitions                       |
| `~/.crok/plugins/`    | User-scoped plugins                                 |
| `~/.crok/agents/`     | User-scoped agent definitions                       |
| `.grok/config.toml`   | Project-scoped config (MCP servers)                 |
| `.grok/skills/`       | Project-scoped skill definitions                    |
| `.grok/plugins/`      | Project-scoped plugins                              |
| `.grok/agents/`       | Project-scoped agent definitions                    |
| `.grok/hooks/`        | Project-scoped hooks                                |
| `.grok/lsp.json`      | LSP server configuration                            |
| `~/.claude/skills/`   | User-scoped skills (Claude Code compat)             |
| `~/.claude/plugins/`  | User-scoped plugins (Claude Code compat)            |
| `~/.claude.json`      | MCP servers (Claude Code compat)                    |
| `.mcp.json`           | Project-scoped MCP servers (Claude Code compat)     |

---

## Environment Variables

Every `CROK_*` variable below can also be spelled with a `GROK_` prefix; when both are set, the `CROK_` spelling wins.

| Variable                         | Description                                                                                              |
| -------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `OPENROUTER_API_KEY`  | OpenRouter API key; takes precedence over the saved `crok login openrouter` credential                  |
| `ANTHROPIC_API_KEY`   | Claude API key; takes precedence over the saved `crok login anthropic` credential                       |
| `DEEPSEEK_API_KEY`    | DeepSeek API key; takes precedence over the saved `crok login deepseek` credential                      |
| `ZAI_API_KEY`         | GLM Coding Plan key from z.ai; takes precedence over the saved `crok login glm` credential              |
| `ZHIPU_API_KEY`       | GLM Coding Plan key from bigmodel.cn; takes precedence over the saved `crok login glm-cn` credential    |
| `XAI_API_KEY`         | API key from [console.x.ai](https://console.x.ai). Exposes xAI-hosted models and authenticates custom endpoints |
| `CROK_CLI_CHAT_PROXY_BASE_URL`  | Override the cli-chat-proxy URL (default: `https://cli-chat-proxy.grok.com/v1`)                          |
| `CROK_MODELS_BASE_URL`          | Custom base URL for inference. Model list auto-fetched from `{base_url}/models` (see [Custom Models Endpoint](#custom-models-endpoint)) |
| `CROK_MODELS_LIST_URL`          | Override the model list URL if it differs from `{CROK_MODELS_BASE_URL}/models`                                              |
| `CROK_HOME`                     | Override config directory (default: `~/.crok`)                                                           |
| `CROK_SUBAGENTS`                | Enable (`1`) or disable (`0`) subagent/task tool support                                                 |
| `CROK_MEMORY`                   | Enable (`1`) or disable (`0`) cross-session memory                                                       |
| `CROK_AGENT`                    | Custom agent definition path or name (see [Agent Profiles](#agent-profiles))                             |
| `CROK_WEB_FETCH`                | Enable (`1`) or disable (`0`) the `web_fetch` tool                                                       |
| `CROK_WEB_FETCH_PROXY`          | Egress proxy URL for `web_fetch` requests (overridden by `[toolset.web_fetch] proxy_endpoint`)           |
| `CROK_RESPECT_GITIGNORE`        | Disable `.gitignore` filtering in tools when set to `0`                                                  |
| `CROK_FEEDBACK_ENABLED`         | Enable (`1`) or disable (`0`) feedback system independently from telemetry                               |
| `CROK_DEPLOYMENT_KEY`           | Management API key for enterprise deployments                                                            |
| `CROK_LOG_FILE`                 | Enable file logging by providing a file path (the value is used verbatim as the path)                    |
| `CROK_DEBUG_LOG`                | Debug firehose (set by `--debug`): truthy routes per-session logs to `~/.crok/debug/<sessionId>.txt`, a path writes that one file |
| `RUST_LOG`                      | Log filter for stderr (headless `-p` defaults to `off`, other non-TUI modes to `error`; TUI captures stderr) and for the `CROK_LOG_FILE` log; the `--debug` firehose ignores it |

---

## Shell Completions

Generate completions for your shell and install them to enable tab completion for `crok` commands and flags.

**Note:** The paths below are recommended defaults. Some environments do not automatically source the standard locations — you may need to adapt them to your shell framework or distro conventions.

### Bash

Generate and install:

```bash
mkdir -p ~/.local/share/bash-completion/completions
crok completions bash > ~/.local/share/bash-completion/completions/crok
```

Reload your shell or run `source ~/.bashrc`.

Alternative (Crok-managed location):

```bash
mkdir -p ~/.crok/completions/bash
crok completions bash > ~/.crok/completions/bash/crok.bash
```

Add to `~/.bashrc`:

```bash
[[ -r "$HOME/.crok/completions/bash/crok.bash" ]] && source "$HOME/.crok/completions/bash/crok.bash"
```

### Zsh

Generate and install:

```bash
mkdir -p ~/.zsh/completions
crok completions zsh > ~/.zsh/completions/_crok
```

Add to `~/.zshrc`:

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit
compinit
```

Alternative (Crok-managed location):

```bash
mkdir -p ~/.crok/completions/zsh
crok completions zsh > ~/.crok/completions/zsh/_crok
```

Add to `~/.zshrc`:

```zsh
fpath=("$HOME/.crok/completions/zsh" $fpath)
autoload -Uz compinit
compinit
```

### After Upgrading

Regenerate completions after rebuilding `crok` — the script reflects the CLI of the installed version.

---

## Troubleshooting

### Debug logging

Write logs to a file for debugging. The TUI captures stderr, so `RUST_LOG` alone won't produce visible output in production — use `crok --debug` or `CROK_LOG_FILE` instead:

```bash
# Per-session debug log (~/.crok/debug/<sessionId>.txt)
crok --debug

# Log to a custom path
CROK_LOG_FILE=/tmp/crok-debug.log crok

# Tail the most-recently-opened session's log in another terminal (Unix symlink)
tail -f ~/.crok/debug/latest.txt
```

The `--debug` firehose uses a fixed filter (first-party crates at `debug`) and is not narrowed by `RUST_LOG`. A `CROK_LOG_FILE` log defaults to `debug` and honors `RUST_LOG`, so you can set module-level filters for targeted debugging:

```bash
# Debug auth, info for everything else
CROK_LOG_FILE=/tmp/crok-debug.log RUST_LOG="info,xai_grok_login=debug" crok
```

### Authentication fails

```bash
# Clear saved credentials and sign in again
crok logout openrouter
crok login openrouter        # or: crok login openai-codex

# Debug auth issues — check the log for "auth:" entries
crok --debug-file /tmp/crok-auth.log -p "hello"
grep "auth:" /tmp/crok-auth.log
```

### Model not found

```bash
# List available models
crok models

# Check config.toml for typos in [model.*] sections
```

### MCP server not starting

```bash
# Test the server command manually
npx -y @modelcontextprotocol/server-filesystem /path

# Increase startup timeout in config
[mcp_servers.filesystem]
startup_timeout_sec = 30
```

### Command timeout

```toml
# Increase bash timeout in config.toml
[toolset.bash]
timeout_secs = 300.0
```

### Inspecting session data

Session files are plain JSON/JSONL and can be inspected directly:

```bash
# Find sessions for the current directory
ls ~/.crok/sessions/

# Read session metadata
cat ~/.crok/sessions/<encoded-cwd>/<session-id>/summary.json | jq .

# View conversation history
cat ~/.crok/sessions/<encoded-cwd>/<session-id>/updates.jsonl | head -20

# Count turns in a session
wc -l ~/.crok/sessions/<encoded-cwd>/<session-id>/chat_history.jsonl
```

### Context window full

If auto-compact triggers too often, lower the threshold to compact earlier and preserve more headroom:

```toml
[session]
auto_compact_threshold_percent = 70    # default is 85
```

---

## License

Licensed under the Apache License, Version 2.0. See the repository root
`LICENSE` file.
