#!/bin/bash
# Checks every file the build jobs made, the way a user's Mac and `crok upgrade` will see them, then writes
# SHA256SUMS.txt over them, signs it and joins the release notes.
#
#   .github/scripts/release/assemble.sh DIR NOTES
# DIR holds what the build jobs uploaded: the six release files (release_files in release/lib.sh) and their
# facts-*.env. Afterwards it holds the release exactly: those files, SHA256SUMS.txt and SHA256SUMS.txt.sig.
# NOTES is where the release body goes. Environment: CROK_RELEASE_SIGNING_KEY, the private key whose public
# half is in release/crok-release.pub (release/ci-secrets.sh sets it from ~/.ssh/crok-release).
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

dir="${1:?usage: assemble.sh DIR NOTES}"
notes="${2:?usage: assemble.sh DIR NOTES}"
dir="$(cd -- "$dir" && pwd)"
version="$(tr -d '[:space:]' < VERSION)"
commit="${GITHUB_SHA:-$(git rev-parse HEAD)}"
work="$RUNNER_TEMP/assemble"
rm -rf "$work"
mkdir -p "$work/facts"
say() { printf '\n==> %s\n' "$*"; }

files=()
while IFS= read -r file; do files+=("$file"); done < <(release_files "$version")

# The notes quote what the builds were made with; those facts are not release files.
mv "$dir"/facts-*.env "$work/facts/"
for file in "${files[@]}"; do
    [[ -f "$dir/$file" ]] || fail "no $file from the build jobs"
done
for path in "$dir"/*; do
    name="$(basename "$path")"
    case " ${files[*]} " in
        *" $name "*) ;;
        *) fail "the build jobs left $name, which is not a release file" ;;
    esac
done

say "Checking the disk images"
for sdk in 26 15; do
    image="$dir/$(release_dmg "$version" "$sdk")"
    mount="$work/macOS$sdk"
    mkdir -p "$mount"
    hdiutil attach "$image" -readonly -nobrowse -noautoopen -mountpoint "$mount" > /dev/null
    app="$mount/Crok Desktop.app"
    check_linked_sdk "$sdk" "$app/Contents/MacOS/GrokDesktop"
    codesign --verify --deep --strict "$app"
    check_signer "$app"
    check_signer "$app/Contents/Resources/crok"
    shown="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
    [[ "$shown" == "$version" ]] || fail "$(basename "$image") holds Crok Desktop $shown, not $version"
    [[ "$(crok_version_field "$app/Contents/Resources/crok" release)" == "$version" ]] || fail "the crok in $(basename "$image") is not release $version"
    check_destination "$app/Contents/Resources/crok"
    check_relay "$app/Contents/Resources/crok"
    printf '%s: Crok Desktop %s, SDK %s\n' "$(basename "$image")" "$shown" "$(linked_sdk "$app/Contents/MacOS/GrokDesktop")"
    hdiutil detach "$mount" > /dev/null
done

say "Checking the standalone crok"
mkdir -p "$work/tarball"
tar -xzf "$dir/$(release_tarball "$version")" -C "$work/tarball" crok
crok="$work/tarball/crok"
check_signer "$crok"
[[ "$(crok_version_field "$crok" release)" == "$version" ]] || fail "the tarball's crok is not release $version"
check_destination "$crok"
check_relay "$crok"

say "Checking the phone apps"
relay="$(prod_relay CONVEX_URL)"
check_ios() {
    local plist
    plist="$work/$(basename "$1").plist"
    unzip -p "$1" "$2/Info.plist" > "$plist"
    [[ "$(plutil -extract CFBundleIdentifier raw "$plist")" == dev.chenli.crok.mobile ]] || fail "$(basename "$1") is not the Crok iOS app"
    [[ "$(plutil -extract CrokRelayURL raw "$plist")" == "$relay" ]] || fail "$(basename "$1") does not sign in to the production relay $relay"
    printf '%s signs in to %s\n' "$(basename "$1")" "$relay"
}
check_ios "$dir/$(release_ios_ipa "$version")" Payload/Crok.app
check_ios "$dir/$(release_ios_simulator "$version")" Crok.app
apk="$dir/$(release_android_apk "$version")"
# Count rather than -q: grep -q stops at the first match and unzip's SIGPIPE would fail the pipeline.
matches="$(unzip -p "$apk" 'classes*.dex' | LC_ALL=C grep -a -c -F "$relay" || true)"
[[ "${matches:-0}" -gt 0 ]] || fail "$(basename "$apk") does not sign in to the production relay $relay"
printf '%s signs in to %s\n' "$(basename "$apk")" "$relay"

say "Signing the manifest"
[[ -n "${CROK_RELEASE_SIGNING_KEY:-}" ]] || fail "the release environment has no CROK_RELEASE_SIGNING_KEY secret; run release/ci-secrets.sh"
key="$work/crok-release"
(umask 077 && printf '%s\n' "$CROK_RELEASE_SIGNING_KEY" | sed '/^[[:space:]]*$/d' > "$key")
signer="$(ssh-keygen -y -f "$key" | cut -d ' ' -f 1,2)"
grep -qF "$signer" release/crok-release.pub \
    || fail "CROK_RELEASE_SIGNING_KEY is not one of the keys in release/crok-release.pub; crok would refuse the release"
(cd "$dir" && shasum -a 256 "${files[@]}" > SHA256SUMS.txt)
rm -f "$dir/SHA256SUMS.txt.sig"
ssh-keygen -Y sign -f "$key" -n crok-release "$dir/SHA256SUMS.txt"
rm -f "$key"
cat "$dir/SHA256SUMS.txt"

say "Checking the release the way crok upgrade will"
CROK_HOME="$work/crok-home" "$crok" upgrade --verify-dir "$dir"

say "Joining the release notes"
values=(--set "COMMIT=${commit:0:8}")
for facts in "$work"/facts/*.env; do
    while IFS= read -r line; do
        [[ -n "$line" ]] && values+=(--set "$line")
    done < "$facts"
done
expect=()
for file in "${files[@]}"; do expect+=(--expect "$file"); done
python3 -I release/notes/assemble.py "release/notes/v$version" --out "$notes" --sums "$dir/SHA256SUMS.txt" \
    "${values[@]}" "${expect[@]}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        printf '\n| File | Size | SHA-256 |\n| --- | --- | --- |\n'
        for file in "${files[@]}"; do
            # shellcheck disable=SC2016 # the backticks are Markdown
            printf '| `%s` | %s MB | `%s` |\n' "$file" "$(( $(stat -f %z "$dir/$file") / 1048576 ))" \
                "$(awk -v name="$file" '$2 == name { print $1 }' "$dir/SHA256SUMS.txt")"
        done
        printf '\nBuilt with: %s\n' "$(cat "$work"/facts/*.env | tr '\n' ' ')"
    } >> "$GITHUB_STEP_SUMMARY"
fi
