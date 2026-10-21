#!/bin/bash
# Builds the release crok the way release/publish.sh does (make build, production relay, the Agent
# Observability destination built in) and packs the standalone tarball, signed by Crok Code Signing.
#
#   .github/scripts/release/build-tui.sh OUT
# Writes OUT/crok-<version>-aarch64-apple-darwin.tar.gz and OUT/facts-tui.env (for the notes).
# Environment: CROK_AGENTO11Y_ENV, the contents of the ~/.crok/agento11y.env to build in; CROK_CODESIGN_DIR.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

out="${1:?usage: build-tui.sh OUT}"
version="$(tr -d '[:space:]' < VERSION)"
mkdir -p "$out"

[[ -n "${CROK_AGENTO11Y_ENV:-}" ]] \
    || fail "the release environment has no CROK_AGENTO11Y_ENV secret (the ~/.crok/agento11y.env every release builds in); run release/ci-secrets.sh"
agento11y_env="$RUNNER_TEMP/agento11y.env"
(umask 077 && printf '%s\n' "$CROK_AGENTO11Y_ENV" > "$agento11y_env")
check_agento11y_env "$agento11y_env"

# --locked: the release builds exactly the dependencies in Cargo.lock.
make build CARGO="cargo --locked" CROK_RELAY_ENV=prod CROK_AGENTO11Y_BUILTIN_ENV="$agento11y_env"
harness=target/release/xai-grok-pager
built="$(crok_version_field "$harness" release)"
[[ "$built" == "$version" ]] || fail "the built crok carries release $built, not $version"
check_destination "$harness"
check_relay "$harness"

staging="$RUNNER_TEMP/crok-tarball"
rm -rf "$staging"
mkdir -p "$staging"
cp "$harness" "$staging/crok"
chmod 755 "$staging/crok"
release/codesign.sh --identifier dev.chenli.crok "$staging/crok"
check_signer "$staging/crok"
tar -czf "$out/$(release_tarball "$version")" -C "$staging" crok

{
    printf 'CROK_VERSION=%s\n' "$(crok_version_field "$staging/crok" currentVersion)"
    printf 'TUI_SDK=%s\n' "$(linked_sdk "$staging/crok")"
} > "$out/facts-tui.env"
cat "$out/facts-tui.env"
ls -l "$out"
