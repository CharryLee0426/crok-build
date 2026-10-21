#!/bin/bash
# Builds one Crok Desktop disk image around the release crok, the way release/publish.sh does, after
# .github/scripts/select-xcode.sh has picked the Xcode and SDK.
#
#   .github/scripts/release/build-desktop.sh 26|15 TUI_DIR OUT
# TUI_DIR holds build-tui.sh's tarball. Writes OUT/Crok-Desktop-<version>-arm64-macOS<sdk>-SDK.dmg and
# OUT/facts-desktop-<sdk>.env (for the notes). Environment: CROK_CODESIGN_DIR.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

sdk="${1:?usage: build-desktop.sh 26|15 TUI_DIR OUT}"
tui_dir="${2:?usage: build-desktop.sh 26|15 TUI_DIR OUT}"
out="${3:?usage: build-desktop.sh 26|15 TUI_DIR OUT}"
case "$sdk" in 26 | 15) ;; *) fail "unknown SDK $sdk: expected 26 or 15" ;; esac
version="$(tr -d '[:space:]' < VERSION)"
mkdir -p "$out"

harness_dir="$RUNNER_TEMP/crok-harness"
rm -rf "$harness_dir"
mkdir -p "$harness_dir"
tar -xzf "$tui_dir/$(release_tarball "$version")" -C "$harness_dir" crok
harness="$harness_dir/crok"

rm -rf desktop/macOS/.build desktop/macOS/dist/*.dmg
DESKTOP_REGISTER_APP=0 make dmg-desktop CROK_BINARY="$harness"

app="desktop/macOS/dist/Crok Desktop.app"
check_linked_sdk "$sdk" "$app/Contents/MacOS/GrokDesktop"
check_signer "$app"
check_signer "$app/Contents/Resources/crok"
check_destination "$app/Contents/Resources/crok"
check_relay "$app/Contents/Resources/crok"
images=(desktop/macOS/dist/Crok-Desktop-"$version"-*.dmg)
[[ ${#images[@]} == 1 && -f "${images[0]}" ]] || fail "expected one disk image of $version in desktop/macOS/dist, found: ${images[*]}"
mv -f "${images[0]}" "$out/$(release_dmg "$version" "$sdk")"

{
    printf 'SDK%s=%s\n' "$sdk" "$(linked_sdk "$app/Contents/MacOS/GrokDesktop")"
    printf 'XCODE%s=%s\n' "$sdk" "$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
} > "$out/facts-desktop-$sdk.env"
cat "$out/facts-desktop-$sdk.env"
ls -l "$out"
