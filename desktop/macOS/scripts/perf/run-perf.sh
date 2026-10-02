#!/bin/bash
# Long-task performance scenarios for a Crok Desktop build, against the offline mock harness.
#
#   run-perf.sh <GrokDesktop executable> <out-dir> [scenario…]
#
# Scenarios (all by default):
#   stream   one `fixture:long:$ROUNDS:$PACED` turn: $ROUNDS rounds as fast as the app reads
#            them (the burst), then $PACED rounds at a model's pace on top of that history
#            (the steady state of a task that has been running for hours); STREAM_TIMEOUT
#            (half-seconds, default 1200) bounds the wait for it to finish
#   browser  the stream scenario with the side panel's browser open on a page that keeps changing
#            (an animation, a counter, a title that ticks): what a page beside a streaming task
#            costs. webkit-browser.csv samples the CPU and memory of the WebKit processes the app
#            started. Not in the default set; a build without the browser runs it as a plain stream
#   launch   launch with a saved $ROUNDS-round task selected
#   switch   switch between the long task and a short one, then scroll the long one
#   replay   a recorded session ($REPLAY: a /trace export or a session's updates.jsonl) streamed
#            through a new task: its first $FAST_TURNS turns (10) at once, the rest at
#            $REPLAY_SPEED times their recorded pace (4) with gaps cut to $REPLAY_GAP seconds (10).
#            Every 2 s, transcript-replay.jsonl records how many rows the conversation shows;
#            none, while it streams, is the blank transcript of Crok Desktop 1.2.0
#
# The window must be on screen, on the current Space: AppKit does not lay out, and SwiftUI does
# not draw, a window behind a full-screen app or on another Space.
#
# Every scenario runs `ax-probe probe` beside the app: each line of probe-*.csv is one
# accessibility request, which the app serves on its main thread, so its latency is how long
# the main thread was blocked. ps samples CPU and memory every second. Nothing touches the
# real app state: the state file, CROK_HOME, and the project live in <out-dir>.
set -uo pipefail

APP=$1; OUT=$2; shift 2
SCENARIOS=${*:-stream launch switch}
ROUNDS=${ROUNDS:-3000}
PACED=${PACED:-80}
HERE=$(cd "$(dirname "$0")" && pwd)
MOCK=$(cd "$HERE/../../Tests/Fixtures" && pwd)/mock-grok.py
PROBE=${AX_PROBE:-$OUT/ax-probe}
mkdir -p "$OUT"
[ -x "$PROBE" ] || swiftc -O "$HERE/ax-probe.swift" -o "$PROBE"

launch() { # <state-dir> <label>: starts the app, the probe, and the sampler
    local dir=$1 label=$2
    mkdir -p "$dir/home"
    CROK_DESKTOP_STATE_FILE="$dir/state.json" CROK_DESKTOP_HARNESS="$MOCK" CROK_HOME="$dir/home" \
        CROK_FIXTURE_HISTORY="$dir/history.json" CROK_FIXTURE_DONE_FILE="$dir/done" \
        CROK_FIXTURE_REPLAY="${REPLAY:-}" CROK_FIXTURE_REPLAY_FAST_TURNS="${FAST_TURNS:-10}" \
        CROK_FIXTURE_REPLAY_SPEED="${REPLAY_SPEED:-4}" CROK_FIXTURE_REPLAY_MAX_GAP="${REPLAY_GAP:-10}" \
        CROK_DESKTOP_BROWSER="${BROWSER_PAGE:-}" \
        "$APP" -ApplePersistenceIgnoreState YES >"$OUT/$label.app.log" 2>&1 &
    APP_PID=$!
    T_LAUNCH=$(python3 -c 'import time; print(time.time())')
    WINDOW_MS=$("$PROBE" wait-window "$APP_PID" 180)
    "$PROBE" probe "$APP_PID" "$OUT/probe-$label.csv" 50 &
    PROBE_PID=$!
    (while kill -0 "$APP_PID" 2>/dev/null; do
        ps -o %cpu=,rss=,cputime= -p "$APP_PID" | awk -v t="$(date +%s)" '{n=split($3,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; print t","$1","$2","s}'; sleep 1
     done) >"$OUT/ps-$label.csv" &
    PS_PID=$!
}

stop_app() {
    kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
    kill "$PROBE_PID" "$PS_PID" 2>/dev/null; wait "$PROBE_PID" "$PS_PID" 2>/dev/null
}

mark() { echo "$1,$(python3 -c 'import time; print(time.time())')" >>"$OUT/marks-$LABEL.csv"; }

for scenario in $SCENARIOS; do
    LABEL=$scenario; rm -f "$OUT/marks-$LABEL.csv"
    case $scenario in
    stream)
        dir="$OUT/state-stream"; rm -rf "$dir"; mkdir -p "$dir/project"; git init -q "$dir/project"
        pid=$(uuidgen)
        printf '{"projects":[{"id":"%s","path":"%s"}],"conversations":[],"selectedProjectID":"%s","deletedSessionIDs":[],"collapsedProjectIDs":[]}' \
            "$pid" "$dir/project" "$pid" >"$dir/state.json"
        echo '{}' >"$dir/history.json"
        launch "$dir" stream
        sleep 4
        mark send
        "$PROBE" send "$APP_PID" "fixture:long:$ROUNDS:$PACED Run the whole suite, fix what fails, repeat." >/dev/null
        for _ in $(seq 1 "${STREAM_TIMEOUT:-1200}"); do [ -f "$dir/done" ] && break; sleep 0.5; done
        echo "fill,$(cat "$dir/done.fill")" >>"$OUT/marks-$LABEL.csv"
        mark done
        sleep 8   # the tail: batched updates, the final save
        mark end
        echo "stream: window ${WINDOW_MS}ms, sent → done $(python3 -c "import sys;l=dict(x.strip().split(',') for x in open('$OUT/marks-stream.csv'));print(round(float(l['done'])-float(l['send']),1))")s"
        stop_app
        ls -l "$dir/state.json" | awk '{print "stream: state file " $5 " bytes"}'
        ;;
    browser)
        dir="$OUT/state-browser"; rm -rf "$dir"; mkdir -p "$dir/project"; git init -q "$dir/project"
        pid=$(uuidgen)
        printf '{"projects":[{"id":"%s","path":"%s"}],"conversations":[],"selectedProjectID":"%s","deletedSessionIDs":[],"collapsedProjectIDs":[]}' \
            "$pid" "$dir/project" "$pid" >"$dir/state.json"
        echo '{}' >"$dir/history.json"
        cat >"$dir/project/busy.html" <<'PAGE'
<!doctype html><meta charset="utf-8"><title>Busy page</title>
<style>@keyframes spin { to { transform: rotate(360deg) } } #spinner { width: 48px; height: 48px; background: teal; animation: spin 1s linear infinite }
body { font: 14px -apple-system; padding: 20px }</style>
<div id="spinner"></div><p id="clock"></p><div id="rows"></div>
<script>
const rows = document.getElementById('rows');
for (let i = 0; i < 400; i++) { const p = document.createElement('p'); p.textContent = 'Row ' + i + ': the quick brown fox jumps over the lazy dog.'; rows.appendChild(p) }
let n = 0;
function tick() { document.getElementById('clock').textContent = 'frame ' + (n++); requestAnimationFrame(tick) }
tick();
setInterval(() => { document.title = 'Busy page ' + n }, 250);
</script>
PAGE
        webkit_before=$(pgrep -f 'com.apple.WebKit' | sort)
        BROWSER_PAGE="$dir/project/busy.html" launch "$dir" browser
        sleep 6   # the page loads and WebKit's processes start
        webkit_pids=$(comm -13 <(echo "$webkit_before") <(pgrep -f 'com.apple.WebKit' | sort) | tr '\n' ',' | sed 's/,$//')
        echo "browser: WebKit processes ${webkit_pids:-none}"
        (while kill -0 "$APP_PID" 2>/dev/null; do
            [ -n "$webkit_pids" ] && ps -o %cpu=,rss= -p "$webkit_pids" 2>/dev/null | awk -v t="$(date +%s)" '{c+=$1; r+=$2; n++} END {if (n) print t","c","r","n}'
            sleep 1
         done) >"$OUT/webkit-browser.csv" &
        WEBKIT_PID=$!
        mark send
        "$PROBE" send "$APP_PID" "fixture:long:$ROUNDS:$PACED Run the whole suite, fix what fails, repeat." >/dev/null
        for _ in $(seq 1 "${STREAM_TIMEOUT:-1200}"); do [ -f "$dir/done" ] && break; sleep 0.5; done
        echo "fill,$(cat "$dir/done.fill")" >>"$OUT/marks-$LABEL.csv"
        mark done
        sleep 8
        mark end
        echo "browser: window ${WINDOW_MS}ms, sent → done $(python3 -c "import sys;l=dict(x.strip().split(',') for x in open('$OUT/marks-browser.csv'));print(round(float(l['done'])-float(l['send']),1))")s"
        stop_app
        kill "$WEBKIT_PID" 2>/dev/null; wait "$WEBKIT_PID" 2>/dev/null
        ;;
    replay)
        [ -f "${REPLAY:-}" ] || { echo "replay: set REPLAY to a trace export or updates.jsonl"; continue; }
        dir="$OUT/state-replay"; rm -rf "$dir"; mkdir -p "$dir/project"; git init -q "$dir/project"
        pid=$(uuidgen)
        printf '{"projects":[{"id":"%s","path":"%s"}],"conversations":[],"selectedProjectID":"%s","deletedSessionIDs":[],"collapsedProjectIDs":[]}' \
            "$pid" "$dir/project" "$pid" >"$dir/state.json"
        echo '{}' >"$dir/history.json"
        launch "$dir" replay
        sleep 4
        mark send
        "$PROBE" send "$APP_PID" "fixture:replay Continue the recorded task." >/dev/null
        : >"$OUT/transcript-replay.jsonl"
        for _ in $(seq 1 "${REPLAY_TIMEOUT:-900}"); do
            [ -f "$dir/done" ] && break
            echo "{\"t\":$(python3 -c 'import time; print(time.time())'),\"ax\":$("$PROBE" transcript "$APP_PID" 2>/dev/null || echo null)}" >>"$OUT/transcript-replay.jsonl"
            sleep 2
        done
        mark done
        sleep 8
        mark end
        echo "replay: sent → done $(python3 -c "import sys;l=dict(x.strip().split(',') for x in open('$OUT/marks-replay.csv'));print(round(float(l['done'])-float(l['send']),1))")s"
        stop_app
        ;;
    launch)
        dir="$OUT/state-launch"; rm -rf "$dir"
        python3 "$HERE/make-long-state.py" "$dir" "$ROUNDS" 30 --select long >/dev/null
        launch "$dir" launch
        echo "$WINDOW_MS" >"$OUT/launch-window.txt"
        mark window
        sleep 12
        mark end
        echo "launch: window ${WINDOW_MS}ms"
        stop_app
        ;;
    switch)
        dir="$OUT/state-switch"; rm -rf "$dir"
        python3 "$HERE/make-long-state.py" "$dir" "$ROUNDS" 30 --select short >/dev/null
        launch "$dir" switch
        sleep 6
        for step in "press:Long task" "wait" "press:Short task 1" "wait" "press:Long task" "wait" \
                    "scroll:0" "wait" "scroll:0.5" "wait" "scroll:1" "wait" "press:Short task 2" "wait"; do
            case $step in
            wait) sleep 4 ;;
            press:*) mark "$step"; "$PROBE" press "$APP_PID" "${step#press:}" >>"$OUT/switch.actions.log" ;;
            scroll:*) mark "$step"; "$PROBE" scroll "$APP_PID" "${step#scroll:}" >>"$OUT/switch.actions.log" ;;
            esac
        done
        mark end
        echo "switch: done"
        stop_app
        ;;
    esac
done
python3 "$HERE/summarize.py" "$OUT"
