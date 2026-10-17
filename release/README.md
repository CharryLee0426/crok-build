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
3. It downloads the one file this installation needs, checks its SHA-256 against the signed
   manifest, and only then installs it. For Crok Desktop that is the disk image of the SDK the
   installed app was linked against (`LC_BUILD_VERSION` of its executable: 26 or later takes the
   `macOS26-SDK` image, older the `macOS15-SDK` one), not the one for the macOS it runs on; a
   release without it is reported as not installable here, already by `--check`. A tarball's
   `crok` is renamed over the old binary; a disk image is mounted, its app copied beside the
   installed bundle, its signature checked with `codesign`, and the bundle swapped in with two
   renames once Crok Desktop has quit (the app waits as long as it takes and cancels with
   SIGTERM). The old bundle is moved to the Trash under its version when macOS lets the updater
   reach the Trash, and deleted otherwise. What happened after the quit is written to
   `$CROK_HOME/updates/last-install.json`, which the reopened app reads and removes.

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

## The code signing certificate

macOS keeps Screen Recording, Accessibility, the microphone and its other privacy permissions
for the code signature it gave them to, by that signature's designated requirement. An ad hoc
signature's requirement is the one build's hash (`cdhash H"…"`), so through 1.5.1 every update,
and every test build, lost them. [`codesign.sh`](codesign.sh) now signs everything with one
self-signed certificate, "Crok Code Signing", and the requirement becomes

```
identifier "dev.chenli.crok.desktop" and certificate leaf = H"4d47861c871242056da13d30e3874a36be0aa14c"
```

which every later build signed by that certificate meets, so a permission given to one version
holds for the next. `desktop/macOS/scripts/build-app.sh`, `make deploy`, `make build-test-tui`,
`make build-test-desktop` and the tarball in `publish.sh` all sign through it. The identifiers
keep release and test permissions apart:

| Code | Identifier |
|---|---|
| Crok Desktop | `dev.chenli.crok.desktop` |
| `crok` (in the app, the tarball, `make deploy`) | `dev.chenli.crok` |
| Crok Desktop Test | `dev.chenli.crok.desktop.test` |
| `crok-test` and the test app's `crok` | `dev.chenli.crok.test` |

The identity is made on first use in `~/.crok-codesign` (`CROK_CODESIGN_DIR`): a keychain of its
own, which is never added to the keychain search list, and the password that unlocks it. Its
public certificate is [`crok-codesign.pem`](crok-codesign.pem). `publish.sh` checks before
building that this Mac's identity is that certificate, and before signing the manifest that both
apps, their `crok` and the tarball's `crok` are signed by it; otherwise it publishes nothing.

Keep `~/.crok-codesign` private and backed up, like `~/.ssh/crok-release`: anyone with it can sign
code that macOS treats as Crok Desktop, with Crok Desktop's permissions. To build releases on
another Mac, copy the folder there (`ditto ~/.crok-codesign <the other Mac's home>/.crok-codesign`).
Without it a Mac makes a certificate of its own, which is fine for local builds (they keep their
permissions from build to build on that Mac) but not for a release. To change certificates on
purpose, for example to a Developer ID one with `SIGN_IDENTITY`, replace `crok-codesign.pem`;
users then allow the permissions once more.

The TUI in a terminal is not involved: there macOS asks for the terminal app's permissions
(Ghostty, Terminal, iTerm…), which a crok update never changes. The apps' own permissions are
the ones that moved with each build.

The first release signed by this certificate meets none of the old ad hoc grants. System
Settings may then show Crok Desktop switched on while Crok says it is not allowed: remove it
from the list with **−** and allow it again, once. `tccutil reset Accessibility
dev.chenli.crok.desktop` and `tccutil reset ScreenCapture dev.chenli.crok.desktop` do the same.

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
