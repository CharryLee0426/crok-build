#!/bin/bash
# Puts DotSlash on the rest of a macOS job's PATH. The proto build scripts run bin/protoc, a DotSlash file
# that fetches the pinned protoc (README.md, "Building from source"), so every crok build needs it.
#
#   .github/scripts/install-dotslash.sh
set -euo pipefail

version=v0.5.9
sha256=eef15be1b554de7b1409cb0c69c24f2cd04f19c0f101ad69fcdf9d66d4d51639

curl -fsSL --retry 3 -o "$RUNNER_TEMP/dotslash.tar.gz" \
    "https://github.com/facebook/dotslash/releases/download/$version/dotslash-macos-arm64.$version.tar.gz"
echo "$sha256  $RUNNER_TEMP/dotslash.tar.gz" | shasum -a 256 -c -
mkdir -p "$RUNNER_TEMP/bin"
tar -xzf "$RUNNER_TEMP/dotslash.tar.gz" -C "$RUNNER_TEMP/bin" dotslash
echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"
PATH="$RUNNER_TEMP/bin:$PATH" bin/protoc --version
