#!/bin/bash
# Builds both phone apps for one relay environment and puts them in the Desktop folder with its suffix.
#
#   mobile/scripts/build-apps.sh prod    iOS Release + Android release, production relay   → *-prod
#   mobile/scripts/build-apps.sh test    iOS Debug + Android debug, development relay       → *-debug
#
# The relay is the environment's CONVEX_URL (relay/environments/<env>.env), passed to both builds and read back
# from each result. Output (OUT, default "~/Desktop/Crok mobile e2e builds"):
#
#   Crok-iOS-<suffix>.app          iOS Simulator app (arm64)
#   Crok-iOS-<suffix>-unsigned.ipa iOS device app, not signed (with --ios-device): a sideloading tool or
#                                  `codesign` signs it with the installer's own Apple ID
#   crok-android-<suffix>.apk      Android APK (release: R8-minified, signed with the debug key)
#   README.txt                     what is there, from which commit, and how to install it (README-builds.txt when
#                                  README.txt holds notes this script did not write)
#
# Options: --ios-only, --android-only, --ios-device. Builds happen under target/mobile/ in the repository.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'build-apps: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
    prod|production) env_name=prod; suffix=prod; ios_config=Release; android_type=release ;;
    test|dev|debug) env_name=dev; suffix=debug; ios_config=Debug; android_type=debug ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
shift
ios=1
android=1
ios_device=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ios-only) android=0 ;;
        --android-only) ios=0 ;;
        --ios-device) ios_device=1 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option $1" ;;
    esac
    shift
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$script_dir/../.." && pwd)"
env_file="$repo/relay/environments/$env_name.env"
[[ -f "$env_file" ]] || fail "missing $env_file"
setting() { sed -n "s/^$1=//p" "$env_file" | tail -n 1; }
convex_url="$(setting CONVEX_URL)"
web_url="$(setting WEB_URL)"
[[ -n "$convex_url" ]] || fail "$env_file sets no CONVEX_URL"
out="${OUT:-$HOME/Desktop/Crok mobile e2e builds}"
build_root="$repo/target/mobile/$env_name"
commit="$(git -C "$repo" rev-parse --short HEAD)"
dirty=""
if [[ -n "$(git -C "$repo" status --porcelain -- mobile relay/environments)" ]]; then dirty=" + uncommitted changes"; fi
mkdir -p "$out" "$build_root"
say "Phone apps for the $env_name relay ($convex_url) from $commit$dirty → $out (*-$suffix)"

if [[ "$ios" == 1 ]]; then
    say "iOS $ios_config (Simulator)"
    # Xcode's own builds read the xcconfig; say so when it disagrees with the environment file.
    xcconfig="$repo/mobile/iOS/Config/$ios_config.xcconfig"
    # xcconfig files write `//` as `/$()/`, since `//` starts a comment there.
    xcconfig_slashes='/$()/'
    if ! grep -qxF "CROK_RELAY_URL = ${convex_url/\/\//$xcconfig_slashes}" "$xcconfig"; then
        printf 'note: %s does not name %s; this build passes it on the command line\n' "${xcconfig#"$repo/"}" "$convex_url"
    fi
    log="$build_root/ios-build.log"
    xcodebuild build -project "$repo/mobile/iOS/Crok.xcodeproj" -scheme Crok -configuration "$ios_config" \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$build_root/ios" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CROK_RELAY_URL="$convex_url" > "$log" 2>&1 \
        || { grep -E 'error:|BUILD FAILED' "$log" | tail -n 20 >&2; fail "the iOS build failed (log: $log)"; }
    app="$build_root/ios/Build/Products/$ios_config-iphonesimulator/Crok.app"
    built_url="$(/usr/bin/plutil -extract CrokRelayURL raw "$app/Info.plist")"
    [[ "$built_url" == "$convex_url" ]] || fail "the iOS app was built for $built_url, not $convex_url"
    rm -rf "$out/Crok-iOS-$suffix.app"
    ditto "$app" "$out/Crok-iOS-$suffix.app"
    printf 'Crok-iOS-%s.app signs in to %s\n' "$suffix" "$built_url"

    if [[ "$ios_device" == 1 ]]; then
        say "iOS $ios_config (devices, unsigned)"
        log="$build_root/ios-device-build.log"
        xcodebuild build -project "$repo/mobile/iOS/Crok.xcodeproj" -scheme Crok -configuration "$ios_config" \
            -destination 'generic/platform=iOS' -derivedDataPath "$build_root/ios-device" \
            CODE_SIGNING_ALLOWED=NO CROK_RELAY_URL="$convex_url" > "$log" 2>&1 \
            || { grep -E 'error:|BUILD FAILED' "$log" | tail -n 20 >&2; fail "the iOS device build failed (log: $log)"; }
        app="$build_root/ios-device/Build/Products/$ios_config-iphoneos/Crok.app"
        built_url="$(/usr/bin/plutil -extract CrokRelayURL raw "$app/Info.plist")"
        [[ "$built_url" == "$convex_url" ]] || fail "the iOS device app was built for $built_url, not $convex_url"
        # An .ipa is a zip of Payload/<name>.app.
        payload="$build_root/ios-ipa"
        rm -rf "$payload" "$out/Crok-iOS-$suffix-unsigned.ipa"
        mkdir -p "$payload/Payload"
        ditto "$app" "$payload/Payload/Crok.app"
        ditto -c -k --sequesterRsrc --keepParent "$payload/Payload" "$out/Crok-iOS-$suffix-unsigned.ipa"
        printf 'Crok-iOS-%s-unsigned.ipa signs in to %s\n' "$suffix" "$built_url"
    fi
fi

if [[ "$android" == 1 ]]; then
    say "Android $android_type"
    if [[ -z "${JAVA_HOME:-}" ]]; then
        JAVA_HOME="$(/usr/libexec/java_home -v 21 2>/dev/null || /usr/libexec/java_home 2>/dev/null || true)"
        export JAVA_HOME
    fi
    if [[ -z "${ANDROID_HOME:-}" && -d "$HOME/Library/Android/sdk" ]]; then export ANDROID_HOME="$HOME/Library/Android/sdk"; fi
    task=":app:assemble$(tr '[:lower:]' '[:upper:]' <<<"${android_type:0:1}")${android_type:1}"
    log="$build_root/android-build.log"
    (cd "$repo/mobile/Android" && ./gradlew "$task" -PcrokRelayEnv="$env_name" > "$log" 2>&1) \
        || { grep -E 'error|FAILED|What went wrong' -A3 "$log" | tail -n 30 >&2; fail "the Android build failed (log: $log)"; }
    apk="$repo/mobile/Android/app/build/outputs/apk/$android_type/app-$android_type.apk"
    [[ -f "$apk" ]] || fail "no APK at $apk"
    # Count rather than -q: grep -q stops at the first match and unzip's SIGPIPE would fail the pipeline.
    matches="$(unzip -p "$apk" 'classes*.dex' | LC_ALL=C grep -a -c -F "$convex_url" || true)"
    [[ "${matches:-0}" -gt 0 ]] || fail "the Android APK does not name $convex_url"
    cp -f "$apk" "$out/crok-android-$suffix.apk"
    printf 'crok-android-%s.apk signs in to %s\n' "$suffix" "$convex_url"
fi

# What this build is, for the README.
printf 'commit=%s%s\ndate=%s\nrelay=%s\nweb=%s\nios=%s\nandroid=%s\n' "$commit" "$dirty" "$(date '+%Y-%m-%d %H:%M')" \
    "$convex_url" "$web_url" "$ios_config" "$android_type" > "$out/.build-$suffix"

stamp() { sed -n "s/^$2=//p" "$out/.build-$1" 2>/dev/null; }
# README.txt is this script's unless someone wrote their own notes there; those are left alone.
readme_title='Crok phone apps (made by mobile/scripts/build-apps.sh)'
readme="$out/README.txt"
if [[ -f "$readme" ]] && [[ "$(head -n 1 "$readme")" != "$readme_title" ]]; then readme="$out/README-builds.txt"; fi
{
    printf '%s\n\n' "$readme_title"
    printf 'Two sets live here side by side. They are the same app (dev.chenli.crok.mobile), so a phone or simulator\n'
    printf 'holds one of them at a time; an app that finds a sign-in to the other relay signs out and asks again.\n'
    for s in prod debug; do
        [[ -f "$out/.build-$s" ]] || continue
        if [[ "$s" == prod ]]; then title="-prod: production relay"; else title="-debug: development relay (test builds)"; fi
        printf '\n%s\n' "$title"
        printf '  built      %s from %s\n' "$(stamp "$s" date)" "$(stamp "$s" commit)"
        printf '  relay      %s\n' "$(stamp "$s" relay)"
        printf '  web        %s (sign-in, approvals, devices, sessions)\n' "$(stamp "$s" web)"
        [[ -d "$out/Crok-iOS-$s.app" ]] && printf '  iOS        Crok-iOS-%s.app (%s, Simulator, arm64)\n' "$s" "$(stamp "$s" ios)"
        [[ -f "$out/Crok-iOS-$s-unsigned.ipa" ]] && printf '             Crok-iOS-%s-unsigned.ipa (%s, devices, not signed)\n' "$s" "$(stamp "$s" ios)"
        [[ -f "$out/crok-android-$s.apk" ]] && printf '  Android    crok-android-%s.apk (%s)\n' "$s" "$(stamp "$s" android)"
    done
    cat <<'TEXT'

iOS Simulator
  xcrun simctl boot "iPhone 17"; open -a Simulator
  xcrun simctl install booted Crok-iOS-prod.app      (or Crok-iOS-debug.app)
  xcrun simctl launch booted dev.chenli.crok.mobile
  Demo mode without a computer: add -CrokDemo YES to the launch (debug builds).

Android
  adb install -r crok-android-prod.apk               (or crok-android-debug.apk)
  Switching between the two sets needs `adb uninstall dev.chenli.crok.mobile` first only if Android refuses the
  update; both are signed with this Mac's debug key.

Computers: prod apps see computers signed in with crok / Crok Desktop releases (`crok remote login`); debug apps
see the test builds (crok-test, Crok Desktop Test). The web app of the same relay approves sign-ins for both.
TEXT
} > "$readme"

say "Done: $(ls "$out" | grep -E -- "^(Crok-iOS|crok-android)-$suffix(-unsigned)?\\.(app|ipa|apk)$" | tr '\n' ' ')in $out"
