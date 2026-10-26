#!/bin/bash
# Runs the eval smoke suite (evals/run.py, cases tagged `smoke`) against the release crok the TUI job
# built, and fails when it regresses against evals/baselines/smoke.json: pass@1 over the shared cases
# drops by more than the allowed margin, or a safety case that always passed fails.
#
#   .github/scripts/release/eval-gate.sh BUILD_DIR
# BUILD_DIR holds crok-<version>-aarch64-apple-darwin.tar.gz (the build-tui artifact).
# Environment: VERSION; OPENROUTER_API_KEY (the "release" environment's CROK_EVAL_OPENROUTER_API_KEY
# secret) for the model the trials use; CROK_EVAL_MODEL (default: the baseline's model); CROK_EVAL_MAX_DROP.
# Without a key the gate is skipped with a warning, so a release is never blocked on a missing secret.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

build="${1:?usage: eval-gate.sh BUILD_DIR}"
version="${VERSION:?VERSION is not set}"
baseline=evals/baselines/smoke.json
# The gate compares pass rates case by case, which says something about crok only when the baseline was
# measured with the same model: run the one it names unless CROK_EVAL_MODEL asks for another.
baseline_model=""
if [[ -f "$baseline" ]]; then
    baseline_model="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("model") or "")' "$baseline")"
fi
model="${CROK_EVAL_MODEL:-${baseline_model:-openrouter/meta/muse-spark-1.3-contributor}}"

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "::warning title=Evals skipped::the release environment has no CROK_EVAL_OPENROUTER_API_KEY secret, so the smoke suite did not run"
    exit 0
fi
if [[ -n "$baseline_model" && "$model" != "$baseline_model" ]]; then
    echo "::warning title=Eval model differs from the baseline::CROK_EVAL_MODEL is $model but $baseline was measured with $baseline_model; a drop may be the model's, not crok's"
fi

bin_dir="$RUNNER_TEMP/eval-crok"
mkdir -p "$bin_dir"
tar -xzf "$build/$(release_tarball "$version")" -C "$bin_dir"
"$bin_dir/crok" version --json

gate=()
if [[ -f "$baseline" ]]; then
    gate=(--gate "$baseline" --max-drop "${CROK_EVAL_MAX_DROP:-0.20}")
else
    echo "::warning title=No eval baseline::$baseline is missing; the run is reported but gates nothing"
fi
python3 evals/run.py run --select smoke --model "$model" --crok "$bin_dir/crok" \
    --trials 2 --jobs 4 --run-id "release-$version-$(date -u +%Y%m%dT%H%M%SZ)" \
    --out "$repo/target/evals/release" "${gate[@]}"
