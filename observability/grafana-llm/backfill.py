#!/usr/bin/env python3
"""Fetch Claude Platform and OpenRouter usage from the providers' own APIs for the time the
llm-history recording rules did not record, and save it as daily totals that build_dashboards.py
embeds in the LLM Spend History dashboard.

Why embedded and not written to Prometheus: Grafana Cloud's Prometheus (Mimir) rejects samples
more than two hours older than the newest one it holds, and a free stack keeps metrics for 14 days.
Daily totals inside the dashboard (Infinity inline data) have neither limit.

What is fetched, by default for the two months before the recording rules started, plus every
10-minute window the rules missed since then (the rules do not run again for a window Grafana
skipped):
- Claude: the Admin API usage report, tokens by model in day, hour and minute buckets. It has no
  request or error counts. Spend is estimated from prices.json the way the recording rules do it;
  the Admin API cost report is fetched as a cross-check only.
- OpenRouter: the analytics API, for one workspace (the default workspace unless
  --openrouter-workspace names another): requests, tokens and billed spend by model.

Keys come from ANTHROPIC_ADMIN_KEY and OPENROUTER_MANAGEMENT_KEY, or else from the macOS Keychain
items llm-backfill-anthropic-admin and llm-backfill-openrouter-management. They go only to
api.anthropic.com and openrouter.ai and are never printed or written to disk.

    backfill.py plan              # the windows it would fetch (needs gcx only)
    backfill.py fetch             # fetch and write backfill/llm-backfill.json

Only the standard library is used.
"""

from __future__ import annotations

import argparse
import datetime as dt
import getpass
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "backfill" / "llm-backfill.json"
RAW = HERE / "backfill" / "raw"

# The recording rules (build_dashboards.HISTORY_*) run every 10 minutes and record the window
# from 30 to 20 minutes before each evaluation.
RULE_FROM, RULE_TO = 1800, 1200

KEYCHAIN = {"anthropic": "llm-backfill-anthropic-admin", "openrouter": "llm-backfill-openrouter-management"}
ENV = {"anthropic": "ANTHROPIC_ADMIN_KEY", "openrouter": "OPENROUTER_MANAGEMENT_KEY"}

CACHE_5M, CACHE_1H = 1.25, 2.0
MINUTE, HOUR, DAY = 60, 3600, 86400


def log(msg: str):
    print(msg, file=sys.stderr, flush=True)


def iso(t: int) -> str:
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(s: str) -> int:
    return int(dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())


def day_of(t: int) -> str:
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%d")


def num(v) -> float:
    """Counts can come back as strings (OpenRouter) or be missing."""
    if v is None or v == "":
        return 0.0
    return float(v)


# ---------------------------------------------------------------------------------------------
# Which time the recording rules covered


def gcx_prom(prom_uid: str, query: str, at: int) -> dict:
    path = f"/api/datasources/proxy/uid/{prom_uid}/api/v1/query?" + urllib.parse.urlencode({"query": query, "time": at})
    args = ["gcx", "api", path]
    if os.environ.get("GCX_CONTEXT"):
        args += ["--context", os.environ["GCX_CONTEXT"]]
    run = subprocess.run(args, capture_output=True, text=True)
    if run.returncode:
        raise SystemExit(f"Reading the rule history failed: {(run.stdout + run.stderr).strip()[:600]}")
    out = run.stdout
    # gcx prints a hint line before the JSON in agent mode.
    return json.loads(out[out.find('{"data"'):] if '{"data"' in out else out[out.find("{"):])


# Grafana Cloud's Prometheus refuses a query that spans more than 32 days (err-mimir-max-query-length).
QUERY_DAYS = 30


def rule_samples(prom_uid: str, since: int, now: int) -> dict[str, list[int]]:
    """Evaluation times of llm_requests per provider: that rule writes a sample (0 when idle) on
    every evaluation, so its samples show which windows were recorded."""
    out: dict[str, set[int]] = {}
    at = now
    while at > since - RULE_FROM:
        res = gcx_prom(prom_uid, f'llm_requests{{source="llm-observability"}}[{QUERY_DAYS}d]', at)
        for r in res["data"]["result"]:
            out.setdefault(r["metric"].get("provider", ""), set()).update(int(round(float(v[0]))) for v in r.get("values", []))
        at -= QUERY_DAYS * DAY
    return {k: sorted(v) for k, v in out.items()}


def subtract(span: tuple[int, int], covered: list[tuple[int, int]]) -> list[tuple[int, int]]:
    a, b = span
    gaps, cur = [], a
    for s, e in sorted(covered):
        if e <= cur or s >= b:
            continue
        if s > cur:
            gaps.append((cur, min(s, b)))
        cur = max(cur, e)
    if cur < b:
        gaps.append((cur, b))
    return gaps


def to_minute(t: int) -> int:
    return int(round(t / MINUTE)) * MINUTE


def missing_windows(samples: list[int], since: int, now: int) -> tuple[list[tuple[int, int]], dict]:
    """Time from `since` that no recording-rule evaluation covered, in whole minutes. Time after
    the last recorded window is left to the rules, which have not run for it yet."""
    if not samples:
        end = to_minute(now - RULE_TO)
        return [(since, end)], {"rules_found": False, "recorded_until": None}
    covered = [(t - RULE_FROM, t - RULE_TO) for t in samples]
    gaps = subtract((since, max(e for _, e in covered)), covered)
    # The API buckets are whole minutes; a boundary moves by at most 30 seconds.
    gaps = [(to_minute(a), to_minute(b)) for a, b in gaps]
    return [(a, b) for a, b in gaps if b > a], {
        "rules_found": True,
        "first_recorded": iso(covered[0][0]),
        "recorded_until": iso(max(e for _, e in covered)),
    }


def pieces(a: int, b: int) -> list[tuple[str, int, int]]:
    """Split [a, b) (whole minutes) into the fewest aligned day, hour and minute runs."""
    out: list[tuple[str, int, int]] = []

    def add(kind, s, e):
        if e > s:
            if out and out[-1][0] == kind and out[-1][2] == s:
                out[-1] = (kind, out[-1][1], e)
            else:
                out.append((kind, s, e))

    t = a
    while t < b:
        if t % DAY == 0 and t + DAY <= b:
            add("day", t, t + DAY)
            t += DAY
        elif t % HOUR == 0 and t + HOUR <= b:
            add("hour", t, t + HOUR)
            t += HOUR
        else:
            add("minute", t, t + MINUTE)
            t += MINUTE
    return out


# ---------------------------------------------------------------------------------------------
# HTTP


def secret(provider: str) -> str:
    v = os.environ.get(ENV[provider], "").strip()
    if v:
        return v
    try:
        v = subprocess.run(["security", "find-generic-password", "-a", getpass.getuser(), "-s", KEYCHAIN[provider], "-w"],
                           capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        v = ""
    if not v:
        raise SystemExit(f"No {provider} key: set {ENV[provider]}, or add it to the Keychain with\n"
                         f"  security add-generic-password -U -a \"$USER\" -s {KEYCHAIN[provider]} -w")
    return v


def http(method: str, url: str, headers: dict, body: dict | None = None, tries: int = 6) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(tries):
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={**headers, "user-agent": "crok-llm-backfill/1", "accept": "application/json",
                                              **({"content-type": "application/json"} if data else {})})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            text = e.read().decode(errors="replace")[:600]
            if e.code in (429, 500, 502, 503, 504, 529) and attempt < tries - 1:
                wait = float(e.headers.get("retry-after") or 0) or min(60, 5 * 2 ** attempt)
                log(f"  {e.code} from {urllib.parse.urlsplit(url).path}, retrying in {wait:.0f}s")
                time.sleep(wait)
                continue
            raise SystemExit(f"{method} {urllib.parse.urlsplit(url).path} failed: HTTP {e.code}: {text}")
        except urllib.error.URLError as e:
            if attempt < tries - 1:
                time.sleep(5 * 2 ** attempt)
                continue
            raise SystemExit(f"{method} {url} failed: {e}")
    raise AssertionError


def save_raw(name: str, obj):
    RAW.mkdir(parents=True, exist_ok=True)
    (RAW / name).write_text(json.dumps(obj, indent=1))


# ---------------------------------------------------------------------------------------------
# Claude


ANTHROPIC = "https://api.anthropic.com/v1/organizations"
CLAUDE_WIDTH = {"day": ("1d", 31), "hour": ("1h", 168), "minute": ("1m", 1440)}


def claude_headers(key: str, beta: str = "") -> dict:
    h = {"x-api-key": key, "anthropic-version": "2023-06-01"}
    if beta:
        h["anthropic-beta"] = beta
    return h


def claude_pages(key: str, path: str, params: list[tuple[str, str]]) -> list[dict]:
    buckets, page = [], None
    while True:
        q = params + ([("page", page)] if page else [])
        res = http("GET", f"{ANTHROPIC}/{path}?{urllib.parse.urlencode(q)}", claude_headers(key))
        buckets += res.get("data", [])
        page = res.get("next_page")
        if not res.get("has_more") or not page:
            return buckets


def price_group(prices: dict, model: str) -> dict | None:
    for g in prices["claude"]:
        if re.fullmatch(f"(?:{g['match']})(?:-2.*)?", model):
            return g
    return None


def claude_cost(g: dict, uncached: float, cache_read: float, w5m: float, w1h: float, out: float) -> float:
    i = g["input"] / 1e6
    return uncached * i + cache_read * g["cache_read"] / 1e6 + w5m * CACHE_5M * i + w1h * CACHE_1H * i + out * g["output"] / 1e6


def fetch_claude(key: str, runs: list[tuple[str, int, int]], prices: dict) -> tuple[list[dict], dict]:
    info: dict = {"workspaces": "all"}
    try:
        dests = http("GET", f"{ANTHROPIC}/telemetry_destinations", claude_headers(key, "telemetry-destinations-2026-08-11"))
        info["telemetry_destinations"] = [
            {"id": d.get("id"), "host": urllib.parse.urlsplit(d.get("endpoint_url", "")).hostname,
             "state": (d.get("state") or {}).get("type"), "workspaces": d.get("workspaces")}
            for d in dests.get("data", [])]
    except SystemExit as e:
        info["telemetry_destinations"] = f"not read: {e}"
    rows: dict[tuple[str, str], dict] = {}
    for kind, a, b in runs:
        width, limit = CLAUDE_WIDTH[kind]
        log(f"  Claude usage {kind:6} {iso(a)} .. {iso(b)}")
        buckets = claude_pages(key, "usage_report/messages", [
            ("starting_at", iso(a)), ("ending_at", iso(b)), ("bucket_width", width), ("group_by[]", "model"),
            ("limit", str(limit))])
        save_raw(f"claude-usage-{kind}-{iso(a)}.json", buckets)
        for bucket in buckets:
            start = parse_ts(bucket["starting_at"])
            if not (a <= start < b):
                continue
            for r in bucket.get("results", []):
                model = r.get("model") or "(unknown)"
                row = rows.setdefault((day_of(start), model), {
                    "day": day_of(start), "provider": "claude", "model": model, "uncached": 0.0, "cache_read": 0.0,
                    "cache_write_5m": 0.0, "cache_write_1h": 0.0, "output": 0.0, "web_search_requests": 0.0})
                cc = r.get("cache_creation") or {}
                row["uncached"] += num(r.get("uncached_input_tokens"))
                row["cache_read"] += num(r.get("cache_read_input_tokens"))
                row["cache_write_5m"] += num(cc.get("ephemeral_5m_input_tokens"))
                row["cache_write_1h"] += num(cc.get("ephemeral_1h_input_tokens"))
                row["output"] += num(r.get("output_tokens"))
                row["web_search_requests"] += num((r.get("server_tool_use") or {}).get("web_search_requests"))
    out, unpriced = [], set()
    for row in rows.values():
        row["input"] = row["uncached"] + row["cache_read"] + row["cache_write_5m"] + row["cache_write_1h"]
        g = price_group(prices, row["model"])
        if g:
            row["price_group"] = g["name"]
            row["spend"] = claude_cost(g, row["uncached"], row["cache_read"], row["cache_write_5m"], row["cache_write_1h"],
                                       row["output"])
        else:
            unpriced.add(row["model"])
            row["price_group"], row["spend"] = "unpriced", 0.0
        if row["input"] or row["output"]:
            out.append(row)
    info["unpriced_models"] = sorted(unpriced)
    return sorted(out, key=lambda r: (r["day"], r["model"])), info


def claude_cost_check(key: str, days: list[str]) -> dict:
    """Billed cost per whole UTC day from the cost report, to compare with the estimate."""
    if not days:
        return {}
    a = parse_ts(days[0] + "T00:00:00Z")
    b = parse_ts(days[-1] + "T00:00:00Z") + DAY
    log(f"  Claude cost report        {iso(a)} .. {iso(b)}")
    buckets = claude_pages(key, "cost_report", [("starting_at", iso(a)), ("ending_at", iso(b)), ("bucket_width", "1d"),
                                                ("group_by[]", "description"), ("limit", "31")])
    save_raw("claude-cost.json", buckets)
    out: dict[str, dict] = {}
    for bucket in buckets:
        d = day_of(parse_ts(bucket["starting_at"]))
        if d not in days:
            continue
        for r in bucket.get("results", []):
            e = out.setdefault(d, {"tokens": 0.0, "other": 0.0})
            e["tokens" if r.get("cost_type") == "tokens" else "other"] += num(r.get("amount")) / 100
    return out


# ---------------------------------------------------------------------------------------------
# OpenRouter


OPENROUTER = "https://openrouter.ai/api/v1"
WANTED = {  # our field -> metric names the analytics API has used for it, first found wins
    "requests": ["request_count", "requests"],
    "spend": ["total_usage", "usage", "spend"],
    "input": ["tokens_prompt", "prompt_tokens", "native_tokens_prompt"],
    "output": ["tokens_completion", "completion_tokens", "native_tokens_completion"],
    "cache_read": ["tokens_cached", "cached_tokens", "native_tokens_cached", "tokens_cache_read"],
    "reasoning": ["reasoning_tokens", "tokens_reasoning"],
    "errors": ["error_count", "errors", "request_error_count", "failed_request_count"],
}
TIME_KEYS = ("date", "time", "timestamp", "bucket", "period", "time_bucket")


def fetch_openrouter(key: str, runs: list[tuple[str, int, int]], workspace: str) -> tuple[list[dict], dict]:
    h = {"authorization": f"Bearer {key}"}
    spaces = http("GET", f"{OPENROUTER}/workspaces", h).get("data", [])
    save_raw("openrouter-workspaces.json", [{k: w.get(k) for k in ("id", "name", "slug", "created_at",
                                                                   "is_observability_broadcast_enabled")} for w in spaces])
    if workspace:
        pick = [w for w in spaces if workspace in (w.get("id"), w.get("name"), w.get("slug"))]
    else:
        pick = [w for w in spaces if (w.get("slug") or "").lower() == "default" or (w.get("name") or "").lower() == "default"]
        if not pick and len(spaces) == 1:
            pick = spaces
    if len(pick) != 1:
        names = ", ".join(f"{w.get('name')} ({w.get('slug')})" for w in spaces)
        raise SystemExit(f"Could not tell which OpenRouter workspace to use; pass --openrouter-workspace. Workspaces: {names}")
    ws = pick[0]
    meta = http("GET", f"{OPENROUTER}/analytics/meta", h).get("data", {})
    save_raw("openrouter-meta.json", meta)
    names = {m["name"] for m in meta.get("metrics", [])}
    metrics = {}
    for field, options in WANTED.items():
        found = next((n for n in options if n in names), None)
        if found:
            metrics[field] = found
    for need in ("requests", "spend", "input", "output"):
        if need not in metrics:
            raise SystemExit(f"OpenRouter analytics has no metric for {need}; it offers: {', '.join(sorted(names))}")
    dims = {d["name"] for d in meta.get("dimensions", [])}
    grans = {g["name"] for g in meta.get("granularities", [])}
    info = {"workspace": {"id": ws["id"], "name": ws.get("name"), "slug": ws.get("slug")}, "metrics": metrics,
            "broadcast_enabled": ws.get("is_observability_broadcast_enabled")}
    rows: dict[tuple[str, str], dict] = {}
    for kind, a, b in runs:
        if kind not in grans:
            raise SystemExit(f"OpenRouter analytics has no {kind} granularity; it offers {sorted(grans)}")
        log(f"  OpenRouter     {kind:6} {iso(a)} .. {iso(b)}")
        body = {"metrics": sorted(set(metrics.values())), "dimensions": ["model"] if "model" in dims else [],
                "filters": [{"field": "workspace", "operator": "eq", "value": ws["id"]}], "granularity": kind,
                "time_range": {"start": iso(a), "end": iso(b)}, "limit": 100000}
        res = http("POST", f"{OPENROUTER}/analytics/query", h, body).get("data", {})
        save_raw(f"openrouter-{kind}-{iso(a)}.json", res)
        if (res.get("metadata") or {}).get("truncated"):
            raise SystemExit(f"OpenRouter truncated the {kind} rows for {iso(a)}..{iso(b)}; narrow the range.")
        for r in res.get("data", []):
            tkey = next((k for k in TIME_KEYS if r.get(k)), None)
            if not tkey:
                raise SystemExit(f"No time field in an OpenRouter row: {sorted(r)}")
            start = parse_ts(str(r[tkey]) if "T" in str(r[tkey]) else str(r[tkey])[:10] + "T00:00:00Z")
            if not (a <= start < b):
                continue
            model = r.get("model") or "(all)"
            row = rows.setdefault((day_of(start), model), {"day": day_of(start), "provider": "openrouter", "model": model,
                                                           "price_group": "billed", **{f: 0.0 for f in metrics}})
            for field, metric in metrics.items():
                row[field] += num(r.get(metric))
    out = [r for r in rows.values() if r["requests"] or r["spend"]]
    return sorted(out, key=lambda r: (r["day"], r["model"])), info


# ---------------------------------------------------------------------------------------------


def plan(args) -> tuple[dict, list[tuple[str, int, int]]]:
    now = int(time.time())
    since = parse_ts(args.since + "T00:00:00Z")
    samples = rule_samples(args.prometheus_uid, since, now)
    out, runs = {}, {}
    for provider in ("claude", "openrouter"):
        gaps, about = missing_windows(samples.get(provider, []), since, now)
        out[provider] = {**about, "windows": [[iso(a), iso(b)] for a, b in gaps]}
        runs[provider] = [p for a, b in gaps for p in pieces(a, b)]
    return out, runs


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("command", choices=["plan", "fetch"])
    today = dt.datetime.now(dt.timezone.utc).date()
    m = today.month - 2  # two calendar months back
    default_since = today.replace(year=today.year + (m - 1) // 12, month=(m - 1) % 12 + 1, day=min(today.day, 28))
    p.add_argument("--since", default=default_since.isoformat(), help="First UTC day to fetch (default: two months ago, %(default)s)")
    p.add_argument("--prometheus-uid", default="grafanacloud-prom", help="Prometheus datasource holding the rule history")
    p.add_argument("--openrouter-workspace", default="", help="Workspace id, name or slug (default: the default workspace)")
    p.add_argument("--skip-claude", action="store_true")
    p.add_argument("--skip-openrouter", action="store_true")
    p.add_argument("--out", type=pathlib.Path, default=OUT)
    args = p.parse_args(argv)

    about, runs = plan(args)
    for provider, a in about.items():
        log(f"{provider}: rules recorded {a.get('first_recorded', 'nothing')} .. {a.get('recorded_until') or 'now'}; "
            f"missing windows: {len(a['windows'])}")
        for w in a["windows"]:
            log(f"    {w[0]} .. {w[1]}")
    if args.command == "plan":
        print(json.dumps(about, indent=1))
        return 0

    prices = json.loads((HERE / "prices.json").read_text())
    result = {"generated_at": iso(int(time.time())), "since": args.since, "coverage": about, "rows": [],
              "note": "Daily totals for the time the llm-history recording rules did not record, from the providers' APIs."}
    if not args.skip_claude:
        rows, info = fetch_claude(secret("anthropic"), runs["claude"], prices)
        whole = [(a, b) for k, a, b in runs["claude"] if k == "day"]
        full_days = sorted({r["day"] for r in rows if any(a <= parse_ts(r["day"] + "T00:00:00Z") < b for a, b in whole)})
        info["cost_report_check"] = claude_cost_check(secret("anthropic"), full_days)
        result["claude"], result["rows"] = info, result["rows"] + rows
    if not args.skip_openrouter:
        rows, info = fetch_openrouter(secret("openrouter"), runs["openrouter"], args.openrouter_workspace)
        result["openrouter"], result["rows"] = info, result["rows"] + rows
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=1))
    summarize(result)
    log(f"Wrote {args.out}")
    return 0


def summarize(result: dict):
    by: dict[str, dict] = {}
    for r in result["rows"]:
        e = by.setdefault(r["provider"], {"days": set(), "spend": 0.0, "input": 0.0, "output": 0.0, "requests": 0.0})
        e["days"].add(r["day"])
        for k in ("spend", "input", "output", "requests"):
            e[k] += r.get(k) or 0.0
    for provider, e in by.items():
        log(f"{provider}: {len(e['days'])} days with usage, ${e['spend']:.2f}, {e['input']:,.0f} input and "
            f"{e['output']:,.0f} output tokens" + (f", {e['requests']:,.0f} requests" if provider != "claude" else ""))
    check = (result.get("claude") or {}).get("cost_report_check") or {}
    if check:
        est = sum(r["spend"] for r in result["rows"] if r["provider"] == "claude" and r["day"] in check)
        billed = sum(v["tokens"] for v in check.values())
        other = sum(v["other"] for v in check.values())
        log(f"claude check over {len(check)} whole days: estimated ${est:.2f}, cost report ${billed:.2f} for tokens"
            f" (+ ${other:.2f} other)")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
