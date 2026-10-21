#!/bin/bash
# Puts one environment's keys into its Vercel project, straight from the Clerk and Convex CLIs. Nothing is printed;
# the keys pass through a private temporary folder that is deleted at the end.
#
#   relay/scripts/vercel-keys.sh prod   Clerk production instance → crok-relay-prod (Production), and a Convex deploy
#                                       key for tacit-finch-29, so builds of main push the functions too
#   relay/scripts/vercel-keys.sh test   Clerk development instance → crok-relay (Production and Preview)
#
# Sets NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY, CLERK_SECRET_KEY (sensitive) and NEXT_PUBLIC_CONVEX_URL, replacing what is
# there. Run it after `clerk deploy` made the production instance, or after rotating a key; then deploy the web
# (relay/scripts/deploy.sh <env> --web-only), since a build reads the keys when it runs.
#
# Options: --no-deploy-key (prod: leave CONVEX_DEPLOY_KEY alone).
# Needs the Clerk CLI (clerk auth login), the Convex CLI and the Vercel CLI signed in.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
fail() { printf 'vercel-keys: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
    prod|production) env_name=prod; clerk_instance=prod; targets=production ;;
    test|dev|debug) env_name=dev; clerk_instance=dev; targets="production preview" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
shift
deploy_key=1
[[ "${1:-}" == --no-deploy-key ]] && deploy_key=0

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
relay="$(cd -- "$script_dir/.." && pwd)"
env_file="$relay/environments/$env_name.env"
setting() { sed -n "s/^$1=//p" "$env_file" | tail -n 1; }
project="$(setting VERCEL_PROJECT)"
convex_url="$(setting CONVEX_URL)"
deployment="$(setting CONVEX_DEPLOYMENT)"
clerk_app="$(setting CLERK_APP)"
scope="${VERCEL_SCOPE:-charrylees-projects}"
[[ -n "$project" && -n "$convex_url" && -n "$clerk_app" ]] || fail "$env_file needs VERCEL_PROJECT, CONVEX_URL and CLERK_APP"

work="$(mktemp -d "${TMPDIR:-/tmp}/crok-vercel-keys.XXXXXX")"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

# From relay/, where the Clerk CLI sees Next.js and names the key NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY (elsewhere it
# writes CLERK_PUBLISHABLE_KEY, which is read too).
(cd "$relay" && clerk env pull --app "$clerk_app" --instance "$clerk_instance" --file "$work/clerk.env") >/dev/null 2>&1 \
    || fail "clerk env pull failed (is the $clerk_instance instance there? clerk deploy status)"
key() { sed -n "s/^$1=//p" "$work/clerk.env" | tail -n 1 | sed -e 's/^"//' -e 's/"$//'; }
publishable="$(key NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY)"
[[ -n "$publishable" ]] || publishable="$(key CLERK_PUBLISHABLE_KEY)"
secret="$(key CLERK_SECRET_KEY)"
expected_prefix=pk_test_
[[ "$env_name" == prod ]] && expected_prefix=pk_live_
[[ "$publishable" == "$expected_prefix"* ]] || fail "Clerk gave no ${expected_prefix}… publishable key for the $clerk_instance instance"
[[ -n "$secret" ]] || fail "Clerk gave no secret key for the $clerk_instance instance"

put() { # name, value, extra flags…; once per target, since `vercel env add` takes one
    local name="$1" value="$2" target
    shift 2
    for target in $targets; do
        printf '%s' "$value" | vercel env add "$name" "$target" --project "$project" --scope "$scope" --force --yes "$@" \
            >/dev/null 2>"$work/vercel.log" || { tail -n 5 "$work/vercel.log" >&2; fail "could not set $name for $target on $project"; }
        printf 'set %s on %s (%s)\n' "$name" "$project" "$target"
    done
}
put NEXT_PUBLIC_CONVEX_URL "$convex_url" --no-sensitive
put NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY "$publishable" --no-sensitive
put CLERK_SECRET_KEY "$secret" --sensitive

if [[ "$env_name" == prod && "$deploy_key" == 1 ]]; then
    token="$(cd "$relay" && env CONVEX_DEPLOYMENT="prod:$deployment" npx --yes convex deployment token create \
        "vercel-$project-$(date +%Y%m%d)" --deployment "$deployment" 2>/dev/null | tail -n 1)"
    [[ "$token" == prod:* ]] || fail "Convex did not make a production deploy key"
    targets=production put CONVEX_DEPLOY_KEY "$token" --sensitive
fi
printf 'Next: relay/scripts/deploy.sh %s --web-only\n' "$([[ "$env_name" == prod ]] && echo prod || echo test)"
