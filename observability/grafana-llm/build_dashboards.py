#!/usr/bin/env python3
"""Build the LLM observability dashboards for a Grafana Cloud traces (Tempo) datasource.

The dashboards read the OpenTelemetry spans that Claude Platform (service.name "claude-platform")
and OpenRouter Broadcast (service.name "openrouter") send to Grafana Cloud, plus the span crok sends
of every call itself (service.name "crok", through its Agent Observability bridge) for providers
that export nothing of their own: OpenAI Codex, GLM, DeepSeek and the rest. crok's spans of Claude
and OpenRouter calls are left out, because those providers' own spans already count them. The
dashboards come out as gcx resource manifests: push them with

    gcx resources push -p observability/grafana-llm/dashboards

Only the standard library is used, so any python3 runs it.

What the queries rely on, checked against Grafana Cloud Traces on 2026-10-15:
- A TraceQL metrics query covers at most 25 hours, so the dashboards open on the last 24 hours.
- Some queries longer than 1024 characters fail to parse ("unexpected $end"), depending on where a
  long attribute name crosses that mark. Every query here stays under QUERY_LIMIT, which the build
  checks.
- Claude Platform puts the same token counts on `anthropic.messages.create` and on each of its
  `anthropic.model_request` children. Only the request span (kind = server) is counted.
- Claude spans carry tokens but no cost, so Claude spend is estimated from prices.json. OpenRouter
  spans carry the billed cost in `gen_ai.usage.total_cost`. crok puts its own figure on its spans
  (`crok.cost.usd`): the provider's cost when it reports one, else the standard API price.
- crok's spans set a token attribute only when it is not zero, and `crok.cancelled` only on a call
  the user interrupted, so "missing" means zero or "not cancelled" (`=nil`).
- TraceQL arithmetic is an inner join: a side with no data (a model nobody called) empties the
  whole result. So each Claude price group is its own query, and Grafana adds them up.
- The Tempo datasource ignores legendFormat and overwrites each frame's refId with the series
  name, so neither legends nor per-query overrides can name a series. A series is named by its
  group-by values; see CONSTANT_GROUPS for queries that need a fixed name.
- Regex matches (=~) are anchored. Backtick strings keep regex escapes intact.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import io
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent

QUERY_LIMIT = 1000
# An interpolated variable is assumed to be at most this long when checking QUERY_LIMIT.
VAR_ALLOWANCE = 48

DS = {"type": "tempo", "uid": "${ds}"}

# Claude cache writes: five minutes cost 1.25x input, one hour 2x input.
CACHE_5M = 1.25
CACHE_1H = 2.0

# Spans-table columns: attribute -> header.
COLUMNS = {
    "service.name": "Source",
    "gen_ai.provider.name": "Provider",
    "gen_ai.request.model": "Model",
    "gen_ai.agent.name": "Agent",
    "crok.backend": "Backend",
    "gen_ai.usage.input_tokens": "Input tokens",
    "gen_ai.usage.cache_read.input_tokens": "Cache read",
    "gen_ai.usage.cache_read_input_tokens": "Cache read (crok)",
    "gen_ai.usage.cache_write.input_tokens": "Cache write",
    "gen_ai.usage.output_tokens": "Output tokens",
    "gen_ai.usage.total_cost": "Cost",
    "crok.cost.usd": "Cost (crok)",
    "anthropic.message.stop_reason": "Stop reason",
    "gen_ai.response.finish_reason": "Finish reason",
    "gen_ai.response.finish_reasons": "Finish reasons",
    "gen_ai.request.reasoning.level": "Effort",
    "error.type": "Error",
    "error.category": "Error category",
    "crok.cancelled": "Cancelled",
    "anthropic.request.id": "Request ID",
    "trace.metadata.openrouter.provider_name": "Upstream provider",
    "trace.metadata.openrouter.api_key_name": "API key",
    "agento11y.tag.surface": "Surface",
    "agento11y.tag.host": "Machine",
    "user.id": "User",
    "session.id": "Session",
}

# The providers crok reports for, by the history's provider label and the span's gen_ai.provider.name.
# codex is every OpenAI call crok makes (ChatGPT sign-in, or an OpenAI API key); glm is Z.ai and
# BigModel. Any other provider crok reports for (xAI, a local model) is "other" in the history.
CROK_PROVIDERS = [("codex", "openai"), ("glm", "zai"), ("deepseek", "deepseek")]
# The history series of everything crok reports for.
CROK_HISTORY_SEL = f'provider=~"{"|".join(label for label, _ in CROK_PROVIDERS)}|other"'


class Ctx:
    def __init__(self, args: argparse.Namespace, prices: dict):
        self.claude = args.claude_service
        self.openrouter = args.openrouter_service
        self.crok = args.crok_service
        self.crok_skip = args.crok_skip_providers
        self.ds_uid = args.datasource_uid
        self.ds_name = args.datasource_name or args.datasource_uid
        self.folder = args.folder_uid
        self.prom_uid = args.prometheus_uid
        self.prom_name = args.prometheus_name or args.prometheus_uid
        self.prices = prices
        self.tag = "llm-observability"

    def claude_req(self) -> str:
        """Claude Messages API request spans: one per call, carrying that call's tokens once."""
        return f'resource.service.name="{self.claude}"&&name="anthropic.messages.create"&&kind=server'

    def or_req(self, scoped: bool = False) -> str:
        """OpenRouter generation spans, optionally narrowed by the dashboard's variables."""
        f = f'resource.service.name="{self.openrouter}"&&span.gen_ai.request.model!=nil'
        if scoped:
            # Model and key are on every generation, failed ones too. The upstream provider is not
            # a filter: a failed generation can lack it, and the nil check would not fit the
            # parser's length limit.
            f += ("&&span.gen_ai.request.model=~`$model_re`"
                  "&&span.trace.metadata.openrouter.api_key_name=~`$key_re`")
        return f

    def crok_req(self, providers: str = "") -> str:
        """crok's spans of calls to providers that export none: one per call, failed and cancelled
        ones too. `providers` narrows them to a gen_ai.provider.name regex."""
        f = f'resource.service.name="{self.crok}"'
        if providers:
            return f + f'&&span.gen_ai.provider.name=~"{providers}"'
        return f + (f'&&span.gen_ai.provider.name!~"{self.crok_skip}"' if self.crok_skip else "")

    def crok_others(self) -> str:
        """crok's spans of providers that are neither skipped nor in CROK_PROVIDERS."""
        names = "|".join(n for n in [self.crok_skip, *(span for _, span in CROK_PROVIDERS)] if n)
        return f'resource.service.name="{self.crok}"&&span.gen_ai.provider.name!~"{names}"'

    @staticmethod
    def failed(req: str) -> str:
        """Failed calls among `req`. crok marks a call the user interrupted as an error too, with
        `crok.cancelled`; it is set on nothing else, so `=nil` also keeps older crok's failures."""
        return f"{req}&&status=error&&span.crok.cancelled=nil"

    def any_req(self) -> str:
        return f"({self.claude_req()})||({self.or_req()})||({self.crok_req()})"

    def any_failed(self) -> str:
        # Claude Platform and OpenRouter spans never carry crok.cancelled, so one filter fits all three.
        return self.failed(f"({self.any_req()})")


# ---------------------------------------------------------------------------------------------
# Claude spend


def num(x: float) -> str:
    """A TraceQL number literal: plain decimal, no exponent."""
    s = f"{x:.12f}".rstrip("0").rstrip(".")
    return s if s not in ("", "-0") else "0"


def model_match(group: dict) -> str:
    # Older model ids end in a release date, `claude-haiku-4-5-20251001`.
    return f'span.gen_ai.response.model=~"{group["match"]}(-2.*)?"'


# The Tempo datasource names a series after its group-by values and gives Grafana no way to name
# one query's series (it even overwrites the frame's refId). A query that needs a fixed name groups
# by an attribute with one known value on every Claude Messages API request span, then a regex
# renames that value. Each value here is different, so one panel can use them all.
CONSTANT_GROUPS = [
    ("kind", "server"),
    ("span.gen_ai.operation.name", "chat"),
    ("span.gen_ai.provider.name", "anthropic"),
    ("span.http.request.method", "POST"),
    ("span.url.scheme", "https"),
]


def rename(value: str, name: str) -> dict:
    return {"id": "renameByRegex", "options": {"regex": f"^{re.escape(value)}$", "renamePattern": name}}


def claude_cost(flt: str, inp: float, cache_read: float, out: float, by: str = "") -> str:
    """USD for the spans that `flt` matches, as one TraceQL metrics expression grouped by `by`.

    input_tokens includes cache reads and writes, and cache writes split into 5m and 1h, so
    cost = in*I + (cr-in)*CR + (1.25-1)*in*W5m + (2-1)*in*W1h + out*O.
    """
    terms = [
        ("span.gen_ai.usage.input_tokens", inp),
        ("span.gen_ai.usage.cache_read.input_tokens", cache_read - inp),
        ("span.anthropic.usage.cache_creation.ephemeral_5m_input_tokens", (CACHE_5M - 1) * inp),
        ("span.anthropic.usage.cache_creation.ephemeral_1h_input_tokens", (CACHE_1H - 1) * inp),
        ("span.gen_ai.usage.output_tokens", out),
    ]
    group = f"by({by})" if by else ""
    return "+".join(f"({{{flt}}}|sum_over_time({attr}){group})*{num(rate / 1e6)}" for attr, rate in terms if rate)


def claude_cost_targets(ctx: Ctx, instant: bool) -> tuple[list[dict], list[dict]]:
    """Queries for Claude spend and the renames their series need.

    One query per price group, grouped by model, so each series is a model id. A group whose long
    prompts cost more gets a second query for the extra on those prompts alone: base rates on
    every request plus (long - base) rates on the long ones is the tiered price. The filter picks
    request spans by kind = server: the SDK's spans of the same name are client spans,
    model_request children are internal, and only Claude Platform's API spans carry a Claude
    response model with kind = server.
    """
    targets, renames = [], []
    names = iter(CONSTANT_GROUPS)
    for g in ctx.prices["claude"]:
        base = f"kind=server&&{model_match(g)}"
        targets.append(target(claude_cost(base, g["input"], g["cache_read"], g["output"], "span.gen_ai.response.model"), instant))
        long = g.get("long_context")
        if long:
            attr, value = next(names)
            cut = long["above_input_tokens"]
            extra = claude_cost(f"{base}&&span.gen_ai.usage.input_tokens>{cut}", long["input"] - g["input"],
                                long["cache_read"] - g["cache_read"], long["output"] - g["output"], attr)
            targets.append(target(extra, instant))
            renames.append(rename(value, f"{g['name']}: extra for prompts over {cut // 1000}K"))
    return targets, renames


def known_claude_models(ctx: Ctx) -> str:
    alts = "|".join(g["match"] for g in ctx.prices["claude"])
    return f"({alts})(-2.*)?"


# ---------------------------------------------------------------------------------------------
# Panels


# Totals come from range queries at this step, added up by Grafana. A single-value (instant) TraceQL
# metrics query leaves out spans of the last minutes, and a range query leaves out up to one step
# at its end, so a short fixed step keeps totals complete. Ratios and percentiles stay instant:
# missing the newest spans barely moves them.
TOTAL_STEP = "1m"


def totals(targets: list[dict]) -> list[dict]:
    for t in targets:
        t["metricsQueryType"] = "range"
        t["step"] = TOTAL_STEP
    return targets


def target(query: str, instant: bool = False) -> dict:
    return {
        "refId": "",
        "datasource": DS,
        "queryType": "traceql",
        "query": query,
        "metricsQueryType": "instant" if instant else "range",
    }


def search(query: str, limit: int = 20) -> dict:
    # A crok or agent session is often one trace holding every request of the session, so the
    # search asks for many spans per trace (spss); the table sorts them newest first.
    return {"refId": "A", "datasource": DS, "queryType": "traceql", "query": query, "tableType": "spans",
            "limit": limit, "spss": 100}


def finish(panel: dict, targets: list[dict]) -> dict:
    for n, t in enumerate(targets):
        t["refId"] = chr(ord("A") + n) if n < 26 else f"Q{n}"
    panel["targets"] = targets
    return panel


# Grouping on an attribute that some spans lack makes a group named "nil".
NOT_SET = {"id": "renameByRegex", "options": {"regex": "^nil$", "renamePattern": "(not set)"}}


# A series grouped by two attributes is named like {a="x", b="y"}.
TWO_LABELS = {"id": "renameByRegex", "options": {"regex": '^\\{[^=]+="?([^",]*)"?, [^=]+="?([^"]*)"?\\}$', "renamePattern": "$1 · $2"}}


def provider_names() -> list[dict]:
    """crok's provider names as the dashboards call them (openai -> codex, zai -> glm), for series
    named by gen_ai.provider.name alone or followed by a space (`openai p95`, `zai · rate_limit`)."""
    return [{"id": "renameByRegex", "options": {"regex": f"^{span}((?: .*)?)$", "renamePattern": f"{label}$1"}}
            for label, span in CROK_PROVIDERS if label != span]


def quantile_names(drop_p: bool = False) -> list[dict]:
    """quantile_over_time series are named like {p=0.95, resource.service.name="x"}."""
    out = []
    for p, label in (("0.5", "p50"), ("0.95", "p95"), ("0.99", "p99")):
        out.append({"id": "renameByRegex", "options": {
            "regex": r'^\{p=' + re.escape(p) + r', [^=]+="?([^"]*)"?\}$',
            "renamePattern": "$1" if drop_p else f"$1 {label}"}})
        # A group whose attribute is missing loses its label, and the series is named by p alone.
        out.append({"id": "renameByRegex", "options": {"regex": r"^(\{p=" + re.escape(p) + r"\}|" + re.escape(p) + r")$",
                                                        "renamePattern": "(not set)" if drop_p else f"(not set) {label}"}})
    return out


def stat(title, targets, unit="short", desc="", decimals=None, no_value="0", color="text", steps=None, total=False,
         recent_note=True):
    """A single number. With total=True it is the sum of every query over the whole range (counts,
    tokens, spend); otherwise the value of a single instant query (ratios, percentiles)."""
    defaults = {
        "unit": unit,
        "noValue": no_value,
        "color": {"mode": "thresholds"},
        "thresholds": {"mode": "absolute", "steps": steps or [{"color": color, "value": None}]},
    }
    if decimals is not None:
        defaults["decimals"] = decimals
    if not total and recent_note:
        desc += RECENT_NOTE
    panel = {
        "type": "stat",
        "title": title,
        "description": desc,
        "datasource": DS,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": "value",
            "graphMode": "none",
            "justifyMode": "center",
            "textMode": "value",
            "orientation": "auto",
            "wideLayout": True,
            "showPercentChange": False,
        },
    }
    if total:
        # Each query's series becomes a row holding its sum over time; the stat adds the rows.
        # Queries without data add nothing, where inside one TraceQL expression they would empty
        # the result.
        totals(targets)
        panel["transformations"] = [{"id": "reduce", "options": {"reducers": ["sum"], "mode": "seriesToRows"}}]
        panel["options"]["reduceOptions"] = {"calcs": ["sum"], "fields": "/^Total$/", "values": False}
    return finish(panel, targets)


LEGEND_CALC_NAMES = {"sum": "Total", "max": "Max", "mean": "Mean", "min": "Min"}


def timeseries(title, targets, unit="short", desc="", bars=False, stack=False, calcs=("sum",), decimals=None,
               legend="bottom", transformations=None):
    custom = {
        "drawStyle": "bars" if bars else "line",
        "fillOpacity": 70 if bars else 12,
        "lineWidth": 1 if bars else 2,
        "showPoints": "never",
        "spanNulls": False,
        "barAlignment": 0,
        "gradientMode": "none" if bars else "opacity",
        "stacking": {"mode": "normal" if stack else "none", "group": "A"},
        "axisSoftMin": 0,
    }
    defaults = {"unit": unit, "custom": custom, "color": {"mode": "palette-classic"}}
    if decimals is not None:
        defaults["decimals"] = decimals
    panel = {
        "type": "timeseries",
        "title": title,
        "description": desc,
        "datasource": DS,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "legend": {"displayMode": "table", "placement": legend, "calcs": list(calcs), "showLegend": True,
                       "sortBy": LEGEND_CALC_NAMES.get(calcs[0], "") if calcs else "", "sortDesc": True},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
    }
    panel["transformations"] = [NOT_SET, *(transformations or [])]
    return finish(panel, targets)


def bars(title, targets, name="Name", value="Value", unit="short", desc="", decimals=None, color="blue", rename=None, total=True,
         recent_note=True):
    """A ranked table with a bar in each row: series become rows, rows of the same name are added
    up (a model's spend from several queries), and the largest comes first. A table always shows
    the names, where a bar gauge hides the name of a lone bar. total=False shows the value of
    instant queries instead of sums over time (for percentiles)."""
    reducer, column = ("sum", "Total") if total else ("lastNotNull", "Last *")
    if total:
        totals(targets)
    elif recent_note:
        desc += RECENT_NOTE
    value_props = [
        {"id": "displayName", "value": value},
        {"id": "unit", "value": unit},
        {"id": "min", "value": 0},
        {"id": "color", "value": {"mode": "fixed", "fixedColor": color}},
        {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "basic", "valueDisplayMode": "text"}},
    ]
    if decimals is not None:
        value_props.append({"id": "decimals", "value": decimals})
    panel = {
        "type": "table",
        "title": title,
        "description": desc,
        "datasource": DS,
        "fieldConfig": {"defaults": {"custom": {"align": "auto", "cellOptions": {"type": "auto"}}}, "overrides": [
            {"matcher": {"id": "byName", "options": "Field"},
             "properties": [{"id": "displayName", "value": name}, {"id": "custom.width", "value": 230}]},
            {"matcher": {"id": "byName", "options": f"{column} (sum)"}, "properties": value_props},
        ]},
        "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
        "transformations": [
            NOT_SET, *(rename or []),
            {"id": "reduce", "options": {"reducers": [reducer], "mode": "seriesToRows"}},
            {"id": "groupBy", "options": {"fields": {"Field": {"operation": "groupby", "aggregations": []},
                                                     column: {"operation": "aggregate", "aggregations": ["sum"]}}}},
            {"id": "sortBy", "options": {"sort": [{"field": f"{column} (sum)", "desc": True}]}},
        ],
    }
    return finish(panel, targets)


def pie(title, targets, desc="", unit="short"):
    totals(targets)
    panel = {
        "type": "piechart",
        "title": title,
        "description": desc,
        "datasource": DS,
        "transformations": [NOT_SET],
        "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "palette-classic"}}, "overrides": []},
        "options": {
            "reduceOptions": {"calcs": ["sum"], "fields": "", "values": False},
            "pieType": "donut",
            "legend": {"displayMode": "table", "placement": "right", "values": ["value", "percent"], "showLegend": True},
            "tooltip": {"mode": "single"},
            "displayLabels": [],
        },
    }
    return finish(panel, targets)


def table(title, query, desc="", limit=20):
    overrides = [{"matcher": {"id": "byName", "options": attr}, "properties": [{"id": "displayName", "value": header}]}
                 for attr, header in COLUMNS.items()]
    for attr in ("gen_ai.usage.total_cost", "crok.cost.usd"):
        overrides.append({"matcher": {"id": "byName", "options": attr},
                          "properties": [{"id": "unit", "value": "currencyUSD"}, {"id": "decimals", "value": 4}]})
    overrides.append({"matcher": {"id": "byName", "options": "traceIdHidden"},
                      "properties": [{"id": "displayName", "value": "Trace ID"}, {"id": "custom.width", "value": 130}]})
    # The root service and name of a Claude trace started by your own app read "<root span not yet
    # received>" unless the app exports its spans too, so they are hidden; the model tells sources apart.
    for col in ("Trace Service", "Trace Name", "kind"):
        overrides.append({"matcher": {"id": "byName", "options": col}, "properties": [{"id": "custom.hidden", "value": True}]})
    for col, width in (("Span ID", 150), ("Start time", 165), ("Name", 200)):
        overrides.append({"matcher": {"id": "byName", "options": col}, "properties": [{"id": "custom.width", "value": width}]})
    return {
        "type": "table",
        "title": title,
        "description": desc,
        "datasource": DS,
        "targets": [search(query, limit)],
        "fieldConfig": {"defaults": {"custom": {"align": "auto", "filterable": True},
                                     "mappings": [{"type": "value", "options": {"nil": {"text": "(not set)"}}}]},
                        "overrides": overrides},
        "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False},
                    "sortBy": [{"displayName": "Start time", "desc": True}]},
    }


def text(title, md):
    return {"type": "text", "title": title, "options": {"mode": "markdown", "content": md}}


class Board:
    """Lays panels out left to right in 24 columns, one band at a time."""

    def __init__(self, ctx: Ctx, uid: str, title: str, desc: str, tags: list[str], ds_var: dict | None = None,
                 time_from: str = "now-24h"):
        self.ctx, self.uid, self.title, self.desc, self.tags = ctx, uid, title, desc, tags
        self.time_from = time_from
        self.panels: list[dict] = []
        self.vars: list[dict] = [ds_var or datasource_var(ctx)]
        self.x = self.y = self.band = 0
        self.next_id = 1
        self.collapsed_row: dict | None = None

    def _id(self) -> int:
        self.next_id += 1
        return self.next_id - 1

    def newline(self):
        if self.x:
            self.y += self.band
            self.x = self.band = 0

    def row(self, title: str, collapsed: bool = False):
        self.newline()
        panel = {"type": "row", "title": title, "collapsed": collapsed, "panels": [], "id": self._id(),
                 "gridPos": {"h": 1, "w": 24, "x": 0, "y": self.y}}
        self.panels.append(panel)
        self.collapsed_row = panel if collapsed else None
        self.y += 1

    def add(self, panel: dict, w: int, h: int):
        if self.x + w > 24:
            self.newline()
        panel["id"] = self._id()
        panel["gridPos"] = {"h": h, "w": w, "x": self.x, "y": self.y}
        (self.collapsed_row["panels"] if self.collapsed_row else self.panels).append(panel)
        self.x += w
        self.band = max(self.band, h)

    def manifest(self) -> dict:
        spec = {
            "title": self.title,
            "description": self.desc,
            "tags": [self.ctx.tag, *self.tags],
            "timezone": "browser",
            "editable": True,
            "graphTooltip": 1,
            "schemaVersion": 41,
            "time": {"from": self.time_from, "to": "now"},
            "refresh": "5m",
            "timepicker": {"refresh_intervals": ["1m", "5m", "15m", "30m", "1h"]},
            "links": [{"type": "dashboards", "tags": [self.ctx.tag], "asDropdown": False, "title": "LLM dashboards",
                       "includeVars": False, "keepTime": True, "targetBlank": False}],
            "templating": {"list": self.vars},
            "annotations": {"list": []},
            "panels": self.panels,
        }
        return {
            "apiVersion": "dashboard.grafana.app/v1beta1",
            "kind": "Dashboard",
            "metadata": {"name": self.uid, "annotations": {"grafana.app/folder": self.ctx.folder}},
            "spec": spec,
        }


def datasource_var(ctx: Ctx) -> dict:
    return {"type": "datasource", "name": "ds", "label": "Traces", "query": "tempo", "regex": "", "refresh": 1, "hide": 0,
            "current": {"selected": True, "text": ctx.ds_name, "value": ctx.ds_uid}}


def prom_var(ctx: Ctx) -> dict:
    """The Prometheus datasource the history rules record into."""
    return {"type": "datasource", "name": "prom", "label": "Metrics", "query": "prometheus", "regex": "", "refresh": 1,
            "hide": 0, "current": {"selected": True, "text": ctx.prom_name, "value": ctx.prom_uid}}


def textbox_var(name: str, label: str, description: str) -> dict:
    """A free-text regex filter, `.*` for everything.

    The Tempo datasource's value pickers only know attributes seen in the last few minutes and
    show an error otherwise, so the filters are typed instead.
    """
    return {"type": "textbox", "name": name, "label": label, "description": description, "query": ".*",
            "current": {"text": ".*", "value": ".*"}, "options": [{"selected": True, "text": ".*", "value": ".*"}]}


def custom_var(name: str, label: str, options: list[tuple[str, str]], include_all=False) -> dict:
    query = ",".join(f"{text} : {value}" if text != value else value for text, value in options)
    text0, value0 = ("All", "$__all") if include_all else options[0]
    v = {
        "type": "custom",
        "name": name,
        "label": label,
        "query": query,
        "multi": False,
        "includeAll": include_all,
        "current": {"selected": True, "text": text0, "value": value0},
        "options": [{"selected": not include_all and n == 0, "text": t, "value": val} for n, (t, val) in enumerate(options)],
    }
    if include_all:
        v["allValue"] = ".*"
    return v


# Single-value (instant) TraceQL queries leave out roughly the newest 15 minutes of spans, so ratio
# and percentile panels say so.
RECENT_NOTE = " Covers the time range up to about 15 minutes ago."
RANGE_NOTE = " Grafana Cloud runs a TraceQL metrics query over 25 hours at most, so keep the time range at 24 hours or less."
SPEND_NOTE = ("Claude spend is estimated from tokens at standard Claude API list prices (prices.json, read on {read_on}); "
              "batch, priority-tier and negotiated discounts are not applied. OpenRouter spend is the cost OpenRouter billed.")


# ---------------------------------------------------------------------------------------------
# Dashboards


def overview(ctx: Ctx) -> Board:
    b = Board(ctx, "llm-overview", "LLM Overview",
              "Start here: requests, spend, tokens, latency and errors of every LLM call that Claude Platform and "
              "OpenRouter traced, and that crok reported itself for Codex, GLM, DeepSeek and other providers without "
              "traces of their own.", ["overview"])
    b.vars.append(prom_var(ctx))
    anyq = f"{{{ctx.any_req()}}}"
    exported = f"{{({ctx.claude_req()})||({ctx.or_req()})}}"
    ors = f"{{{ctx.or_req()}}}"
    cl = f"{{{ctx.claude_req()}}}"
    ck = f"{{{ctx.crok_req()}}}"
    spend_note = SPEND_NOTE.format(read_on=ctx.prices["read_on"])
    # Claude Platform and OpenRouter by source, crok's own reports by provider (codex, glm, deepseek, ...).
    by_source = lambda q: [target(q(exported, "resource.service.name")), target(q(ck, "span.gen_ai.provider.name"))]

    b.row("At a glance (whole time range)")
    b.add(stat("Requests", [target(f"{anyq}|count_over_time()", instant=True)],
               desc="LLM API calls in the time range: Claude Messages API requests, OpenRouter generations and the calls crok "
                    "reported for providers without traces of their own." + RANGE_NOTE, total=True), 4, 4)
    claude_spend, claude_names = claude_cost_targets(ctx, True)
    b.add(stat("Spend", claude_spend + [target(f"{ors}|sum_over_time(span.gen_ai.usage.total_cost)", instant=True),
                                        target(f"{ck}|sum_over_time(span.crok.cost.usd)", instant=True)],
               unit="currencyUSD", decimals=2, color="green", no_value="$0", total=True, desc=spend_note), 4, 4)
    b.add(stat("Tokens", [target(f"({anyq}|sum_over_time(span.gen_ai.usage.input_tokens))+({anyq}|sum_over_time(span.gen_ai.usage.output_tokens))", instant=True)],
               desc="Input plus output tokens. Input includes prompt-cache reads and writes.", total=True), 4, 4)
    b.add(stat("Claude cache hit rate", [target(f"({cl}|sum_over_time(span.gen_ai.usage.cache_read.input_tokens))/({cl}|sum_over_time(span.gen_ai.usage.input_tokens))", instant=True)],
               unit="percentunit", decimals=1, no_value="–",
               steps=[{"color": "red", "value": None}, {"color": "orange", "value": 0.5}, {"color": "green", "value": 0.8}],
               desc="Share of Claude input tokens read from the prompt cache. A cache read costs a tenth of input or less, so higher is cheaper. Long agent sessions usually stay above 80%."), 4, 4)
    b.add(stat("Error rate", [target(f"({{{ctx.any_failed()}}}|count_over_time())/({anyq}|count_over_time())", instant=True)],
               unit="percentunit", decimals=1, no_value="0%",
               steps=[{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}],
               desc="Share of calls whose span ended with an error status: rate limits, overloads, invalid requests, upstream failures. "
                    "A call the user interrupted in crok is not counted as failed."), 4, 4)
    b.add(stat("p95 latency", [target(f"{anyq}|quantile_over_time(duration,.95)", instant=True)], unit="s", decimals=1, no_value="–",
               desc="95% of calls finished faster than this, from request start to the last streamed token. Tempo buckets durations to powers of two, so read it as a range."), 4, 4)

    b.row("Week over week (recorded history, any time range)")
    for _, panel in wow_totals():
        b.add(panel, 6, 4)
    b.add(history_bars("Spend per day by provider (last 14 days)", per_day("llm_spend_usd", "provider"), "{{provider}}",
                       unit="currencyUSD", decimals=2, last_14_days=True,
                       desc="Spend in each UTC day of the last 14 days, by provider (codex, glm and deepseek as crok reported them). "
                            "From the recorded history, whatever the time range above. " + spend_note), 12, 8)
    b.add(history_bars("Requests per day by provider (last 14 days)", per_day("llm_requests", "provider"), "{{provider}}",
                       last_14_days=True, desc="Calls in each UTC day of the last 14 days, by provider. From the recorded history."), 12, 8)

    b.row("Traffic")
    b.add(timeseries("Requests per minute", [
        target(f"({exported}|rate() by(resource.service.name))*60"), target(f"({ck}|rate() by(span.gen_ai.provider.name))*60")],
        unit="suffix: req/min", calcs=("max", "mean"), transformations=provider_names(),
        desc="Calls per minute: Claude Platform and OpenRouter by source, crok's reports by provider."), 12, 8)
    b.add(timeseries("Tokens by source", by_source(lambda q, by: f"({q}|sum_over_time(span.gen_ai.usage.input_tokens) by({by}))+({q}|sum_over_time(span.gen_ai.usage.output_tokens) by({by}))"),
                     bars=True, stack=True, transformations=provider_names(),
                     desc="Input plus output tokens in each time bucket. The legend total is the sum over the range."), 12, 8)

    b.row("Spend")
    b.add(timeseries("Spend over time", claude_cost_targets(ctx, False)[0] + [
        target(f"{ors}|sum_over_time(span.gen_ai.usage.total_cost) by(span.gen_ai.request.model)"),
        target(f"{ck}|sum_over_time(span.crok.cost.usd) by(span.gen_ai.request.model)")],
        unit="currencyUSD", decimals=3, bars=True, stack=True, legend="right", transformations=claude_names,
        desc="Spend in each time bucket by model (claude-* models through Claude Platform, provider/model ids through OpenRouter, "
             "the rest as crok reported them). The legend total is the spend over the range. " + spend_note), 14, 9)
    b.add(bars("Spend by model", name="Model", value="Spend", targets=claude_spend + [
        target(f"{ors}|sum_over_time(span.gen_ai.usage.total_cost) by(span.gen_ai.request.model)", instant=True),
        target(f"{ck}|sum_over_time(span.crok.cost.usd) by(span.gen_ai.request.model)", instant=True)],
        unit="currencyUSD", decimals=3, color="green", rename=claude_names,
        desc="Spend over the time range for each model, largest first. Claude Haiku 5.5 prompts over 100K tokens pay five times the base rates; that extra has its own bar. " + spend_note), 10, 9)

    b.row("Latency and reliability")
    b.add(timeseries("Latency p50 / p95", by_source(lambda q, by: f"{q}|quantile_over_time(duration,.5,.95) by({by})"),
                     unit="s", calcs=("mean", "max"), transformations=quantile_names() + provider_names(),
                     desc="Call duration percentiles by source (crok's reports by provider). p50 is the median."), 12, 8)
    b.add(timeseries("Errors", [
        target(f"{{(({ctx.claude_req()})||({ctx.or_req()}))&&status=error}}|count_over_time() by(resource.service.name,span.error.type)"),
        target(f"{{{ctx.failed(ctx.crok_req())}}}|count_over_time() by(span.gen_ai.provider.name,span.error.category)")],
        bars=True, stack=True, transformations=[TWO_LABELS, *provider_names()],
        desc="Failed calls by source and error type, for example rate_limit_error or overloaded_error; crok's reports by provider "
             "and error category (rate_limit, server_error, auth_error, client_error, timeout, sdk_error for a connection that "
             "failed). Empty is good."), 12, 8)

    b.row("Models")
    b.add(bars("Requests by model", name="Model", value="Requests", targets=[target(f"{anyq}|count_over_time() by(span.gen_ai.request.model)", instant=True)],
               desc="Calls over the time range for each requested model."), 8, 8)
    b.add(bars("Tokens by model", name="Model", value="Tokens", targets=[target(f"({anyq}|sum_over_time(span.gen_ai.usage.input_tokens) by(span.gen_ai.request.model))+({anyq}|sum_over_time(span.gen_ai.usage.output_tokens) by(span.gen_ai.request.model))", instant=True)],
               color="purple", desc="Input plus output tokens over the time range for each requested model."), 8, 8)
    b.add(bars("p95 latency by model", name="Model", value="p95 latency", targets=[target(f"{anyq}|quantile_over_time(duration,.95) by(span.gen_ai.request.model)", instant=True)],
               unit="s", color="orange", rename=quantile_names(drop_p=True), total=False, desc="95th percentile call duration for each model over the time range."), 8, 8)

    b.row("Latest calls")
    b.add(table("Latest LLM calls", f"{anyq}|select(resource.service.name,span.gen_ai.provider.name,span.gen_ai.request.model,span.gen_ai.usage.input_tokens,span.gen_ai.usage.output_tokens,span.gen_ai.usage.total_cost,span.crok.cost.usd,span.anthropic.message.stop_reason,span.gen_ai.response.finish_reason,span.error.type)",
                desc="The most recent calls. Cost is what OpenRouter billed; Cost (crok) is what crok reported. Click a trace ID to open the whole trace."), 24, 10)
    return b


def claude_dashboard(ctx: Ctx) -> Board:
    b = Board(ctx, "llm-claude-platform", "Claude Platform",
              "Messages API traffic from the Claude Platform OpenTelemetry export: spend estimate, prompt cache, latency, "
              "stop reasons and errors, for every workspace the export covers.", ["claude", "anthropic"])
    q = f"{{{ctx.claude_req()}}}"
    spend_note = SPEND_NOTE.format(read_on=ctx.prices["read_on"])

    def tok(attr, by=""):
        return f"{q}|sum_over_time({attr})" + (f" by({by})" if by else "")

    b.row("At a glance (whole time range)")
    b.add(stat("Requests", [target(f"{q}|count_over_time()", instant=True)], desc="Messages API requests in every covered workspace." + RANGE_NOTE, total=True), 4, 4)
    claude_spend, claude_names = claude_cost_targets(ctx, True)
    b.add(stat("Estimated spend", claude_spend, unit="currencyUSD", decimals=2, color="green", no_value="$0", total=True,
               desc=spend_note + " Your bill is in the Claude Console under Billing."), 4, 4)
    b.add(stat("Input tokens", [target(tok("span.gen_ai.usage.input_tokens"), instant=True)], desc="Prompt tokens, cache reads and writes included.", total=True), 4, 4)
    b.add(stat("Output tokens", [target(tok("span.gen_ai.usage.output_tokens"), instant=True)], desc="Generated tokens, thinking included.", total=True), 4, 4)
    b.add(stat("Cache hit rate", [target(f"({tok('span.gen_ai.usage.cache_read.input_tokens')})/({tok('span.gen_ai.usage.input_tokens')})", instant=True)],
               unit="percentunit", decimals=1, no_value="–",
               steps=[{"color": "red", "value": None}, {"color": "orange", "value": 0.5}, {"color": "green", "value": 0.8}],
               desc="Share of input tokens read from the prompt cache. A low value in long sessions means the start of the prompt keeps changing."), 4, 4)
    b.add(stat("p95 latency", [target(f"{q}|quantile_over_time(duration,.95)", instant=True)], unit="s", decimals=1, no_value="–",
               desc="95% of requests finished faster than this (bucketed to powers of two)."), 4, 4)

    b.add(stat("Error rate", [target(f"({{{ctx.claude_req()}&&status=error}}|count_over_time())/({q}|count_over_time())", instant=True)],
               unit="percentunit", decimals=1, no_value="0%",
               steps=[{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}],
               desc="Share of requests that failed."), 4, 4)
    b.add(stat("Rate limited", [target(f"{{{ctx.claude_req()}&&(span.error.type=\"rate_limit_error\"||span.http.response.status_code=429)}}|count_over_time()", instant=True)],
               steps=[{"color": "green", "value": None}, {"color": "orange", "value": 1}],
               desc="Requests refused with 429 / rate_limit_error. If this grows, spread the load or ask for a higher rate limit.", total=True), 4, 4)
    out_q = f"{{{ctx.claude_req()}&&span.gen_ai.usage.output_tokens>0}}"
    b.add(stat("Output speed", [target(f"({out_q}|sum_over_time(span.gen_ai.usage.output_tokens))/({out_q}|sum_over_time(duration))", instant=True)],
               unit="suffix: tok/s", decimals=0, no_value="–",
               desc="Output tokens divided by request time over all requests. Request time includes reading the prompt, so long prompts lower it."), 4, 4)
    b.add(stat("Avg prompt", [target(f"({tok('span.gen_ai.usage.input_tokens')})/({q}|count_over_time())", instant=True)],
               decimals=0, no_value="–", desc="Average input tokens per request. Agents grow it as a conversation gets longer."), 4, 4)
    b.add(stat("Thinking share", [target(f"({tok('span.gen_ai.usage.reasoning.output_tokens')})/({tok('span.gen_ai.usage.output_tokens')})", instant=True)],
               unit="percentunit", decimals=0, no_value="–", desc="Share of output tokens spent on extended thinking."), 4, 4)
    b.add(stat("Unpriced model requests", [target(f"{{{ctx.claude_req()}&&span.gen_ai.response.model!~\"{known_claude_models(ctx)}\"}}|count_over_time()", instant=True)],
               steps=[{"color": "green", "value": None}, {"color": "orange", "value": 1}],
               desc="Requests to a model that prices.json does not list, so the spend estimate leaves them out. Add the model to prices.json and rebuild the dashboards.", total=True), 4, 4)

    b.row("Spend and tokens")
    b.add(timeseries("Estimated spend by model", claude_cost_targets(ctx, False)[0], unit="currencyUSD", decimals=3, bars=True, stack=True,
                     legend="right", transformations=claude_names,
                     desc="Estimated spend in each time bucket. The legend total is the spend over the range. " + spend_note), 12, 9)
    parts = [
        ("Uncached input", lambda by: f"({tok('span.gen_ai.usage.input_tokens', by)})-({tok('span.gen_ai.usage.cache_read.input_tokens', by)})-({tok('span.gen_ai.usage.cache_write.input_tokens', by)})"),
        ("Cache read", lambda by: tok("span.gen_ai.usage.cache_read.input_tokens", by)),
        ("Cache write, 5 min", lambda by: tok("span.anthropic.usage.cache_creation.ephemeral_5m_input_tokens", by)),
        ("Cache write, 1 hour", lambda by: tok("span.anthropic.usage.cache_creation.ephemeral_1h_input_tokens", by)),
        ("Output", lambda by: tok("span.gen_ai.usage.output_tokens", by)),
    ]
    b.add(timeseries("Token mix", [target(build(attr)) for (_, build), (attr, _) in zip(parts, CONSTANT_GROUPS)],
                     bars=True, stack=True, legend="right",
                     transformations=[rename(value, name) for (name, _), (_, value) in zip(parts, CONSTANT_GROUPS)],
                     desc="Where the tokens go. A cache read costs a tenth of input or less, a cache write 1.25x (5 min) or 2x (1 hour) input, output 5x input."), 12, 9)
    b.add(timeseries("Cache hit rate by model", [target(f"({tok('span.gen_ai.usage.cache_read.input_tokens', 'span.gen_ai.request.model')})/({tok('span.gen_ai.usage.input_tokens', 'span.gen_ai.request.model')})")],
                     unit="percentunit", calcs=("mean", "min"), desc="A sudden drop means the start of the prompt changed: a new system prompt, a changed tool list, or compaction."), 12, 8)
    b.add(bars("Estimated spend by model", name="Model", value="Estimated spend", targets=claude_spend, unit="currencyUSD", decimals=3, color="green", rename=claude_names,
               desc="Estimated spend over the time range for each model, largest first. " + spend_note), 12, 8)

    b.row("Latency")
    b.add(timeseries("Request duration by model", [target(f"{q}|quantile_over_time(duration,.5,.95,.99) by(span.gen_ai.request.model)")],
                     unit="s", calcs=("mean", "max"), transformations=quantile_names(),
                     desc="From the API receiving the request to the last token."), 12, 8)
    b.add(timeseries("Output speed by model", [target(f"({out_q}|sum_over_time(span.gen_ai.usage.output_tokens) by(span.gen_ai.request.model))/({out_q}|sum_over_time(duration) by(span.gen_ai.request.model))")],
                     unit="suffix: tok/s", calcs=("mean",), desc="Output tokens per second of request time."), 12, 8)

    b.row("Outcomes")
    b.add(pie("Stop reasons", [target(f"{q}|count_over_time() by(span.anthropic.message.stop_reason)", instant=True)],
              desc="end_turn: finished. tool_use: asked for a tool. max_tokens: cut off, raise max_tokens. refusal: declined. pause_turn: a server tool paused the turn."), 8, 8)
    b.add(timeseries("Errors by type", [target(f"{{{ctx.claude_req()}&&status=error}}|count_over_time() by(span.error.type)")],
                     bars=True, stack=True, desc="Failed requests by error type. rate_limit_error and overloaded_error are worth retrying with backoff."), 8, 8)
    b.add(bars("HTTP status", name="Status", value="Requests", targets=[target(f"{q}|count_over_time() by(span.http.response.status_code)", instant=True)],
               color="orange", desc="Final HTTP status of each request."), 8, 8)
    b.add(bars("Effort level", name="Effort", value="Requests", targets=[target(f"{q}|count_over_time() by(span.gen_ai.request.reasoning.level)", instant=True)],
               color="purple", desc="Requests by the effort set in output_config. (not set) means the request did not set one."), 8, 7)
    b.add(bars("Service tier", name="Tier", value="Requests", targets=[target(f"{q}|count_over_time() by(span.anthropic.response.service_tier)", instant=True)],
               desc="The tier that served each request: standard, priority or batch."), 8, 7)
    b.add(bars("Requests by workspace", name="Workspace", value="Requests", targets=[target(f"{q}|count_over_time() by(span.anthropic.workspace.id)", instant=True)],
               desc="Requests per Claude Console workspace. Workspace names are in the Console under Settings > Workspaces."), 8, 7)

    b.row("Requests")
    b.add(table("Latest requests", f"{q}|select(span.gen_ai.request.model,span.gen_ai.usage.input_tokens,span.gen_ai.usage.cache_read.input_tokens,span.gen_ai.usage.output_tokens,span.anthropic.message.stop_reason,span.gen_ai.request.reasoning.level,span.error.type,span.anthropic.request.id)",
                desc="The most recent requests. Request ID is the request-id that Anthropic support asks for."), 24, 10)

    b.row("Tools and Managed Agents", collapsed=True)
    tools = f'resource.service.name="{ctx.claude}"&&span.gen_ai.operation.name="execute_tool"'
    b.add(bars("Server and MCP tool uses", name="Tool", value="Uses", targets=[target(f"{{{tools}}}|count_over_time() by(span.gen_ai.tool.name)", instant=True)],
               desc="Tools that the API ran: web search, code execution, MCP connector tools and Managed Agents tools. Empty unless you use them."), 8, 8)
    b.add(bars("Tool errors", name="Tool", value="Errors", targets=[target(f"{{{tools}&&status=error}}|count_over_time() by(span.gen_ai.tool.name)", instant=True)],
               color="red", desc="Tool uses that failed."), 8, 8)
    b.add(bars("Managed Agents turns", name="Stop reason", value="Turns", targets=[target(f'{{resource.service.name="{ctx.claude}"&&name="anthropic.session.turn"}}|count_over_time() by(span.anthropic.session.turn.stop_reason)', instant=True)],
               color="purple", desc="Agent turns by why the turn ended. Empty unless you run Claude Managed Agents."), 8, 8)
    return b


def openrouter_dashboard(ctx: Ctx) -> Board:
    b = Board(ctx, "llm-openrouter", "OpenRouter",
              "Generations from OpenRouter Broadcast: billed spend by model, API key, upstream provider and user, plus tokens, latency and outcomes.",
              ["openrouter"])
    b.vars.append(textbox_var("model_re", "Model (regex)", "Filter by model, for example anthropic/.* or .*gpt.*"))
    b.vars.append(textbox_var("key_re", "API key (regex)", "Filter by OpenRouter API key name"))
    req = ctx.or_req(scoped=True)
    q = f"{{{req}}}"

    def s(attr, by=""):
        return f"{q}|sum_over_time({attr})" + (f" by({by})" if by else "")

    b.row("At a glance (whole time range)")
    b.add(stat("Requests", [target(f"{q}|count_over_time()", instant=True)], desc="Generations through OpenRouter." + RANGE_NOTE, total=True), 4, 4)
    b.add(stat("Spend", [target(s("span.gen_ai.usage.total_cost"), instant=True)], unit="currencyUSD", decimals=2, color="green", no_value="$0",
               desc="What OpenRouter billed for these generations (gen_ai.usage.total_cost).", total=True), 4, 4)
    b.add(stat("Avg cost / request", [target(f"({s('span.gen_ai.usage.total_cost')})/({q}|count_over_time())", instant=True)],
               unit="currencyUSD", decimals=4, no_value="–", desc="Spend divided by requests."), 4, 4)
    b.add(stat("Tokens", [target(f"({s('span.gen_ai.usage.input_tokens')})+({s('span.gen_ai.usage.output_tokens')})", instant=True)],
               desc="Prompt plus completion tokens.", total=True), 4, 4)
    b.add(stat("Cached input share", [target(f"({s('span.gen_ai.usage.input_tokens.cached')})/({s('span.gen_ai.usage.input_tokens')})", instant=True)],
               unit="percentunit", decimals=1, no_value="–", steps=[{"color": "text", "value": None}, {"color": "green", "value": 0.5}],
               desc="Share of prompt tokens the upstream provider served from its cache. Empty when no provider reported cached tokens."), 4, 4)
    b.add(stat("p95 latency", [target(f"{q}|quantile_over_time(duration,.95)", instant=True)], unit="s", decimals=1, no_value="–",
               desc="95% of generations finished faster than this (bucketed to powers of two)."), 4, 4)

    b.row("Spend")
    b.add(timeseries("Spend by model", [target(s("span.gen_ai.usage.total_cost", "span.gen_ai.request.model"))],
                     unit="currencyUSD", decimals=3, bars=True, stack=True, legend="right", desc="Billed cost in each time bucket by model. The legend total is the spend over the range."), 16, 9)
    b.add(bars("Spend by API key", name="API key", value="Spend", targets=[target(s("span.gen_ai.usage.total_cost", "span.trace.metadata.openrouter.api_key_name"), instant=True)],
               unit="currencyUSD", decimals=3, color="green", desc="Which OpenRouter API key spent the money. Give each app or machine its own key to tell them apart."), 8, 9)
    b.add(bars("Spend by upstream provider", name="Provider", value="Spend", targets=[target(s("span.gen_ai.usage.total_cost", "span.trace.metadata.openrouter.provider_name"), instant=True)],
               unit="currencyUSD", decimals=3, color="green", desc="The provider OpenRouter routed each request to."), 8, 8)
    b.add(bars("Spend by user", name="User", value="Spend", targets=[target(s("span.gen_ai.usage.total_cost", "span.user.id"), instant=True)],
               unit="currencyUSD", decimals=3, color="green", desc="By the request's user field, or your OpenRouter account when it is not set."), 8, 8)
    b.add(bars("Spend by session", name="Session", value="Spend", targets=[target(s("span.gen_ai.usage.total_cost", "span.session.id"), instant=True)],
               unit="currencyUSD", decimals=3, color="green", desc="By session_id (or the x-session-id header). (not set) when the client sends none."), 8, 8)

    b.row("Traffic and tokens")
    b.add(timeseries("Requests per minute by model", [target(f"({q}|rate() by(span.gen_ai.request.model))*60")],
                     unit="suffix: req/min", calcs=("max", "mean"), desc="Generations per minute by model."), 12, 8)
    b.add(timeseries("Tokens by model", [target(f"({s('span.gen_ai.usage.input_tokens', 'span.gen_ai.request.model')})+({s('span.gen_ai.usage.output_tokens', 'span.gen_ai.request.model')})")],
                     bars=True, stack=True, desc="Prompt plus completion tokens in each time bucket by model. The legend total is the sum over the range."), 12, 8)

    b.row("Latency and outcomes")
    b.add(timeseries("Duration by model", [target(f"{q}|quantile_over_time(duration,.5,.95) by(span.gen_ai.request.model)")],
                     unit="s", calcs=("mean", "max"), transformations=quantile_names(), desc="Generation duration percentiles by model."), 12, 8)
    b.add(bars("p95 by upstream provider", name="Provider", value="p95 latency", targets=[target(f"{q}|quantile_over_time(duration,.95) by(span.trace.metadata.openrouter.provider_name)", instant=True)],
               unit="s", color="orange", rename=quantile_names(drop_p=True), total=False,
               desc="Slow providers show up here. OpenRouter's provider routing preferences can avoid them."), 6, 8)
    b.add(pie("Finish reasons", [target(f"{q}|count_over_time() by(span.gen_ai.response.finish_reason)", instant=True)],
              desc="stop: finished. tool_calls: asked for a tool. length: cut off by max_tokens. content_filter: blocked. error: failed upstream."), 6, 8)
    b.add(timeseries("Errors by model", [target(f"{{{req}&&status=error}}|count_over_time() by(span.gen_ai.request.model)")],
                     bars=True, stack=True, desc="Failed generations by model."), 24, 7)

    b.row("Requests")
    b.add(table("Latest generations", f"{q}|select(span.gen_ai.request.model,span.trace.metadata.openrouter.provider_name,span.trace.metadata.openrouter.api_key_name,span.gen_ai.usage.input_tokens,span.gen_ai.usage.output_tokens,span.gen_ai.usage.total_cost,span.gen_ai.response.finish_reason,span.user.id,span.session.id)",
                desc="The most recent generations. Click a trace ID to open it."), 24, 10)
    return b


def crok_dashboard(ctx: Ctx) -> Board:
    b = Board(ctx, "llm-crok", "Codex, GLM and DeepSeek",
              "Calls that crok reported itself, for providers that export no traces of their own: OpenAI Codex (and any "
              "OpenAI API key), GLM (Z.ai, BigModel), DeepSeek, xAI and local models. Spend is what crok worked out per "
              "call; subscription plans show what the same calls would cost on the API.", ["crok", "codex", "glm", "deepseek"])
    b.vars.append(prom_var(ctx))
    b.vars.append(custom_var("provider", "Provider", [(label, span) for label, span in CROK_PROVIDERS], include_all=True))
    b.vars.append(textbox_var("model_re", "Model (regex)", "Filter by model, for example gpt-.* or deepseek-.*"))
    req = f'{ctx.crok_req()}&&span.gen_ai.provider.name=~"${{provider:regex}}"&&span.gen_ai.request.model=~`$model_re`'
    q = f"{{{req}}}"
    failed = f"{{{ctx.failed(req)}}}"
    out_q = f"{{{req}&&span.gen_ai.usage.output_tokens>0}}"
    cost_note = ("crok's figure for each call: the provider's own cost when it reports one (xAI), else the model's standard "
                 "API price for the call's tokens (the table crok's /usage estimates with). Codex and GLM Coding Plan "
                 "calls are paid by the subscription, so for them it is what the calls would cost on the API. Calls from "
                 "crok releases before this report carry no cost (see Unpriced calls).")

    def s(attr, by=""):
        return f"{q}|sum_over_time({attr})" + (f" by({by})" if by else "")

    b.row("At a glance (whole time range)")
    b.add(stat("Requests", [target(f"{q}|count_over_time()", instant=True)], desc="Calls crok made to these providers, failed and "
               "interrupted ones included, in the TUI and in Crok Desktop, on every machine that reports." + RANGE_NOTE, total=True), 4, 4)
    b.add(stat("Spend", [target(s("span.crok.cost.usd"), instant=True)], unit="currencyUSD", decimals=2, color="green", no_value="$0",
               total=True, desc=cost_note), 4, 4)
    b.add(stat("Tokens", [target(f"({s('span.gen_ai.usage.input_tokens')})+({s('span.gen_ai.usage.output_tokens')})", instant=True)],
               desc="Input plus output tokens. Input includes prompt-cache reads.", total=True), 4, 4)
    b.add(stat("Cache hit rate", [target(f"({s('span.gen_ai.usage.cache_read_input_tokens')})/({s('span.gen_ai.usage.input_tokens')})", instant=True)],
               unit="percentunit", decimals=1, no_value="–",
               steps=[{"color": "red", "value": None}, {"color": "orange", "value": 0.5}, {"color": "green", "value": 0.8}],
               desc="Share of input tokens the provider read from its prompt cache. DeepSeek and GLM cache prompts by themselves; "
                    "a low value in long sessions means the start of the prompt keeps changing."), 4, 4)
    b.add(stat("Error rate", [target(f"({failed}|count_over_time())/({q}|count_over_time())", instant=True)],
               unit="percentunit", decimals=1, no_value="0%",
               steps=[{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}],
               desc="Share of calls that failed. A call the user interrupted is not a failure (see Cancelled)."), 4, 4)
    b.add(stat("p95 latency", [target(f"{q}|quantile_over_time(duration,.95)", instant=True)], unit="s", decimals=1, no_value="–",
               desc="95% of calls finished faster than this, from the request to the last streamed token (bucketed to powers of two)."), 4, 4)

    b.add(stat("Cancelled", [target(f"{{{req}&&span.crok.cancelled=true}}|count_over_time()", instant=True)],
               desc="Calls the user interrupted before the model finished (Esc, a new prompt, closing the session).", total=True), 4, 4)
    b.add(stat("Rate limited", [target(f"{{{req}&&span.error.category=\"rate_limit\"}}|count_over_time()", instant=True)],
               steps=[{"color": "green", "value": None}, {"color": "orange", "value": 1}], total=True,
               desc="Calls refused with HTTP 429. Coding plans limit requests per few hours; this shows when you hit it."), 4, 4)
    b.add(stat("Unpriced calls", [target(f"{{{req}&&status!=error&&span.crok.cost.usd=nil}}|count_over_time()", instant=True)],
               steps=[{"color": "green", "value": None}, {"color": "orange", "value": 1}], total=True,
               desc="Finished calls without a cost: the model is not in crok's price list, or the call came from a crok release "
                    "older than this report. Spend leaves them out."), 4, 4)
    b.add(stat("Output speed", [target(f"({out_q}|sum_over_time(span.gen_ai.usage.output_tokens))/({out_q}|sum_over_time(duration))", instant=True)],
               unit="suffix: tok/s", decimals=0, no_value="–",
               desc="Output tokens divided by call time over all calls. Call time includes reading the prompt, so long prompts lower it."), 4, 4)
    b.add(stat("Avg prompt", [target(f"({s('span.gen_ai.usage.input_tokens')})/({q}|count_over_time())", instant=True)],
               decimals=0, no_value="–", desc="Average input tokens per call. It grows as a conversation gets longer."), 4, 4)
    b.add(stat("Thinking share", [target(f"({s('span.gen_ai.usage.reasoning_tokens')})/({s('span.gen_ai.usage.output_tokens')})", instant=True)],
               unit="percentunit", decimals=0, no_value="–", desc="Share of output tokens the model spent thinking."), 4, 4)

    b.row("Week over week (recorded history, any time range)")
    for _, panel in wow_totals(CROK_HISTORY_SEL):
        panel["description"] += " All the providers on this dashboard; the filters above do not apply."
        b.add(panel, 6, 4)
    b.add(wow_table("Spend by model, week over week", "llm_spend_usd", CROK_HISTORY_SEL, "provider, model", "currencyUSD", 3,
                    "Spend per provider and model in the last 7 days and the 7 before. " + cost_note, model=True), 12, 9)
    b.add(wow_table("Requests by model, week over week", "llm_requests", CROK_HISTORY_SEL, "provider, model", "short", None,
                    "Calls per provider and model in the last 7 days and the 7 before.", model=True), 12, 9)
    b.add(history_bars("Spend per day by provider (last 14 days)", per_day("llm_spend_usd", "provider", CROK_HISTORY_SEL), "{{provider}}",
                       unit="currencyUSD", decimals=2, last_14_days=True,
                       desc="Spend in each UTC day of the last 14 days, from the recorded history. " + cost_note), 12, 8)
    b.add(history_bars("Requests per day by model (last 14 days)",
                       f"sum by (model) ({with_label_from_name(f'sum_over_time(llm_requests{{{CROK_HISTORY_SEL}}}[1d] offset -1d)', 'model')})",
                       "{{model}}", last_14_days=True, desc="Calls in each UTC day of the last 14 days, by model, from the recorded history."), 12, 8)

    b.row("Spend and tokens")
    b.add(timeseries("Spend by model", [target(s("span.crok.cost.usd", "span.gen_ai.request.model"))], unit="currencyUSD", decimals=3,
                     bars=True, stack=True, legend="right",
                     desc="Spend in each time bucket by model. The legend total is the spend over the range. " + cost_note), 12, 9)
    b.add(bars("Spend by provider", name="Provider", value="Spend", targets=[target(s("span.crok.cost.usd", "span.gen_ai.provider.name"), instant=True)],
               unit="currencyUSD", decimals=3, color="green", rename=provider_names(),
               desc="codex is OpenAI (Codex sign-in or an API key), glm is Z.ai and BigModel. " + cost_note), 6, 9)
    b.add(bars("Spend by agent", name="Agent", value="Spend", targets=[target(s("span.crok.cost.usd", "span.gen_ai.agent.name"), instant=True)],
               unit="currencyUSD", decimals=3, color="green",
               desc="crok is the session's own turns, crok/<type> a sub-agent's, crok/side and the like crok's side calls (titles, "
                    "summaries, permission checks)."), 6, 9)
    kinds = [("Input (cache included)", "span.gen_ai.usage.input_tokens"), ("Cache read", "span.gen_ai.usage.cache_read_input_tokens"),
             ("Cache write", "span.gen_ai.usage.cache_write_input_tokens"), ("Output", "span.gen_ai.usage.output_tokens"),
             ("Thinking (part of output)", "span.gen_ai.usage.reasoning_tokens")]
    constants = [("kind", "client"), ("span.gen_ai.operation.name", "streamText"), ("resource.service.name", ctx.crok),
                 ("span.agento11y.sdk.name", "sdk-js"), ("span.gen_ai.token.semantics", "inclusive")]
    b.add(timeseries("Tokens by kind", [target(s(attr, by)) for (_, attr), (by, _) in zip(kinds, constants)], legend="right",
                     transformations=[rename(value, name) for (name, _), (_, value) in zip(kinds, constants)],
                     desc="Input counts the whole prompt, cache reads and writes included, and output counts thinking, so the "
                          "bars overlap rather than add up."), 12, 8)
    b.add(timeseries("Cache hit rate by model", [target(f"({s('span.gen_ai.usage.cache_read_input_tokens', 'span.gen_ai.request.model')})/({s('span.gen_ai.usage.input_tokens', 'span.gen_ai.request.model')})")],
                     unit="percentunit", calcs=("mean", "min"),
                     desc="Share of each model's input read from the cache. A model that never read from it has no line."), 12, 8)

    b.row("Latency")
    b.add(timeseries("Call duration by model", [target(f"{q}|quantile_over_time(duration,.5,.95) by(span.gen_ai.request.model)")],
                     unit="s", calcs=("mean", "max"), transformations=quantile_names(),
                     desc="From sending the request to the last streamed token."), 8, 8)
    ttft_sel = ",".join(x for x in [f'job="{ctx.crok}"', f'gen_ai_provider_name!~"{ctx.crok_skip}"' if ctx.crok_skip else "",
                                    'gen_ai_provider_name=~"${provider:regex}"', 'gen_ai_request_model=~"$model_re"'] if x)
    ttft = lambda p: (f"histogram_quantile({p}, sum by (le, gen_ai_provider_name) "
                      f"(rate(gen_ai_client_time_to_first_token_seconds_bucket{{{ttft_sel}}}[$__rate_interval])))")
    first_token = timeseries("Time to first token by provider", [prom(ttft(0.5), "{{gen_ai_provider_name}} p50"),
                                                                  prom(ttft(0.95), "{{gen_ai_provider_name}} p95")],
                             unit="s", calcs=("mean", "max"), transformations=provider_names(),
                             desc="How long the provider took to send the first token, from the agento11y SDK's "
                                  "gen_ai.client.time_to_first_token histogram (Prometheus).")
    b.add(on_prom(first_token), 8, 8)
    b.add(timeseries("Output speed by model", [target(f"({out_q}|sum_over_time(span.gen_ai.usage.output_tokens) by(span.gen_ai.request.model))/({out_q}|sum_over_time(duration) by(span.gen_ai.request.model))")],
                     unit="suffix: tok/s", calcs=("mean",), desc="Output tokens per second of call time."), 8, 8)

    b.row("Outcomes")
    b.add(pie("Finish reasons", [target(f"{q}|count_over_time() by(span.gen_ai.response.finish_reasons)", instant=True)],
              desc="stop / end_turn: finished. tool_calls / tool_use: asked for a tool. length / max_tokens: cut off. (not set): "
                   "the call failed or was interrupted."), 8, 8)
    b.add(timeseries("Failures by category", [target(f"{failed}|count_over_time() by(span.error.category)")], bars=True, stack=True,
                     desc="rate_limit (429), server_error (5xx), auth_error (401/403: sign in again), client_error (other 4xx), "
                          "timeout, sdk_error (no HTTP status: the connection failed). Interrupted calls are left out."), 8, 8)
    b.add(bars("Requests by backend", name="Backend", value="Requests", targets=[target(f"{q}|count_over_time() by(span.crok.backend)", instant=True)],
               desc="The API crok spoke: openai_codex (ChatGPT sign-in), glm, deepseek, responses or chat_completions (an API key), "
                    "messages. (not set): crok releases before this report."), 8, 8)
    b.add(bars("Requests by agent", name="Agent", value="Requests", targets=[target(f"{q}|count_over_time() by(span.gen_ai.agent.name)", instant=True)],
               color="purple", desc="The session's own turns (crok), sub-agents (crok/<type>) and side calls."), 8, 7)
    b.add(bars("Requests by surface", name="Surface", value="Requests", targets=[target(f"{q}|count_over_time() by(span.agento11y.tag.surface)", instant=True)],
               desc="tui (the terminal), desktop (Crok Desktop) or agent (another ACP client)."), 8, 7)
    b.add(bars("Requests by machine", name="Machine", value="Requests", targets=[target(f"{q}|count_over_time() by(span.agento11y.tag.host)", instant=True)],
               desc="The name of the Mac each call came from."), 8, 7)

    b.row("Calls")
    b.add(table("Latest calls", f"{q}|select(span.gen_ai.provider.name,span.gen_ai.request.model,span.crok.backend,span.gen_ai.agent.name,span.gen_ai.usage.input_tokens,span.gen_ai.usage.cache_read_input_tokens,span.gen_ai.usage.output_tokens,span.crok.cost.usd,span.gen_ai.response.finish_reasons,span.error.category,span.crok.cancelled,span.agento11y.tag.surface)",
                desc="The most recent calls. Click a trace ID to open one: the span holds tokens, cost and, unless content capture "
                     "is off, the conversation title. The prompts and replies are in Agent Observability."), 24, 10)
    return b


def explorer_dashboard(ctx: Ctx) -> Board:
    b = Board(ctx, "llm-request-explorer", "LLM Request Explorer",
              "Find single calls: slow, failed, expensive, cut off, or with huge prompts, from Claude Platform, OpenRouter "
              "and crok's own reports (Codex, GLM, DeepSeek, ...). Any time range up to 14 days.", ["explorer"])
    b.vars.append(custom_var("source", "Source", [(ctx.claude, ctx.claude), (ctx.openrouter, ctx.openrouter), (ctx.crok, ctx.crok)],
                             include_all=True))
    b.vars.append(textbox_var("model_re", "Model (regex)", "Filter by model, for example claude-opus.*, anthropic/.*, gpt-.* or glm-.*"))
    b.vars.append(custom_var("min_duration", "Slower than", [(v, v) for v in ("0s", "2s", "5s", "10s", "30s", "60s", "120s")]))
    b.vars.append(custom_var("status", "Status", [("Any", "true"), ("Failed", "status=error&&span.crok.cancelled=nil"),
                                                  ("Succeeded", "status!=error"), ("Cancelled (crok)", "span.crok.cancelled=true")]))

    # A request the API rejects early (say, an unknown model id) has no model attribute.
    base = (f"({ctx.any_req()})&&resource.service.name=~`${{source:regex}}`"
            "&&(span.gen_ai.request.model=~`$model_re`||span.gen_ai.request.model=nil)")
    cols = ("resource.service.name,span.gen_ai.provider.name,span.gen_ai.request.model,span.gen_ai.usage.input_tokens,"
            "span.gen_ai.usage.output_tokens,span.gen_ai.usage.total_cost,span.crok.cost.usd,span.anthropic.message.stop_reason,"
            "span.gen_ai.response.finish_reason,span.error.type")

    b.row("Search")
    b.add(text("How to use", (
        "Set **Source**, **Model (regex)** (`.*` for all, `claude-opus.*` for one family, `gpt-.*` for Codex, `deepseek-.*`), "
        "**Slower than** and **Status** at the top; the first table follows all four, the saved searches follow Source and Model. "
        "Source **crok** is what crok reported for providers without traces of their own (Codex, GLM, DeepSeek, xAI). Searches "
        "reach back 14 days: widen the time range to find older calls. Click a **trace ID** to open the trace: each span's "
        "attributes hold tokens, cache use, the stop reason, crok's cost and, with full-content export, the prompt and the "
        "response.\n\n"
        "For anything else open **Explore** (compass icon), pick the traces datasource and write TraceQL, for example "
        "`{ resource.service.name = \"crok\" && span.gen_ai.provider.name = \"deepseek\" && span.gen_ai.usage.input_tokens > 150000 }`.")), 24, 4)
    b.add(table("Matching calls", f"{{{base}&&duration>=$min_duration&&$status}}|select({cols})", limit=50,
                desc="Every call that matches the filters, newest first (up to 100)."), 24, 10)

    b.row("Saved searches")
    b.add(table("Failed calls", f"{{{ctx.failed(base)}}}|select({cols},span.error.category)",
                desc="Calls that ended with an error. The Error and Error category columns say why. Calls the user interrupted "
                     "in crok are left out."), 12, 9)
    b.add(table("Slowest calls (over 30 s)", f"{{{base}&&duration>30s}}|select({cols})", desc="Calls that took longer than 30 seconds."), 12, 9)
    b.add(table("Cut off by the token limit", f"{{{base}&&(span.anthropic.message.stop_reason=\"max_tokens\"||span.gen_ai.response.finish_reason=\"length\"||span.gen_ai.response.finish_reasons=\"length\")}}|select({cols})",
                desc="Responses that stopped because they reached max_tokens. Raise max_tokens or ask for shorter output."), 12, 9)
    b.add(table("Huge prompts (over 150K tokens)", f"{{{base}&&span.gen_ai.usage.input_tokens>150000}}|select({cols},span.gen_ai.usage.cache_read.input_tokens,span.gen_ai.usage.cache_read_input_tokens)",
                desc="Calls whose prompt passed 150K tokens. Compaction or a fresh session usually helps."), 12, 9)
    b.add(table("Expensive calls (over $0.05)", f"{{{base}&&(span.gen_ai.usage.total_cost>0.05||span.crok.cost.usd>0.05)}}|select({cols})",
                desc="Single calls that cost more than 5 cents: billed by OpenRouter, or as crok worked out (Claude calls are "
                     "priced on the dashboards, not per span)."), 12, 9)
    b.add(table("Cache misses on big prompts", f"{{{base}&&span.gen_ai.usage.input_tokens>20000&&(span.gen_ai.usage.cache_read.input_tokens<1000||(resource.service.name=\"{ctx.crok}\"&&span.gen_ai.usage.cache_read_input_tokens=nil))}}|select({cols},span.gen_ai.usage.cache_write.input_tokens)",
                desc="Calls over 20K input tokens that read almost nothing from the prompt cache, so they paid full price for the "
                     "prompt: Claude requests under 1K cached tokens, and crok's calls with none."), 12, 9)
    return b


# ---------------------------------------------------------------------------------------------
# Long-term history
#
# TraceQL metrics reach back 25 hours. For days and months, Grafana-managed recording rules copy
# small totals into the stack's Prometheus (Mimir) every HISTORY_INTERVAL seconds. Each evaluation
# records the window HISTORY_WINDOW back from its own time: single-value TraceQL queries leave out
# the newest ~15 minutes, so a window that ended 20 minutes ago is complete, and back-to-back
# windows neither overlap nor leave gaps. Each sample is the amount in its window, so
# sum_over_time() over any range gives the total for that range. Mimir rejects label names with
# dots, so a rule cannot keep TraceQL's group-by labels; each rule records one ungrouped total and
# says what it is with fixed labels (provider, direction, price_group).

HISTORY_GROUP = "llm-history"
HISTORY_INTERVAL = 600
HISTORY_WINDOW = {"from": 1800, "to": 1200}


def history_rules(ctx: Ctx) -> dict:
    rules = []

    def rule(metric: str, labels: dict, query: str):
        key = metric + json.dumps(labels, sort_keys=True)
        rules.append({
            "uid": "llm-hist-" + hashlib.sha1(key.encode()).hexdigest()[:12],
            "title": f"{metric} {', '.join(f'{k}={v}' for k, v in labels.items())}",
            "folderUID": ctx.folder,
            "ruleGroup": HISTORY_GROUP,
            "condition": "B",
            "record": {"metric": metric, "from": "B", "targetDatasourceUid": ctx.prom_uid},
            "data": [
                {"refId": "A", "queryType": "traceql", "datasourceUid": ctx.ds_uid, "relativeTimeRange": HISTORY_WINDOW,
                 "model": {"refId": "A", "datasource": {"type": "tempo", "uid": ctx.ds_uid}, "queryType": "traceql",
                           "query": query, "metricsQueryType": "instant"}},
                # A Tempo result is not a series Grafana can write; a reduce turns it into a number.
                {"refId": "B", "datasourceUid": "__expr__",
                 "model": {"refId": "B", "type": "reduce", "expression": "A", "reducer": "last", "settings": {"mode": "dropNN"},
                           "datasource": {"type": "__expr__", "uid": "__expr__"}}},
            ],
            "labels": {"source": "llm-observability", **labels},
            "noDataState": "OK",
            "execErrState": "Error",
            "for": "0s",
        })

    for provider, req in (("claude", ctx.claude_req()), ("openrouter", ctx.or_req())):
        rule("llm_requests", {"provider": provider}, f"{{{req}}}|count_over_time()")
        rule("llm_errors", {"provider": provider}, f"{{{req}&&status=error}}|count_over_time()")
        rule("llm_tokens", {"provider": provider, "direction": "input"}, f"{{{req}}}|sum_over_time(span.gen_ai.usage.input_tokens)")
        rule("llm_tokens", {"provider": provider, "direction": "output"}, f"{{{req}}}|sum_over_time(span.gen_ai.usage.output_tokens)")
    rule("llm_tokens", {"provider": "claude", "direction": "cache_read"},
         f"{{{ctx.claude_req()}}}|sum_over_time(span.gen_ai.usage.cache_read.input_tokens)")
    rule("llm_spend_usd", {"provider": "openrouter", "price_group": "billed"}, f"{{{ctx.or_req()}}}|sum_over_time(span.gen_ai.usage.total_cost)")
    for g in ctx.prices["claude"]:
        base = f"kind=server&&{model_match(g)}"
        rule("llm_spend_usd", {"provider": "claude", "price_group": g["name"]},
             claude_cost(base, g["input"], g["cache_read"], g["output"]))
        long = g.get("long_context")
        if long:
            cut = long["above_input_tokens"]
            rule("llm_spend_usd", {"provider": "claude", "price_group": f"{g['name']}: extra for prompts over {cut // 1000}K"},
                 claude_cost(f"{base}&&span.gen_ai.usage.input_tokens>{cut}", long["input"] - g["input"],
                             long["cache_read"] - g["cache_read"], long["output"] - g["output"]))
    # crok's own reports, kept per model: grouped by the span name (`streamText <model>`), whose
    # label `name` has no dot, so Mimir takes it (see MODEL_FROM_NAME).
    crok_sources = [(label, ctx.crok_req(span)) for label, span in CROK_PROVIDERS] + [("other", ctx.crok_others())]
    for provider, req in crok_sources:
        rule("llm_requests", {"provider": provider}, f"{{{req}}}|count_over_time() by(name)")
        rule("llm_errors", {"provider": provider}, f"{{{ctx.failed(req)}}}|count_over_time()")
        for direction, attr in (("input", "input_tokens"), ("output", "output_tokens"), ("cache_read", "cache_read_input_tokens")):
            rule("llm_tokens", {"provider": provider, "direction": direction}, f"{{{req}}}|sum_over_time(span.gen_ai.usage.{attr}) by(name)")
        rule("llm_spend_usd", {"provider": provider, "price_group": "crok"}, f"{{{req}}}|sum_over_time(span.crok.cost.usd) by(name)")
    return {"title": HISTORY_GROUP, "folderUid": ctx.folder, "interval": HISTORY_INTERVAL, "rules": rules}


PROM = {"type": "prometheus", "uid": "${prom}"}
MIXED = {"type": "datasource", "uid": "-- Mixed --"}


def prom(expr: str, legend: str = "", instant: bool = False, interval: str = "", table: bool = False) -> dict:
    t = {"refId": "", "datasource": PROM, "expr": expr, "legendFormat": legend or "__auto",
         "instant": instant, "range": not instant, "editorMode": "code"}
    if interval:
        t["interval"] = interval
    if table:
        t["format"] = "table"
    return t


def on_prom(panel: dict) -> dict:
    panel["datasource"] = PROM
    return panel


# crok's history rules keep the span name, `"streamText <model>"` (quotes included), as the label
# `name`: the only label of a TraceQL group-by that Mimir takes, having no dot in it. This takes
# the model out of it; a series without `name` (Claude Platform, OpenRouter) is left as it is.
MODEL_FROM_NAME = '`"?streamText (.+?)"?`'


def with_label_from_name(expr: str, label: str) -> str:
    return f'label_replace({expr}, "{label}", "$1", "name", {MODEL_FROM_NAME})'


# ---------------------------------------------------------------------------------------------
# Week over week
#
# Each recorded sample is the amount in its own 10-minute window, so sum_over_time(m[7d]) at the
# end of the time range is the last seven days and `offset 7d` the seven days before them. Both
# lag the rules by the same 20-30 minutes, so they compare like with like. They are instant
# queries: the panels work on any dashboard at any time range, with the query reaching 14 days
# back, inside the free tier's 14-day metrics retention and Mimir's 32-day query limit.


def week(metric: str, sel: str = "", by: str = "", before: bool = False, model: bool = False) -> str:
    inner = f"sum_over_time({metric}{{{sel}}}[7d]{' offset 7d' if before else ''})"
    if model:
        inner = with_label_from_name(inner, "model")
    return f"sum{f' by ({by})' if by else ''} ({inner})"


def change(metric: str, sel: str = "", by: str = "", model: bool = False) -> str:
    return f"{week(metric, sel, by, model=model)} / {week(metric, sel, by, True, model)} - 1"


WEEK_NOTE = (" Last 7 days is the seven days up to the end of the time range; the 7 days before are the seven before"
             " that. Both come from the recorded history (LLM Spend History), which lags 20-30 minutes, and do not"
             " depend on the time range's length.")


def wow_stat(title: str, queries: list[tuple[str, str, str, int | None]], desc: str) -> dict:
    """Instant Prometheus values side by side, each (name, expression, unit, decimals or None for Grafana's)."""
    panel = stat(title, [prom(expr, instant=True) for _, expr, _, _ in queries], desc=desc + WEEK_NOTE,
                 no_value="–", recent_note=False)
    panel["options"]["textMode"] = "value_and_name"
    panel["fieldConfig"]["overrides"] = [
        {"matcher": {"id": "byFrameRefID", "options": chr(ord("A") + n)},
         "properties": [{"id": "displayName", "value": name}, {"id": "unit", "value": unit},
                        *([{"id": "decimals", "value": decimals}] if decimals is not None else [])]}
        for n, (name, _, unit, decimals) in enumerate(queries)]
    return on_prom(panel)


def wow_totals(sel: str = "", spend_decimals: int = 2) -> list[tuple[str, dict]]:
    """Spend, requests, tokens and error rate: the last 7 days and how they compare with the 7 before."""
    tokens = f'{sel},direction=~"input|output"' if sel else 'direction=~"input|output"'
    rate = lambda before: f"{week('llm_errors', sel, before=before)} / {week('llm_requests', sel, before=before)}"
    return [
        ("spend", wow_stat("Spend, week over week", [("Last 7 days", week("llm_spend_usd", sel), "currencyUSD", spend_decimals),
                                                     ("vs the 7 days before", change("llm_spend_usd", sel), "percentunit", 0)],
                           "Spend in the last 7 days and how much more (or less, below zero) than the 7 days before.")),
        ("requests", wow_stat("Requests, week over week", [("Last 7 days", week("llm_requests", sel), "short", None),
                                                           ("vs the 7 days before", change("llm_requests", sel), "percentunit", 0)],
                              "Calls in the last 7 days, compared with the 7 days before.")),
        ("tokens", wow_stat("Tokens, week over week", [("Last 7 days", week("llm_tokens", tokens), "short", 1),
                                                       ("vs the 7 days before", change("llm_tokens", tokens), "percentunit", 0)],
                            "Input plus output tokens in the last 7 days, compared with the 7 days before.")),
        ("errors", wow_stat("Error rate, week over week", [("Last 7 days", rate(False), "percentunit", 1),
                                                           ("The 7 days before", rate(True), "percentunit", 1)],
                            "Failed calls divided by all calls (a call the user interrupted in crok is not a failure).")),
    ]


def wow_table(title: str, metric: str, sel: str, by: str, unit: str, decimals: int | None, desc: str, model: bool = False) -> dict:
    """One row per value of `by`: the last 7 days, the 7 before, and the change."""
    this, before = week(metric, sel, by, model=model), week(metric, sel, by, True, model)
    headers = {"provider": "Provider", "model": "Model", "price_group": "Price group"}
    panel = {
        "type": "table",
        "title": title,
        "description": desc + WEEK_NOTE,
        "datasource": PROM,
        "fieldConfig": {"defaults": {"unit": unit, **({"decimals": decimals} if decimals is not None else {}),
                                     "custom": {"align": "auto", "cellOptions": {"type": "auto"}}},
                        "overrides": [{"matcher": {"id": "byName", "options": "Change"},
                                       "properties": [{"id": "unit", "value": "percentunit"}, {"id": "decimals", "value": 0}]}]},
        "options": {"showHeader": True, "cellHeight": "sm", "sortBy": [{"displayName": "Last 7 days", "desc": True}],
                    "footer": {"show": True, "reducer": ["sum"], "fields": ["Last 7 days", "The 7 days before"], "countRows": False}},
        # Instant results share one time, so merge joins them on the `by` labels.
        "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {"excludeByName": {"Time": True},
                                           "renameByName": {"Value #A": "Last 7 days", "Value #B": "The 7 days before",
                                                            "Value #C": "Change",
                                                            **{d.strip(): headers.get(d.strip(), d.strip()) for d in by.split(",")}}}},
        ],
    }
    return finish(panel, [prom(this, instant=True, table=True), prom(before, instant=True, table=True),
                          prom(f"{this} / {before} - 1", instant=True, table=True)])


def history_bars(title: str, expr: str, legend: str, unit: str = "short", decimals: int | None = None, desc: str = "",
                 last_14_days: bool = False, stack: bool = True) -> dict:
    """A per-UTC-day bar chart straight from Prometheus. With last_14_days it always shows the last
    14 days, whatever the dashboard's time range (a trace dashboard opens on 24 hours)."""
    panel = timeseries(title, [prom(expr, legend, interval="1d")], unit=unit, decimals=decimals, bars=True, stack=stack,
                       desc=desc, transformations=provider_names())
    panel["maxDataPoints"] = 5000  # keeps the step at one day on long ranges
    if last_14_days:
        panel["timeFrom"] = "14d"
    return on_prom(panel)


def day_vs_week_before(title: str, metric: str, sel: str, unit: str, decimals: int | None, desc: str) -> dict:
    """Each UTC day's total as a bar, and the same weekday a week earlier as a dashed line."""
    day = lambda offset: f"sum (sum_over_time({metric}{{{sel}}}[1d] offset {offset}))"
    panel = timeseries(title, [prom(day("-1d"), "That day", interval="1d"), prom(day("6d"), "7 days earlier", interval="1d")],
                       unit=unit, decimals=decimals, bars=True, desc=desc)
    panel["maxDataPoints"] = 5000
    panel["fieldConfig"]["overrides"] = [{"matcher": {"id": "byName", "options": "7 days earlier"}, "properties": [
        {"id": "custom.drawStyle", "value": "line"}, {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [8, 6]}},
        {"id": "custom.showPoints", "value": "always"}, {"id": "custom.fillOpacity", "value": 0},
        {"id": "color", "value": {"mode": "fixed", "fixedColor": "text"}}]}]
    return on_prom(panel)


# The history panels add up two sources. Prometheus holds what the recording rules recorded, from
# the day they were installed. backfill/llm-backfill.json (written by backfill.py) holds daily
# totals from the providers' own APIs for the time the rules did not record: before they were
# installed, and any window Grafana skipped since. The file goes into the dashboard as Infinity
# inline data, because Grafana Cloud's Prometheus does not take samples older than two hours.
#
# Both sources come out as rows of (Time, dimensions..., Value), one per UTC day. Grafana merges
# the rows, adds up the rows of the same day and dimensions, and splits them into one series per
# dimension value. Each Prometheus query is a range query with a one-day step that sums one day
# per step: Grafana Cloud's Prometheus refuses a query that spans more than 32 days, so a
# [$__range] total would fail on longer ranges.

DAY_MS = 86_400_000
# Every row of a day that overlaps the time range, the same days the one-day steps cover.
IN_RANGE = f"ms + {DAY_MS} > ${{__from}} && ms < ${{__to}}"
# Grafana names a frame's only number field after the frame when nothing else names it, so the
# backfill's Value shows as "B" (its query) whenever Prometheus has no rows; renamed back here.
MERGE = [
    {"id": "organize", "options": {"excludeByName": {"ms": True}, "renameByName": {"Value #A": "Value", "B": "Value"}}},
    {"id": "merge", "options": {}},
]


def per_day(metric: str, by: str = "", sel: str = "", label_from_name: str = "") -> str:
    """One UTC day per step. `label_from_name` sets that label of crok's series to their model."""
    inner = f"sum_over_time({metric}{{{sel}}}[1d] offset -1d)"
    if label_from_name:
        inner = with_label_from_name(inner, label_from_name)
    return f"sum{f' by ({by})' if by else ''} ({inner})"


def group(dims: list[str], by_time: bool = True) -> dict:
    fields = {d: {"operation": "groupby", "aggregations": []} for d in (["Time"] if by_time else []) + dims}
    fields["Value"] = {"operation": "aggregate", "aggregations": ["sum"]}
    return {"id": "groupBy", "options": {"fields": fields}}


def series_by(dims: list[str]) -> list[dict]:
    """Merged rows -> one daily series per combination of dimension values."""
    return [*MERGE, group(dims), {"id": "sortBy", "options": {"sort": [{"field": "Time"}]}},
            {"id": "partitionByValues", "options": {"fields": dims, "keepFields": False, "naming": {"asLabels": True}}}]


class Backfill:
    def __init__(self, data: dict | None, infinity_uid: str):
        self.data = data or {}
        self.rows = self.data.get("rows", [])
        self.ds = {"type": "yesoreyeram-infinity-datasource", "uid": infinity_uid}

    def __bool__(self) -> bool:
        return bool(self.rows)

    def target(self, dims: list[str], measure) -> list[dict]:
        """An Infinity query holding the daily totals of measure(row) -> [(dimension values, value)]."""
        if not self.rows:
            return []
        sums: dict[tuple, float] = {}
        for r in self.rows:
            for values, v in measure(r):
                if v:
                    key = (r["day"], *(values[d] for d in dims))
                    sums[key] = sums.get(key, 0.0) + v
        buf = io.StringIO()
        w = csv.writer(buf, lineterminator="\n")
        w.writerow(["t", "ms", *dims, "v"])
        for (day, *vals), v in sorted(sums.items()):
            ms = int(dt.datetime.fromisoformat(day).replace(tzinfo=dt.timezone.utc).timestamp() * 1000)
            w.writerow([ms, ms, *vals, f"{v:.10g}"])
        columns = [{"selector": "t", "text": "Time", "type": "timestamp_epoch"}, {"selector": "ms", "text": "ms", "type": "number"},
                   *({"selector": d, "text": d, "type": "string"} for d in dims), {"selector": "v", "text": "Value", "type": "number"}]
        return [{"refId": "", "datasource": self.ds, "type": "csv", "source": "inline", "parser": "backend", "format": "table",
                 "data": buf.getvalue(), "columns": columns, "filterExpression": IN_RANGE}]

    def summary(self) -> str:
        cov = (self.data.get("coverage") or {})
        windows = sorted({tuple(w) for c in cov.values() for w in c.get("windows", [])})
        fmt = lambda s: s.replace("T", " ").replace(":00Z", " UTC")
        spans = "; ".join(f"{fmt(a)} – {fmt(b)}" for a, b in windows)
        ws = ((self.data.get("openrouter") or {}).get("workspace") or {}).get("name")
        return (f"**Backfilled from the providers' APIs** (fetched {fmt(self.data.get('generated_at', '?'))}): {spans}. "
                f"Claude tokens come from the Claude Admin usage API (all workspaces), with spend estimated at list prices; "
                f"OpenRouter requests, tokens and billed spend from its analytics API"
                + (f" (workspace {ws})" if ws else "") + ". The Claude usage API has no request or error counts, so Claude "
                "requests in those windows are missing. Everything else comes from the recording rules. "
                "Run `setup.sh backfill` again to fill windows the rules miss later.")


def mixed(panel: dict, transformations: list[dict]) -> dict:
    panel["datasource"] = MIXED
    panel["maxDataPoints"] = 5000  # keeps the step at one day on long ranges
    panel["transformations"] = transformations
    return panel


def history_dashboard(ctx: Ctx, backfill: Backfill) -> Board:
    b = Board(ctx, "llm-history", "LLM Spend History",
              "Spend, requests and tokens by day and week over week, from totals that recording rules copy out of the traces "
              "every 10 minutes: Claude Platform, OpenRouter, and crok's own reports for Codex, GLM and DeepSeek"
              + (", plus daily totals backfilled from the Claude and OpenRouter usage APIs for the time the rules did not record."
                 if backfill else ". Starts on the day the rules were installed.")
              + " Opens on the last 14 days, as long as Grafana Cloud's free tier keeps metrics.", ["history"],
              ds_var=prom_var(ctx), time_from="now-14d")
    note = (" Recorded every 10 minutes for the window that ended 20 minutes earlier, so the newest 20-30 minutes are not in yet."
            + (" Days before the rules started, and windows they missed, come from the providers' usage APIs." if backfill
               else " History starts when the recording rules were installed.") + " Days are UTC days.")
    day = lambda metric, by="", sel="", label="": prom(per_day(metric, by, sel, label), interval="1d", table=True)
    one = lambda field, provider=None: lambda r: [({}, r.get(field) or 0)] if provider in (None, r["provider"]) else []
    crok_note = (" codex, glm and deepseek are crok's own reports (crok's cost per call: the provider's when it reports one, "
                 "else the standard API price); codex is every OpenAI call crok makes.")

    if backfill:
        b.row("About the data")
        b.add(text("", backfill.summary()), 24, 3)

    def total(title, metric, sel, measure, **kw):
        panel = stat(title, [day(metric, sel=sel), *backfill.target([], measure)], recent_note=False, **kw)
        panel["options"]["reduceOptions"] = {"calcs": ["sum"], "fields": "/^Value$/", "values": False}
        return mixed(panel, MERGE)

    b.row("Totals for the time range")
    b.add(total("Spend", "llm_spend_usd", "", one("spend"), unit="currencyUSD", decimals=2, color="green", no_value="$0",
                desc="Claude (estimated at list prices) plus OpenRouter (billed) plus what crok reported." + crok_note + note), 4, 4)
    b.add(total("Claude, estimated", "llm_spend_usd", 'provider="claude"', one("spend", "claude"), unit="currencyUSD", decimals=2,
                no_value="$0", desc="Claude spend from tokens at list prices." + note), 3, 4)
    b.add(total("OpenRouter, billed", "llm_spend_usd", 'provider="openrouter"', one("spend", "openrouter"), unit="currencyUSD",
                decimals=2, no_value="$0", desc="The cost OpenRouter reported." + note), 3, 4)
    b.add(total("Codex, GLM, DeepSeek", "llm_spend_usd", CROK_HISTORY_SEL, lambda r: [], unit="currencyUSD", decimals=2,
                no_value="$0", desc="What crok reported for the providers without traces of their own." + crok_note + note), 4, 4)
    b.add(total("Requests", "llm_requests", "", one("requests"),
                desc="Calls to every provider." + (" Claude calls in backfilled time are not counted: the Claude usage API "
                                                   "reports tokens only." if backfill else "") + note), 3, 4)
    b.add(total("Tokens", "llm_tokens", 'direction=~"input|output"', lambda r: [({}, (r.get("input") or 0) + (r.get("output") or 0))],
                desc="Input plus output tokens." + note), 3, 4)
    errors = stat("Error rate", [prom(per_day("llm_errors"), "errors", interval="1d"), prom(per_day("llm_requests"), "requests", interval="1d")],
                  unit="percentunit", decimals=1, no_value="0%", recent_note=False,
                  steps=[{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}],
                  desc="Failed calls divided by all calls, from the traces only: the usage APIs do not count failures. A call "
                       "the user interrupted in crok is not a failure." + note)
    errors["transformations"] = [
        {"id": "joinByField", "options": {"byField": "Time", "mode": "outer"}},
        {"id": "reduce", "options": {"mode": "reduceFields", "reducers": ["sum"]}},
        {"id": "calculateField", "options": {"mode": "binary", "binary": {"left": "errors", "operator": "/", "right": "requests"},
                                             "alias": "Error rate", "replaceFields": True}},
    ]
    errors["maxDataPoints"] = 5000
    b.add(on_prom(errors), 4, 4)

    b.row("Week over week")
    for _, panel in wow_totals():
        b.add(panel, 6, 4)
    b.add(wow_table("Spend by provider, week over week", "llm_spend_usd", "", "provider", "currencyUSD", 2,
                    "Spend per provider in the last 7 days and the 7 before; Change is how much more (below zero: less)." + crok_note), 8, 8)
    b.add(wow_table("Requests by provider, week over week", "llm_requests", "", "provider", "short", None,
                    "Calls per provider in the last 7 days and the 7 before."), 8, 8)
    b.add(wow_table("Tokens by provider, week over week", "llm_tokens", 'direction=~"input|output"', "provider", "short", 1,
                    "Input plus output tokens per provider in the last 7 days and the 7 before."), 8, 8)
    b.add(day_vs_week_before("Spend per day, and 7 days earlier", "llm_spend_usd", "", "currencyUSD", 2,
                             "Bars: spend in each UTC day. Dashed line: the same weekday a week earlier, so each day reads against "
                             "last week's. Recorded history only (no backfill)." + note), 12, 8)
    b.add(day_vs_week_before("Requests per day, and 7 days earlier", "llm_requests", "", "short", 0,
                             "Bars: calls in each UTC day. Dashed line: the same weekday a week earlier." + note), 12, 8)

    def bars_day(title, targets, dims, name, **kw):
        panel = timeseries(title, targets, bars=True, stack=True, **kw)
        panel["fieldConfig"]["defaults"]["displayName"] = name
        return mixed(panel, [NOT_SET, *series_by(dims)])

    b.row("By day")
    b.add(bars_day("Spend per day", [day("llm_spend_usd", "provider"),
                                      *backfill.target(["provider"], lambda r: [({"provider": r["provider"]}, r.get("spend"))])],
                   ["provider"], "${__field.labels.provider}", unit="currencyUSD", decimals=2,
                   desc="Spend in each UTC day, by provider. The legend total is the spend over the range." + crok_note + note), 12, 9)
    b.add(bars_day("Claude spend per day by price group",
                   [day("llm_spend_usd", "price_group", 'provider="claude"'),
                    *backfill.target(["price_group"], lambda r: [({"price_group": r["price_group"]}, r.get("spend"))]
                                     if r["provider"] == "claude" else [])],
                   ["price_group"], "${__field.labels.price_group}", unit="currencyUSD", decimals=2, legend="right",
                   desc="Estimated Claude spend in each day, by model price group." + note), 12, 9)
    b.add(bars_day("Requests per day", [day("llm_requests", "provider"),
                                         *backfill.target(["provider"], lambda r: [({"provider": r["provider"]}, r.get("requests"))])],
                   ["provider"], "${__field.labels.provider}",
                   desc="Calls in each day, by provider." + (" Claude has none in backfilled time: its usage API reports "
                                                            "tokens only." if backfill else "") + note), 12, 8)
    b.add(bars_day("Tokens per day", [day("llm_tokens", "provider, direction", 'direction=~"input|output"'),
                                       *backfill.target(["provider", "direction"], lambda r: [
                                           ({"provider": r["provider"], "direction": "input"}, r.get("input")),
                                           ({"provider": r["provider"], "direction": "output"}, r.get("output"))])],
                   ["provider", "direction"], "${__field.labels.provider} ${__field.labels.direction}",
                   desc="Input and output tokens in each day, by provider." + note), 12, 8)

    b.row("Where the money went")
    spend_rank = bars("Spend by price group", name="Price group", value="Spend", unit="currencyUSD", decimals=2, color="green",
                      targets=[day("llm_spend_usd", "provider, price_group", label="price_group"),
                               *backfill.target(["provider", "price_group"], lambda r: [
                                   ({"provider": r["provider"], "price_group": r["price_group"]}, r.get("spend"))])],
                      desc="Spend over the time range for each Claude price group, for OpenRouter, and for each model crok "
                           "reported, largest first." + note, total=False, recent_note=False)
    spend_rank["fieldConfig"]["overrides"] = [
        {"matcher": {"id": "byName", "options": "provider"}, "properties": [{"id": "displayName", "value": "Provider"},
                                                                            {"id": "custom.width", "value": 110}]},
        {"matcher": {"id": "byName", "options": "price_group"}, "properties": [{"id": "displayName", "value": "Price group"},
                                                                               {"id": "custom.width", "value": 200}]},
        {"matcher": {"id": "byName", "options": "Value (sum)"}, "properties": spend_rank["fieldConfig"]["overrides"][1]["properties"]},
    ]
    b.add(mixed(spend_rank, [*MERGE, group(["provider", "price_group"], by_time=False),
                             {"id": "sortBy", "options": {"sort": [{"field": "Value (sum)", "desc": True}]}}]), 12, 8)
    cache = timeseries("Claude cache reads per day", [
        day("llm_tokens", "direction", 'provider="claude",direction=~"cache_read|input"'),
        *backfill.target(["direction"], lambda r: [({"direction": "cache_read"}, r.get("cache_read")),
                                                   ({"direction": "input"}, r.get("input"))] if r["provider"] == "claude" else [])],
        unit="percentunit", calcs=("mean",), desc="Share of Claude input tokens read from the prompt cache, per day." + note)
    cache["fieldConfig"]["defaults"].update({"min": 0, "max": 1})
    cache["fieldConfig"]["defaults"]["custom"].update({"showPoints": "always", "pointSize": 6, "spanNulls": True})
    b.add(mixed(cache, [*MERGE, group(["direction"]),
                        {"id": "groupingToMatrix", "options": {"columnField": "direction", "rowField": "Time", "valueField": "Value (sum)"}},
                        {"id": "convertFieldType", "options": {"conversions": [{"targetField": "Time\\direction", "destinationType": "time"}]}},
                        {"id": "calculateField", "options": {"mode": "binary", "binary": {"left": "cache_read", "operator": "/", "right": "input"},
                                                             "alias": "cache hit rate", "replaceFields": True}},
                        {"id": "sortBy", "options": {"sort": [{"field": "Time\\direction"}]}}]), 12, 8)
    b.add(history_bars("Codex, GLM, DeepSeek spend per day by model",
                       f"sum by (provider, model) ({with_label_from_name(f'sum_over_time(llm_spend_usd{{{CROK_HISTORY_SEL}}}[1d] offset -1d)', 'model')})",
                       "{{provider}} · {{model}}", unit="currencyUSD", decimals=2,
                       desc="What crok reported in each UTC day, by provider and model." + crok_note + note), 24, 8)
    return b


def folder(ctx: Ctx) -> dict:
    return {"apiVersion": "folder.grafana.app/v1", "kind": "Folder", "metadata": {"name": ctx.folder},
            "spec": {"title": "LLM Observability", "description": "Claude Platform, OpenRouter and crok traces (Codex, GLM, "
                                                                 "DeepSeek): spend, tokens, latency, errors, 14 days of history."}}


def queries(panels: list[dict]):
    for p in panels:
        if p.get("type") == "row":
            yield from queries(p.get("panels", []))
        for t in p.get("targets", []):
            if t.get("queryType") == "traceql":
                yield p["title"], t["query"]


def check_lengths(board: Board) -> list[str]:
    problems = []
    for title, q in queries(board.panels):
        worst = re.sub(r"\$\{\w+(:\w+)?\}|\$\w+", "x" * VAR_ALLOWANCE, q)
        if len(worst) > QUERY_LIMIT:
            problems.append(f"{board.uid} / {title}: {len(worst)} characters (limit {QUERY_LIMIT})")
    return problems


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--datasource-uid", default="grafanacloud-traces", help="UID of the Tempo datasource (default: %(default)s)")
    p.add_argument("--datasource-name", default="", help="Display name of that datasource, for the picker's default")
    p.add_argument("--folder-uid", default="llm-observability", help="Folder for the dashboards (default: %(default)s)")
    p.add_argument("--claude-service", default="claude-platform", help="service.name of Claude Platform spans (default: %(default)s)")
    p.add_argument("--openrouter-service", default="openrouter", help="service.name of OpenRouter spans (default: %(default)s)")
    p.add_argument("--crok-service", default="crok", help="service.name of the spans crok reports itself (default: %(default)s)")
    p.add_argument("--crok-skip-providers", default="anthropic|openrouter",
                   help="Regex of gen_ai.provider.name values whose crok spans are left out, because the provider's own export "
                        "already counts them (default: %(default)s; empty keeps them all)")
    p.add_argument("--prometheus-uid", default="grafanacloud-prom", help="UID of the Prometheus datasource the history is "
                   "recorded into (default: %(default)s)")
    p.add_argument("--prometheus-name", default="", help="Display name of that datasource")
    p.add_argument("--infinity-uid", default="grafanacloud-infinity", help="UID of the Infinity datasource that serves the "
                   "backfilled days (default: %(default)s)")
    p.add_argument("--backfill", default=str(HERE / "backfill" / "llm-backfill.json"),
                   help="Daily totals from backfill.py, embedded in LLM Spend History when the file exists (default: %(default)s)")
    p.add_argument("--prices", default=str(HERE / "prices.json"), help="Claude price table (default: %(default)s)")
    p.add_argument("--out", default=str(HERE / "dashboards"), help="Directory for the dashboard manifests (default: %(default)s)")
    p.add_argument("--rules-out", default=str(HERE / "rules" / "llm-history.json"),
                   help="File for the recording-rule group (default: %(default)s)")
    args = p.parse_args(argv)

    ctx = Ctx(args, json.loads(pathlib.Path(args.prices).read_text()))
    bf_path = pathlib.Path(args.backfill)
    backfill = Backfill(json.loads(bf_path.read_text()) if bf_path.exists() else None, args.infinity_uid)
    boards = [overview(ctx), claude_dashboard(ctx), openrouter_dashboard(ctx), crok_dashboard(ctx), explorer_dashboard(ctx),
              history_dashboard(ctx, backfill)]
    rules = history_rules(ctx)
    problems = [msg for b in boards for msg in check_lengths(b)]
    problems += [f"rule {r['title']}: {len(r['data'][0]['model']['query'])} characters"
                 for r in rules["rules"] if len(r["data"][0]["model"]["query"]) > QUERY_LIMIT]
    if problems:
        print("Queries too long for Grafana Cloud's TraceQL parser:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 1

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    files = {out / "folder.json": folder(ctx), **{out / f"{b.uid}.json": b.manifest() for b in boards},
             pathlib.Path(args.rules_out): rules}
    for path, doc in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
