#!/usr/bin/env bash
# Print the Cargo package names of crates under crates/codegen touched between
# BASE and HEAD, one per line. Workspace-wide inputs (root manifest, lockfile,
# toolchain pin) select every codegen crate.
set -euo pipefail

base=${1:?usage: changed-codegen-crates.sh <base-ref> [head-ref]}
head=${2:-HEAD}

changed=$(git diff --name-only "$base...$head")

# package name <TAB> crate directory relative to the workspace root
packages=$(cargo metadata --no-deps --format-version 1 --locked |
  jq -r --arg root "$(pwd)/" '.packages[]
    | (.manifest_path | ltrimstr($root) | rtrimstr("/Cargo.toml")) as $dir
    | select($dir | startswith("crates/codegen/"))
    | "\(.name)\t\($dir)"')

if grep -qxE 'Cargo\.toml|Cargo\.lock|rust-toolchain\.toml' <<<"$changed"; then
  cut -f1 <<<"$packages" | sort -u
  exit 0
fi

while IFS=$'\t' read -r name dir; do
  if grep -q "^$dir/" <<<"$changed"; then
    echo "$name"
  fi
done <<<"$packages" | sort -u
