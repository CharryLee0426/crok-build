#!/bin/bash
# Packages dist/Crok Desktop.app as a drag-to-Applications disk image in dist/.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd -- "$script_dir/.." && pwd)"
app_name="Crok Desktop"
app_dir="$package_dir/dist/$app_name.app"
volume_name="$app_name"
# LZMA makes the smallest download; images in it open on macOS 10.15 and later, below the app's minimum.
format="${DMG_FORMAT:-ULMO}"

harness="$app_dir/Contents/Resources/crok"
launcher="$app_dir/Contents/Resources/bin/crok"
for required in "$app_dir/Contents/MacOS/GrokDesktop" "$harness" "$launcher"; do
    if [[ ! -x "$required" ]]; then
        printf 'Build the app first (make build-desktop); missing %s\n' "$required" >&2
        exit 1
    fi
done
/usr/bin/codesign --verify --deep --strict "$app_dir"

architectures() {
    case " $(/usr/bin/lipo -archs "$1") " in
        *" arm64 "*" x86_64 "* | *" x86_64 "*" arm64 "*) echo universal ;;
        *) /usr/bin/lipo -archs "$1" ;;
    esac
}
arch="$(architectures "$app_dir/Contents/MacOS/GrokDesktop")"
harness_arch="$(architectures "$harness")"
if [[ "$arch" != "$harness_arch" ]]; then
    printf 'The app is built for %s but its Crok Build for %s; rebuild them for the same architectures.\n' "$arch" "$harness_arch" >&2
    exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
dmg="$package_dir/dist/Crok-Desktop-$version-$arch.dmg"

# Finder addresses the new volume by name, so another volume with that name would get the layout.
if [[ -e "/Volumes/$volume_name" ]]; then
    printf 'Eject the mounted "%s" volume, then run this again.\n' "$volume_name" >&2
    exit 1
fi

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/crok-dmg.XXXXXX")"
device=""
cleanup() {
    if [[ -n "$device" ]]; then /usr/bin/hdiutil detach "$device" -force -quiet >/dev/null 2>&1 || true; fi
    /bin/rm -rf "$work"
}
trap cleanup EXIT

# Kills a command that outlives its time, such as osascript waiting on a Finder permission prompt.
run_with_timeout() {
    local seconds=$1
    shift
    "$@" &
    local pid=$!
    (sleep "$seconds" && kill "$pid" 2>/dev/null) &
    local watchdog=$!
    local status=0
    wait "$pid" || status=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$status"
}

detach() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if /usr/bin/hdiutil detach "$1" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    /usr/bin/hdiutil detach "$1" -force >/dev/null
}

staging="$work/staging"
/bin/mkdir -p "$staging"
/usr/bin/ditto "$app_dir" "$staging/$app_name.app"
/bin/ln -s /Applications "$staging/Applications"

size_mb=$(( $(/usr/bin/du -sm "$staging" | /usr/bin/cut -f1) + 40 ))
# hdiutil create sometimes fails with "Resource busy" while the system scans the new files.
for attempt in 1 2 3; do
    if /usr/bin/hdiutil create -volname "$volume_name" -srcfolder "$staging" -fs HFS+ -format UDRW -size "${size_mb}m" -ov "$work/layout.dmg" >/dev/null; then break; fi
    if [[ "$attempt" == 3 ]]; then exit 1; fi
    sleep 3
done
attached="$(/usr/bin/hdiutil attach "$work/layout.dmg" -readwrite -noverify -noautoopen)"
device="$(printf '%s\n' "$attached" | /usr/bin/awk '/^\/dev\// { print $1; exit }')"
mount_point="$(printf '%s\n' "$attached" | /usr/bin/awk -F '\t' '/\/Volumes\// { print $NF; exit }')"

cat > "$work/layout.applescript" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    set appName to item 2 of argv
    tell application "Finder"
        tell disk volumeName
            open
            set theWindow to container window
            set current view of theWindow to icon view
            set toolbar visible of theWindow to false
            set statusbar visible of theWindow to false
            set bounds of theWindow to {200, 160, 740, 500}
            set viewOptions to icon view options of theWindow
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 128
            set text size of viewOptions to 13
            set position of item appName of theWindow to {140, 150}
            set position of item "Applications" of theWindow to {400, 150}
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
APPLESCRIPT

if [[ "${DMG_FINDER_LAYOUT:-1}" == 0 ]]; then
    printf 'Skipping the Finder layout (DMG_FINDER_LAYOUT=0).\n'
elif run_with_timeout 60 /usr/bin/osascript "$work/layout.applescript" "$volume_name" "$app_name.app" >/dev/null; then
    # Finder writes the layout to .DS_Store shortly after the window closes.
    for _ in $(seq 1 20); do
        if [[ -f "$mount_point/.DS_Store" ]]; then break; fi
        sleep 0.5
    done
    printf 'Laid out the installer window with Finder.\n'
else
    printf 'Finder could not lay out the installer window, so the image opens in the default view.\n' >&2
fi

# After the layout: Finder's view update deletes a volume icon it finds and clears the custom icon flag.
/bin/cp "$package_dir/Resources/AppIcon.icns" "$mount_point/.VolumeIcon.icns"
if [[ -x /usr/bin/SetFile ]]; then /usr/bin/SetFile -a C "$mount_point"; fi

/bin/rm -rf "$mount_point/.fseventsd" "$mount_point/.Trashes"
/bin/sync
detach "$device"
device=""

/bin/rm -f "$dmg"
/usr/bin/hdiutil convert "$work/layout.dmg" -format "$format" -o "$dmg" >/dev/null
if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$dmg"
fi
/usr/bin/hdiutil verify "$dmg" >/dev/null

# Check what a user gets: the signed app and a working crok command inside the finished image.
check="$work/check"
/bin/mkdir -p "$check"
attached="$(/usr/bin/hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$check")"
device="$(printf '%s\n' "$attached" | /usr/bin/awk '/^\/dev\// { print $1; exit }')"
/usr/bin/codesign --verify --deep --strict "$check/$app_name.app"
bundled_version="$("$check/$app_name.app/Contents/Resources/bin/crok" --version)"
if [[ ! -L "$check/Applications" || ! -f "$check/.VolumeIcon.icns" ]]; then
    printf 'The image is missing its Applications link or volume icon.\n' >&2
    exit 1
fi
detach "$device"
device=""

printf 'Built %s\n' "$dmg"
printf '  Crok Desktop %s for %s, bundling %s\n' "$version" "$arch" "$bundled_version"
printf '  %s, SHA-256 %s\n' "$(/usr/bin/du -h "$dmg" | /usr/bin/cut -f1 | /usr/bin/tr -d ' ')" "$(/usr/bin/shasum -a 256 "$dmg" | /usr/bin/cut -d ' ' -f1)"
if [[ -z "${SIGN_IDENTITY:-}" || "$SIGN_IDENTITY" == "-" ]]; then
    printf '  Ad hoc signed and not notarized: on first launch macOS asks users to allow it in System Settings > Privacy & Security.\n'
fi
