#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd -- "$script_dir/.." && pwd)"
repository_dir="$(cd -- "$package_dir/../.." && pwd)"
app_name="${DESKTOP_APP_NAME:-Crok Desktop}"
bundle_identifier="${DESKTOP_BUNDLE_ID:-dev.chenli.crok.desktop}"
app_dir="${DESKTOP_APP_DIR:-$package_dir/dist/$app_name.app}"
icon_path="${DESKTOP_ICON_PATH:-$package_dir/Resources/AppIcon.icns}"
icon_preview="${DESKTOP_ICON_PREVIEW_PATH:-$package_dir/dist/AppIcon-preview.png}"
icon_style="${DESKTOP_ICON_STYLE:-standard}"
test_build="${DESKTOP_TEST_BUILD:-0}"
register_app="${DESKTOP_REGISTER_APP:-1}"
state_file="${DESKTOP_STATE_FILE:-}"
version="${DESKTOP_VERSION:-$(/usr/bin/tr -d '[:space:]' < "$package_dir/VERSION")}"
grok_source="${CROK_BINARY:-${GROK_BINARY:-$repository_dir/target/release/xai-grok-pager}}"
if [[ "$app_dir" != /* ]]; then app_dir="$PWD/$app_dir"; fi
if [[ "$icon_path" != /* ]]; then icon_path="$PWD/$icon_path"; fi
if [[ "$icon_preview" != /* ]]; then icon_preview="$PWD/$icon_preview"; fi
if [[ -n "$state_file" && "$state_file" != /* ]]; then state_file="$PWD/$state_file"; fi
if [[ "$grok_source" != /* ]]; then grok_source="$PWD/$grok_source"; fi
if [[ ! -f "$grok_source" || ! -x "$grok_source" ]]; then
    printf 'A bundled crok executable is required: %s\nBuild the release harness first or set CROK_BINARY at build time.\n' "$grok_source" >&2
    exit 1
fi
case "$test_build:$register_app" in
    0:0|0:1|1:0|1:1) ;;
    *) printf 'DESKTOP_TEST_BUILD and DESKTOP_REGISTER_APP must each be 0 or 1.\n' >&2; exit 1 ;;
esac
if [[ "$test_build" == 1 ]]; then test_build_bool=true; else test_build_bool=false; fi

# Renames a fresh copy over the executable. Overwriting it in place would invalidate the signed pages of a
# copy that is running from this bundle, and macOS kills such processes, with any tasks they run.
replace_executable() {
    local temporary
    temporary="$(/usr/bin/mktemp "$2.XXXXXX")"
    /bin/cp "$1" "$temporary"
    /bin/chmod 755 "$temporary"
    /bin/mv -f "$temporary" "$2"
}

icon_arguments=("$icon_path" "$package_dir/Resources/GrokMark.svg" "$package_dir/Sources/GrokDesktop/GrokSymbol.swift" "$icon_preview")
case "$icon_style" in
    standard) ;;
    test) icon_arguments+=(--test) ;;
    *) printf 'DESKTOP_ICON_STYLE must be standard or test.\n' >&2; exit 1 ;;
esac
swift "$script_dir/make-icon.swift" "${icon_arguments[@]}"
swift build --package-path "$package_dir" --configuration release
binary_dir="$(swift build --package-path "$package_dir" --configuration release --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
replace_executable "$binary_dir/GrokDesktop" "$app_dir/Contents/MacOS/GrokDesktop"

/bin/rm -f "$app_dir/Contents/Resources/grok" "$app_dir/Contents/Resources/bin/grok"
replace_executable "$grok_source" "$app_dir/Contents/Resources/crok"
/usr/bin/codesign --force --sign "${SIGN_IDENTITY:--}" "$app_dir/Contents/Resources/crok"
printf 'Bundled harness: %s\n' "$grok_source"
# The `crok` command: Settings links /usr/local/bin/crok to this launcher, which runs the bundled TUI.
/bin/mkdir -p "$app_dir/Contents/Resources/bin"
/usr/bin/install -m 755 "$package_dir/Resources/crok-command.sh" "$app_dir/Contents/Resources/bin/crok"
# Give changed artwork a new resource name so Finder and Dock can distinguish
# an in-place development rebuild from their cached icon for the same app.
icon_hash="$(/usr/bin/shasum -a 256 "$icon_path" | /usr/bin/cut -c 1-12)"
icon_name="AppIcon-$icon_hash"
for stale_icon in "$app_dir/Contents/Resources"/AppIcon-*.icns; do
    if [[ -f "$stale_icon" ]]; then /bin/rm "$stale_icon"; fi
done
cp "$icon_path" "$app_dir/Contents/Resources/$icon_name.icns"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>Crok Desktop</string>
    <key>CFBundleExecutable</key><string>GrokDesktop</string>
    <key>CFBundleIdentifier</key><string>dev.chenli.crok.desktop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>GrokDesktopTestBuild</key><false/>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Crok Desktop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Crok Desktop uses the microphone only while you dictate a prompt.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>When your account has no xAI voice credential, Crok Desktop transcribes your dictation on this Mac.</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -replace CFBundleDisplayName -string "$app_name" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "$app_name" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_identifier" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIconFile -string "$icon_name" "$app_dir/Contents/Info.plist"
if [[ -n "$state_file" ]]; then
    /usr/bin/plutil -insert GrokDesktopStateFile -string "$state_file" "$app_dir/Contents/Info.plist"
fi
/usr/bin/plutil -replace GrokDesktopTestBuild -bool "$test_build_bool" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$version" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"
# Ad hoc signing makes the local app bundle self-contained. Set SIGN_IDENTITY to
# a Developer ID identity when producing a distributable (then notarize it).
/usr/bin/codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$app_dir"
# Refresh only this bundle's registration; do not restart Dock or clear caches.
if [[ "$register_app" == 1 ]]; then
    /usr/bin/touch "$app_dir"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_dir"
fi
printf 'Built %s (version %s)\n' "$app_dir" "$version"
printf 'Launch with: open "%s"\n' "$app_dir"
