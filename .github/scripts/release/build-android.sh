#!/bin/bash
# Builds the production Android APK with mobile/scripts/build-apps.sh (release, the production relay),
# signed with the release key, so it installs over the APK of the release before.
#
#   .github/scripts/release/build-android.sh OUT
# Writes OUT/Crok-Android-<version>.apk.
# Environment (release/ci-secrets.sh sets them): CROK_ANDROID_KEYSTORE_BASE64 (the keystore, base64),
# CROK_ANDROID_KEYSTORE_PASSWORD, CROK_ANDROID_KEY_ALIAS; ANDROID_HOME, JAVA_HOME from the runner.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

out="${1:?usage: build-android.sh OUT}"
version="$(tr -d '[:space:]' < VERSION)"
mkdir -p "$out"
phone="$RUNNER_TEMP/phone"

[[ -n "${CROK_ANDROID_KEYSTORE_BASE64:-}" && -n "${CROK_ANDROID_KEYSTORE_PASSWORD:-}" && -n "${CROK_ANDROID_KEY_ALIAS:-}" ]] \
    || fail "the release environment lacks CROK_ANDROID_KEYSTORE_BASE64, CROK_ANDROID_KEYSTORE_PASSWORD or CROK_ANDROID_KEY_ALIAS; run release/ci-secrets.sh"
keystore_dir="$RUNNER_TEMP/crok-android"
rm -rf "$keystore_dir"
mkdir -m 700 "$keystore_dir"
printf '%s' "$CROK_ANDROID_KEYSTORE_BASE64" | base64 --decode > "$keystore_dir/release.keystore"
# app/build.gradle.kts signs release builds with this keystore.
export CROK_ANDROID_KEYSTORE="$keystore_dir/release.keystore"

OUT="$phone" mobile/scripts/build-apps.sh prod --android-only
apk="$phone/crok-android-prod.apk"

apksigner="$(printf '%s\n' "$ANDROID_HOME"/build-tools/*/apksigner | sort -V | tail -n 1)"
[[ -x "$apksigner" ]] || fail "no apksigner in $ANDROID_HOME/build-tools"
certificates="$("$apksigner" verify --print-certs "$apk")"
printf '%s\n' "$certificates"
if grep -q 'CN=Android Debug' <<<"$certificates"; then
    fail "the APK is signed with a debug key, not the release key"
fi
cp -f "$apk" "$out/$(release_android_apk "$version")"
ls -l "$out"
