#!/bin/bash
# Compiles the Libraries.dev Metal shaders (Shaders/*.metal) into one library,
# LibrariesDev.metallib, which `LibrariesDevShaders` loads at run time.
#
# SwiftPM on its own does not compile .metal files (Xcode's build system does),
# so the desktop app's build-app.sh runs this and copies the result into the
# bundle's Resources. It needs Xcode's Metal Toolchain; on Xcode 26 and later
# that is a separate component:
#
#     xcodebuild -downloadComponent MetalToolchain
#
# Usage: build-shaders.sh <output.metallib>
# Exits 2 (and writes nothing) when no Metal compiler is installed, so callers
# can build without the effects rather than fail.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output="${1:?usage: build-shaders.sh <output.metallib>}"
# The app runs on macOS 14 and later; SwiftUI shader effects start there too.
deployment_target="${LIBRARIESDEV_METAL_MIN_MACOS:-14.0}"

if ! /usr/bin/xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    printf 'warning: no Metal compiler (install it with: xcodebuild -downloadComponent MetalToolchain); building without the Libraries.dev shader effects.\n' >&2
    exit 2
fi

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/librariesdev-shaders.XXXXXX")"
trap '/bin/rm -rf "$work"' EXIT
air_files=()
for source in "$script_dir"/Shaders/*.metal; do
    air="$work/$(/usr/bin/basename "$source" .metal).air"
    /usr/bin/xcrun -sdk macosx metal -c -std=metal3.0 -mmacosx-version-min="$deployment_target" "$source" -o "$air"
    air_files+=("$air")
done
/bin/mkdir -p "$(/usr/bin/dirname "$output")"
/usr/bin/xcrun -sdk macosx metallib "${air_files[@]}" -o "$work/LibrariesDev.metallib"
/bin/mv -f "$work/LibrariesDev.metallib" "$output"
printf 'Built %s\n' "$output"
