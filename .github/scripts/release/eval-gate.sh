#!/bin/bash
# Runs the eval smoke suite (evals/run.py, cases tagged `smoke`) against the release crok the TUI job
# built, and fails when it regresses against evals/baselines/smoke.json: pass@1 over the shared cases
# drops by more than the allowed margin, or a safety case that always passed fails.
#
#   .github/scripts/release/eval-gate.sh BUILD_DIR
# BUILD_DIR holds crok-<version>-aarch64-apple-darwin.tar.gz (the build-tui artifact).
# Environment: VERSION; OPENROUTER_API_KEY (the "release" environment's CROK_EVAL_OPENROUTER_API_KEY
# secret) for the model the trials use; CROK_EVAL_MODEL (default below); CROK_EVAL_MAX_DROP.
# Without a key the gate is skipped with a warning, so a release is never blocked on a missing secret.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

build="${1:?usage: eval-gate.sh BUILD_DIR}"
version="${VERSION:?VERSION is not set}"
model="${CROK_EVAL_MODEL:-openrouter/~deepseek/deepseek-flash-latest}"
baseline=evals/baselines/smoke.json

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "::warning title=Evals skipped::the release environment has no CROK_EVAL_OPENROUTER_API_KEY secret, so the smoke suite did not run"
    exit 0
fi

bin_dir="$RUNNER_TEMP/eval-crok"
mkdir -p "$bin_dir"
tar -xzf "$build/$(release_tarball "$version")" -C "$bin_dir"
"$bin_dir/crok" version --json

gate=()
if [[ -f "$baseline" ]]; then
    gate=(--gate "$baseline" --max-drop "${CROK_EVAL_MAX_DROP:-0.15}")
else
    echo "::warning title=No eval baseline::$baseline is missing; the run is reported but gates nothing"
fi
python3 evals/run.py run --select smoke --model "$model" --crok "$bin_dir/crok" \
    --trials 1 --jobs 3 --run-id "release-$version-$(date -u +%Y%m%dT%H%M%SZ)" \
    --out "$repo/target/evals/release" "${gate[@]}"
