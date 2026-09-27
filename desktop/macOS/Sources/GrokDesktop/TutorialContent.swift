// Generated from crates/codegen/xai-grok-pager/docs/tutorial/*.md by scripts/gen-tutorial.py.
// The page text is verbatim; regenerate instead of editing it by hand.

/// The nine `/tutorial` topics, in the terminal's order (`xai-grok-pager/src/tutorial_docs.rs`).
enum GrokTutorial {
    static let topics: [GrokTutorialTopic] = [
        GrokTutorialTopic(
            id: "01-coming-from-another-tool",
            title: "Coming from Claude, Cursor, or Codex?",
            blurb: "your settings, rules & skills carry over",
            goDeeper: "Project Rules (AGENTS.md)",
            content: #"""
            # Coming from Claude, Cursor, or Codex?

            Fear not — your settings, rules, and skills come with you. Crok Build
            reads the same project conventions other agents use, and imports the rest.

            ## Picked up automatically

            - **Rules & instructions** — `AGENTS.md` (the Codex/OpenCode convention),
              `CLAUDE.md` (including nested ones), and `*.md` rules under
              `.claude/rules/` and `.cursor/rules/`.
            - **Skills & custom commands** — `~/.claude/skills/`, `~/.claude/commands/`,
              `~/.cursor/skills/`, and their project-level twins. Flat command `.md`
              files become slash commands here too.
            - **MCP servers** — from `~/.claude.json`, `.cursor/mcp.json`, and project
              `.mcp.json`.
            - **Hooks** — from `.claude/settings.json`, including matcher aliases like
              `Bash`, so most hooks run unchanged.

            ## One-step import

            **`/import-claude`** scans your `~/.claude` settings — permissions, env
            vars, MCP servers, hooks — and shows a checkbox preview; confirming
            writes the items you selected into your `.grok` config. Re-run it anytime.

            ## Pick up where you left off

            The **`/resume-claude`**, **`/resume-codex`**, and **`/resume-cursor`**
            skills continue a recent session from those tools right here.

            ## Check what was discovered

            Run **`crok inspect`** in a repo to see every rules file, skill, and MCP
            server Crok picked up, tagged with where it came from. Each compat source
            can be toggled in `[compat.claude]` / `[compat.cursor]` config sections.

            And a few things you might have missed elsewhere: `/btw` asks a side
            question without interrupting the current task, and `/rewind` rewinds the
            conversation to an earlier turn (file changes stay as they are).

            *Go deeper: `/docs Project Rules (AGENTS.md)`, `/docs Skills`, or `/docs MCP Servers`*
            """#
        ),
        GrokTutorialTopic(
            id: "02-first-prompt",
            title: "Your First Prompt",
            blurb: "send, queue, cancel",
            goDeeper: "Getting Started",
            content: #"""
            # Your First Prompt

            Crok Build is a conversation with an agent that can read your code, run
            commands, and edit files — right here in your terminal.

            Type what you want and press `Enter`. Crok streams its work into the
            **scrollback** above the prompt: responses, shell commands, file edits.

            ## Keep typing while Crok works

            While a turn is running, `Enter` **queues** your next message instead of
            interrupting. Change your mind? Press `Enter` on the empty prompt to stop
            the current turn and send the queued message right away.

            ## You are always in control

            - **`Ctrl+C`** — cancel a running turn (with a draft, the first press only clears it). `Esc` does not cancel; it reminds you to use `Ctrl+C`.
            - **`Esc Esc`** while idle — clear the prompt; with an empty prompt, open
              the rewind picker instead. Cleared something by accident? `Ctrl+Z` undoes.
            - **`Ctrl+Q`** — quit (`Ctrl+D` in VS Code-family terminals), press twice.

            The **shortcuts bar** at the bottom always shows the keys relevant to what
            you're doing right now — when in doubt, look down.

            *Go deeper: `/docs Getting Started`*
            """#
        ),
        GrokTutorialTopic(
            id: "03-attach-and-paste",
            title: "Attach Files, Images & Paste",
            blurb: "@files, line ranges, screenshots",
            goDeeper: "Getting Started",
            content: #"""
            # Attach Files, Images & Paste

            The more precisely you point Crok at the right context, the better the
            result. Three ways to get things into the prompt:

            ## Mention files with `@`

            Type `@` for a fuzzy file picker — line ranges work too:

            ```
            @src/main.rs          attach a file
            @src/main.rs:10-50    attach specific lines
            @!.env                reach hidden files with @!
            ```

            ## Paste images

            Paste a screenshot straight into the prompt: `Cmd+V` on macOS, `Ctrl+V` on
            Linux, `Alt+V` on Windows. Great for error dialogs, designs, and diagrams.

            ## Run shell commands yourself

            Type `!` on an empty prompt to run a shell command directly — the output
            lands in the scrollback where Crok can see it too.

            *Go deeper: `/docs Getting Started`*
            """#
        ),
        GrokTutorialTopic(
            id: "04-navigation",
            title: "Finding Your Way Around",
            blurb: "focus, scrollback, panes",
            goDeeper: "Keyboard Shortcuts",
            content: #"""
            # Finding Your Way Around

            The screen has three parts: the **scrollback** (the conversation), the
            **prompt** below it, and the **shortcuts bar** at the bottom. Panes for
            todos and background tasks slide in when you need them.

            ## Focus

            **`Tab`** switches focus between the prompt and the scrollback. Focused
            scrollback gets a selection you can move with the arrow keys.

            ## Moving through the conversation

            - **`↑`/`↓`** — select the previous/next entry.
            - **`Shift+←`/`Shift+→`** — jump between turns (your prompts).
            - **`PageUp`/`PageDown`** — scroll by page; this works straight from the
              prompt, no focus change needed.
            - **`←`/`→`** — collapse/expand the selected entry; long tool output stays
              out of your way until you want it.
            - **`Enter`** — open the selected entry in a fullscreen viewer.

            ## Panes

            - **`Ctrl+T`** — toggle the **todos pane**: Crok's live plan for the
              current task.
            - **`Ctrl+G`** — toggle the **tasks pane**: everything running in the
              background, with its status.

            Prefer vim keys? **`/vim-mode`** switches the scrollback to `j`/`k`,
            `g`/`G`, and friends.

            *Go deeper: `/docs Keyboard Shortcuts`*
            """#
        ),
        GrokTutorialTopic(
            id: "05-slash-commands",
            title: "Slash Commands",
            blurb: "/help  /model  /resume  and Ctrl+P",
            goDeeper: "Slash Commands",
            content: #"""
            # Slash Commands

            Type `/` on an empty prompt and a searchable dropdown of commands appears.
            A few worth knowing on day one:

            | Command | What it does |
            |---------|--------------|
            | `/help` | Browse every command and keyboard shortcut |
            | `/model` | Switch models or reasoning effort |
            | `/resume` | Pick up a previous session where you left off |
            | `/new` | Start a fresh session |
            | `/compact` | Compress a long conversation to free up context |
            | `/btw` | Send Crok an aside *without* interrupting its current task |
            | `/rewind` (alias `/undo`) | Rewind the conversation to an earlier turn |
            | `/docs` | Full How-to Guides, in the TUI or on the web |
            | `/feedback` | Send feedback to the team |

            Two of those deserve a second look:

            - **`/compact`** takes an optional hint: `/compact keep the auth details`.
              Check context usage anytime with `/context` — Crok also auto-compacts
              when the window fills up.
            - **`/rewind`** (or **`/undo`**) rewinds the conversation to an earlier
              turn, dropping later turns (file changes are left as-is).

            ## The command palette

            Press **`Ctrl+P`** (or `?` from the scrollback) to open the command palette —
            one searchable list of every command, shortcut, and skill. There's also a
            full shortcuts cheatsheet on `Ctrl+.` (use `Ctrl+X` if your terminal
            swallows it).

            You don't need to memorize anything: `/` and `Ctrl+P` will always show you
            what's available.

            *Go deeper: `/docs Slash Commands`*
            """#
        ),
        GrokTutorialTopic(
            id: "06-worktrees",
            title: "Parallel Work: Worktrees",
            blurb: "isolated sessions on one repo",
            goDeeper: "Session Management",
            content: #"""
            # Parallel Work: Worktrees

            Want Crok working on a feature while you (or another Crok session) work on
            something else in the same repo? **Git worktrees** give each session its own
            isolated checkout — no stepping on each other's changes, no stashing.

            ## Start a session in a worktree

            - **From anywhere:** press `Ctrl+N` (twice to confirm) for a new session,
              then choose the worktree option.
            - **From the welcome screen:** press `Ctrl+W` (inside a git repo) to open
              the New Worktree dialog.
            - **From the shell:**

              ```bash
              crok --worktree=my-feature "refactor the auth module"
              ```

              (Use `=` — otherwise the prompt is taken as the worktree name.)

            ## Why this is great

            - Run two or three Crok sessions on the same repo simultaneously.
            - Experiments stay isolated — if a change doesn't work out, your main
              checkout is untouched.
            - When the work is done, apply the changes back like any git branch.

            **`/fork`** copies your current conversation into a parallel session —
            add a directive to point it at a task: `/fork try the async approach`.

            Running several agents? The **dashboard** (`/dashboard` or `Ctrl+\`) shows
            every session grouped by state — who needs input, who's working, who's done.

            *Go deeper: `/docs Session Management`*
            """#
        ),
        GrokTutorialTopic(
            id: "07-plan-and-permissions",
            title: "Plan Mode & Permissions",
            blurb: "review the approach before it acts",
            goDeeper: "Plan Mode",
            content: #"""
            # Plan Mode & Permissions

            Crok asks before doing anything risky — and can plan before it codes.

            ## Permissions

            When Crok wants to run a risky command or edit a file, it pauses and asks:
            allow once, always allow that kind of action, or deny.

            Reading is always free: file reads, searches, and safe read-only commands
            (`ls`, `git status`, `grep`, …) never prompt. Chained commands are
            checked piece by piece — `ls && rm -rf tmp` still prompts for the `rm`.

            Trust the session? `/always-approve` (or `Ctrl+O`) skips the prompts.

            ## Plan mode

            For bigger or more ambiguous tasks, use **plan mode**: Crok explores the
            codebase read-only, designs an approach, and presents a plan you approve
            *before* any code is written.

            - **`Shift+Tab`** (prompt focused) cycles the mode: Normal → Plan →
              Always-approve.
            - **`/plan`** enters plan mode directly; `/plan <task>` plans that task in
              one step.

            When the plan is ready: `a` approves, `c` comments on a specific line,
            `s` requests changes — Crok iterates until you're happy, then implements.

            A good habit: plan mode for "how should we even do this?", normal mode for
            "just do it".

            ## Long-running commands

            A build or test run hogging the turn? **`Ctrl+B`** sends it to the
            background — Crok keeps working and you're notified when it finishes
            (`Ctrl+G` shows the tasks pane).

            *Go deeper: `/docs Plan Mode` or `/docs Permissions and Safety`*
            """#
        ),
        GrokTutorialTopic(
            id: "08-make-it-yours",
            title: "Make It Yours",
            blurb: "just ask: AGENTS.md, memory, themes",
            goDeeper: "Project Rules (AGENTS.md)",
            content: #"""
            # Make It Yours

            ## The easiest way: just ask

            Crok knows its own capabilities and can configure itself. Try:

            - *"add the Postgres MCP server for our staging db"*
            - *"switch to a light theme"*
            - *"write an AGENTS.md for this repo"*

            If you'd rather drive, everything below has a command too.

            ## Teach Crok your project: AGENTS.md

            Drop an `AGENTS.md` file in your repo root with build commands, conventions,
            and gotchas. Crok reads it automatically in every session — it's the single
            highest-leverage customization:

            ```markdown
            # My Project
            - Run tests with `pnpm test`
            - Never edit files under generated/
            ```

            ## Teach Crok your facts: memory

            Start a prompt with `#` (or use `/remember`) to save a note for future
            sessions: `# the staging deploy uses eu-west`.

            ## Looks, keys, and extensions

            - **`/theme`** — color themes (or `auto` to follow your OS); **`/settings`**
              (or `F2`) for everything else; **`/vim-mode`** if that's your thing.
            - **Skills** (`/skills`) — reusable prompt packages; user-invocable skills
              become slash commands automatically.
            - **MCP servers** (`/mcps`) and **plugins & hooks** (`/plugins`, `/hooks`).

            Start with `AGENTS.md` and a theme; add the rest when you need it.

            *Go deeper: `/docs Project Rules (AGENTS.md)`, `/docs Skills`, or `/docs MCP Servers`*
            """#
        ),
        GrokTutorialTopic(
            id: "09-where-next",
            title: "Where to Go Next",
            blurb: "guides, feedback, and good habits",
            goDeeper: nil,
            content: #"""
            # Where to Go Next

            You know enough to be productive. When you want more:

            ## Built-in help

            - **`/help`** or **`Ctrl+P`** — every command, shortcut, and skill, searchable.
            - **`/docs`** — the full How-to Guides inside the TUI (`/docs web` for the
              online docs). Covers sessions, headless mode, subagents, sandboxing,
              memory, and much more.
            - **Ask Crok itself** — it can read its own user guide and set itself up.
              Try: "How do I run you in CI?" or "add an MCP server for GitHub".

            ## Good habits

            - Sessions save automatically. Resume the latest with `crok -c`, or pick
              one with `/resume` (`Ctrl+R`).
            - Long session getting slow? `/compact` frees context; `/context` shows
              where it's going.
            - Automate anything: `crok -p "summarize new TODOs" --output-format json`
              runs headless — great for scripts and CI.
            - Stay current with `crok update`; see what changed with `/release-notes`.
            - Something feel off? `/feedback <text>` goes straight to the team, and bare
              `/feedback` opens a form with your saved drafts.

            ## Reopen this tutorial

            Type **`/tutorial`** anytime.

            Now go build something.
            """#
        ),
    ]
}
