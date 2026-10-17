#!/bin/bash
# Builds, signs and publishes one crok release: both Crok Desktop disk images, the standalone
# crok tarball, SHA256SUMS.txt and its signature, as a GitHub release of the fork.
#
#   release/publish.sh --notes dist/v1.5.0/release-notes.md
#
# The version is VERSION at the repository root; the tag is desktop-v<version>. The manifest is
# signed with `ssh-keygen -Y sign` and the key in ~/.ssh/crok-release (SIGN_KEY), whose public half
# is release/crok-release.pub, compiled into crok. `crok upgrade` and Check for Updates… refuse a
# release whose manifest does not verify against it. The apps and crok are code signed by
# release/codesign.sh, and nothing is published unless that is the certificate in
# release/crok-codesign.pem, so macOS permissions carry over from the previous release.
#
# Options:
#   --notes FILE     Release notes (English first, then the five translations; see the README).
#   --dry-run        Build, sign and verify, but create no tag and no release.
#   --skip-build     Reuse the images and tarball already in desktop/macOS/dist/v<version>.
#   --allow-dirty    Build from a tree with uncommitted changes.
# Environment:
#   SIGN_KEY           Private key (default ~/.ssh/crok-release).
#   REPO               GitHub repository (default CharryLee0426/crok-build).
#   MACOS26_SDKROOT    SDK for the macOS 26 image (default: the toolchain's default SDK).
#   MACOS15_SDKROOT    SDK for the macOS 15 image (default: the newest MacOSX15*.sdk in CommandLineTools).
#   CARGO_TARGET_DIR   Passed to make (a worktree can reuse the main checkout's target).
#   CROK_CODESIGN_DIR  The code signing identity's folder (default ~/.crok-codesign).
#   SIGN_IDENTITY      Another code signing identity; it must still be release/crok-codesign.pem's.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$script_dir/.." && pwd)"
cd "$repo"

notes=""
dry_run=0
skip_build=0
allow_dirty=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes) notes="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --skip-build) skip_build=1; shift ;;
        --allow-dirty) allow_dirty=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) printf 'unknown option %s\n' "$1" >&2; exit 2 ;;
    esac
done

github_repo="${REPO:-CharryLee0426/crok-build}"
sign_key="${SIGN_KEY:-$HOME/.ssh/crok-release}"
version="$(tr -d '[:space:]' < VERSION)"
tag="desktop-v$version"
out="$repo/desktop/macOS/dist/v$version"
arch="$(uname -m)"
case "$arch" in
    arm64) tarball_arch=aarch64 ;;
    *) tarball_arch="$arch" ;;
esac
tarball="crok-$version-$tarball_arch-apple-darwin.tar.gz"
make_cmd=(make)
if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then make_cmd+=("CARGO_TARGET_DIR=$CARGO_TARGET_DIR"); fi
target_dir="${CARGO_TARGET_DIR:-target}"
harness="$target_dir/release/xai-grok-pager"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

say "Crok release $version ($tag) for $github_repo"
[[ "$(uname -s)" == Darwin ]] || fail "releases are built on macOS"
[[ -f "$sign_key" ]] || fail "no signing key at $sign_key (ssh-keygen -t ed25519 -f $sign_key -C 'crok release signing')"
signer_public="$(ssh-keygen -y -f "$sign_key" | cut -d ' ' -f 1,2)"
if ! grep -qF "$signer_public" "$repo/release/crok-release.pub"; then
    fail "$sign_key is not one of the keys in release/crok-release.pub; crok would reject the release"
fi
if [[ "$allow_dirty" == 0 && -n "$(git status --porcelain)" ]]; then
    fail "the tree has uncommitted changes (use --allow-dirty to build anyway)"
fi
if [[ "$dry_run" == 0 ]]; then
    [[ -n "$notes" ]] || fail "--notes FILE is required to publish"
    [[ -f "$notes" ]] || fail "release notes not found: $notes"
    gh auth status >/dev/null 2>&1 || fail "gh is not signed in"
    if gh release view "$tag" -R "$github_repo" >/dev/null 2>&1; then
        fail "release $tag already exists on $github_repo"
    fi
fi
# Every release is signed by this certificate, so the permissions macOS gave one version (Screen
# Recording, Accessibility, microphone) carry over to the next. A release signed by any other
# would make every user allow them again.
signer_pem="$repo/release/crok-codesign.pem"
[[ -f "$signer_pem" ]] || fail "missing $signer_pem, the certificate releases are signed by"
fingerprint() { /usr/bin/openssl x509 -noout -fingerprint -sha1 | cut -d = -f 2 | tr -d : | tr '[:upper:]' '[:lower:]'; }
signer="$(fingerprint < "$signer_pem")"
if [[ "$skip_build" == 0 && -z "${SIGN_IDENTITY:-}" ]]; then
    local_signer="$({ release/codesign.sh --certificate 2>/dev/null || true; } | fingerprint 2>/dev/null || true)"
    if [[ "$local_signer" != "$signer" ]]; then
        fail "this Mac's Crok Code Signing identity (${CROK_CODESIGN_DIR:-~/.crok-codesign}) is not the certificate in release/crok-codesign.pem. Copy that folder from the Mac that has it (see release/README.md); replace the .pem only to change certificates on purpose."
    fi
fi
check_signer() {
    codesign --verify --strict -R="certificate leaf = H\"$signer\"" "$1" 2>/dev/null \
        || fail "$1 is not signed by the certificate in release/crok-codesign.pem"
}

mkdir -p "$out"
if [[ "$skip_build" == 0 ]]; then
    say "Building the TUI"
    "${make_cmd[@]}" build
    built_release="$("$harness" version --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("release",""))')"
    [[ "$built_release" == "$version" ]] || fail "the built crok carries release $built_release, not $version (VERSION changed after the build?)"

    macos15_sdk="${MACOS15_SDKROOT:-$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk 2>/dev/null | sort -V | tail -1)}"
    [[ -n "$macos15_sdk" && -d "$macos15_sdk" ]] || fail "no macOS 15 SDK found; set MACOS15_SDKROOT"
    for sdk in 26 15; do
        say "Building the macOS $sdk SDK image"
        rm -rf desktop/macOS/.build desktop/macOS/dist/*.dmg
        if [[ "$sdk" == 26 ]]; then
            sdkroot="${MACOS26_SDKROOT:-}"
        else
            sdkroot="$macos15_sdk"
        fi
        if [[ -n "$sdkroot" ]]; then
            SDKROOT="$sdkroot" DESKTOP_REGISTER_APP=0 "${make_cmd[@]}" dmg-desktop CROK_BINARY="$repo/$harness"
        else
            DESKTOP_REGISTER_APP=0 "${make_cmd[@]}" dmg-desktop CROK_BINARY="$repo/$harness"
        fi
        app="desktop/macOS/dist/Crok Desktop.app"
        linked_sdk="$(otool -l "$app/Contents/MacOS/GrokDesktop" | awk '/LC_BUILD_VERSION/ {f=1} f && /sdk/ {print $2; exit}')"
        case "$sdk:$linked_sdk" in
            26:26*|26:27*|26:28*) ;;
            15:15*) ;;
            *) fail "the macOS $sdk image was linked against SDK $linked_sdk" ;;
        esac
        image="$(ls desktop/macOS/dist/Crok-Desktop-"$version"-*.dmg)"
        mv -f "$image" "$out/Crok-Desktop-$version-$arch-macOS$sdk-SDK.dmg"
        rm -rf "$out/apps/macOS$sdk-SDK.app"
        mkdir -p "$out/apps"
        ditto "$app" "$out/apps/macOS$sdk-SDK.app"
    done

    say "Packing the standalone crok"
    staging="$(mktemp -d "${TMPDIR:-/tmp}/crok-release.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    cp "$harness" "$staging/crok"
    chmod 755 "$staging/crok"
    release/codesign.sh --identifier dev.chenli.crok "$staging/crok"
    tar -czf "$out/$tarball" -C "$staging" crok
fi

say "Checking the code signatures"
for sdk in 26 15; do
    app="$out/apps/macOS$sdk-SDK.app"
    [[ -d "$app" ]] || fail "missing $app, the app inside the macOS $sdk SDK image"
    check_signer "$app"
    check_signer "$app/Contents/Resources/crok"
done
unpacked="$(mktemp -d "${TMPDIR:-/tmp}/crok-release-check.XXXXXX")"
tar -xzf "$out/$tarball" -C "$unpacked" crok
check_signer "$unpacked/crok"
rm -rf "$unpacked"
printf 'Signed by release/crok-codesign.pem (%s)\n' "$signer"

say "Signing the manifest"
cd "$out"
for required in "Crok-Desktop-$version-$arch-macOS26-SDK.dmg" "Crok-Desktop-$version-$arch-macOS15-SDK.dmg" "$tarball"; do
    [[ -f "$required" ]] || fail "missing $required in $out"
done
shasum -a 256 Crok-Desktop-*.dmg "$tarball" > SHA256SUMS.txt
rm -f SHA256SUMS.txt.sig
ssh-keygen -Y sign -f "$sign_key" -n crok-release SHA256SUMS.txt
cat SHA256SUMS.txt
cd "$repo"

say "Checking the release the way crok upgrade will"
"$harness" upgrade --verify-dir "$out"

if [[ "$dry_run" == 1 ]]; then
    say "Dry run: not publishing. The release files are in $out"
    exit 0
fi

say "Tagging $tag"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    printf 'tag %s exists locally at %s\n' "$tag" "$(git rev-parse --short "$tag")"
else
    git tag -a "$tag" -m "Crok Desktop $version"
fi
git push origin "refs/tags/$tag"

say "Publishing"
gh release create "$tag" -R "$github_repo" --title "Crok Desktop $version" --notes-file "$notes" \
    "$out/Crok-Desktop-$version-$arch-macOS26-SDK.dmg" \
    "$out/Crok-Desktop-$version-$arch-macOS15-SDK.dmg" \
    "$out/$tarball" \
    "$out/SHA256SUMS.txt" \
    "$out/SHA256SUMS.txt.sig"

say "Published. Checking from the built crok:"
"$harness" upgrade --check
