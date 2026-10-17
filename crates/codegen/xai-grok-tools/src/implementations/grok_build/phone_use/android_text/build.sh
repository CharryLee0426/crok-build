#!/usr/bin/env bash
# Rebuilds phone-text.dex, the Android text helper embedded by ../android.rs, from PhoneText.java.
# Needs a JDK and the Android SDK (a platform's android.jar and build-tools' d8). The dex is
# committed, so building Crok needs neither.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
android_jar="$(ls -d "$sdk"/platforms/android-*/android.jar | sort -V | tail -1)"
d8="$(ls -d "$sdk"/build-tools/*/d8 | sort -V | tail -1)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
javac --release 8 -nowarn -Xlint:-options -cp "$android_jar" -d "$work/classes" "$here/PhoneText.java"
mkdir "$work/out"
"$d8" --release --min-api 21 --lib "$android_jar" --output "$work/out" "$work"/classes/dev/chenli/crok/*.class
cp "$work/out/classes.dex" "$here/phone-text.dex"
echo "built $here/phone-text.dex ($(wc -c < "$here/phone-text.dex" | tr -d ' ') bytes) with $(basename "$(dirname "$android_jar")") and d8 $(basename "$(dirname "$d8")")"
