#!/bin/bash
# Lets a relay deployment read its owner's Grafana Cloud stack for the phones' o11y tab (relay/DESIGN.md §3 "o11y"):
# a Viewer service account "crok-relay-o11y" on the stack gcx is signed in to, a token of it for this deployment, and
# the deployment's GRAFANA_URL, GRAFANA_TOKEN and O11Y_VIEWERS.
#
#   relay/scripts/o11y-setup.sh test <viewer>…    the development deployment (the phones' dev builds)
#   relay/scripts/o11y-setup.sh prod <viewer>…    the production one
#   relay/scripts/o11y-setup.sh test --users      list the deployment's accounts, to pick viewers from
#
# A viewer is an account's email, Clerk user id (user_…) or relay users id: only they see the pages, which carry the
# stack's spend and conversation titles. Running it again makes a new token and deletes this deployment's older ones;
# `--viewers-only` changes O11Y_VIEWERS alone; `--grants-only` only gives the account its read access again.
#
# The account's read access, beyond its Viewer role: View on the LLM Observability dashboards' folder (a folder made
# through the API can have no role permissions at all, so a Viewer would not see it) and the Agent Observability
# plugin's "Agento11y Reader" role (its agents, conversations and evaluation APIs).
#
# Needs: gcx signed in to the stack (gcx login <stack> --server https://<stack>.grafana.net --oauth) as someone who
# may manage service accounts, and the Convex CLI signed in to the team that owns the deployments. The token is
# never printed: it goes from gcx's answer into a 0600 file that `convex env set --from-file` reads, then the file is
# deleted.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'o11y-setup: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
    prod|production) env_name=prod; convex_kind=prod ;;
    test|dev|debug) env_name=dev; convex_kind=dev ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
shift
list_users=0
viewers_only=0
grants_only=0
viewers=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --users) list_users=1 ;;
        --viewers-only) viewers_only=1 ;;
        --grants-only) grants_only=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) fail "unknown option $1" ;;
        *) viewers+=("$1") ;;
    esac
    shift
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
relay="$(cd -- "$script_dir/.." && pwd)"
env_file="$relay/environments/$env_name.env"
[[ -f "$env_file" ]] || fail "missing $env_file"
deployment="$(sed -n 's/^CONVEX_DEPLOYMENT=//p' "$env_file" | tail -n 1)"
[[ -n "$deployment" ]] || fail "$env_file sets no CONVEX_DEPLOYMENT"
convex() { (cd "$relay" && env CONVEX_DEPLOYMENT="$convex_kind:$deployment" npx --no-install convex "$@"); }

work="$(mktemp -d "${TMPDIR:-/tmp}/crok-o11y-setup.XXXXXX")"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

if [[ "$list_users" == 1 ]]; then
    say "Accounts on Convex $convex_kind deployment $deployment"
    convex data users --format jsonLines --limit 1000 --deployment "$deployment" | /usr/bin/python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    u = json.loads(line)
    subject = (u.get("tokenIdentifier") or "").split("|")[-1]
    print("%-40s %-34s %s  %s" % (u.get("email") or "-", subject, u["_id"], u.get("name") or ""))'
    exit 0
fi
[[ ${#viewers[@]} -gt 0 || "$grants_only" == 1 ]] || fail "name at least one viewer (an email, user_… or users id); --users lists them"
viewer_list="$(IFS=,; printf '%s' "${viewers[*]:-}")"

# `gcx api` prints hint lines and may spill a large answer to a file; this prints the answer's JSON alone.
gcx_json() {
    gcx api "$@" 2>/dev/null | /usr/bin/python3 -c '
import json, sys
docs = []
for line in sys.stdin:
    line = line.strip()
    if line.startswith(("{", "[")):
        try:
            docs.append(json.loads(line))
        except ValueError:
            pass
docs = [d for d in docs if not (isinstance(d, dict) and d.get("class") == "hint")]
if not docs:
    sys.exit(1)
d = docs[-1]
if isinstance(d, dict) and d.get("type") == "gcx.spill_reference":
    d = json.load(open(d["spilled_to"]))
if isinstance(d, dict) and d.get("type") == "gcx.error":
    print(json.dumps(d.get("error")), file=sys.stderr)
    sys.exit(1)
json.dump(d, sys.stdout)'
}

grafana_url="$(gcx config view --minify -o json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
text = sys.stdin.read()
doc = json.loads(text[text.index("{\n"):])
name = doc["current-context"]
stack = (doc.get("contexts") or {}).get(name, {}).get("stack") or name
print(doc["stacks"][stack]["grafana"]["server"].rstrip("/"))')" || fail "gcx is not signed in to a stack (gcx login <stack> --server https://<stack>.grafana.net --oauth)"

if [[ "$viewers_only" == 0 ]]; then
    say "Service account crok-relay-o11y on $grafana_url"
    account_id="$(gcx_json "/api/serviceaccounts/search?query=crok-relay-o11y" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
for a in d.get("serviceAccounts") or []:
    if a.get("name") == "crok-relay-o11y":
        print(a["id"]); break')" || fail "cannot list service accounts on $grafana_url (does your gcx sign-in manage them?)"
    if [[ -z "$account_id" ]]; then
        [[ "$grants_only" == 0 ]] || fail "there is no crok-relay-o11y service account yet: run without --grants-only"
        printf '{"name":"crok-relay-o11y","role":"Viewer","isDisabled":false}' > "$work/account.json"
        account_id="$(gcx_json /api/serviceaccounts -X POST -d "@$work/account.json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" \
            || fail "cannot create the service account"
        printf 'made service account %s (Viewer)\n' "$account_id"
    else
        printf 'service account %s\n' "$account_id"
    fi

    # Read access beyond the Viewer role: the dashboards' folder, and Agent Observability's reader role.
    folder="$(gcx_json /api/dashboards/uid/llm-overview | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["meta"].get("folderUid") or "")')" \
        || fail "cannot read the llm-overview dashboard (observability/grafana-llm/setup.sh dashboards pushes it)"
    if [[ -n "$folder" ]]; then
        printf '{"permission":"View"}' > "$work/view.json"
        gcx_json "/api/access-control/folders/$folder/serviceAccounts/$account_id" -X POST -d "@$work/view.json" >/dev/null \
            || fail "cannot give the service account View on folder $folder"
        printf 'View on folder %s\n' "$folder"
    fi
    role="$(gcx_json "/api/access-control/roles?delegatable=false" | /usr/bin/python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r.get("name") == "plugins:grafana-agento11y-app:agento11y-reader":
        print(r["uid"]); break')"
    if [[ -n "$role" ]]; then
        has="$(gcx_json "/api/access-control/users/$account_id/roles" | /usr/bin/python3 -c '
import json, sys
print("yes" if any(r.get("uid") == sys.argv[1] for r in json.load(sys.stdin) or []) else "")' "$role")"
        if [[ -z "$has" ]]; then
            printf '{"roleUid":"%s","global":false}' "$role" > "$work/role.json"
            gcx_json "/api/access-control/users/$account_id/roles" -X POST -d "@$work/role.json" >/dev/null \
                || fail "cannot give the service account the Agento11y Reader role"
        fi
        printf 'role Agento11y Reader (agents, conversations, evaluation)\n'
    else
        printf 'note: no Agent Observability plugin on this stack; its pages will show errors\n'
    fi
fi

if [[ "$viewers_only" == 0 && "$grants_only" == 0 ]]; then
    old_tokens="$(gcx_json "/api/serviceaccounts/$account_id/tokens" | /usr/bin/python3 -c '
import json, sys
for t in json.load(sys.stdin) or []:
    if str(t.get("name", "")).startswith(sys.argv[1] + "-"):
        print(t["id"])' "$deployment")"
    token_name="$deployment-$(date -u +%Y%m%dT%H%M%SZ)"
    printf '{"name":"%s"}' "$token_name" > "$work/token-request.json"
    umask 077
    gcx_json "/api/serviceaccounts/$account_id/tokens" -X POST -d "@$work/token-request.json" | /usr/bin/python3 -c '
import json, sys
key = json.load(sys.stdin).get("key") or ""
if not key.startswith("glsa_"):
    sys.exit("no token in the answer")
with open(sys.argv[1], "w") as f:
    f.write(f"GRAFANA_URL={sys.argv[2]}\nGRAFANA_TOKEN={key}\n")' "$work/grafana.env" "$grafana_url" \
        || fail "cannot make a token"
    printf 'made token %s\n' "$token_name"

    say "Convex $convex_kind deployment $deployment"
    convex env set --from-file "$work/grafana.env" --force --deployment "$deployment" >/dev/null
    rm -f "$work/grafana.env"
    printf 'set GRAFANA_URL=%s and GRAFANA_TOKEN (not shown)\n' "$grafana_url"
    for old in $old_tokens; do
        gcx_json "/api/serviceaccounts/$account_id/tokens/$old" -X DELETE >/dev/null && printf 'deleted older token %s\n' "$old"
    done
fi

if [[ "$grants_only" == 0 ]]; then
    convex env set O11Y_VIEWERS "$viewer_list" --deployment "$deployment" >/dev/null
    printf 'set O11Y_VIEWERS=%s\n' "$viewer_list"
fi

say "Checking: o11y:check builds the home page with the token"
convex run o11y:check '{"page":"home"}' --deployment "$deployment" || fail "o11y:check failed: are the functions deployed (relay/scripts/deploy.sh $env_name --functions-only)?"
