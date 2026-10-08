<div align="center">

<h1>Crok (<code>crok</code>)</h1>

**Crok** is a terminal-based AI coding agent and agentic harness. It runs as a
full-screen TUI that understands your codebase, edits files, executes shell
commands, searches the web, and manages long-running tasks — interactively,
headlessly for scripting/CI, or embedded in editors via the Agent Client
Protocol (ACP). It also ships **Crok Desktop**, a native macOS client for the
same harness.

Crok is a personal fork. It is not an official product of any company and has
no official release: build it from this checkout.

[What this fork changes](#what-this-fork-changes) ·
[Building from source](#building-from-source) ·
[macOS desktop app](#macos-desktop-app) ·
[Syncing with upstream](#syncing-with-upstream) ·
[Documentation](#documentation) ·
[Repository layout](#repository-layout) ·
[Development](#development) ·
[License](#license)

</div>

## What this fork changes

- **Name and home.** The command is `crok`, the desktop app is **Crok Desktop**,
  and state lives in `~/.crok` (override with `CROK_HOME`). Every `CROK_X`
  environment variable overrides the matching upstream `GROK_X`. Project `.grok/`
  folders and `AGENTS.md` files are read exactly as upstream reads them.
- **Model providers.** Sign in with `crok login openrouter` or
  `crok login openai-codex`, add a key with `crok login anthropic` (the Claude
  API), `crok login deepseek` or `crok login glm` (a GLM Coding Plan), or set
  `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY` or
  `ZAI_API_KEY`. The first interactive
  launch asks which provider to use. Vendor account sign-in is removed; use any
  model through OpenRouter or an OpenAI-compatible endpoint. See the
  [authentication guide](crates/codegen/xai-grok-pager/docs/user-guide/02-authentication.md).
- **No self-update.** Crok never installs an official release over itself.
  `crok update` explains how to rebuild instead.
- **Trace viewers.** `crok trace` and the in-TUI `/trace` show an agent's turns,
  tool calls, and reasoning in the terminal or as a self-contained HTML page.
- **Voice dictation** transcribes with OpenRouter models.
- **Crok Desktop**, a SwiftUI app for macOS 14+ (see below).

Model ids, theme ids, the Rust crate names (`xai-grok-*`), and config file names
are unchanged, so upstream merges stay small.

### Importing settings from an existing install

```sh
make import-grok-config
```

This copies settings, sessions, and desktop app state from a previous
`~/.grok` and its desktop support folder into their crok locations. It never
overwrites a file crok already has, so it is safe to run again.

## Building from source

Requirements:

- **Rust** — the toolchain is pinned by [`rust-toolchain.toml`](rust-toolchain.toml).
  Use rustup's `cargo`; the Makefile picks it automatically even when another
  `cargo` (for example Homebrew's) comes first on `PATH`.
- **[DotSlash](https://dotslash-cli.com)** — required so hermetic tools under
  [`bin/`](bin/) (notably [`bin/protoc`](bin/protoc)) can download and run.
  Install it and ensure `dotslash` is on your `PATH` **before** building:

  ```sh
  cargo install dotslash
  # or: prebuilt packages — https://dotslash-cli.com/docs/installation/
  /usr/bin/env dotslash --help   # sanity check
  ```

- **protoc** — proto codegen resolves [`bin/protoc`](bin/protoc) via DotSlash,
  or falls back to a `protoc` on `PATH` / `$PROTOC`.
- macOS and Linux are supported build hosts; Windows builds are best-effort
  and not currently tested from this tree.

```sh
make                                       # release TUI: target/release/xai-grok-pager
make deploy                                # build + install TUI to ~/.local/bin/crok
cargo run -p xai-grok-pager-bin            # build + launch the TUI
cargo check -p xai-grok-pager-bin          # fast validation
```

The binary artifact is named `xai-grok-pager`; `make deploy` installs it as
`crok`. Put `~/.local/bin` on your `PATH`, or choose another destination with
`make deploy BINDIR=/path/to/bin`. `CARGO_TARGET_DIR` overrides the build output
directory. `make`, `make build`, and `make deploy` build only the CLI/TUI;
the desktop app has its own commands below. Run `make help` for the full list.

### Workspace test builds

Build a test TUI and launch it with a workspace-only command:

```sh
make build-test-tui
PATH="$PWD/bin:$PATH" crok-test
```

Add `export PATH="$PWD/bin:$PATH"` to the current shell once if you want to type
`crok-test` directly. The launcher runs this checkout's build and refuses to
run when the current directory is outside the workspace. The compiled test TUI
stays under `target/test-builds/`; the small `bin/crok-test` file is the only
repository file added to the command path.

## macOS desktop app

[Crok Desktop](desktop/macOS/README.md) is a native SwiftUI client for macOS 14+
with project and task navigation, streaming conversations, tool approvals,
saved harness sessions, a side panel with files, changes, side chat, and a
terminal, and native equivalents of every TUI command. It drives this
repository's harness through ACP and shares the CLI's provider credentials and
configuration.

```sh
make build-desktop
open "desktop/macOS/dist/Crok Desktop.app"

# Build the separate TESTING-badged test app inside this workspace:
make build-test-desktop
open "target/test-builds/desktop/Crok Desktop Test.app"

# Or build and install it to ~/Applications:
make deploy-desktop

# Or build the drag-to-Applications installer:
make dmg-desktop    # desktop/macOS/dist/Crok-Desktop-<version>-<arch>.dmg
```

The desktop build first builds the release Rust harness and embeds it in the
app, so the app and its disk image need no separate crok install. Its
**Settings › Command line** switch links `/usr/local/bin/crok` to the bundled
TUI for use in any terminal. Set `CROK_BINARY=/path/to/crok` to reuse an
existing harness and compile only the desktop app. `DESKTOP_INSTALL_DIR`
overrides the desktop install directory. It requires Swift 5.9+ and a macOS 14+
SDK; build with Xcode 26+ for Liquid Glass on macOS 26.

The test app uses the `dev.chenli.crok.desktop.test` bundle identifier, a
workspace-local state file, an icon with an orange **TESTING** pill, and a
build script guard that keeps it from changing the global `/usr/local/bin/crok`
link. The app and disk image are ad hoc signed, not notarized, and have no
automatic updater. See the [desktop guide](desktop/macOS/README.md) for
installing, development builds, shortcuts, and local data storage.

## Syncing with upstream

An `upstream` remote tracks the original source this fork is derived from.
Merge `upstream/main` into `charlie/dev`, then:

- Keep removed vendor-account features out: `/login`, `/logout`, `/privacy`, the
  vendor entries in the first-run chooser and welcome screen, vendor voice, and
  the desktop's account, billing, and subscription screens.
- Rebrand new user-visible strings from `grok` to `crok`. Only string
  literals, help text, and docs change; identifiers and crate names stay.
- Rebuild with `make build-test-tui` and `make build-test-desktop`.

## Documentation

The user guide ships with the pager crate:
[`crates/codegen/xai-grok-pager/docs/user-guide/`](crates/codegen/xai-grok-pager/docs/user-guide/)
— getting started, keyboard shortcuts, slash commands, configuration, theming,
MCP servers, skills, plugins, hooks, headless mode, sandboxing, and more.

## Repository layout

| Path | Contents |
|------|----------|
| `crates/codegen/xai-grok-pager-bin` | Composition-root package; builds the `xai-grok-pager` binary |
| `crates/codegen/xai-grok-pager` | The TUI: scrollback, prompt, modals, rendering |
| `crates/codegen/xai-grok-shell` | Agent runtime + leader/stdio/headless entry points |
| `crates/codegen/xai-grok-tools` | Tool implementations (terminal, file edit, search, ...) |
| `crates/codegen/xai-grok-workspace` | Host filesystem, VCS, execution, checkpoints |
| `crates/codegen/...` | The rest of the CLI crate closure (config, MCP, markdown, sandbox, ...) |
| `crates/common/`, `crates/build/`, `prod/mc/` | Small shared leaf crates pulled in by the closure |
| `third_party/` | Vendored upstream source (Mermaid diagram stack, SwiftTerm) |
| `desktop/macOS/` | Crok Desktop: SwiftUI client, ACP transport, tests, and app packaging |
| `bin/` | `crok-test` launcher, `crok-import-grok`, and DotSlash tools |

A small `SOURCE_REV` file at the root records the upstream monorepo commit SHA
of the last upstream sync.

> [!IMPORTANT]
> The root `Cargo.toml` (workspace members, dependency versions, lints,
> profiles) is **generated** upstream — treat it as read-only. Prefer editing
> per-crate `Cargo.toml` files.

## Development

```sh
cargo check -p <crate>        # always target specific crates; full-workspace builds are slow
cargo test -p xai-grok-config # per-crate tests
cargo clippy -p <crate>       # lint config: clippy.toml at the repo root
cargo fmt --all               # rustfmt.toml at the repo root
swift test --package-path desktop/macOS   # desktop tests
```

## License

First-party code in this repository is licensed under the **Apache License,
Version 2.0** — see [`LICENSE`](LICENSE). This fork's changes are offered under
the same license. Grok and Grok Build are SpaceXAI's names; crok is not
affiliated with or endorsed by SpaceXAI.

Third-party and vendored code remains under its original licenses. See:

- [`THIRD-PARTY-NOTICES`](THIRD-PARTY-NOTICES) — crates.io / git dependencies,
  bundled UI themes, and **in-tree source ports** (including openai/codex and
  sst/opencode tool implementations)
- [`crates/codegen/xai-grok-tools/THIRD_PARTY_NOTICES.md`](crates/codegen/xai-grok-tools/THIRD_PARTY_NOTICES.md)
  — crate-local notice for the codex and opencode ports (license texts +
  Apache §4(b) change notice)
- [`third_party/NOTICE`](third_party/NOTICE) — vendored Mermaid-stack index
