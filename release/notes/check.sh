#!/bin/bash
# Checks the release notes of the repository's VERSION, release/notes/v<version>/: the English, then the
# translations into 简体中文, 日本語, Español, Français and Deutsch, naming every file the release carries.
#
#   release/notes/check.sh                the notes of VERSION
#   release/notes/check.sh --unreleased   only while VERSION has no tag on origin, as in a pull request into
#                                         main: merging it makes that release (.github/workflows/release.yml)
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

version="$(tr -d '[:space:]' < VERSION)"
tag="desktop-v$version"
case "${1:-}" in
    "") ;;
    --unreleased)
        if [[ -n "$(remote_tag_commit "$tag")" ]]; then
            printf 'Crok %s is released already (%s): merging this makes no release, so there are no notes to check.\n' "$version" "$tag"
            exit 0
        fi
        ;;
    *) fail "unknown option $1" ;;
esac

notes="release/notes/v$version"
[[ -d "$notes" ]] || fail "VERSION is $version, which is not released yet, but $notes holds no notes for it. Write en.md, zh.md, ja.md, es.md, fr.md and de.md there (start from the last release's), or keep VERSION at the released number."
expect=()
while IFS= read -r file; do expect+=(--expect "$file"); done < <(release_files "$version")
python3 -I release/notes/assemble.py "$notes" --check "${expect[@]}"
