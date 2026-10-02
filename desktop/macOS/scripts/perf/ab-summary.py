#!/usr/bin/env python3
"""Summarizes an offscreen A/B: the PERF lines of <tree>-<suite>-<round>.log, as the median of each
number across rounds, base beside head.

    ab-summary.py <out-dir> [--json]      (the folder offscreen-ab.sh wrote)
"""
import glob
import json
import os
import re
import statistics
import sys

NUMBER = re.compile(r"(?<![A-Za-z_])-?\d[\d,]*\.?\d*")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def perf_lines(path):
    lines = []
    with open(path, errors="replace") as f:
        for line in f:
            line = ANSI.sub("", line).strip()
            if line.startswith("PERF "):
                lines.append(line[5:])
    return lines


def split(line):
    """The line's key (its text with numbers blanked) and its numbers."""
    numbers = [float(n.replace(",", "")) for n in NUMBER.findall(line)]
    return NUMBER.sub("#", line), numbers


def main(out, as_json):
    results = {}  # key -> tree -> [numbers per round]
    order = []
    for path in sorted(glob.glob(os.path.join(out, "*.log"))):
        name = os.path.basename(path)[:-4]
        tree, suite, _ = name.split("-", 2)
        for line in perf_lines(path):
            key, numbers = split(line)
            if key not in results:
                results[key] = {}
                order.append(key)
            results[key].setdefault(tree, []).append(numbers)
    summary = []
    for key in order:
        entry = {"line": key, "rounds": {t: len(v) for t, v in results[key].items()}}
        for tree, rounds in results[key].items():
            width = min(len(r) for r in rounds)
            entry[tree] = [round(statistics.median(r[i] for r in rounds), 3) for i in range(width)]
            entry[tree + "_range"] = [[round(min(r[i] for r in rounds), 3), round(max(r[i] for r in rounds), 3)] for i in range(width)]
        summary.append(entry)
    if as_json:
        json.dump(summary, sys.stdout, indent=1)
        return
    for entry in summary:
        print(entry["line"])
        for tree in ("base", "head"):
            if tree in entry:
                cells = ["{:g} [{:g}–{:g}]".format(m, lo, hi) if lo != hi else "{:g}".format(m)
                         for m, (lo, hi) in zip(entry[tree], entry[tree + "_range"])]
                print("   {} ({} rounds): {}".format(tree, entry["rounds"][tree], "  |  ".join(cells)))
        print()


if __name__ == "__main__":
    main(sys.argv[1], "--json" in sys.argv)
