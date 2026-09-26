<div align="center">

<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://media.x.ai/v1/website/spacexai-symbol-white-transparent-0c31957f.png">
    <source media="(prefers-color-scheme: light)" srcset="https://media.x.ai/v1/website/spacexai-symbol-black-transparent-6435cf42.png">
    <img alt="SpaceXAI logo" src="https://media.x.ai/v1/website/spacexai-symbol-black-transparent-6435cf42.png" width="96">
  </picture>
  <br>
  Grok Build (<code>grok</code>)
</h1>

**Grok Build** is SpaceXAI's terminal-based AI coding agent. It runs as a
full-screen TUI that understands your codebase, edits files, executes shell
commands, searches the web, and manages long-running tasks — interactively,
headlessly for scripting/CI, or embedded in editors via the Agent Client
Protocol (ACP).

[Installing the released binary](#installing-the-released-binary) ·
[Building from source](#building-from-source) ·
[macOS desktop app](#macos-desktop-app) ·
[Documentation](#documentation) ·
[Repository layout](#repository-layout) ·
[Development](#development) ·
[Contributing](#contributing) ·
[License](#license)

![Grok Build TUI](https://media.x.ai/v1/website/universe-tui-screenshot-6f7a0837.png)

**Learn more about Grok Build at [x.ai/cli](https://x.ai/cli)**

This repository contains the Rust source for the `grok` CLI/TUI and its agent
runtime. It is synced periodically from the SpaceXAI monorepo.

A small `SOURCE_REV` file at the root records the full monorepo commit SHA
for the version of the code present in this tree.

</div>

---

## Installing the released binary

Prebuilt binaries are published for macOS, Linux, and Windows:

```sh
curl -fsSL https://x.ai/cli/install.sh | bash   # macOS / Linux / Git Bash
irm https://x.ai/cli/install.ps1 | iex          # Windows PowerShell
grok --version
```

See the [changelog](https://x.ai/build/changelog) for the latest fixes,
features, and improvements in each release.

## Building from source

Requirements:

- **Rust** — the toolchain is pinned by [`rust-toolchain.toml`](rust-toolchain.toml);
  `rustup` installs it automatically on first build.
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
make deploy                                # build + install TUI to ~/.local/bin/grok
cargo run -p xai-grok-pager-bin              # build + launch the TUI
cargo check -p xai-grok-pager-bin            # fast validation
```

### Workspace test builds

Build a test TUI and launch it with a workspace-only command:

```sh
make build-test-tui
PATH="$PWD/bin:$PATH" grok-test
```

Add `export PATH="$PWD/bin:$PATH"` to the current shell once if you want to type
`grok-test` directly. The launcher resolves this checkout's build, disables
self-update, and refuses to run when the current directory is outside the
workspace. The compiled test TUI stays under `target/test-builds/`; the small
`bin/grok-test` file is the only repository file added to the command path.

`make`, `make build`, and `make deploy` build only the CLI/TUI and its Rust
runtime. Desktop compilation and installation require the explicit commands
below. The direct Cargo equivalent of `make build` is
`cargo build -p xai-grok-pager-bin --release`.

For local deployment, put `~/.local/bin` on your `PATH`, or choose another
destination with `make deploy BINDIR=/path/to/bin`. `CARGO_TARGET_DIR` overrides
the build output directory. Run `make help` for all local build/deploy commands.

The binary artifact is named `xai-grok-pager`; official installs ship it as
`grok`. On first interactive launch, choose OpenAI Codex (ChatGPT subscription)
or OpenRouter. Existing provider credentials skip this setup. xAI accounts are
not supported: sign in with `grok login openrouter` or `grok login openai-codex`,
and use Grok models through OpenRouter (`openrouter/x-ai/...`) — see the
[authentication guide](crates/codegen/xai-grok-pager/docs/user-guide/02-authentication.md).

## macOS desktop app

[Grok Desktop](desktop/macOS/README.md) is a native SwiftUI client for macOS 14+
with project and task navigation, streaming conversations, tool approvals,
saved harness sessions, and a Git changes inspector. It uses this repository's
Grok harness through ACP and shares the CLI's provider credentials and configuration.

Build and package the desktop app explicitly:

```sh
make build-desktop
open "desktop/macOS/dist/Grok Desktop.app"

# Build the separate orange test app inside this workspace:
make build-test-desktop
open "target/test-builds/desktop/Grok Desktop Test.app"

# Or build and install it to ~/Applications:
make deploy-desktop

# Or build the drag-to-Applications installer for new users:
make dmg-desktop    # desktop/macOS/dist/Grok-Desktop-<version>-<arch>.dmg
```

The desktop command first builds the release Rust harness and embeds it in the
app, so the app and its disk image need no separate Grok Build install. Its
**Settings › Command line** switch links `/usr/local/bin/grok` to the bundled TUI
for use in any terminal.
Set `GROK_BINARY=/path/to/grok` to reuse an existing harness and compile only
the desktop app. `DESKTOP_INSTALL_DIR` overrides the desktop install directory.
It requires Swift 5.9+ and a macOS 14+ SDK; the desktop package has no external
Swift dependencies. The test app uses the `ai.grok.build.desktop.test` bundle
identifier, a workspace-local state file, an orange icon with a **TESTING**
banner, and a build script guard that prevents it from changing the global
`/usr/local/bin/grok` link.
See the [desktop guide](desktop/macOS/README.md) for installing, development
builds, shortcuts, executable selection, and local data storage. The app and disk
image are ad hoc signed, not notarized, and do not include an automatic updater.

## Documentation

Full online documentation is available at
[docs.x.ai/build/overview](https://docs.x.ai/build/overview).

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
| `third_party/` | Vendored upstream source (Mermaid diagram stack) — see below |
| `desktop/macOS/` | Native SwiftUI desktop client, ACP transport, tests, and app packaging |

> [!IMPORTANT]
> The root `Cargo.toml` (workspace members, dependency versions, lints,
> profiles) is **generated** — treat it as read-only. Prefer editing per-crate
> `Cargo.toml` files.

## Development

```sh
cargo check -p <crate>        # always target specific crates; full-workspace builds are slow
cargo test -p xai-grok-config # per-crate tests
cargo clippy -p <crate>       # lint config: clippy.toml at the repo root
cargo fmt --all               # rustfmt.toml at the repo root
```

## Contributing

> [!NOTE]
> External contributions are not accepted. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

First-party code in this repository is licensed under the **Apache License,
Version 2.0** — see [`LICENSE`](LICENSE).

Third-party and vendored code remains under its original licenses. See:

- [`THIRD-PARTY-NOTICES`](THIRD-PARTY-NOTICES) — crates.io / git dependencies,
  bundled UI themes, and **in-tree source ports** (including openai/codex and
  sst/opencode tool implementations)
- [`crates/codegen/xai-grok-tools/THIRD_PARTY_NOTICES.md`](crates/codegen/xai-grok-tools/THIRD_PARTY_NOTICES.md)
  — crate-local notice for the codex and opencode ports (license texts +
  Apache §4(b) change notice)
- [`third_party/NOTICE`](third_party/NOTICE) — vendored Mermaid-stack index
