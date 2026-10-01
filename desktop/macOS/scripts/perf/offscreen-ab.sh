#!/bin/bash
# Compares two trees with the tests that measure offscreen, in a window that is never shown:
# LongTaskPerformance, MarkdownPerformance, TranscriptVisibility, and SidePanelPerformance, which
# uses only what Crok Desktop 1.2.1 had, so it can be copied into an older tree's tests. It needs
# no screen, so it runs with the screen locked or the app's Space hidden.
#
#   offscreen-ab.sh <base desktop/macOS> <head desktop/macOS> <out-dir> [rounds] [suite…]
#
# Build both first, optimized and testable: `swift build -c release --build-tests -Xswiftc
# -enable-testing` (tests that use debug-only members have to be left out of that build). The trees
# take turns going first, each test process runs under a watchdog, and `ab-summary.py <out-dir>`
# prints every PERF line as the median across rounds, base beside head.
set -uo pipefail
BASE=$1; HEAD=$2; OUT=$3; ROUNDS=${4:-3}
shift 3; shift || true
SUITES=${*:-LongTaskPerformance MarkdownPerformance TranscriptVisibility SidePanelPerformance}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

run() { # <tree> <package-dir> <suite> <round> <limit-seconds>
    # A filter may name one test ("Suite/testName"); its log's name cannot hold the slash.
    local name=$1 dir=$2 suite=$3 round=$4 limit=$5 log="$OUT/$1-${3//\//.}-$4.log"
    echo "LOAD $(sysctl -n vm.loadavg) at $(date +%H:%M:%S)" >"$log"
    ( cd "$dir" && CROK_DESKTOP_UI_TESTS=1 swift test -c release --skip-build --filter "$suite" ) >>"$log" 2>&1 &
    local pid=$! n=0
    while kill -0 $pid 2>/dev/null && [ $n -lt "$limit" ]; do sleep 1; n=$((n + 1)); done
    if kill -0 $pid 2>/dev/null; then
        pkill -f "xctest.*GrokDesktop"; sleep 1; kill $pid 2>/dev/null
        echo "WATCHDOG killed $name $suite after ${limit}s" | tee -a "$log"
    fi
    wait $pid 2>/dev/null
    printf '%s %s round %s: %ss, %s\n' "$name" "$suite" "$round" "$n" \
        "$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E 'Executed [0-9]+ tests?' | tail -1 | sed 's/^[[:space:]]*//')"
}

for round in $(seq 1 "$ROUNDS"); do
    for suite in $SUITES; do
        if [ $((round % 2)) = 1 ]; then order="base head"; else order="head base"; fi
        for tree in $order; do
            if [ "$tree" = base ]; then dir=$BASE; else dir=$HEAD; fi
            run "$tree" "$dir" "$suite" "$round" "${LIMIT:-420}"
        done
    done
done
python3 "$HERE/ab-summary.py" "$OUT"
