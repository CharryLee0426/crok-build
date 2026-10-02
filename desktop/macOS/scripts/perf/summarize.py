#!/usr/bin/env python3
"""Summarizes a run-perf.sh output directory into summary.json and a short table.

Main-thread latency comes from probe-<scenario>.csv (Unix time, ms, AXError). macOS shows
the spinning cursor once the main thread misses events for about 2 s, so stalls are counted
past 250 ms (a visible hitch), 1 s, and 2 s (reported as "not responding").
"""

import json
import os
import sys


def percentile(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))]


def load_csv(path):
    if not os.path.exists(path):
        return []
    rows = []
    for line in open(path):
        parts = line.strip().split(",")
        try:
            rows.append([float(x) for x in parts])
        except ValueError:
            continue
    return rows


def load_marks(path):
    marks = []
    if os.path.exists(path):
        for line in open(path):
            name, _, at = line.strip().rpartition(",")
            marks.append((name, float(at)))
    return marks


def stats(samples):
    # A probe that waits 3 s for a reply sees one 3 s sample; the stall is that sample.
    latencies = [s[1] for s in samples]
    return {
        "samples": len(latencies),
        "p50_ms": round(percentile(latencies, 50), 1),
        "p95_ms": round(percentile(latencies, 95), 1),
        "p99_ms": round(percentile(latencies, 99), 1),
        "max_ms": round(max(latencies, default=0), 1),
        "stalls_over_250ms": sum(1 for x in latencies if x > 250),
        "stalls_over_1s": sum(1 for x in latencies if x > 1000),
        "stalls_over_2s": sum(1 for x in latencies if x > 2000),
        "blocked_s": round(sum(x for x in latencies if x > 100) / 1000, 2),
    }


def window(samples, start, end):
    return [s for s in samples if start <= s[0] <= end]


def process(ps, start, end):
    rows = [r for r in ps if start - 1 <= r[0] <= end + 1]
    if not rows:
        return {}
    seconds = max(rows[-1][0] - rows[0][0], 1)
    return {"cpu_avg_pct": round((rows[-1][3] - rows[0][3]) / seconds * 100, 1) if len(rows[0]) > 3 else None,
            "rss_peak_mb": round(max(r[2] for r in rows) / 1024, 1),
            "rss_end_mb": round(rows[-1][2] / 1024, 1),
            "cpu_seconds": round(rows[-1][3] - rows[0][3], 1) if len(rows[0]) > 3 else None}


def main(out):
    summary = {}
    probe = lambda name: load_csv(os.path.join(out, "probe-{}.csv".format(name)))
    ps = lambda name: load_csv(os.path.join(out, "ps-{}.csv".format(name)))
    marks = lambda name: load_marks(os.path.join(out, "marks-{}.csv".format(name)))

    # "browser" is the stream scenario with a page open in the side panel's browser.
    for name in ("stream", "browser"):
        m = dict(marks(name))
        if "send" not in m or "done" not in m:
            continue
        samples = probe(name)
        send, done, end = m["send"], m["done"], m.get("end", m["done"])
        # The burst's backlog is worked off after the harness has sent it; give it 12 s.
        steady = min(m.get("fill", send) + 12, done)
        summary[name] = {
            "burst_seconds": round(m.get("fill", done) - send, 1),
            "steady_seconds": round(done - steady, 1),
            "burst": stats(window(samples, send, steady)),
            "burst_process": process(ps(name), send, steady),
            "steady": stats(window(samples, steady, done)),
            "steady_process": process(ps(name), steady, done),
            "after": stats(window(samples, done, end)),
        }
        state = os.path.join(out, "state-{}".format(name), "state.json")
        if os.path.exists(state):
            summary[name]["state_mb"] = round(os.path.getsize(state) / 1e6, 1)
        # WebKit's processes, which are not the app's: summed CPU (% of a core) and memory, once a second.
        webkit = [r for r in load_csv(os.path.join(out, "webkit-{}.csv".format(name))) if send <= r[0] <= done]
        if webkit:
            summary[name]["webkit"] = {"processes": int(max(r[3] for r in webkit)),
                                       "cpu_avg_pct": round(sum(r[1] for r in webkit) / len(webkit), 1),
                                       "cpu_max_pct": round(max(r[1] for r in webkit), 1),
                                       "rss_peak_mb": round(max(r[2] for r in webkit) / 1024, 1)}

    m = dict(marks("replay"))
    if "send" in m and "done" in m:
        send, done = m["send"], m["done"]
        # Rows on screen, sampled every 2 s while the replay streams; two or fewer is a blank transcript.
        rows = []
        path = os.path.join(out, "transcript-replay.jsonl")
        if os.path.exists(path):
            for line in open(path):
                try:
                    ax = json.loads(line).get("ax") or {}
                except ValueError:
                    continue
                if "onScreen" in ax:
                    rows.append(ax["onScreen"])
        summary["replay"] = {
            "seconds": round(done - send, 1),
            "streaming": stats(window(probe("replay"), send, done)),
            "process": process(ps("replay"), send, done),
            "transcript_samples": len(rows),
            "blank_samples": sum(1 for count in rows if count <= 2),
        }

    m = marks("launch")
    if m:
        samples = probe("launch")
        start, end = m[0][1], m[-1][1]
        summary["launch"] = {"after_window": stats(window(samples, start, end)), "process": process(ps("launch"), start, end)}
        log = os.path.join(out, "launch-window.txt")
        if os.path.exists(log):
            summary["launch"]["window_ms"] = float(open(log).read().strip() or 0)

    m = marks("switch")
    if m:
        samples = probe("switch")
        actions = []
        for (name, at), (_, following) in zip(m, m[1:]):
            actions.append({"action": name, **stats(window(samples, at, following))})
        summary["switch"] = {"actions": actions, "process": process(ps("switch"), m[0][1], m[-1][1])}

    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    for name, value in summary.items():
        if name == "switch":
            for action in value["actions"]:
                print("switch {:<20} max {:>7.0f} ms  p95 {:>6.0f} ms".format(action["action"], action["max_ms"], action["p95_ms"]))
        elif name in ("stream", "browser"):
            for phase in ("burst", "steady"):
                d = value[phase]
                print("{} {}: p50 {} p95 {} p99 {} max {} ms, >1s {}, >2s {}, blocked {} s; {}".format(
                    name, phase, d["p50_ms"], d["p95_ms"], d["p99_ms"], d["max_ms"], d["stalls_over_1s"], d["stalls_over_2s"],
                    d["blocked_s"], value[phase + "_process"]))
            if "webkit" in value:
                print("{} WebKit processes: {}".format(name, value["webkit"]))
        elif name == "replay":
            d = value["streaming"]
            print("replay: {} s, p50 {} p95 {} p99 {} max {} ms, >1s {}, blocked {} s; blank {} of {} samples; {}".format(
                value["seconds"], d["p50_ms"], d["p95_ms"], d["p99_ms"], d["max_ms"], d["stalls_over_1s"], d["blocked_s"],
                value["blank_samples"], value["transcript_samples"], value["process"]))
        else:
            d = value["after_window"]
            print("launch: window {} ms, max {} ms, blocked {} s; {}".format(value.get("window_ms"), d["max_ms"], d["blocked_s"], value["process"]))


if __name__ == "__main__":
    main(sys.argv[1])
