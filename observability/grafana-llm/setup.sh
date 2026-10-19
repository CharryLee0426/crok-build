#!/usr/bin/env bash
# Set up LLM observability in Grafana Cloud for traces that Claude Platform (Claude Console
# OpenTelemetry export) and OpenRouter (Broadcast) send, then install the dashboards.
#
# Made to be run step by step by an agent (Claude Code, crok, ...) or by a person. Every step is
# a subcommand that does one thing, prints what it found, and, where only the user can act (a
# browser sign-in, a token, a console form), prints a block that starts with
# "ACTION FOR THE USER". Run `setup.sh help` for the steps.
#
# Needs: gcx (the Grafana Cloud CLI) and python3. Never prints or stores secrets: the Grafana token
# and an Anthropic Admin API key are read from environment variables only when a step needs them.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_SERVICE="${CLAUDE_SERVICE:-claude-platform}"
OPENROUTER_SERVICE="${OPENROUTER_SERVICE:-openrouter}"
FOLDER_UID="${FOLDER_UID:-llm-observability}"
DASHBOARDS_DIR="${DASHBOARDS_DIR:-$HERE/dashboards}"
RULES_FILE="${RULES_FILE:-$HERE/rules/llm-history.json}"
BACKFILL_FILE="${BACKFILL_FILE:-$HERE/backfill/llm-backfill.json}"
DASHBOARD_UIDS=(llm-overview llm-claude-platform llm-openrouter llm-request-explorer llm-history)

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=; G=; Y=; R=; N=; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s✘ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
action() {
  printf '\n%s==> ACTION FOR THE USER%s\n' "$B" "$N"
  cat
  printf '%s<== END OF ACTION%s\n\n' "$B" "$N"
}

# gcx prints a hint line before JSON in agent mode; keep only the JSON document.
gcx_json() { gcx "$@" -o json 2>/dev/null | python3 -I -c 'import sys; t=sys.stdin.read(); i=t.find("\n{") if t.startswith("{\"class\"") else -1; print(t[i+1:] if i>=0 else t)'; }

need_gcx() { command -v gcx >/dev/null 2>&1 || die "gcx is not installed. Run: $0 install"; }

# ---------------------------------------------------------------------------------------------

cmd_help() {
  cat <<EOF
${B}LLM observability for Grafana Cloud: Claude Platform + OpenRouter traces${N}

Steps, in order (each one can be run again safely):
  install            Install gcx, the Grafana Cloud CLI (Homebrew, or the official install script).
  login [URL]        Sign gcx in to your Grafana Cloud stack in the browser, for example
                     $0 login https://mystack.grafana.net
  info [--json]      Show the stack ID, the OTLP endpoint and the traces datasource.
  token              How to create the Grafana Cloud token (scope traces:write) both senders need.
  claude             How to add the Grafana Cloud destination in the Claude Console.
  claude-api         Add that destination with the Anthropic Admin API instead (needs
                     ANTHROPIC_ADMIN_KEY and GRAFANA_OTLP_TOKEN in the environment).
  openrouter         How to turn on OpenRouter Broadcast to Grafana Cloud.
  verify [--wait N]  Look for Claude Platform and OpenRouter spans in the last hour; with --wait,
                     keep looking for N minutes.
  dashboards         Build the dashboards for this stack, push them with gcx, and install the
                     recording rules that keep long-term history (LLM Spend History).
  backfill [ARGS]    Fetch up to two months of Claude and OpenRouter usage from their APIs for the
                     time the recording rules did not record, and add it to LLM Spend History.
                     Needs a Claude Admin API key and an OpenRouter management key (it says how).
                     ARGS go to backfill.py, for example --since 2026-08-15 or
                     --openrouter-workspace <name>.
  snapshot [DIR]     Render every dashboard to a PNG (for checking them without a browser).
  all                Run the whole flow, pausing where the user has to act.

Environment: GCX_CONTEXT (gcx context to use), CLAUDE_SERVICE, OPENROUTER_SERVICE, FOLDER_UID.
EOF
}

cmd_install() {
  if command -v gcx >/dev/null 2>&1; then ok "gcx is installed: $(gcx --version 2>/dev/null | head -1)"; return; fi
  if command -v brew >/dev/null 2>&1; then
    say "Installing gcx with Homebrew…"
    brew install gcx
  else
    say "Installing gcx with the official script (to ~/.local/bin)…"
    curl -fsSL https://raw.githubusercontent.com/grafana/gcx/main/scripts/install.sh | sh
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "Add ~/.local/bin to PATH to use gcx." ;; esac
  fi
  command -v gcx >/dev/null 2>&1 && ok "gcx installed: $(gcx --version | head -1)"
  command -v python3 >/dev/null 2>&1 || warn "python3 is needed by the dashboard builder."
}

ctx_args() { if [ -n "${GCX_CONTEXT:-}" ]; then printf -- '--context\n%s\n' "$GCX_CONTEXT"; fi; }

cmd_login() {
  need_gcx
  local url="${1:-}"
  if [ -z "$url" ]; then
    if gcx config check >/dev/null 2>&1; then ok "gcx is already signed in ($(gcx config current-context 2>/dev/null | tail -1))."; return; fi
    action <<EOF
Tell the agent your Grafana Cloud stack URL, for example https://mystack.grafana.net
(it is the address of your Grafana; on grafana.com it is listed under your stack).
EOF
    return 1
  fi
  url="${url%/}"
  case "$url" in http*) ;; *) url="https://$url" ;; esac
  local slug; slug="$(printf '%s' "$url" | sed -E 's#https?://([^.]+)\..*#\1#')"
  action <<EOF
A browser page from $url opens (or open the link gcx prints below).
Check that the verification code it shows matches the one printed here, then click Approve.
EOF
  # agent mode skips opening the browser; open it ourselves when we can.
  local opened=0
  gcx login "$slug" --server "$url" --oauth --yes 2>&1 | while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
      "  https://"*"/cli/auth?"*)
        if [ "$opened" = 0 ] && command -v open >/dev/null 2>&1; then open "${line#  }" 2>/dev/null || true; opened=1; fi ;;
    esac
  done
  gcx config check >/dev/null 2>&1 && ok "Signed in to $url as context $slug." || die "Sign-in did not finish."
}

# Discover the stack: id, slug, region, OTLP endpoint, traces datasource.
discover() {
  need_gcx
  local args=(); while IFS= read -r a; do args+=("$a"); done < <(ctx_args)
  {
    gcx_json config view "${args[@]+"${args[@]}"}"
    printf '\n----\n'
    gcx_json datasources list "${args[@]+"${args[@]}"}"
  } | python3 -I -c '
import json, re, sys
cfg_txt, ds_txt = sys.stdin.read().split("\n----\n")
cfg = json.loads(cfg_txt); ds = json.loads(ds_txt).get("datasources", [])
ctx_name = sys.argv[1] or cfg.get("current-context", "")
stack_name = cfg.get("contexts", {}).get(ctx_name, {}).get("stack", "")
stack = cfg.get("stacks", {}).get(stack_name, {})
g = stack.get("grafana", {})
def pick(kind, suffix):
    found = [d for d in ds if d.get("type") == kind]
    found.sort(key=lambda d: (not d["name"].endswith(suffix), d["name"]))
    return found[0] if found else {}
t = pick("tempo", "-traces")
p = pick("prometheus", "-prom")
i = pick("yesoreyeram-infinity-datasource", "-infinity")
m = re.search(r"tempo-prod-\d+-(prod-[a-z0-9-]+?)\.grafana\.net", t.get("url", ""))
region = m.group(1) if m else ""
out = {
  "context": ctx_name, "server": g.get("server", ""), "slug": stack.get("slug", stack_name),
  "stack_id": g.get("stack-id", ""), "region": region,
  "otlp_endpoint": f"https://otlp-gateway-{region}.grafana.net/otlp" if region else "",
  "otlp_base_url": f"https://otlp-gateway-{region}.grafana.net" if region else "",
  "traces_datasource_uid": t.get("uid", ""), "traces_datasource_name": t.get("name", ""),
  "metrics_datasource_uid": p.get("uid", ""), "metrics_datasource_name": p.get("name", ""),
  "infinity_datasource_uid": i.get("uid", ""),
}
print(json.dumps(out))
' "${GCX_CONTEXT:-}"
}

field() { python3 -I -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))' "$1"; }

cmd_info() {
  local info; info="$(discover)" || die "Could not read the gcx configuration. Run: $0 login <stack URL>"
  if [ "${1:-}" = "--json" ]; then printf '%s\n' "$info"; return; fi
  say "${B}Grafana Cloud stack${N}"
  say "  Grafana URL           $(field server <<<"$info")"
  say "  Stack slug            $(field slug <<<"$info")"
  say "  Instance ID (stack)   $(field stack_id <<<"$info")"
  say "  Region                $(field region <<<"$info")"
  say "  OTLP endpoint         $(field otlp_endpoint <<<"$info")      (Claude Console)"
  say "  OTLP base URL         $(field otlp_base_url <<<"$info")           (OpenRouter)"
  say "  Traces datasource     $(field traces_datasource_name <<<"$info") (uid $(field traces_datasource_uid <<<"$info"))"
  say "  Metrics datasource    $(field metrics_datasource_name <<<"$info") (uid $(field metrics_datasource_uid <<<"$info"), for the history)"
  [ -n "$(field region <<<"$info")" ] || warn "Region not found from the traces datasource URL; copy the OTLP endpoint from grafana.com > your stack > OpenTelemetry."
}

cmd_token() {
  local info; info="$(discover)"
  action <<EOF
Create a Grafana Cloud token that may write traces (both Claude Platform and OpenRouter use it):

  1. Open https://grafana.com/profile/org and choose your organization.
  2. Go to Security > Access Policies > Create access policy.
       Name:   llm-traces-write
       Realm:  your stack ($(field slug <<<"$info"))
       Scopes: traces:write   (nothing else)
  3. On the new policy click Add token, name it (for example claude-and-openrouter), set an
     expiry you are comfortable with, and copy the token (it starts with glc_). It is shown once.

  Shortcut: grafana.com > your stack > OpenTelemetry > Configure can generate a token too; it also
  grants metrics and logs write, which these senders do not need.

Keep the token to paste into the Claude Console and OpenRouter. Do not paste it into the agent's
chat. For the claude-api step, export it in your own shell instead:
  export GRAFANA_OTLP_TOKEN=glc_...
EOF
}

cmd_claude() {
  local info; info="$(discover)"
  local id endpoint
  id="$(field stack_id <<<"$info")"; endpoint="$(field otlp_endpoint <<<"$info")"
  action <<EOF
Send Claude Platform traces to Grafana Cloud (needs the Admin role in the Claude Console):

  1. Open https://platform.claude.com/settings/telemetry-destinations and click Add destination.
  2. Provider: Grafana Cloud. Fill in
       OTLP endpoint:  $endpoint
       Instance ID:    $id
       Token:          the glc_ token from the token step
     (If you pick Custom instead: OTLP endpoint URL = $endpoint and one request header
      Authorization = Basic <base64 of "$id:<token>">. Do not add /v1/traces.)
  3. Content mode: "Metadata only" keeps prompts and responses out of Grafana; "Full content"
     adds them (useful for debugging, but they are then stored in Grafana under its retention).
  4. Workspaces: All, or only the workspaces whose API keys you use (for crok, the workspace of
     the key in crok's sign-in).
  5. Save, then More actions > Test. An "anthropic.test" span should reach Grafana in a minute.
  6. The Delivery column should turn Healthy after your next API request.
EOF
}

cmd_claude_api() {
  local info; info="$(discover)"
  local id endpoint
  id="$(field stack_id <<<"$info")"; endpoint="$(field otlp_endpoint <<<"$info")"
  [ -n "${ANTHROPIC_ADMIN_KEY:-}" ] || die "Set ANTHROPIC_ADMIN_KEY (an Admin API key, sk-ant-admin...) in your shell first."
  [ -n "${GRAFANA_OTLP_TOKEN:-}" ] || die "Set GRAFANA_OTLP_TOKEN (the glc_ token with traces:write) in your shell first."
  local content="${CLAUDE_CONTENT_MODE:-metadata_only}"
  say "This adds a telemetry destination to your Claude organization:"
  say "  endpoint $endpoint, instance $id, content mode $content, all workspaces."
  if [ "${YES:-}" != "1" ]; then
    if [ -t 0 ]; then read -r -p "Add it? [y/N] " reply; [ "$reply" = y ] || [ "$reply" = Y ] || die "Not added."
    else die "Not added: rerun with YES=1 after the user agrees."; fi
  fi
  # Secrets travel in the environment and through stdin / a file descriptor, never as command-line
  # arguments, so they do not show in the process list.
  OTLP_AUTH="$(printf '%s:%s' "$id" "$GRAFANA_OTLP_TOKEN" | base64 | tr -d '\n')" \
  OTLP_ENDPOINT="$endpoint" CONTENT_MODE="$content" python3 -I -c '
import json, os
print(json.dumps({"endpoint_url": os.environ["OTLP_ENDPOINT"],
                  "headers": {"Authorization": "Basic " + os.environ["OTLP_AUTH"]},
                  "traces": {"content_mode": os.environ["CONTENT_MODE"]}, "workspaces": {"type": "all"}}))' |
  curl --fail-with-body -sS https://api.anthropic.com/v1/organizations/telemetry_destinations \
    -H @<(printf 'x-api-key: %s\n' "$ANTHROPIC_ADMIN_KEY") -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: telemetry-destinations-2026-08-11" -H "content-type: application/json" --data-binary @- |
  python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("Destination", d.get("id"), "created.")'
  ok "Now open https://platform.claude.com/settings/telemetry-destinations and use More actions > Test."
}

cmd_openrouter() {
  local info; info="$(discover)"
  action <<EOF
Send OpenRouter traces to Grafana Cloud:

  1. Open https://openrouter.ai/settings/observability and turn on Broadcast.
  2. Add the Grafana Cloud destination:
       Base URL:     $(field otlp_base_url <<<"$info")   (no /otlp at the end)
       Instance ID:  $(field stack_id <<<"$info")
       API key:      the glc_ token from the token step
  3. Optional: Privacy mode strips prompts and responses (tokens, cost and timing still arrive);
     Sampling 1.0 sends every request; API key filters limit which keys are traced.
  4. Click Test Connection, then save. Two "Test Generation" traces appear in Grafana.
  5. Tip: give each app or machine its own OpenRouter API key, and send a session_id (or the
     x-session-id header) and user, so spend can be split by key, session and user.
EOF
}

cmd_verify() {
  need_gcx
  local wait_min=0
  if [ "${1:-}" = "--wait" ]; then wait_min="${2:-10}"; fi
  local info uid; info="$(discover)"; uid="$(field traces_datasource_uid <<<"$info")"
  [ -n "$uid" ] || die "No traces (Tempo) datasource found in this stack."
  local deadline=$(( $(date +%s) + wait_min * 60 ))
  while :; do
    local found_claude found_or
    found_claude="$(gcx_json traces metrics -d "$uid" "{resource.service.name=\"$CLAUDE_SERVICE\"}|count_over_time() by(name)" --since 1h --step 1m | python3 -I -c '
import json,sys
d=json.load(sys.stdin); out=[]
for s in d.get("series") or []:
    name=[list(l["value"].values())[0] for l in s["labels"] if l["key"]=="name"]
    n=int(sum(x.get("value",0) for x in s.get("samples",[])))
    if n: out.append(f"{name[0] if name else s}: {n}")
print(", ".join(out))' 2>/dev/null || true)"
    found_or="$(gcx_json traces metrics -d "$uid" "{resource.service.name=\"$OPENROUTER_SERVICE\"}|count_over_time() by(span.gen_ai.request.model)" --since 1h --step 1m | python3 -I -c '
import json,sys
d=json.load(sys.stdin); out=[]
for s in d.get("series") or []:
    name=[str(list(l["value"].values())[0]) for l in s["labels"] if l["key"]!="__name__"]
    n=int(sum(x.get("value",0) for x in s.get("samples",[])))
    label = name[0] if name else "(no model)"
    if n: out.append(f"{label}: {n}")
print(", ".join(out))' 2>/dev/null || true)"
    if [ -n "$found_claude" ]; then ok "Claude Platform spans in the last hour: $found_claude"; else warn "No Claude Platform spans in the last hour."; fi
    if [ -n "$found_or" ]; then ok "OpenRouter spans in the last hour: $found_or"; else warn "No OpenRouter spans in the last hour."; fi
    if { [ -n "$found_claude" ] && [ -n "$found_or" ]; } || [ "$(date +%s)" -ge "$deadline" ]; then break; fi
    say "Waiting 30 s for spans… (send a request, or press Test in the Claude Console / OpenRouter)"
    sleep 30
  done
  if [ -z "$found_claude" ] || [ -z "$found_or" ]; then
    action <<EOF
Send one request through each provider (any small prompt), or use the Test buttons:
  Claude Console > Settings > OpenTelemetry > More actions > Test   (span "anthropic.test")
  OpenRouter > Settings > Observability > Test Connection            (trace "Test Generation")
Spans take about a minute to arrive. If the Claude destination shows Failing, hover it:
401/403 = wrong token or instance ID, 404 = wrong endpoint path.
EOF
  fi
}

cmd_dashboards() {
  need_gcx
  command -v python3 >/dev/null 2>&1 || die "python3 is needed."
  local info uid name puid pname iuid args=()
  info="$(discover)"; uid="$(field traces_datasource_uid <<<"$info")"; name="$(field traces_datasource_name <<<"$info")"
  puid="$(field metrics_datasource_uid <<<"$info")"; pname="$(field metrics_datasource_name <<<"$info")"
  iuid="$(field infinity_datasource_uid <<<"$info")"
  [ -n "$uid" ] || die "No traces (Tempo) datasource found in this stack."
  [ -n "$puid" ] || die "No Prometheus datasource found in this stack (needed for the history)."
  while IFS= read -r a; do args+=("$a"); done < <(ctx_args)
  python3 -I "$HERE/build_dashboards.py" --datasource-uid "$uid" --datasource-name "$name" --folder-uid "$FOLDER_UID" \
    --prometheus-uid "$puid" --prometheus-name "$pname" --rules-out "$RULES_FILE" \
    ${iuid:+--infinity-uid "$iuid"} --backfill "$BACKFILL_FILE" \
    --claude-service "$CLAUDE_SERVICE" --openrouter-service "$OPENROUTER_SERVICE" --out "$DASHBOARDS_DIR" >/dev/null
  ok "Built the dashboards in $DASHBOARDS_DIR"
  gcx resources validate -p "$DASHBOARDS_DIR" "${args[@]+"${args[@]}"}" >/dev/null 2>&1 || die "gcx validation failed: gcx resources validate -p $DASHBOARDS_DIR"
  gcx resources push -p "$DASHBOARDS_DIR" --dry-run "${args[@]+"${args[@]}"}" >/dev/null 2>&1 || die "Dry run failed: gcx resources push -p $DASHBOARDS_DIR --dry-run"
  gcx resources push -p "$DASHBOARDS_DIR" "${args[@]+"${args[@]}"}" >/dev/null 2>&1 || die "Push failed: gcx resources push -p $DASHBOARDS_DIR"
  # The folder exists now; the recording rules go in it as one group, editable in the Grafana UI.
  gcx api "/api/v1/provisioning/folder/$FOLDER_UID/rule-groups/llm-history" -X PUT -H 'X-Disable-Provenance: true' \
    -d @"$RULES_FILE" "${args[@]+"${args[@]}"}" >/dev/null 2>&1 || die "Installing the recording rules failed: $RULES_FILE"
  local server; server="$(field server <<<"$info")"
  ok "Pushed to folder \"LLM Observability\" and installed the llm-history recording rules (every 10 minutes):"
  for d in "${DASHBOARD_UIDS[@]}"; do say "  $server/d/$d"; done
  say "LLM Spend History fills from now on; the trace dashboards show the last 24 hours right away."
}

cmd_snapshot() {
  need_gcx
  local dir="${1:-$PWD/llm-dashboard-snapshots}"; mkdir -p "$dir"
  GCX_AGENT_MODE=true gcx dashboards snapshot "${DASHBOARD_UIDS[@]}" --output-dir "$dir" --since 24h --width 1920 --theme dark --timeout 3m >/dev/null
  ok "PNGs in $dir"; ls -1 "$dir"/*.png
}

has_key() {  # an environment variable, or else a Keychain item of this user
  [ -n "${!1:-}" ] || security find-generic-password -a "$USER" -s "$2" >/dev/null 2>&1
}

cmd_backfill() {
  need_gcx
  local info puid; info="$(discover)"; puid="$(field metrics_datasource_uid <<<"$info")"
  [ -n "$puid" ] || die "No Prometheus datasource found in this stack."
  local skip=()
  if ! has_key ANTHROPIC_ADMIN_KEY llm-backfill-anthropic-admin || ! has_key OPENROUTER_MANAGEMENT_KEY llm-backfill-openrouter-management; then
    action <<EOF
The backfill reads the providers' usage APIs, which need keys the tracing setup did not:

  Claude:      an Admin API key (sk-ant-admin...), made by an org admin at
               https://platform.claude.com/settings/admin-keys
  OpenRouter:  a management key, from https://openrouter.ai/settings/management-keys

Store each one in the macOS Keychain from your own Terminal (it asks for the key twice, hidden):

  security add-generic-password -U -a "\$USER" -s llm-backfill-anthropic-admin -w
  security add-generic-password -U -a "\$USER" -s llm-backfill-openrouter-management -w

(or export ANTHROPIC_ADMIN_KEY / OPENROUTER_MANAGEMENT_KEY in the shell that runs this step).
Do not paste the keys into the agent's chat. Both keys can do more than read usage: delete them
when the backfill is done if you do not want to keep them.
EOF
    has_key ANTHROPIC_ADMIN_KEY llm-backfill-anthropic-admin || skip+=(--skip-claude)
    has_key OPENROUTER_MANAGEMENT_KEY llm-backfill-openrouter-management || skip+=(--skip-openrouter)
    [ "${#skip[@]}" -lt 2 ] || return 1
    warn "Only one key is there; fetching that provider alone (${skip[*]})."
  fi
  python3 -I "$HERE/backfill.py" fetch --prometheus-uid "$puid" --out "$BACKFILL_FILE" "${skip[@]+"${skip[@]}"}" "$@" ||
    die "The backfill did not finish; nothing was changed in Grafana."
  cmd_dashboards
  ok "LLM Spend History now adds the backfilled days. Check it with: $0 snapshot"
}

pause() { if [ -t 0 ]; then read -r -p "Press Enter when done… " _; else say "(Run the next step when the user is done.)"; fi; }

cmd_all() {
  cmd_install
  if ! gcx config check >/dev/null 2>&1; then
    local url="${1:-}"
    if [ -z "$url" ] && [ -t 0 ]; then read -r -p "Grafana Cloud stack URL (https://<stack>.grafana.net): " url; fi
    cmd_login "$url"
  fi
  cmd_info
  cmd_token; pause
  cmd_claude; pause
  cmd_openrouter; pause
  cmd_verify --wait 5
  cmd_dashboards
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    help|-h|--help) cmd_help ;;
    install) cmd_install ;;
    login) cmd_login "$@" ;;
    info) cmd_info "$@" ;;
    token) cmd_token ;;
    claude) cmd_claude ;;
    claude-api) cmd_claude_api ;;
    openrouter) cmd_openrouter ;;
    verify) cmd_verify "$@" ;;
    dashboards) cmd_dashboards ;;
    snapshot) cmd_snapshot "$@" ;;
    backfill) cmd_backfill "$@" ;;
    all) cmd_all "$@" ;;
    *) cmd_help; exit 2 ;;
  esac
}

main "$@"
