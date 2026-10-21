#!/bin/bash
# Deploys the relay for one environment: the Convex functions to its deployment, then the web app to its Vercel
# project. relay/environments/<env>.env says where; both come from the commit checked out.
#
#   relay/scripts/deploy.sh prod    production: Convex tacit-finch-29, the web at https://crok.chenli.dev
#   relay/scripts/deploy.sh test    development: Convex limitless-badger-727, the web at https://crok-relay.vercel.app
#
# Options:
#   --functions-only   only the Convex functions (and the deployment's settings below)
#   --web-only         only the web app
#   --working-tree     deploy relay/ as it is on disk, uncommitted changes included (default: HEAD)
#
# Before pushing the functions it makes sure the deployment has CROK_WEB_URL and CLERK_JWT_ISSUER_DOMAIN as the
# environment file says, and a device signing key (scripts/generate-keys.mjs) if it has none. The Clerk keys are
# environment variables of the Vercel project (NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY, CLERK_SECRET_KEY, with
# NEXT_PUBLIC_CONVEX_URL); the script checks they are there and match the environment, and never prints them.
#
# The web is deployed from a copy outside the repository: the Vercel CLI sends a git checkout's commit metadata,
# and the Hobby plan refuses ("Not authorized") commits it cannot match to the account, such as co-authored ones.
#
# Needs: Node 20+, the Convex CLI signed in (npx convex login) to the team that owns the deployments, and the Vercel
# CLI signed in (vercel login) to VERCEL_SCOPE (default charrylees-projects).
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
    prod|production) env_name=prod ;;
    test|dev|debug) env_name=dev ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
shift
functions=1
web=1
tree=head
while [[ $# -gt 0 ]]; do
    case "$1" in
        --functions-only) web=0 ;;
        --web-only) functions=0 ;;
        --working-tree) tree=working ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option $1" ;;
    esac
    shift
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
relay="$(cd -- "$script_dir/.." && pwd)"
repo="$(cd -- "$relay/.." && pwd)"
env_file="$relay/environments/$env_name.env"
[[ -f "$env_file" ]] || fail "missing $env_file"
setting() {
    local value
    value="$(sed -n "s/^$1=//p" "$env_file" | tail -n 1)"
    [[ -n "$value" ]] || fail "$env_file sets no $1"
    printf '%s' "$value"
}
deployment="$(setting CONVEX_DEPLOYMENT)"
convex_url="$(setting CONVEX_URL)"
web_url="$(setting WEB_URL)"
project="$(setting VERCEL_PROJECT)"
issuer="$(setting CLERK_ISSUER)"
scope="${VERCEL_SCOPE:-charrylees-projects}"
if [[ "$env_name" == prod ]]; then convex_kind=prod; key_prefix=pk_live_; else convex_kind=dev; key_prefix=pk_test_; fi

commit="$(git -C "$repo" rev-parse --short HEAD)"
say "Relay $env_name from $commit ($tree): Convex $deployment, web $web_url (Vercel $project)"

# A copy of relay/ (and the root .vercelignore, which a project whose Root Directory is relay/ uploads by).
work="$(mktemp -d "${TMPDIR:-/tmp}/crok-relay-deploy.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [[ "$tree" == head ]]; then
    if [[ -n "$(git -C "$repo" status --porcelain -- relay .vercelignore)" ]]; then
        printf 'note: relay/ has uncommitted changes; deploying %s without them (--working-tree includes them)\n' "$commit"
    fi
    git -C "$repo" archive HEAD relay .vercelignore | tar -x -C "$work"
else
    (cd "$repo" && git ls-files -z -co --exclude-standard -- relay .vercelignore | tar -c --null -T - -f -) | tar -x -C "$work"
fi
src="$work/relay"
if [[ -d "$relay/node_modules" ]] && cmp -s "$relay/package-lock.json" "$src/package-lock.json"; then
    cp -cR "$relay/node_modules" "$src/node_modules" 2>/dev/null || cp -R "$relay/node_modules" "$src/node_modules"
else
    say "Installing the relay's packages"
    (cd "$src" && npm ci --no-audit --no-fund >/dev/null)
fi

convex() { (cd "$src" && env CONVEX_DEPLOYMENT="$convex_kind:$deployment" npx --no-install convex "$@"); }

if [[ "$functions" == 1 ]]; then
    say "Convex $convex_kind deployment $deployment"
    # Settings auth.config.ts and deviceAuth.ts read; plain addresses, not secrets.
    for pair in "CROK_WEB_URL=$web_url" "CLERK_JWT_ISSUER_DOMAIN=$issuer"; do
        name="${pair%%=*}"
        value="${pair#*=}"
        current="$(convex env get "$name" --deployment "$deployment" 2>/dev/null || true)"
        if [[ "$current" != "$value" ]]; then
            convex env set "$name" "$value" --deployment "$deployment" >/dev/null
            printf 'set %s=%s\n' "$name" "$value"
        else
            printf '%s=%s\n' "$name" "$value"
        fi
    done
    if ! convex env list --names-only --deployment "$deployment" | grep -qx DEVICE_JWKS_DATA_URI; then
        printf 'no device signing key yet: making one\n'
        (cd "$src" && node scripts/generate-keys.mjs --out "$work/device-keys.env" >/dev/null)
        convex env set --from-file "$work/device-keys.env" --force --deployment "$deployment" >/dev/null
        rm -f "$work/device-keys.env"
    fi
    if [[ "$convex_kind" == prod ]]; then
        convex deploy --typecheck enable --message "relay/scripts/deploy.sh $env_name $commit"
    else
        convex dev --once --typecheck enable
    fi
fi

if [[ "$web" == 1 ]]; then
    say "Vercel project $project"
    project_json="$(vercel api "/v9/projects/$project" --scope "$scope")" || fail "cannot read the Vercel project $project in $scope (vercel login?)"
    read -r project_id org_id root_dir < <(/usr/bin/python3 -c 'import json,sys; p=json.load(sys.stdin); print(p["id"], p["accountId"], p.get("rootDirectory") or ".")' <<<"$project_json")
    # The build needs these for the production target, and the Clerk keys must be the environment's own instance.
    # The listing carries no values; only the two public ones (the Convex address, the publishable key) are read, one
    # at a time, and only the address is ever printed.
    env_ids="$(vercel api "/v9/projects/$project_id/env" --scope "$scope" --raw | /usr/bin/python3 -c '
import json, sys
envs = [e for e in json.load(sys.stdin).get("envs", []) if "production" in (e.get("target") or [])]
ids = {e["key"]: e["id"] for e in envs}
missing = [k for k in ("NEXT_PUBLIC_CONVEX_URL", "NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY", "CLERK_SECRET_KEY") if k not in ids]
for key in missing:
    print(f"deploy: {key} is not set for Production", file=sys.stderr)
print(ids.get("NEXT_PUBLIC_CONVEX_URL", "-"), ids.get("NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY", "-"))
sys.exit(1 if missing else 0)')" || fail "set $project's Production variables first (relay/scripts/vercel-keys.sh $env_name)"
    read -r url_id publishable_id <<<"$env_ids"
    env_value() {
        vercel api "/v1/projects/$project_id/env/$1" --scope "$scope" --raw \
            | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("value") or "")'
    }
    built_url="$(env_value "$url_id")"
    [[ "${built_url%/}" == "$convex_url" ]] \
        || fail "$project's NEXT_PUBLIC_CONVEX_URL is ${built_url:-unreadable}, not $convex_url (relay/scripts/vercel-keys.sh $env_name)"
    [[ "$(env_value "$publishable_id")" == "$key_prefix"* ]] \
        || fail "$project's NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY is not a ${key_prefix}… key (relay/scripts/vercel-keys.sh $env_name)"
    printf 'Production variables: NEXT_PUBLIC_CONVEX_URL=%s, Clerk %s… keys\n' "$built_url" "$key_prefix"
    case "$root_dir" in
        relay) deploy_dir="$work" ;;
        .) deploy_dir="$src" ;;
        *) fail "$project's Root Directory is $root_dir; expected relay" ;;
    esac
    mkdir -p "$deploy_dir/.vercel"
    printf '{"projectId":"%s","orgId":"%s","projectName":"%s"}\n' "$project_id" "$org_id" "$project" > "$deploy_dir/.vercel/project.json"
    url="$(cd "$deploy_dir" && vercel deploy --prod --yes --scope "$scope" 2>"$work/vercel.log")" || { tail -n 30 "$work/vercel.log" >&2; fail "the Vercel deploy failed"; }
    printf 'deployed %s\n' "$url"
    home_status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$web_url/" || true)"
    devices_status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$web_url/devices" || true)"
    printf '%s/ answers %s, /devices answers %s (a redirect to sign-in is expected)\n' "$web_url" "$home_status" "$devices_status"
    [[ "$home_status" == 200 ]] || fail "$web_url/ answered $home_status"
fi

say "Done: relay $env_name at $convex_url, web $web_url, from $commit"
