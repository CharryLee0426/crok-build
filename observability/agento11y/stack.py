#!/usr/bin/env python3
"""crok's online evaluation in Grafana Agent Observability: evaluators, rules and guards from
stack.json, applied with gcx; and the conversations already on the stack scored with them, so the
weeks of traffic collected before the rules existed get quality scores too.

    stack.py inventory                 # what the stack has: agents, evaluators, rules, guards, judges
    stack.py apply [--dry-run]         # evaluators, then rules, then guards, then the collections
    stack.py backfill --since 2026-10-16 [--judge-sample 0.25] [--max-conversations 200]
    stack.py report                    # the backfilled scores by model and version
    stack.py alerts [--dry-run]        # the crok-alerts rule group (alerts.json)
    stack.py slos [--dry-run]          # the SLOs (slos.json)

Evaluators fork the stack's own templates (`gcx agento11y templates get`) where one fits, with the
judge model resolved from `gcx agento11y judge list-models`; guards are always created in warn mode.
`apply` is idempotent: an evaluator is upserted with a new version only when its definition changed,
and rules and guards are created or updated to match.

`backfill` reads the conversations in the window (agent crok and its sub-agents, not eval traffic),
runs each rule's evaluators on the generations its selector picks (`gcx agento11y evaluators test`,
which uses the stack's judge but stores nothing), and exports the results as scores through the
Agent Observability plugin (`scores:export`) with ids derived from evaluator and generation, so a
second run adds nothing twice. Regex and heuristic evaluators run on every generation they select;
LLM judges on a deterministic sample (--judge-sample). Results also land in backfill/scores.jsonl
(git-ignored) for `report`.

Needs gcx signed in to the stack (`gcx login <stack> --server https://<stack>.grafana.net --oauth`).
Only the standard library is used.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
STACK = HERE / "stack.json"
BACKFILL = HERE / "backfill"
SCORES_FILE = BACKFILL / "scores.jsonl"
PLUGIN_EVAL = "/api/plugins/grafana-agento11y-app/resources/eval"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------------------------
# gcx
# ---------------------------------------------------------------------------------------------


def gcx(*args: str, data: dict | None = None, check: bool = True):
    """Runs gcx with JSON output and returns the parsed document (gcx prints hint lines first)."""
    cmd = ["gcx", *args]
    if "-o" not in args and args[0] != "api":
        cmd += ["-o", "json"]
    tmp = None
    if data is not None:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(data, tmp)
        tmp.close()
        cmd += ["-f", tmp.name] if args[0] != "api" else ["-d", f"@{tmp.name}"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if tmp is not None:
        pathlib.Path(tmp.name).unlink(missing_ok=True)
    if proc.returncode != 0:
        if check:
            raise RuntimeError(f"{' '.join(cmd[:6])}: {(proc.stderr or proc.stdout).strip()[:500]}")
        return None
    return parse_json(proc.stdout)


def parse_json(text: str):
    """The last JSON document gcx printed (it may print a `{"class":"hint",...}` line first)."""
    docs = []
    decoder = json.JSONDecoder()
    i = 0
    text = text.strip()
    while i < len(text):
        while i < len(text) and text[i] in " \r\n\t":
            i += 1
        if i >= len(text):
            break
        try:
            doc, end = decoder.raw_decode(text, i)
        except json.JSONDecodeError:
            break
        docs.append(doc)
        i = end
    docs = [d for d in docs if not (isinstance(d, dict) and d.get("class") == "hint")]
    return docs[-1] if docs else None


def items(doc) -> list:
    """The list inside a gcx list response, whatever the envelope."""
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict):
        for key in ("items", "data", "results", "evaluators", "rules", "guards", "hook_rules", "templates",
                    "models", "providers", "conversations", "collections", "agents", "generations", "slos",
                    "datasources"):
            if isinstance(doc.get(key), list):
                return doc[key]
    return []


def spec(doc) -> dict:
    """A get response's body: K8s-style manifests keep it under `spec`."""
    if isinstance(doc, dict) and isinstance(doc.get("spec"), dict):
        return doc["spec"]
    return doc if isinstance(doc, dict) else {}


def field(obj: dict, *names, default=None):
    for name in names:
        if isinstance(obj, dict) and obj.get(name) not in (None, ""):
            return obj[name]
    return default


# ---------------------------------------------------------------------------------------------
# inventory
# ---------------------------------------------------------------------------------------------


def cmd_inventory(_args) -> int:
    ctx = subprocess.run(["gcx", "config", "current-context"], capture_output=True, text=True).stdout.strip()
    print(f"gcx context: {ctx.splitlines()[-1] if ctx else '?'}")
    for label, args in (("agents", ("agents", "list", "--limit", "50")), ("evaluators", ("evaluators", "list")),
                        ("rules", ("rules", "list")), ("guards", ("guards", "list")),
                        ("templates", ("templates", "list")), ("judge providers", ("judge", "list-providers")),
                        ("collections", ("collections", "list"))):
        rows = items(gcx("agento11y", *args, check=False))
        names = [field(r, "name", "agent_name", "evaluator_id", "rule_id", "template_id", "id", default="?") for r in rows]
        print(f"{label}: {len(rows)}" + (f"  {', '.join(map(str, names[:30]))}" if names else ""))
    return 0


# ---------------------------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------------------------


def resolve_judges(config: dict) -> dict:
    out = {}
    for name, want in config.get("judges", {}).items():
        models = items(gcx("agento11y", "judge", "list-models", "--provider", want["provider"], check=False))
        ids = [field(m, "id", "model", "name", default="") for m in models]
        match = sorted(i for i in ids if want["model_pattern"] in i)
        if not match:
            raise SystemExit(f"judge {name}: no {want['provider']} model matching {want['model_pattern']!r} among {ids}")
        out[name] = {"provider": want["provider"], "model": match[-1]}
    return out


def desired_evaluator(ev: dict, judges: dict) -> dict:
    if "template" in ev:
        template = spec(gcx("agento11y", "templates", "get", ev["template"]))
        version = field(template, "latest_version", "current_version")
        body = template.get("versions", [{}])[-1] if not template.get("config") and template.get("versions") else template
        kind = field(body, "kind", default=field(template, "kind"))
        config = dict(field(body, "config", default={}) or {})
        output_keys = field(body, "output_keys", default=field(template, "output_keys", default=[]))
        description = field(template, "description", default="")
        if not kind:
            raise SystemExit(f"{ev['evaluator_id']}: template {ev['template']} has no kind (version {version})")
    else:
        kind, config, output_keys, description = ev["kind"], dict(ev["config"]), ev.get("output_keys", []), ""
    if ev.get("judge"):
        config.update(judges[ev["judge"]])
    if ev.get("system_prompt"):
        config["system_prompt"] = ev["system_prompt"]
    config.update(ev.get("config_overrides", {}))
    out = {"evaluator_id": ev["evaluator_id"], "kind": kind, "config": config,
           "description": (ev.get("why") or description)[:500]}
    if output_keys:
        out["output_keys"] = output_keys
    return out


def fingerprint(body: dict) -> str:
    keep = {k: body.get(k) for k in ("kind", "config", "output_keys")}
    return hashlib.sha256(json.dumps(keep, sort_keys=True).encode()).hexdigest()[:12]


def apply_evaluators(config: dict, judges: dict, dry: bool) -> None:
    existing = {field(e, "evaluator_id", "id"): e for e in items(gcx("agento11y", "evaluators", "list", check=False))}
    today = dt.date.today().isoformat()
    for ev in config["evaluators"]:
        body = desired_evaluator(ev, judges)
        current = existing.get(ev["evaluator_id"])
        if current is not None:
            current = spec(gcx("agento11y", "evaluators", "get", ev["evaluator_id"], check=False)) or current
            if fingerprint(current) == fingerprint(body):
                log(f"evaluator {ev['evaluator_id']}: unchanged")
                continue
        old_version = str(field(current or {}, "version", default=""))
        version = today if not old_version.startswith(today) else f"{today}.{int(old_version.split('.')[-1]) + 1 if old_version.count('.') else 1}"
        body["version"] = version
        log(f"evaluator {ev['evaluator_id']}: {'create' if current is None else 'update'} {version} ({body['kind']})")
        if not dry:
            gcx("agento11y", "evaluators", "upsert", data=body)


def apply_named(kind: str, config_items: list[dict], dry: bool) -> None:
    existing = {field(r, "rule_id", "id") for r in items(gcx("agento11y", kind, "list", check=False))}
    for item in config_items:
        body = {k: v for k, v in item.items() if k != "why"}
        verb = "update" if item["rule_id"] in existing else "create"
        log(f"{kind[:-1]} {item['rule_id']}: {verb}")
        if dry:
            continue
        if verb == "create":
            gcx("agento11y", kind, "create", data=body)
        else:
            gcx("agento11y", kind, "update", item["rule_id"], data=body)


def apply_collections(config: dict, since: str, dry: bool) -> None:
    existing = {field(c, "name"): field(c, "collection_id", "id") for c in items(gcx("agento11y", "collections", "list", check=False))}
    for col in config.get("collections", []):
        cid = existing.get(col["name"])
        if cid is None:
            log(f"collection {col['name']}: create")
            if dry:
                continue
            created = gcx("agento11y", "collections", "create", "--name", col["name"], "--description", col["description"])
            cid = field(spec(created), "collection_id", "id")
        conversations = items(gcx("agento11y", "conversations", "search", "--filters", col["from_search"],
                                  "--from", since, "--limit", str(col.get("limit", 40)), check=False))
        saved_ids = []
        for conv in conversations:
            conv_id = field(conv, "conversation_id", "id")
            title = field(conv, "title", "conversation_title", default=conv_id)
            if dry:
                log(f"  would save {conv_id} ({title})")
                continue
            saved = gcx("agento11y", "saved-conversations", "save", conv_id, "--name", f"{title}"[:120], check=False)
            sid = field(spec(saved or {}), "saved_id", "saved_conversation_id", "id")
            if sid:
                saved_ids.append(sid)
        if saved_ids and not dry:
            gcx("agento11y", "collections", "add-conversations", cid, *saved_ids, check=False)
        log(f"collection {col['name']}: {len(saved_ids)} conversations saved and added")


def cmd_apply(args) -> int:
    config = json.loads(STACK.read_text())
    judges = resolve_judges(config)
    log(f"judges: {judges}")
    apply_evaluators(config, judges, args.dry_run)
    apply_named("rules", config["rules"], args.dry_run)
    apply_named("guards", config["guards"], args.dry_run)
    apply_collections(config, args.since, args.dry_run)
    return 0


# ---------------------------------------------------------------------------------------------
# backfill
# ---------------------------------------------------------------------------------------------


def generation_parts(gen: dict) -> tuple[bool, bool]:
    """(has text, has tool calls) in a generation's output."""
    text = calls = False
    for message in field(gen, "output", default=[]) or []:
        for part in field(message, "parts", default=[]) or []:
            kind = field(part, "type", "kind", default="")
            if "tool_call" in str(kind) or "toolCall" in part or "tool_call" in part:
                calls = True
            elif str(field(part, "text", default="")).strip():
                text = True
    return text, calls


def selected(selector: str, gen: dict) -> bool:
    text, calls = generation_parts(gen)
    if selector == "all_assistant_generations":
        return text or calls
    if selector == "tool_call_steps":
        return calls
    if selector in ("user_visible_turn", "turn"):
        # The answer the user saw: a generation that ends its turn (no tool calls left).
        return not calls and not field(gen, "call_error", "callError")
    return False


def matches_agent(patterns: list[str], agent: str) -> bool:
    import fnmatch

    return any(fnmatch.fnmatchcase(agent or "", p) for p in patterns)


def sampled(generation_id: str, evaluator_id: str, rate: float) -> bool:
    digest = hashlib.sha256(f"{evaluator_id}:{generation_id}".encode()).digest()
    return int.from_bytes(digest[:4], "big") / 2**32 < rate


def evaluator_kinds(config: dict) -> dict:
    kinds = {}
    for ev in config["evaluators"]:
        kinds[ev["evaluator_id"]] = ev.get("kind") or ("llm_judge" if ev.get("judge") else "deterministic")
    return kinds


def ingest_target() -> tuple[str, dict] | None:
    """The ingest endpoint and headers crok reports with (~/.crok/agento11y.env or the environment),
    for score export when the plugin route refuses: scores take a sigil:write access-policy token."""
    import base64
    import os

    settings = {}
    env_file = pathlib.Path(os.environ.get("CROK_HOME", "~/.crok")).expanduser() / "agento11y.env"
    if env_file.is_file():
        for line in env_file.read_text().splitlines():
            key, sep, value = line.strip().removeprefix("export ").partition("=")
            if sep and not key.startswith("#"):
                settings[key.strip()] = value.strip().strip('"').strip("'")
    settings.update({k: v for k, v in os.environ.items() if k.startswith("AGENTO11Y_")})
    endpoint, tenant, token = (settings.get(k, "") for k in ("AGENTO11Y_ENDPOINT", "AGENTO11Y_AUTH_TENANT_ID", "AGENTO11Y_AUTH_TOKEN"))
    if not (endpoint and tenant and token):
        return None
    basic = base64.b64encode(f"{tenant}:{token}".encode()).decode()
    return endpoint.rstrip("/"), {"Authorization": f"Basic {basic}", "Content-Type": "application/json"}


def export_scores(scores: list[dict]) -> str:
    import urllib.request

    if not scores:
        return "nothing to export"
    result = gcx("api", f"{PLUGIN_EVAL}/scores:export", data={"scores": scores}, check=False)
    if result is not None:
        return f"exported {len(scores)} through the plugin (accepted {field(result, 'accepted', default='?')})"
    target = ingest_target()
    if target is None:
        return "the plugin refused scores:export and no ingest token is set up; kept in backfill/scores.jsonl only"
    endpoint, headers = target
    req = urllib.request.Request(f"{endpoint}/api/v1/scores:export", data=json.dumps({"scores": scores}).encode(),
                                 headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read() or b"{}")
        return f"exported {len(scores)} to the ingest API (accepted {field(body, 'accepted', default='?')})"
    except Exception as err:  # noqa: BLE001 - reported, the scores stay in the local file
        return f"score export failed ({err}); kept in backfill/scores.jsonl"


def cmd_backfill(args) -> int:
    config = json.loads(STACK.read_text())
    kinds = evaluator_kinds(config)
    versions = {field(e, "evaluator_id", "id"): field(e, "version", default="1")
                for e in items(gcx("agento11y", "evaluators", "list", check=False))}
    missing = [e for e in kinds if e not in versions]
    if missing:
        raise SystemExit(f"evaluators not on the stack yet: {', '.join(missing)}; run `stack.py apply` first")
    BACKFILL.mkdir(exist_ok=True)
    done = set()
    if SCORES_FILE.exists():
        done = {json.loads(line)["score_id"] for line in SCORES_FILE.read_text().splitlines() if line.strip()}
    filters = 'agent =~ "crok.*"'
    convs = items(gcx("agento11y", "conversations", "search", "--filters", filters, "--from", args.since,
                      "--to", args.until, "--limit", str(args.max_conversations)))
    log(f"{len(convs)} conversations from {args.since} to {args.until}")
    batch, totals = [], {"tested": 0, "skipped": 0, "failed_calls": 0}
    for conv in convs:
        conv_id = field(conv, "conversation_id", "id")
        detail = spec(gcx("agento11y", "conversations", "get", conv_id, check=False) or {})
        for gen in field(detail, "generations", default=[]) or []:
            tags = field(gen, "tags", default={}) or {}
            if tags.get("origin") == "eval":
                continue
            agent = field(gen, "agent_name", "agentName", default="")
            gen_id = field(gen, "generation_id", "id")
            for rule in config["rules"]:
                if not matches_agent(rule["match"].get("agent_name", ["*"]), agent) or not selected(rule["selector"], gen):
                    continue
                for ev_id in rule["evaluator_ids"]:
                    score_id = f"backfill-{ev_id}-{gen_id}"[:128]
                    if score_id in done:
                        totals["skipped"] += 1
                        continue
                    if kinds[ev_id] == "llm_judge" and not sampled(gen_id, ev_id, args.judge_sample):
                        continue
                    if args.dry_run:
                        totals["tested"] += 1
                        continue
                    result = gcx("agento11y", "evaluators", "test", "-e", ev_id, "-g", gen_id, check=False)
                    if result is None:
                        totals["failed_calls"] += 1
                        continue
                    for row in score_rows(result):
                        score = {
                            "score_id": f"{score_id}-{row['key']}"[:128] if row["key"] != "score" else score_id,
                            "evaluator_id": ev_id, "evaluator_version": str(versions[ev_id]),
                            "score_key": row["key"], "value": row["value"],
                            "generation_id": gen_id, "conversation_id": conv_id,
                            "rule_id": rule["rule_id"], "source": {"kind": "backfill", "id": "stack.py"},
                            "metadata": {"model": field(field(gen, "model", default={}), "name", default=""),
                                         "agent_version": field(gen, "agent_version", "agentVersion", default=""),
                                         "agent_name": agent, "backfilled_at": dt.datetime.now(dt.timezone.utc).isoformat()},
                        }
                        if row.get("passed") is not None:
                            score["passed"] = row["passed"]
                        if row.get("explanation"):
                            score["explanation"] = row["explanation"][:1000]
                        batch.append(score)
                        with SCORES_FILE.open("a") as f:
                            f.write(json.dumps(score) + "\n")
                    totals["tested"] += 1
                    if len(batch) >= 50:
                        log(export_scores(batch))
                        batch = []
    if batch:
        log(export_scores(batch))
    log(f"backfill: {totals}")
    return 0


def score_rows(result) -> list[dict]:
    """Scores out of an `evaluators test` response: one per output key."""
    doc = spec(result)
    rows = items(doc) or field(doc, "scores", default=None) or [doc]
    out = []
    for row in rows:
        value = field(row, "value", default=None)
        if isinstance(value, dict) and value:
            wire = value
        elif isinstance(value, bool):
            wire = {"bool": value}
        elif isinstance(value, (int, float)):
            wire = {"number": float(value)}
        elif isinstance(value, str):
            wire = {"string": value}
        else:
            score = field(row, "score", default=None)
            wire = {"number": float(score)} if isinstance(score, (int, float)) else {"bool": bool(field(row, "passed", default=False))}
        out.append({"key": field(row, "score_key", "key", default="score"), "value": wire,
                    "passed": field(row, "passed", default=None), "explanation": field(row, "explanation", default="")})
    return out


def cmd_report(_args) -> int:
    if not SCORES_FILE.exists():
        raise SystemExit("no backfilled scores yet; run `stack.py backfill`")
    table: dict[tuple, list[int]] = {}
    for line in SCORES_FILE.read_text().splitlines():
        s = json.loads(line)
        if s.get("passed") is None:
            continue
        key = (s["evaluator_id"], s["metadata"].get("model", ""))
        cell = table.setdefault(key, [0, 0])
        cell[0] += int(s["passed"])
        cell[1] += 1
    print(f"{'evaluator':<36} {'model':<44} pass rate")
    for (ev, model), (ok, n) in sorted(table.items()):
        print(f"{ev:<36} {model:<44} {ok}/{n} ({ok / n:.0%})")
    return 0


# ---------------------------------------------------------------------------------------------
# alerts and SLOs
# ---------------------------------------------------------------------------------------------


def gcx_api(path: str, method: str = "GET", body=None, headers: tuple[str, ...] = ()):
    cmd = ["gcx", "api", path, "-X", method]
    for header in headers:
        cmd += ["-H", header]
    tmp = None
    if body is not None:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(body, tmp)
        tmp.close()
        cmd += ["-d", f"@{tmp.name}"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if tmp is not None:
        pathlib.Path(tmp.name).unlink(missing_ok=True)
    if proc.returncode != 0:
        raise RuntimeError(f"{method} {path}: {(proc.stderr or proc.stdout).strip()[:500]}")
    return parse_json(proc.stdout)


def prometheus_uid() -> str:
    sources = items(gcx("datasources", "list"))
    proms = sorted((d for d in sources if d.get("type") == "prometheus"), key=lambda d: (not d["name"].endswith("-prom"), d["name"]))
    if not proms:
        raise SystemExit("no Prometheus datasource on this stack")
    return proms[0]["uid"]


def metric_names(prom: str) -> set[str]:
    doc = gcx_api(f"/api/datasources/proxy/uid/{prom}/api/v1/label/__name__/values")
    return set(field(doc, "data", default=[]) or [])


def label_values(prom: str, metric: str, label: str) -> list[str]:
    doc = gcx_api(f"/api/datasources/proxy/uid/{prom}/api/v1/label/{label}/values?match[]={metric}")
    return list(field(doc, "data", default=[]) or [])


def fill(obj, values: dict):
    text = json.dumps(obj)
    for key, value in values.items():
        text = text.replace("${" + key + "}", value)
    return json.loads(text)


def cmd_alerts(args) -> int:
    group = json.loads((HERE / "alerts.json").read_text())
    prom = prometheus_uid()
    names = metric_names(prom)
    rules = []
    for rule in group["rules"]:
        needed = rule.pop("needs_metric")
        if needed not in names:
            log(f"alert {rule['uid']}: skipped, {needed} is not in Prometheus yet")
            continue
        rule.update({"folderUID": group["folderUid"], "ruleGroup": group["title"]})
        rules.append(fill(rule, {"prom": prom}))
        log(f"alert {rule['uid']}: {rule['title']}")
    body = {"title": group["title"], "folderUid": group["folderUid"], "interval": group["interval"], "rules": rules}
    if not args.dry_run and rules:
        gcx_api(f"/api/v1/provisioning/folder/{group['folderUid']}/rule-groups/{group['title']}", "PUT", body,
                ("X-Disable-Provenance: true",))
        log(f"installed rule group {group['title']} ({len(rules)} rules)")
    return 0


SLO_API = "/api/plugins/grafana-slo-app/resources/v1/slo"


def cmd_slos(args) -> int:
    config = json.loads((HERE / "slos.json").read_text())
    prom = prometheus_uid()
    names = metric_names(prom)
    existing = {s.get("name"): s.get("uuid") for s in items(gcx_api(SLO_API))}
    for slo in config["slos"]:
        needed = slo.pop("needs_metric")
        slo.pop("uuid", None)
        if needed not in names:
            log(f"SLO {slo['name']}: skipped, {needed} is not in Prometheus yet")
            continue
        values = {"prom": prom}
        if "bucket_le" in slo:
            want = float(slo.pop("bucket_le"))
            bounds = sorted((v for v in label_values(prom, needed, "le") if v != "+Inf"), key=float)
            le = next((v for v in bounds if float(v) >= want), None)
            if le is None:
                log(f"SLO {slo['name']}: skipped, no histogram bucket at or above {want}s among {bounds}")
                continue
            values["le"] = le
            if float(le) != want:
                slo["description"] += f" (The closest bucket boundary is {le} s.)"
        body = fill(slo, values)
        uuid = existing.get(slo["name"])
        log(f"SLO {slo['name']}: {'update' if uuid else 'create'}")
        if args.dry_run:
            continue
        if uuid:
            gcx_api(f"{SLO_API}/{uuid}", "PUT", body)
        else:
            gcx_api(SLO_API, "POST", body)
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("inventory")
    a = sub.add_parser("apply")
    a.add_argument("--dry-run", action="store_true")
    a.add_argument("--since", default=(dt.date.today() - dt.timedelta(days=30)).isoformat(),
                   help="window the collections are filled from")
    b = sub.add_parser("backfill")
    b.add_argument("--since", default=(dt.date.today() - dt.timedelta(days=30)).isoformat())
    b.add_argument("--until", default=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    b.add_argument("--judge-sample", type=float, default=0.25)
    b.add_argument("--max-conversations", type=int, default=200)
    b.add_argument("--dry-run", action="store_true")
    sub.add_parser("report")
    al = sub.add_parser("alerts", help="install the crok-alerts rule group (alerts.json)")
    al.add_argument("--dry-run", action="store_true")
    sl = sub.add_parser("slos", help="create or update the SLOs (slos.json)")
    sl.add_argument("--dry-run", action="store_true")
    args = p.parse_args(argv)
    commands = {"inventory": cmd_inventory, "apply": cmd_apply, "backfill": cmd_backfill, "report": cmd_report,
                "alerts": cmd_alerts, "slos": cmd_slos}
    return commands[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
