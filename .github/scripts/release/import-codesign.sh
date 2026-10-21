#!/bin/bash
# Puts the "Crok Code Signing" identity from the release environment's secrets where release/codesign.sh
# signs with it (CROK_CODESIGN_DIR, for the rest of the job), and fails unless it is the certificate in
# release/crok-codesign.pem, so the builds keep the macOS permissions the last release had, and unless
# codesign can sign with it, so an unusable identity fails here and not after a 45-minute build.
#
#   .github/scripts/release/import-codesign.sh
# Environment (release/ci-secrets.sh sets both from this Mac's ~/.crok-codesign):
#   CROK_CODESIGN_KEYCHAIN   crok-codesign.keychain-db, base64
#   CROK_CODESIGN_PASSWORD   the password file's contents
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

[[ -n "${CROK_CODESIGN_KEYCHAIN:-}" && -n "${CROK_CODESIGN_PASSWORD:-}" ]] \
    || fail "the release environment has no CROK_CODESIGN_KEYCHAIN or CROK_CODESIGN_PASSWORD secret; run release/ci-secrets.sh on the Mac that has ~/.crok-codesign"

dir="$RUNNER_TEMP/crok-codesign"
rm -rf "$dir"
mkdir -m 700 "$dir"
printf '%s' "$CROK_CODESIGN_KEYCHAIN" | base64 --decode > "$dir/crok-codesign.keychain-db"
(umask 077 && printf '%s\n' "$CROK_CODESIGN_PASSWORD" > "$dir/password")
echo "CROK_CODESIGN_DIR=$dir" >> "$GITHUB_ENV"

certificate="$(CROK_CODESIGN_DIR="$dir" release/codesign.sh --certificate | fingerprint)"
[[ "$certificate" == "$(pinned_signer)" ]] \
    || fail "the CROK_CODESIGN_KEYCHAIN secret holds certificate $certificate, not release/crok-codesign.pem's $(pinned_signer)"

# codesign on the macOS 26 runner finds no identity in a keychain that is off the user's keychain search
# list, even the one --keychain names (macOS 27 signs from it all the same), so the list gets this one too.
keychain="$dir/crok-codesign.keychain-db"
search_list=()
while IFS= read -r entry; do
    entry="$(sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' <<< "$entry")"
    if [[ -n "$entry" && "$entry" != "$keychain" ]]; then search_list+=("$entry"); fi
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" ${search_list[@]+"${search_list[@]}"}

# Signs a copy of /usr/bin/true the way build-tui.sh signs crok, so a keychain codesign cannot sign from
# stops the release before any build.
probe="$RUNNER_TEMP/crok-codesign-probe"
cp /usr/bin/true "$probe"
CROK_CODESIGN_DIR="$dir" release/codesign.sh --identifier dev.chenli.crok.probe "$probe" \
    || fail "codesign cannot sign with the CROK_CODESIGN_KEYCHAIN secret (see above); if it holds no \"Crok Code Signing\" identity, the secret has the certificate without its key: run release/ci-secrets.sh again on the Mac that has ~/.crok-codesign"
check_signer "$probe"
rm -f "$probe"
printf 'Signing with Crok Code Signing %s\n' "$certificate"
