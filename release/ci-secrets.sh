#!/bin/bash
# Gives the release workflow (.github/workflows/release.yml) what it builds and signs with, as secrets of
# the repository's "release" environment, which only main (and each --branch) may use. Run it on the Mac
# that publishes releases, once, and again after changing any of the files below.
#
#   release/ci-secrets.sh [--branch NAME]... [--only SECRET]... [--dry-run]
#
#   Secret                          From
#   CROK_RELEASE_SIGNING_KEY        ~/.ssh/crok-release (SIGN_KEY): signs SHA256SUMS.txt
#   CROK_CODESIGN_KEYCHAIN          ~/.crok-codesign/crok-codesign.keychain-db, base64 (CROK_CODESIGN_DIR) and
#   CROK_CODESIGN_PASSWORD          ~/.crok-codesign/password: the "Crok Code Signing" identity
#   CROK_AGENTO11Y_ENV              ~/.crok/agento11y.env (CROK_AGENTO11Y_BUILTIN_ENV): the destination built in
#   CROK_ANDROID_KEYSTORE_BASE64    ~/.crok-android/release.p12, base64 (CROK_ANDROID_DIR),
#   CROK_ANDROID_KEYSTORE_PASSWORD  ~/.crok-android/password and
#   CROK_ANDROID_KEY_ALIAS          its key, crok: the key every release's APK is signed with
#   CROK_EVAL_OPENROUTER_API_KEY    OPENROUTER_API_KEY, else crok's OpenRouter sign-in (~/.crok/provider-auth/
#                                   openrouter.json): the eval job's smoke suite (optional; without it the job
#                                   warns and passes)
#
# It checks the first two against release/crok-release.pub and release/crok-codesign.pem, and makes the
# Android key on first use (RSA 3072, 30 years). Keep ~/.crok-android private and backed up, like the other
# two: Android installs an APK over another only when the same key signed both. Only the secrets' names are
# printed. --branch lets another branch use the environment too, for a dry run of the workflow from it.
# --only sets just the secrets it names (say, after changing the OpenRouter key). --dry-run checks everything
# and changes nothing. Environment: REPO (default CharryLee0426/crok-build).
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
cd "$repo_dir"
fail() { printf 'ci-secrets: %s\n' "$*" >&2; exit 1; }
# shellcheck source=release/lib.sh
source release/lib.sh

github_repo="${REPO:-CharryLee0426/crok-build}"
sign_key="${SIGN_KEY:-$HOME/.ssh/crok-release}"
codesign_dir="${CROK_CODESIGN_DIR:-$HOME/.crok-codesign}"
agento11y_env="${CROK_AGENTO11Y_BUILTIN_ENV:-$HOME/.crok/agento11y.env}"
android_dir="${CROK_ANDROID_DIR:-$HOME/.crok-android}"
openrouter_auth="${CROK_OPENROUTER_AUTH:-$HOME/.crok/provider-auth/openrouter.json}"
android_alias=crok
environment=release
secrets="CROK_RELEASE_SIGNING_KEY CROK_CODESIGN_KEYCHAIN CROK_CODESIGN_PASSWORD CROK_AGENTO11Y_ENV \
CROK_ANDROID_KEYSTORE_BASE64 CROK_ANDROID_KEYSTORE_PASSWORD CROK_ANDROID_KEY_ALIAS CROK_EVAL_OPENROUTER_API_KEY"
branches=(main)
only=""
dry_run=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) branches+=("${2:?--branch needs a name}"); shift 2 ;;
        --only)
            [[ " $secrets " == *" ${2:?--only needs a secret name} "* ]] || fail "no secret named $2"
            only+="$2 "; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h | --help) sed -n '2,25p' "$0"; exit 0 ;;
        *) fail "unknown option $1" ;;
    esac
done
[[ -z "$only" ]] || secrets="${only% }"
selected() { [[ " $secrets " == *" $1 "* ]]; }

# The OpenRouter key the eval job's trials use, on stdout (the script never prints it).
openrouter_key() {
    if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
        printf '%s' "$OPENROUTER_API_KEY"
    elif [[ -f "$openrouter_auth" ]]; then
        /usr/bin/python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("access_token") or "", end="")' "$openrouter_auth"
    fi
}
if selected CROK_EVAL_OPENROUTER_API_KEY && [[ -z "$(openrouter_key)" ]]; then
    [[ -z "$only" ]] || fail "no OpenRouter key: set OPENROUTER_API_KEY or sign crok in (crok login openrouter)"
    printf 'No OpenRouter key (OPENROUTER_API_KEY or crok login openrouter): leaving CROK_EVAL_OPENROUTER_API_KEY out; the eval job will warn and pass.\n'
    secrets="${secrets/ CROK_EVAL_OPENROUTER_API_KEY/}"
fi

# What the workflow will sign with must be what installed copies trust.
[[ -f "$sign_key" ]] || fail "no release signing key at $sign_key"
grep -qF "$(ssh-keygen -y -f "$sign_key" | cut -d ' ' -f 1,2)" release/crok-release.pub \
    || fail "$sign_key is not one of the keys in release/crok-release.pub"
[[ -f "$codesign_dir/crok-codesign.keychain-db" && -f "$codesign_dir/password" ]] \
    || fail "no Crok Code Signing identity in $codesign_dir (copy the folder from the Mac that has it; see release/README.md)"
certificate="$(CROK_CODESIGN_DIR="$codesign_dir" release/codesign.sh --certificate | fingerprint)"
[[ "$certificate" == "$(pinned_signer)" ]] \
    || fail "$codesign_dir holds certificate $certificate, not release/crok-codesign.pem's $(pinned_signer)"
check_agento11y_env "$agento11y_env"
if [[ "$dry_run" == 0 ]]; then
    gh auth status > /dev/null 2>&1 || fail "gh is not signed in (gh auth login)"
fi

if [[ ! -f "$android_dir/release.p12" ]]; then
    [[ ! -e "$android_dir" ]] || fail "$android_dir exists but holds no release.p12; move it aside to make a new key"
    if [[ "$dry_run" == 1 ]]; then
        printf 'Would make the Android release key in %s\n' "$android_dir"
    else
        staging="$(mktemp -d "$(dirname "$android_dir")/.crok-android.XXXXXX")"
        trap 'rm -rf "$staging"' EXIT
        chmod 700 "$staging"
        (umask 077 && /usr/bin/openssl rand -hex 24 | tr -d '\n' > "$staging/password")
        (umask 077 && keytool -genkeypair -keystore "$staging/release.p12" -storetype PKCS12 -storepass:file "$staging/password" \
            -alias "$android_alias" -keyalg RSA -keysize 3072 -validity 10950 -dname "CN=Crok, O=crok-build" > /dev/null 2>&1) \
            || fail "keytool could not make the Android key (it needs a JDK: /usr/libexec/java_home -V)"
        mv "$staging" "$android_dir"
        trap - EXIT
        printf 'Made the Android release key in %s. Back that folder up: every later APK must be signed by it.\n' "$android_dir"
    fi
fi

if [[ "$dry_run" == 1 ]]; then
    printf 'Checked. Would set the %s environment of %s (branches: %s) and its secrets:\n' "$environment" "$github_repo" "${branches[*]}"
    # shellcheck disable=SC2086 # one name per word
    printf '  %s\n' $secrets
    exit 0
fi

# Only the branches named here may run jobs in the environment, so only they see its secrets.
gh api -X PUT "repos/$github_repo/environments/$environment" --input - > /dev/null \
    <<< '{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
allowed="$(gh api "repos/$github_repo/environments/$environment/deployment-branch-policies" --jq '.branch_policies[].name')"
for branch in "${branches[@]}"; do
    if ! grep -qxF "$branch" <<< "$allowed"; then
        gh api -X POST "repos/$github_repo/environments/$environment/deployment-branch-policies" \
            -f name="$branch" -f type=branch > /dev/null
    fi
done
printf 'Environment %s of %s: branches %s\n' "$environment" "$github_repo" "$(gh api "repos/$github_repo/environments/$environment/deployment-branch-policies" --jq '[.branch_policies[].name] | join(", ")')"

# The value comes on stdin, so it is never on a command line. Secrets --only leaves out are not touched.
set_secret() {
    if ! selected "$1"; then
        cat > /dev/null
        return
    fi
    gh secret set "$1" --env "$environment" -R "$github_repo" > /dev/null
    printf 'set %s\n' "$1"
}
set_secret CROK_RELEASE_SIGNING_KEY < "$sign_key"
base64 < "$codesign_dir/crok-codesign.keychain-db" | tr -d '\n' | set_secret CROK_CODESIGN_KEYCHAIN
tr -d '\n' < "$codesign_dir/password" | set_secret CROK_CODESIGN_PASSWORD
set_secret CROK_AGENTO11Y_ENV < "$agento11y_env"
base64 < "$android_dir/release.p12" | tr -d '\n' | set_secret CROK_ANDROID_KEYSTORE_BASE64
tr -d '\n' < "$android_dir/password" | set_secret CROK_ANDROID_KEYSTORE_PASSWORD
printf '%s' "$android_alias" | set_secret CROK_ANDROID_KEY_ALIAS
if selected CROK_EVAL_OPENROUTER_API_KEY; then
    openrouter_key | set_secret CROK_EVAL_OPENROUTER_API_KEY
fi
printf 'Done. The next merge into main that bumps VERSION releases it (.github/workflows/release.yml).\n'
