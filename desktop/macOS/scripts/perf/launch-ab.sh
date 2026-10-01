#!/bin/bash
# Compares packaged apps by what launching them costs, without needing their windows on screen:
# each app is launched from a private copy under its own bundle id, with scratch state and the
# offline mock harness, and launch.csv gets one line per launch:
#   window_ms        spawn → the process owns its main window (asked of the window server)
#   cpu_s_2 … _15    CPU time used 2, 5, 10, and 15 s after the spawn
#   idle_cpu_pct     CPU over five more seconds, as a share of one core
#   rss_mb, footprint_mb, threads, children
#   images           libraries dyld loaded, and how many of them are WebKit's
#   webkit_procs     WebKit processes that started during the launch, and their memory together
#                    (none unless BROWSER_PAGE names a page for CROK_DESKTOP_BROWSER to open)
# The screen may be locked. What this cannot see is drawing; run-perf.sh measures that, on a
# visible window. Launch arguments turn the test build's performance monitor off for the run.
#
#   launch-ab.sh <out-dir> <rounds> <label>=<path to .app> …
set -uo pipefail
OUT=$1; ROUNDS=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
MOCK=$(cd "$HERE/../../Tests/Fixtures" && pwd)/mock-grok.py
mkdir -p "$OUT/apps"
WINWAIT=$OUT/winwait
[ -x "$WINWAIT" ] || swiftc -O "$HERE/winwait.swift" -o "$WINWAIT"
echo "label,round,window_ms,cpu_s_2,cpu_s_5,cpu_s_10,cpu_s_15,idle_cpu_pct,rss_mb,footprint_mb,threads,children,images,webkit_images,webkit_procs,webkit_rss_mb" >"$OUT/launch.csv"

cpu() { ps -o cputime= -p "$1" | awk '{n=split($1,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; printf "%.2f", s}'; }

labels=()
for pair in "$@"; do
    label=${pair%%=*}; app=${pair#*=}
    copy="$OUT/apps/$label.app"
    rm -rf "$copy"; /usr/bin/ditto "$app" "$copy"
    # Its own identity: fresh preferences, and nothing shared with an app the user has open.
    /usr/bin/plutil -replace CFBundleIdentifier -string "dev.chenli.crok.desktop.perf.$label" "$copy/Contents/Info.plist"
    /usr/bin/codesign --force --deep --sign - "$copy" >/dev/null 2>&1
    labels+=("$label")
done

for round in $(seq 1 "$ROUNDS"); do
    # The apps take turns going first.
    if [ $((round % 2)) = 1 ]; then order=("${labels[@]}"); else order=(); for ((i=${#labels[@]}-1; i>=0; i--)); do order+=("${labels[i]}"); done; fi
    for label in "${order[@]}"; do
        bin="$OUT/apps/$label.app/Contents/MacOS/GrokDesktop"
        dir="$OUT/state-$label-$round"; rm -rf "$dir"; mkdir -p "$dir/home" "$dir/project"; git init -q "$dir/project"
        project=$(uuidgen)
        printf '{"projects":[{"id":"%s","path":"%s"}],"conversations":[],"selectedProjectID":"%s","deletedSessionIDs":[],"collapsedProjectIDs":[]}' \
            "$project" "$dir/project" "$project" >"$dir/state.json"
        echo '{}' >"$dir/history.json"
        webkit_before=$(pgrep -f 'com.apple.WebKit' | sort)
        spawned=$(python3 -c 'import time; print(time.time())')
        DYLD_PRINT_LIBRARIES=1 CROK_DESKTOP_STATE_FILE="$dir/state.json" CROK_DESKTOP_HARNESS="$MOCK" CROK_HOME="$dir/home" \
            CROK_FIXTURE_HISTORY="$dir/history.json" CROK_DESKTOP_BROWSER="${BROWSER_PAGE:-}" \
            "$bin" -ApplePersistenceIgnoreState YES -performanceMonitor NO >"$OUT/$label-$round.log" 2>&1 &
        pid=$!
        window=$("$WINWAIT" "$pid" "$spawned" 60)
        marks=()
        for at in 2 5 10 15; do
            python3 -c 'import sys, time; time.sleep(max(0, float(sys.argv[1]) + float(sys.argv[2]) - time.time()))' "$spawned" "$at"
            marks+=("$(cpu "$pid")")
        done
        sleep 5
        idle=$(awk -v a="${marks[3]}" -v b="$(cpu "$pid")" 'BEGIN { printf "%.1f", (b - a) / 5 * 100 }')
        rss=$(ps -o rss= -p "$pid" | awk '{printf "%.1f", $1 / 1024}')
        footprint=$(/usr/bin/footprint "$pid" 2>/dev/null | awk '/phys_footprint:/ {v=$2; u=$3; if (u ~ /GB/) v*=1024; if (u ~ /KB/) v/=1024; printf "%.1f", v; exit}')
        threads=$(ps -M -p "$pid" | tail -n +2 | wc -l | tr -d ' ')
        children=$(pgrep -P "$pid" | wc -l | tr -d ' ')
        images=$(grep -c '^dyld\[' "$OUT/$label-$round.log")
        webkit=$(grep -c 'WebKit.framework\|WebCore.framework\|JavaScriptCore.framework' "$OUT/$label-$round.log")
        webkit_pids=$(comm -13 <(echo "$webkit_before") <(pgrep -f 'com.apple.WebKit' | sort) | tr '\n' ',' | sed 's/,$//')
        webkit_procs=0; webkit_rss=0
        if [ -n "$webkit_pids" ]; then
            read -r webkit_procs webkit_rss < <(ps -o rss= -p "$webkit_pids" 2>/dev/null | awk '{n++; r+=$1} END {printf "%d %.1f\n", n, r / 1024}')
        fi
        echo "$label,$round,$window,${marks[0]},${marks[1]},${marks[2]},${marks[3]},$idle,$rss,${footprint:-},$threads,$children,$images,$webkit,$webkit_procs,$webkit_rss" | tee -a "$OUT/launch.csv"
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        sleep 2
    done
done
# The private copies' preferences.
for label in "${labels[@]}"; do
    defaults delete "dev.chenli.crok.desktop.perf.$label" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/dev.chenli.crok.desktop.perf.$label.plist"
done
