#!/usr/bin/env bash
# Writes crok's Agent Observability settings, ~/.crok/agento11y.env (mode 600, outside any repo).
#
#   bash setup.sh --endpoint <Agent Observability API URL> --tenant <instance id> \
#                 --otlp-endpoint <OTLP gateway URL> [--otlp-instance <id>] [--token-stdin]
#
# The values come from the stack's Agent Observability Connection page
# (https://<stack>.grafana.net/plugins/grafana-agento11y-app). The token is a Grafana Cloud
# access policy token (glc_…) with sigil:write, metrics:write, traces:write and logs:write;
# it is asked for with the input hidden (or read from stdin with --token-stdin) and never printed.
# The OTLP gateway takes Basic auth with the OTLP instance id (the tenant id unless given).
set -euo pipefail

die() {
    echo "setup.sh: $*" >&2
    exit 1
}

endpoint="" tenant="" otlp_endpoint="" otlp_instance="" token_stdin=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --endpoint) endpoint="${2:-}"; shift 2 ;;
        --tenant) tenant="${2:-}"; shift 2 ;;
        --otlp-endpoint) otlp_endpoint="${2:-}"; shift 2 ;;
        --otlp-instance) otlp_instance="${2:-}"; shift 2 ;;
        --token-stdin) token_stdin=1; shift ;;
        -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
[[ -n "$endpoint" && -n "$tenant" && -n "$otlp_endpoint" ]] ||
    die "--endpoint, --tenant and --otlp-endpoint are required (see --help)"
otlp_instance="${otlp_instance:-$tenant}"

if [[ "$token_stdin" == 1 ]]; then
    IFS= read -r token || true
else
    read -r -s -p "Access policy token (glc_…): " token
    echo >&2
fi
token="${token//[[:space:]]/}"
[[ -n "$token" ]] || die "no token given"

home="${CROK_HOME:-${GROK_HOME:-$HOME/.crok}}"
mkdir -p "$home"
# `tr -d '\n'`: base64 ends its output with a newline, which breaks the header without an error.
basic="$(printf '%s' "$otlp_instance:$token" | base64 | tr -d '\n')"

umask 077
partial="$(mktemp "$home/agento11y.env.XXXXXX")"
trap 'rm -f "$partial"' EXIT
cat >"$partial" <<EOF
# Grafana Agent Observability for crok, written by setup.sh. It holds a token: keep it mode 600.
# On this machine it replaces the destination built into crok; release builds on this machine carry
# it (the Makefile's CROK_AGENTO11Y_BUILTIN_ENV). AGENTO11Y_ENABLED=false here stops sending.
AGENTO11Y_ENDPOINT=$endpoint
AGENTO11Y_PROTOCOL=http
AGENTO11Y_AUTH_MODE=basic
AGENTO11Y_AUTH_TENANT_ID=$tenant
AGENTO11Y_AUTH_TOKEN=$token
OTEL_EXPORTER_OTLP_ENDPOINT=$otlp_endpoint
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic $basic"
EOF
chmod 600 "$partial"
mv "$partial" "$home/agento11y.env"
trap - EXIT
echo "Wrote $home/agento11y.env (mode 600). Running crok sessions and Crok Desktop conversations pick it up."
echo "It replaces the destination built into crok on this machine, and crok builds made here (make, release/publish.sh) carry it."
