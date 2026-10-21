#!/bin/bash
# Puts the "Crok Code Signing" identity from the release environment's secrets where release/codesign.sh
# signs with it (CROK_CODESIGN_DIR, for the rest of the job), and fails unless it is the certificate in
# release/crok-codesign.pem, so the builds keep the macOS permissions the last release had.
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
printf 'Signing with Crok Code Signing %s\n' "$certificate"
