#!/bin/bash
# Builds the production iOS app with mobile/scripts/build-apps.sh (Release, the production relay) and packs
# the release's two iOS files: the device app, unsigned, as an .ipa, and the Simulator app as a zip.
#
#   .github/scripts/release/build-ios.sh OUT
# Writes OUT/Crok-iOS-<version>-unsigned.ipa and OUT/Crok-iOS-<version>-Simulator.zip.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

out="${1:?usage: build-ios.sh OUT}"
version="$(tr -d '[:space:]' < VERSION)"
mkdir -p "$out"
phone="$RUNNER_TEMP/phone"

xcodebuild -version
OUT="$phone" mobile/scripts/build-apps.sh prod --ios-only --ios-device

cp -f "$phone/Crok-iOS-prod-unsigned.ipa" "$out/$(release_ios_ipa "$version")"
# The zip unpacks to Crok.app, for `xcrun simctl install booted Crok.app`.
staging="$RUNNER_TEMP/ios-simulator"
rm -rf "$staging"
mkdir -p "$staging"
ditto "$phone/Crok-iOS-prod.app" "$staging/Crok.app"
ditto -c -k --sequesterRsrc --keepParent "$staging/Crok.app" "$out/$(release_ios_simulator "$version")"
ls -l "$out"
