# Releases and updates

One GitHub release per version carries everything that ships: the two Crok Desktop disk images, the
standalone `crok` tarball, the iOS and Android apps, `SHA256SUMS.txt` and its signature. `crok upgrade`
in a terminal and **Crok Desktop › Check for Updates…** both install from it, so the TUI and the app
always move together. Nothing but GitHub is involved, and GitHub hosts releases for free. A release is
made by [GitHub Actions](#releases-from-github-actions) when a pull request that bumps `VERSION`
merges into `main`.

## What a release holds

| File | For |
|---|---|
| `Crok-Desktop-<version>-arm64-macOS26-SDK.dmg` | macOS 26 and later (Liquid Glass) |
| `Crok-Desktop-<version>-arm64-macOS15-SDK.dmg` | macOS 14 and 15 |
| `crok-<version>-aarch64-apple-darwin.tar.gz` | a `crok` installed on its own, such as `~/.local/bin/crok` from `make deploy` |
| `Crok-iOS-<version>-unsigned.ipa` | iPhones and iPads (iOS 17 or later), once a sideloading tool signs it with the installer's Apple ID |
| `Crok-iOS-<version>-Simulator.zip` | the iOS Simulator on a Mac with Xcode (`xcrun simctl install booted Crok.app`) |
| `Crok-Android-<version>.apk` | Android 8.0 or later, signed with the release key |
| `SHA256SUMS.txt` | the SHA-256 of each file above |
| `SHA256SUMS.txt.sig` | `ssh-keygen -Y sign` signature of the manifest, namespace `crok-release` |

The phone apps are production builds: iOS Release and Android release, signed in to the production
relay (`relay/environments/prod.env`). A release made on a Mac with `publish.sh`
([below](#publishing-from-a-mac)) carries the first three files only.

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
   release without it is reported as not installable here, already by `--check`.
4. It checks that the new code keeps the installed copy's permissions: the new app and the `crok`
   inside it (or the tarball's `crok`) must meet the designated requirement of the code they
   replace (`codesign --verify -R`), which is what macOS keeps its privacy permissions for (see
   [the code signing certificate](#the-code-signing-certificate)). A release that does not is
   refused before anything changes, unless `--allow-new-signature` is given. An installed copy
   signed ad hoc names only its own build, so nothing can keep its permissions and nothing is
   refused; `--check` reports which case applies as `permissionsCarryOver`.
5. It installs into what is already there. A tarball's `crok` is renamed over the old binary at
   the same path. A disk image is mounted, its app copied beside the installed bundle and its
   signature checked with `codesign`; once Crok Desktop has quit (the app waits as long as it
   takes and cancels with SIGTERM), the installed bundle's `Contents` and the new one's are
   exchanged in one atomic rename (`renamex_np` with `RENAME_SWAP`; three renames on a volume
   that cannot). The bundle folder stays, with its extended attributes and its place in the Dock
   and Finder, and LaunchServices is told it changed (`lsregister -f`). The old contents are
   deleted: kept in the Trash they would be a second app with Crok Desktop's identifier. Only if
   macOS refuses changes inside the bundle is the whole bundle replaced at its path instead.
   What happened after the quit is written to `$CROK_HOME/updates/last-install.json`, which the
   reopened app reads and removes.

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
holds for the next. `crok upgrade` checks that requirement against every release before it
installs it, and refuses one that would not meet it. `desktop/macOS/scripts/build-app.sh`, `make deploy`, `make build-test-tui`,
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
users then allow the permissions once more, and since the updater refuses such a release, say in
its notes to install it from the disk image or with `crok upgrade --allow-new-signature`.

The TUI in a terminal is not involved: there macOS asks for the terminal app's permissions
(Ghostty, Terminal, iTerm…), which a crok update never changes. The apps' own permissions are
the ones that moved with each build.

The first release signed by this certificate meets none of the old ad hoc grants. System
Settings may then show Crok Desktop switched on while Crok says it is not allowed: remove it
from the list with **−** and allow it again, once. `tccutil reset Accessibility
dev.chenli.crok.desktop` and `tccutil reset ScreenCapture dev.chenli.crok.desktop` do the same.

## Releases from GitHub Actions

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs on every push to `main`,
which the "Protect main" ruleset allows only by merging a pull request. Its first job checks that the
commit came from a merged pull request and that `VERSION` names a version with no release yet;
otherwise it stops and the run says why, so a merge that leaves `VERSION` alone releases nothing.

| Job | Runner | Makes |
|---|---|---|
| Plan | `ubuntu-latest` | the decision, and checks the notes before any build |
| TUI | `macos-26` | `make build` with the production relay and the Agent Observability destination built in, signed by Crok Code Signing, packed as the tarball |
| Desktop (macOS 26 SDK) | `macos-26` | `make dmg-desktop` around that `crok`, with the newest Xcode 26 and its SDK |
| Desktop (macOS 15 SDK) | `macos-15` | the same against the newest macOS 15 SDK there |
| iOS | `macos-26` | `mobile/scripts/build-apps.sh prod --ios-only --ios-device`: Release for devices (unsigned `.ipa`) and for the Simulator |
| Android | `ubuntu-latest` | `mobile/scripts/build-apps.sh prod --android-only`, signed with the release key |
| Publish | `macos-26` | mounts both images and checks each app's SDK, signature, version and relay, the tarball's `crok` and the phone apps' relay; writes and signs `SHA256SUMS.txt` over all six files; `crok upgrade --verify-dir`; joins the notes; tags `desktop-v<version>` and creates the release with `gh release create --latest` |

The checks are the ones `publish.sh` makes, from the same [`lib.sh`](lib.sh). Build jobs keep their
files as workflow artifacts for 7 days, and the Publish job keeps the notes and the signed manifest
for 30. A run that failed after tagging can be re-run: a tag naming the same commit is reused.

**Notes.** A release's notes are committed with its `VERSION` bump, in `release/notes/v<version>/`:
`en.md`, then `zh.md`, `ja.md`, `es.md`, `fr.md` and `de.md`, each the full notes in that language
(desktop/macOS/README.md, "Publishing a release", has the rules; copy the last release's folder to
start). [`notes/assemble.py`](notes/assemble.py) joins them with each translation in a collapsed
`<details>` block, adds the checksums, and fills `{{VERSION}}`, `{{COMMIT}}`, `{{CROK_VERSION}}`,
`{{TUI_SDK}}`, `{{SDK26}}`, `{{SDK15}}`, `{{XCODE26}}` and `{{XCODE15}}` from what the builds used.
It refuses notes that miss a language, that do not name every file of the release, whose
translations lack a command or path the English has, or whose `**bold**` GitHub would not render.
CI's **Release notes** job runs the same check ([`notes/check.sh`](notes/check.sh)) on every pull
request into `main` that carries an unreleased `VERSION`, and **All builds** requires it, so such a
pull request cannot merge without its notes.

**Secrets.** The signing material is in the repository's `release` environment, which only `main`
may use, so pull requests and other branches never see it. Set it up, or update it, from the Mac
that publishes releases:

```sh
release/ci-secrets.sh --dry-run   # checks the files below, changes nothing
release/ci-secrets.sh             # creates the environment and sets its secrets
```

| Secret | From |
|---|---|
| `CROK_RELEASE_SIGNING_KEY` | `~/.ssh/crok-release`, [the signing key](#the-signing-key) |
| `CROK_CODESIGN_KEYCHAIN`, `CROK_CODESIGN_PASSWORD` | `~/.crok-codesign`, [the code signing certificate](#the-code-signing-certificate) |
| `CROK_AGENTO11Y_ENV` | `~/.crok/agento11y.env`, the destination every release builds in |
| `CROK_ANDROID_KEYSTORE_BASE64`, `CROK_ANDROID_KEYSTORE_PASSWORD`, `CROK_ANDROID_KEY_ALIAS` | `~/.crok-android`, which the script makes on first use |

Android installs an APK over another only when the same key signed both, so keep `~/.crok-android`
private and backed up like the other two. APKs built before the release key (by
`mobile/scripts/build-apps.sh`, signed with a Mac's debug key) must be uninstalled once before the
first released one installs. iOS apps for devices need an Apple team to be signed, which the
person installing brings, so the `.ipa` is unsigned.

**Dry runs.** Run the workflow by hand (**Actions › Release › Run workflow**, or
`gh workflow run release.yml -R CharryLee0426/crok-build`) to build and check everything without
tagging or publishing; the files are the run's artifacts. Clearing **dry-run** publishes, from `main`
only. A dry run from another branch needs that branch in the environment:
`release/ci-secrets.sh --branch <name>`.

## Publishing from a Mac

The workflow above is how releases are made. `publish.sh` makes the same Mac files on a Mac, for a
release GitHub Actions cannot build; it does not build the phone apps. Do not use both for one
version: whichever publishes first wins, and the other refuses.

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
