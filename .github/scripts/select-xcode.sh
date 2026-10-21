#!/bin/bash
# Points the rest of a CI job at the newest released Xcode 26 on the runner (DEVELOPER_DIR) and, given
# `15`, at the newest macOS 15 SDK there (SDKROOT), the way release/publish.sh builds the macOS 15 image.
# Without an argument, or with `26`, the job keeps Xcode 26's own SDKs.
#
#   .github/scripts/select-xcode.sh [26|15]
set -euo pipefail
shopt -s nullglob

# The last of the paths on stdin by the version in their file name.
newest() {
    while IFS= read -r path; do printf '%s\t%s\n' "$(basename "$path")" "$path"; done | sort -V | tail -n 1 | cut -f 2
}

xcodes=()
for app in /Applications/Xcode_26*.app; do
    case "$app" in *[Bb]eta*|*Release_Candidate*) ;; *) xcodes+=("$app") ;; esac
done
xcode="$(printf '%s\n' ${xcodes[@]+"${xcodes[@]}"} | newest)"
if [[ -z "$xcode" ]]; then
    echo "::error::No Xcode 26 on this runner"
    exit 1
fi
echo "DEVELOPER_DIR=$xcode/Contents/Developer" >> "$GITHUB_ENV"
echo "Xcode: $xcode"

case "${1:-}" in
    "" | 26) ;;
    15)
        sdks=(/Applications/Xcode_16*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.*.sdk
              /Library/Developer/CommandLineTools/SDKs/MacOSX15.*.sdk)
        sdk="$(printf '%s\n' ${sdks[@]+"${sdks[@]}"} | newest)"
        if [[ -z "$sdk" ]]; then
            echo "::error::No macOS 15 SDK on this runner"
            exit 1
        fi
        echo "SDKROOT=$sdk" >> "$GITHUB_ENV"
        echo "SDK: $sdk"
        ;;
    *)
        echo "::error::Unknown SDK $1: expected 26 or 15"
        exit 1
        ;;
esac
