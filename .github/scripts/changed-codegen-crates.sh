#!/usr/bin/env bash
# Print the Cargo package names of crates under crates/codegen, one per line:
# every one with --all, otherwise those touched between BASE and HEAD.
set -euo pipefail

usage='usage: changed-codegen-crates.sh --all | <base-ref> [head-ref]'
base=${1:?$usage}
head=${2:-HEAD}

# package name <TAB> crate directory relative to the workspace root
packages=$(cargo metadata --no-deps --format-version 1 --locked |
  jq -r --arg root "$(pwd)/" '.packages[]
    | (.manifest_path | ltrimstr($root) | rtrimstr("/Cargo.toml")) as $dir
    | select($dir | startswith("crates/codegen/"))
    | "\(.name)\t\($dir)"')

if [ "$base" = --all ]; then
  cut -f1 <<<"$packages" | sort -u
  exit 0
fi

changed=$(git diff --name-only "$base...$head")

while IFS=$'\t' read -r name dir; do
  if grep -q "^$dir/" <<<"$changed"; then
    echo "$name"
  fi
done <<<"$packages" | sort -u
