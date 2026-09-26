# Grok Desktop for macOS

A native SwiftUI client for the Grok Build harness in this repository. It brings a
project sidebar, persistent tasks, a focused conversation view, and a changes
inspector to the existing agent runtime. The app launches `grok agent stdio` and
communicates through ACP v1; the harness continues to run tools, manage sandboxing,
and load provider credentials and configuration.

## Install

Open `Grok-Desktop-<version>-arm64.dmg` and drag **Grok Desktop** to
**Applications**. The app includes Grok Build, the same runtime and `grok` TUI as
the CLI, so nothing else needs to be installed. It requires macOS 14 or later on
Apple silicon. On first launch, sign in to OpenRouter or OpenAI Codex from
**Settings › Accounts**. xAI accounts are not supported; Grok models are available
through OpenRouter.

The disk image is ad hoc signed and not notarized, so macOS blocks the first launch
with a message that it cannot verify the app. Open **System Settings › Privacy &
Security**, click **Open Anyway** beside the Grok Desktop message, and confirm.
macOS remembers the choice.

To use Grok Build in a terminal, turn on **Settings › Command line › `grok` command
in Terminal**. It links `/usr/local/bin/grok` to the app's copy of the TUI, so
`grok` works in any terminal and updates when you install a newer Grok Desktop.
macOS asks for an administrator password when that folder is not writable. The
switch replaces another program's `grok` link only after you confirm, never
replaces an installed file, and removes only its own link. If the app moves,
Settings offers to repair the link. The terminal in the side panel runs the app's
`grok` even with the switch off, unless another `grok` comes earlier in `PATH`.

## Build requirements

- macOS 14 Sonoma or later.
- Xcode 15 or later, or compatible Command Line Tools with Swift 5.9+ and the
  macOS 14+ SDK. Build with Xcode 26+ to enable native Liquid Glass on macOS 26+.
  Earlier systems use the native material fallback. Run `xcode-select --install`
  if the tools are not installed.
- A Grok CLI with `agent stdio` support, preferably built from this checkout.

The desktop package uses Apple's system frameworks and one third-party package,
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), which draws the
embedded terminal. It is vendored under [`third_party/SwiftTerm`](../../third_party/SwiftTerm)
and used as a local path dependency, so building needs no network access.
Building the Rust harness has its own requirements, documented in the
[repository README](../../README.md#building-from-source).

## Build and launch

Run these commands from the repository root:

```sh
# Build the release harness and package the desktop app explicitly.
make build-desktop
open "desktop/macOS/dist/Grok Desktop.app"

# Build a separate workspace-local test app with orange TESTING artwork:
make build-test-desktop
open "target/test-builds/desktop/Grok Desktop Test.app"

# Or build and install it to ~/Applications:
make deploy-desktop

# Or build the installer disk image for new users:
make dmg-desktop
```

The repository default commands (`make`, `make build`, and `make deploy`) only
build or install the CLI/TUI. They do not compile or install the desktop app.
Use `make deploy-desktop DESKTOP_INSTALL_DIR=/Applications` to choose a different
app destination, provided it is writable. `make build-test-desktop` keeps the
packaged test app and its state under the repository's `target/test-builds/`
directory. Its app has a separate bundle identity, state file, orange **TESTING**
icon, and disabled global `grok` command switch, so it remains separate from the
production desktop app.

The packaging script embeds the release harness as `Contents/Resources/grok`,
signs that executable, and then signs the app. It also bundles the `grok` command's
launcher, [`Resources/grok-command.sh`](Resources/grok-command.sh), as
`Contents/Resources/bin/grok`: it runs the embedded harness with its self-updater
off, and answers `grok update` by pointing to a newer Grok Desktop. The app's
version comes from [`VERSION`](VERSION). Rebuilding while the app runs is safe;
the running copy and its tasks keep their executables. To reuse an existing
harness and skip its Rust build:

```sh
make build-desktop GROK_BINARY="/absolute/path/to/grok"
```

The lower-level `./desktop/macOS/scripts/build-app.sh` command remains available
for packaging a prebuilt harness; it requires `target/release/xai-grok-pager` or
an explicit `GROK_BINARY`.

Packaging requires a harness and embeds it as the fixed application default.
Settings does not expose an executable path, and old path preferences are ignored.
For unpackaged development, the app discovers builds in the selected project,
common Grok installation locations, and the inherited `PATH`. `GROK_BUILD_ROOT`
can identify a repository containing a debug or release harness.

For development without packaging:

```sh
swift run --package-path desktop/macOS GrokDesktop
swift test --package-path desktop/macOS
```

## Use the app

1. Choose **Open Project** and select the folder Grok should work in.
2. In **Settings**, check **Accounts** and sign in to OpenRouter or OpenAI Codex
   (`/login` opens the same place). Existing CLI credentials from
   `grok login openrouter` or `grok login openai-codex`, and `OPENROUTER_API_KEY`,
   are reused. Each provider shows its saved account identity when available, and
   signed-in accounts cannot start another sign-in. OpenRouter API keys do not
   include an account name; this is stated explicitly. xAI accounts (xAI sign-in,
   `XAI_API_KEY`) are not supported; use Grok models through OpenRouter. To sign
   out, run `grok logout <provider>` (or `grok logout` for every provider) in the
   side panel's Terminal.
3. Start a task and send a prompt. Responses stream into the conversation, with
   expandable thinking and tool output, plan progress, permission requests,
   project trust decisions, and agent questions. Messages you send while Grok is
   working wait in a queue above the composer and are sent in order.
4. Attach images, files, and folders from **+ › Add photos & files** (⌘U) or
   **+ › Add folder**, by dragging them onto the conversation or the prompt, or by
   pasting a screenshot or copied file with ⌘V. Attachments preview above the
   prompt (click one for Quick Look, hover to remove it) and stay with that draft
   until you send. Images go to the model as images, downscaled when large; files
   and folders go as links, and the harness reads small text files inline.
5. Press **⌘J**, or click the side panel button in the toolbar, for the side
   panel. **Files** browses the project as Git sees it (tracked and untracked,
   without ignored files) with a filter, previews files with syntax highlighting,
   and switches to **Changes** for staged, unstaged, and untracked files and
   their diffs. **Side chat** asks Grok about the task without interrupting it
   (the same as `/btw`); each task keeps its thread. **Terminal** (⌃\`) runs your
   login shell in the project folder and keeps running while you switch tabs or
   tasks. Drag the panel's left edge to resize it; double-click the edge to reset
   it. Drag a file from the panel onto the prompt to attach it.
6. Type **/** in the composer, or press **⇧⌘P**, to browse commands and skills.
   Use the arrow keys to navigate, **Tab** to complete a command, **Return** to
   select it, and **Escape** to dismiss. Commands with arguments fill the composer
   so you can add details before sending. The **+** menu and **Extensions** menu
   provide direct access to the same features.

The command catalog is loaded from the harness for the selected project and
updated during the session. User-invocable skills retain their exact qualified
names, including plugin and scope prefixes. Desktop commands open native views;
shell commands retain the harness's normal slash-command execution semantics.
Unknown commands produce an error instead of becoming ordinary model prompts.

- **MCP servers:** inspect connection status and tools, add remote or local
  servers, enable/disable servers and individual tools, reconnect, authorize, and
  remove locally configured servers. Configuration changes go through the harness.
- **Skills, plugins, hooks, and workflows:** browse discovered extensions, toggle
  supported entries, add a skill folder, install/reload plugins, and prepare skill
  or workflow invocations in the composer.
- **Plan:** `/plan [description]` changes the actual session mode before sending
  the description. `/view-plan` shows the saved Markdown plan, checklist progress,
  and pending approval controls.
- **Goal:** `/goal <objective> [--budget N]` starts a harness goal. The status card
  shows progress and usage; pause, resume, clear, and status controls use the
  harness lifecycle. Pausing a running goal cancels the active turn immediately.
- **Subagents:** inspect live activity, output and failure details, stop children,
  and message addressable agents. Agent definitions and personas have separate
  browsers. Spawning and delegation remain managed by Grok's tools.
- **Other task actions:** `/btw` (in the side panel's Side chat), `/fork`, `/recap`,
  `/rewind`, `/tasks`, `/usage`, history, transcript search, copy/export, and
  model/thinking selection have native interfaces. `/changes` and `/terminal` open
  the side panel's Changes and Terminal. Image/video commands appear when their
  tools are advertised.

Every terminal command has a desktop equivalent. [COMMANDS.md](COMMANDS.md)
records all 72 pager commands, shell built-ins, CLI families, exact ACP
contracts, and what each command does in the desktop app. Commands that open a
picker or panel in the terminal open a native sheet or window here: usage and
context, session info, feedback, release notes, guides, the tutorial,
themes, resume, the session dashboard, tasks and workflow runs, the trace
viewer, diagnostics (`/doctor`), memory, `/remember`, marketplace, personas,
agent definitions, and Import Claude settings. Preferences the terminal also
reads (`[ui]` keys such as `theme`, `show_timestamps`, `permission_mode`, and
the `[models]` defaults) are saved to `~/.grok/config.toml` one key at a time,
leaving the rest of the file as it was. `/share` reports that sharing is
disabled, as it does in the terminal; `/toggle-mouse-reporting` explains that it
has no desktop meaning. Native panels open even while a reply is streaming;
harness commands typed then are queued, and the few commands that need an idle
task (such as `/plan <description>`) keep your draft and say why they must wait.

### Conversations

Replies and thinking render full Markdown: headings, lists and task lists,
quotes and GitHub callouts, tables with column alignment, links, images, and
footnotes. LaTeX math (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`, and environments such
as `aligned`, `cases`, and `pmatrix`) is typeset natively with the system's STIX
Two Math font, and copying typeset math copies its LaTeX. Code blocks are
syntax-highlighted for over a hundred languages and have a Copy button. Each reply is
one selectable text, so a selection can run across paragraphs, tables, and code. Thinking
renders in a scrolling text view that follows the stream, so long reasoning stays
responsive. `/timestamps`, `/timeline`, `/find` (⌘F), `/jump`, and `/vim-mode`
add timestamps, a turn rail, search, a turn picker, and keyboard navigation.

### Sidebar

The sidebar follows the Codex layout. **Projects** lists each folder with its
tasks, most recently updated first; click a folder to fold it (folding is
remembered), and hover it to start a task in that project or reach its actions.
**Recents** lists every task from every project, newest first, and starts folded
on each launch. Pinned tasks also appear under **Pinned**. Each row shows a
compact age (5m, 2h, 3d), a spinner while the task runs, a raised hand when it
needs your answer, and a dot when it finished while you were elsewhere. Hover a
row to pin, archive, or reach more actions; search covers every project.
Deleting a task deletes the harness session too (after confirmation), so it does
not come back through `/resume`; archive a task to hide it instead. Active tasks
must be stopped first. The sync button beside **Projects** imports saved harness
sessions for every project; each folder's menu imports its own. Selecting an
imported task loads its transcript and lets you continue it.

Available model choices load before the first message and when reopening a task;
the model picker searches both names and provider IDs. The composer displays the
model, adjustable thinking level when supported, and conversation mode. Changes
are acknowledged by the harness before sending is re-enabled, and model/thinking
choices persist across relaunches. Settings includes the terminal's themes
(auto, Grok Night, Grok Day, Tokyo Night, Rosé Pine Moon, Oscura Midnight),
permission mode, conversation display, and dictation. The interface uses system typography and native toolbar
controls. Every window is glass: the desktop shows through, blurred, most clearly in the sidebar, and controls such as
the composer use Liquid Glass on macOS 26 (material elsewhere). **Settings › Appearance › Transparency** sets how
much shows through, from Solid to Clear; the terminal themes tint the glass with their own colours. Reduce
Transparency in System Settings makes windows solid, and reduced motion is respected. Unsent drafts and their
attachments are retained while switching between tasks and projects during the app session.

The app uses the CLI's account and configuration files, including provider
credentials under `~/.grok` (or the harness's configured home). It does not copy
API keys into desktop preferences. Apps launched from Finder do not necessarily
inherit environment variables from your shell; saved CLI credentials work across
both launch methods. See the [authentication guide](../../crates/codegen/xai-grok-pager/docs/user-guide/02-authentication.md).

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New task | ⌘N |
| Open project | ⇧⌘O |
| Search tasks | ⌘K |
| Command palette | ⇧⌘P |
| Enter plan mode | ⌥⌘P |
| Toggle sidebar | ⌘B |
| Toggle side panel (files, side chat, terminal) | ⌘J |
| Terminal | ⌃\` |
| Attach photos and files | ⌘U |
| Settings | ⌘, |
| Find in conversation | ⌘F, then ⌘G / ⇧⌘G |
| Dictate | ⇧⌘D |
| Keyboard shortcuts | ⌘/ |
| Send message (or queue it while Grok works) | Return |
| Insert a new line | Shift-Return |
| Stop the current task | ⌘. |

`/multiline` changes Return to insert a newline and ⌘Return to send. `/compact-mode`
toggles a denser transcript layout. The full list, including the palette, theme
picker, jump, and vim-style transcript keys, is in the Keyboard Shortcuts sheet.

## Local data and current scope

Projects, conversation transcripts, session IDs, pins, and archive state are
saved locally in `~/Library/Application Support/Grok Desktop/state.json`, with
owner-only file permissions. Appearance is stored in macOS preferences; the harness is selected at build time. The harness separately retains its own session history and sends
prompts to the configured model provider as usual.

Quitting stops active desktop connections and saves conversations. Reopening a
task resumes its saved harness session when you send another prompt; work does
not continue in the desktop app after it quits.

The Files tab is read-only; it does not stage, commit, or revert files. File
previews and diffs are capped at 1 MiB (diffs per section), and the tree lists up
to 50,000 files. Side chats are saved with their task in the desktop state file.
The terminal runs your login shell with your privileges, exactly as Terminal
does; it ends when you quit the app or restart it from the panel. Pasted and
dragged image data waits in a temporary folder until it is sent. `/fork --worktree` (or the ask sheet)
creates a git worktree and adds it as a project; `/trace` and `/export` run the
bundled `grok` executable. After you open the app, it clears the download
quarantine from its bundled `grok` so terminals can run it. Dictation needs microphone permission; it transcribes
each utterance with an OpenRouter model (chosen in **Settings › Behavior**) using your OpenRouter sign-in or
`OPENROUTER_API_KEY`, and without one uses on-device recognition. GBOOM runs at full speed only in release builds.

## Validation

`swift test --package-path desktop/macOS` runs process-backed ACP tests, task
lifecycle and transcript tests, question-response tests, and temporary Git
repository fixtures. These tests use isolated state and an offline harness;
they require no provider account and do not modify your real projects.
Command integration tests cover catalog refresh, native routing, exact slash
arguments, qualified skills, MCP management, plan transitions, live goals,
subagent activity, and extension errors. Saved-plan tests use temporary artifacts.
Each command area has unit and harness-level tests against a subclassed offline
fixture, and the Markdown parser, math typesetter, and syntax highlighter have
their own corpus, fuzz, and streaming tests. Configuration tests write only to
temporary `GROK_HOME` directories.

Views can be rendered offscreen for review: set `GROK_DESKTOP_SNAPSHOT_DIR` to a
folder and run `swift test --filter Snapshot` to write light and dark PNGs of
the sidebar, conversation, side panel, attachments, and every command sheet and
window. Glass is not drawn offscreen, so surfaces show only their tints there.

For manual UI testing without inference, build a separate development bundle
with `GROK_BINARY="$PWD/desktop/macOS/Tests/Fixtures/mock-grok.py"` passed to the
packaging script. It clearly labels its output as an offline fixture. Prompts containing `fixture:permission`, `fixture:question`,
`fixture:plan`, `fixture:trust`, or `fixture:wait` exercise the interactive flows; replies name any attachments they
received, and side questions get fixture answers.
Rebuild with the real harness afterward.

For isolated development runs, `GROK_DESKTOP_STATE_FILE` selects an absolute path
for desktop state, `GROK_DESKTOP_HARNESS` selects a test executable, and
`GROK_HOME` points the app's shared configuration at a scratch directory. The normal
packaged app continues to use its embedded runtime and standard local state.

## Vector app icon

[`Resources/GrokMark.svg`](Resources/GrokMark.svg) is the editable vector source,
reconstructed from the [Grok homepage](https://grok.com/) mark. No downloaded
raster artwork or font glyph is used. The desktop icon follows Apple's macOS
icon grid, like the other coding agents' icons: an 824 pt continuous-corner tile
on the 1024 pt canvas, with a top-lit black gradient, a faint bezel, and the
system's soft drop shadow, and the white mark at about half the tile. The test
build uses an orange tile with a TESTING pill. The in-app symbol uses the same paths.

The packaging script regenerates the icon before building. To regenerate it
independently, run from the repository root:

```sh
swift desktop/macOS/scripts/make-icon.swift desktop/macOS/Resources/AppIcon.icns
```

The generator creates the multi-resolution ICNS, a scalable `Resources/AppIcon.svg`,
a PNG preview in `dist/`, and the native `GrokSymbol.swift` shape. Edit
`GrokMark.svg` to change the geometry, then regenerate; avoid editing the generated
Swift shape directly. Each required icon size is rendered from vector paths.

## Distribution

`make dmg-desktop` builds the app and then runs
[`scripts/build-dmg.sh`](scripts/build-dmg.sh), which writes
`dist/Grok-Desktop-<version>-<arch>.dmg`: the app beside an **Applications**
shortcut, laid out by Finder, with the app icon on the volume. The image is
LZMA-compressed; set `DMG_FORMAT` to choose another `hdiutil` format, or
`DMG_FINDER_LAYOUT=0` to skip the Finder step (for example without a login
session). Before reporting success, the script mounts the finished image, checks
the app's signature, and runs its `grok` command. It refuses to run while another
volume named "Grok Desktop" is mounted, because Finder lays out the window by
volume name.

The generated app and image are **ad hoc signed**, not Developer ID signed or
notarized, so each Mac asks its user to approve the first launch (see
[Install](#install)). There is no automatic updater; users install a newer disk
image to update, and the bundled `grok` command updates with it. `SIGN_IDENTITY`
selects the signing identity for the app and the image, but the scripts do not
enable the hardened runtime or notarize. The build targets the architecture of
the build machine: a disk image built on Apple silicon runs only on Apple silicon.
