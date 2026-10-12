# Releases and updates

One GitHub release per version carries everything that ships: the two Crok Desktop disk images, the
standalone `crok` tarball, `SHA256SUMS.txt` and its signature. `crok upgrade` in a terminal and
**Crok Desktop › Check for Updates…** both install from it, so the TUI and the app always move
together. Nothing but GitHub is involved, and GitHub hosts releases for free.

## What a release holds

| File | For |
|---|---|
| `Crok-Desktop-<version>-arm64-macOS26-SDK.dmg` | macOS 26 and later (Liquid Glass) |
| `Crok-Desktop-<version>-arm64-macOS15-SDK.dmg` | macOS 14 and 15 |
| `crok-<version>-aarch64-apple-darwin.tar.gz` | a `crok` installed on its own, such as `~/.local/bin/crok` from `make deploy` |
| `SHA256SUMS.txt` | the SHA-256 of each file above |
| `SHA256SUMS.txt.sig` | `ssh-keygen -Y sign` signature of the manifest, namespace `crok-release` |

The release tag is `desktop-v<version>` (`v<version>` is accepted too); `<version>` is the
repository's `VERSION` file, which `desktop/macOS/scripts/build-app.sh` writes into the app and
`crates/codegen/xai-grok-pager-bin/build.rs` compiles into `crok` (`crok version --json` shows it
as `release`).

## How an update is checked

1. `crok upgrade` reads the tag behind `https://github.com/<repo>/releases/latest` (a redirect,
   which GitHub serves without the API's rate limit) and compares it with its own release number.
2. It downloads `SHA256SUMS.txt` and `SHA256SUMS.txt.sig` and verifies the signature against the
   keys in [`crok-release.pub`](crok-release.pub), compiled into the binary. A release that is not
   signed by one of those keys is refused, whatever its page says.
3. It downloads the one file this machine needs, checks its SHA-256 against the signed manifest,
   and only then installs it: a tarball's `crok` is renamed over the old binary; a disk image is
   mounted, its app copied beside the installed bundle, its signature checked with `codesign`, and
   the bundle swapped in with two renames once Crok Desktop has quit. The old bundle is moved to
   the Trash under its version when macOS lets the updater reach the Trash, and deleted otherwise.

The GitHub API is used only to show release notes, and only when it answers.

## The signing key

Signing uses the `ssh-keygen` every Mac ships; no other tool or service is needed.

```sh
ssh-keygen -t ed25519 -f ~/.ssh/crok-release -C 'crok release signing'
cat ~/.ssh/crok-release.pub >> release/crok-release.pub   # then commit
```

Keep `~/.ssh/crok-release` private and backed up: without it no release can be published, and
with it anyone can publish a release every crok will install. Add a passphrase with
`ssh-keygen -p -f ~/.ssh/crok-release` if you like; `publish.sh` prompts for it when signing.
To rotate, add the new public key to `crok-release.pub`, ship a release signed by the old key
(so installed copies learn the new one), then remove the old line.

Anyone can check a release by hand:

```sh
printf 'release namespaces="crok-release" %s\n' "$(cut -d ' ' -f 1,2 release/crok-release.pub)" > allowed
ssh-keygen -Y verify -f allowed -I release -n crok-release -s SHA256SUMS.txt.sig < SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
```

## Publishing

```sh
# 1. Bump VERSION on the branch you release from, and merge it.
# 2. Write the notes: English first, then 简体中文, 日本語, Español, Français and Deutsch
#    (see desktop/macOS/README.md, "Publishing a release").
# 3. From a clean tree at the release commit:
release/publish.sh --notes desktop/macOS/dist/v1.5.0/release-notes.md
```

The script builds the TUI, both disk images (`SDKROOT` for the macOS 15 SDK, the toolchain's
default for 26, checking each app's `LC_BUILD_VERSION`), the tarball, the manifest and its
signature, verifies the folder with the freshly built `crok upgrade --verify-dir`, then tags,
pushes the tag and creates the release with `gh release create -R`. `--dry-run` stops before the
tag. Everything lands in `desktop/macOS/dist/v<version>/`. From a worktree, pass
`CARGO_TARGET_DIR=<main checkout>/target` so the Rust build is shared.

After publishing, `crok upgrade --check` from any older install reports the new version.
