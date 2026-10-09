# Getting Started

Crok Build is a terminal-based AI coding assistant, built from a personal fork of Grok Build. It runs as a TUI (Terminal User Interface) that understands your codebase, executes shell commands, edits files, searches the web, and manages tasks.

You can use it interactively as a full-screen TUI, run it headlessly for scripting and CI/CD, or integrate it into editors via the Agent Client Protocol (ACP).

---

## Installation

Crok has no prebuilt release; build it from the repository checkout (see the repository README for the Rust and DotSlash requirements):

```bash
make deploy          # builds the release TUI and installs ~/.local/bin/crok
```

Put `~/.local/bin` on your `PATH`, then verify the installation:

```bash
crok --version
```

Crok never updates itself, because the official updater would install grok over it. To update, pull the checkout and run `make deploy` again; `crok update` says the same. On macOS, Crok Desktop bundles its own copy of `crok` and can link it into `/usr/local/bin`.

Crok installs beside an official `grok` and keeps its state in `~/.crok`. To start with an existing grok's settings and sessions, run `make import-grok-config` once from the checkout.

To fetch a repository through Grove (NFS on macOS, FUSE on Linux), enable
`crok clone` with `[clone] enabled = true` in Grove config, `CROK_CLONE=1`,
or the enable-both convenience `CROK_GROVE=1` / `[cli] grove = true` in
`~/.crok/config.toml`:

```bash
crok clone <url> [dir]
```

The default is a depth-1 checkout of the selected branch. Pass `--full-history`
for a complete clone. Clone enablement is independent of session / `-w` Grove
worktrees (the convenience above turns both on; the specific knobs still win).
See [crok clone](27-grok-clone.md) and the
[Configuration reference](26-config-reference.md).

---

## First Launch

Start Crok by running:

```bash
crok
```

On first launch without a provider credential, Crok asks which provider to sign in to: OpenAI Codex (a ChatGPT subscription), OpenRouter, DeepSeek, a GLM Coding Plan, or the Claude API. You can also sign in ahead of time:

```bash
crok login openai-codex
crok login openrouter
crok login deepseek      # asks for an API key
crok login anthropic     # Claude API; asks for an API key
crok login glm           # GLM Coding Plan from z.ai; glm-cn for bigmodel.cn
```

Provider credentials are stored in `~/.crok/provider-auth/` and persist across sessions; Codex tokens refresh automatically. For CI/CD or environments without a browser, set `OPENROUTER_API_KEY` instead:

```bash
export OPENROUTER_API_KEY="sk-or-..."
crok
```

xAI accounts are not supported; use Grok models through OpenRouter (for example `openrouter/x-ai/grok-4`). See [Authentication](02-authentication.md) for details.

---

## Basic Interaction

Once authenticated, Crok presents a full-screen TUI with two main areas:

- **Scrollback** -- the conversation history showing your prompts, Crok's responses, tool calls, file edits, and more.
- **Prompt** -- the input area at the bottom where you type messages.

Type a message and press `Enter` to send it. Crok reads files, runs commands, and edits code as needed. Each tool run streams into the scrollback in real time.

Press `Tab` to move focus between the prompt and the scrollback. While a turn is running, `Ctrl+C` cancels it once the composer is empty — with a draft, the first press only clears it. `Esc` never cancels a turn; mid-turn it shows a reminder to use `Ctrl+C`. Idle, press `Esc` twice within 800ms to clear a non-empty prompt, or (with an empty prompt and conversation messages) to open rewind — see [Keyboard Shortcuts](03-keyboard-shortcuts.md#escape). With the scrollback focused, use the arrow keys to select entries and to collapse or expand them. To navigate with `j`/`k` and fold with `h`/`l` instead, enable Vim mode.

### File References

Use `@` in your prompt to attach files:

```
@src/main.rs              # Attach a file
@src/main.rs:10-50        # Attach lines 10-50
@src/                     # Browse a directory
```

The `@` operator opens a fuzzy file picker. By default it respects `.gitignore` and hides dotfiles. Prefix with `!` to search hidden files:

```
@!.github                 # Search hidden files
@!.env                    # Attach a .env file
```

### Permissions

By default, Crok asks for permission before executing shell commands or editing files. You can approve individually or toggle always-approve mode:

- Press `Ctrl+O` to toggle always-approve mode
- Use the `--yolo` flag at launch: `crok --yolo`
- Type `/always-approve` in the prompt to toggle the mode

---

## Key Concepts

### Sessions

Every conversation is a **session**. Sessions are automatically saved to `~/.crok/sessions/` and can be resumed later. Each session tracks the full conversation history, tool calls, file edits, and task state.

- Start a new session: `Ctrl+N` or `/new`
- Resume a previous session: `/resume` in the TUI, or `--resume <ID>` from the CLI
- Continue the most recent session: `crok -c`

### Scrollback

The scrollback is the main display area. It shows:

- **User prompts** -- your messages, rendered as sticky headers
- **Agent messages** -- Crok's responses with full markdown rendering and syntax highlighting
- **Thinking blocks** -- Crok's reasoning process (collapsible)
- **Tool calls** -- file edits (with inline diffs), command executions, search results, and more
- **Task lists** -- TODO items tracking progress

Collapse or expand the selected entry with the `Left`/`Right` arrow keys (or `h`/`l` and `e` in Vim mode). In Vim mode, press `y` to copy its content and `Y` to copy its metadata (for example, the command that ran). Press `Enter` to open it in the fullscreen viewer (in any mode).

### Tools

Crok has built-in tools for:

| Tool | Description |
|------|-------------|
| `read_file` / `search_replace` | Read and edit files with line-precise changes |
| `grep` | Regex search across your codebase (powered by ripgrep) |
| `list_dir` | List directory contents |
| `run_terminal_command` | Execute shell commands |
| `web_search` / `web_fetch` | Search the web and fetch URLs |
| `todo_write` | Create and manage task lists |
| `spawn_subagent` | Spawn parallel subagent sessions |
| `memory_search` | Search cross-session memory |

Tools can be extended with [MCP servers](05-configuration.md#mcp-servers) for integrations like GitHub, databases, and more.

### Slash Commands

Type `/` in the prompt to access commands. These provide quick actions without writing a full prompt:

```
/model openrouter/x-ai/grok-4     # Switch model
/compact                          # Compress conversation history
/always-approve                   # Toggle always-approve mode
/new                              # Start a new session
```

See [Slash Commands](04-slash-commands.md) for the complete reference.

---

## Common Launch Options

```bash
# Launch the interactive TUI and submit an initial prompt as the first turn
crok "fix the failing auth test and run it"

# Initial prompt in a new git worktree. Use --worktree=<name> (with `=`) so the
# prompt isn't swallowed as the worktree name — `crok -w "refactor module X"`
# would treat "refactor module X" as the worktree label, not the prompt.
crok --worktree=feat "refactor module X"

# Base the worktree on a specific branch (e.g. main) instead of the current HEAD:
crok -w --ref main "implement feature from main"


# Start in a specific project directory
crok --cwd ~/projects/my-app

# Add project-specific rules
crok --rules "Always use TypeScript. Prefer functional components."

# Auto-approve all tool executions
crok --yolo

# Use a specific model
crok -m openrouter/x-ai/grok-4

# Resume a previous session
crok --resume <session-id>

# Continue the most recent session
crok -c

# Experimental scrollback-native render mode. Sticky: plain `crok` reopens in
# the mode last chosen via --minimal/--fullscreen (or /minimal//fullscreen).
crok --minimal

# Back to the standard fullscreen TUI (and make it sticky again)
crok --fullscreen

# Headless mode (for scripts)
crok -p "Explain this codebase"
```

---

## Headless Mode

Run Crok non-interactively for scripting, CI/CD, and automation:

```bash
crok -p "Your prompt here"
```

Output formats:

| Format | Flag | Description |
|--------|------|-------------|
| `plain` | (default) | Human-readable text |
| `json` | `--output-format json` | Single JSON object with `text`, `stopReason`, `sessionId`, and `requestId` |
| `streaming-json` | `--output-format streaming-json` | NDJSON event stream for real-time processing |

Example CI/CD usage:

```bash
crok -p "Review changes for bugs" --output-format json --yolo | jq -r '.text'
```

---

## Project Rules (AGENTS.md)

Add per-project instructions by creating an `AGENTS.md` file in your repository. Crok reads these files and injects their contents as a project-instructions message at the start of the conversation:

```
~/.crok/AGENTS.md           # Global rules (apply to all projects)
<repo-root>/AGENTS.md       # Repository-level rules
<cwd>/AGENTS.md             # Directory-level rules (highest priority)
```

Deeper files take precedence. Crok also reads `CLAUDE.md` files for compatibility.

---

## Where to Go Next

| Document | What You Will Learn |
|----------|-------------------|
| [Authentication](02-authentication.md) | OpenRouter and OpenAI Codex sign-in, Claude API, DeepSeek and GLM Coding Plan keys |
| [Keyboard Shortcuts](03-keyboard-shortcuts.md) | Complete reference for all key bindings |
| [Slash Commands](04-slash-commands.md) | All available `/` commands |
| [Configuration](05-configuration.md) | config.toml, pager.toml, environment variables |
