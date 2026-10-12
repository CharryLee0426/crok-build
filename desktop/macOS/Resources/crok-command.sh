#!/bin/sh
# The `crok` command from Crok Desktop, bundled as Contents/Resources/bin/crok. Settings links
# /usr/local/bin/crok here, and the app's terminal panel has this folder on PATH.
unset CDPATH

script=$0
while [ -L "$script" ]; do
    target=$(readlink "$script")
    case $target in
        /*) script=$target ;;
        *) script=$(dirname "$script")/$target ;;
    esac
done
harness="$(cd "$(dirname "$script")/.." && pwd -P)/crok"

if [ ! -x "$harness" ]; then
    echo "crok: Crok Desktop's copy of Crok Build is missing. Reinstall Crok Desktop." >&2
    exit 127
fi

if [ "$1" = update ]; then
    echo "crok: This crok comes with Crok Desktop and updates with it. Run \`crok upgrade\`, or use Crok Desktop > Check for Updates…" >&2
    exit 1
fi

# grok's own updater stays off: \`crok upgrade\` replaces the whole app, this copy with it.
export CROK_DISABLE_AUTOUPDATER=1
exec "$harness" "$@"
