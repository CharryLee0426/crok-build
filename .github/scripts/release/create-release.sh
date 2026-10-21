#!/bin/bash
# Tags the released commit desktop-v<version> (unless a failed run already did) and publishes the GitHub
# release with every file assemble.sh checked, then asks the release's own crok whether it sees it.
#
#   .github/scripts/release/create-release.sh DIR NOTES
# Environment: GH_TOKEN (contents: write), GITHUB_REPOSITORY, GITHUB_SHA; origin pushable (actions/checkout).
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

dir="${1:?usage: create-release.sh DIR NOTES}"
notes="${2:?usage: create-release.sh DIR NOTES}"
version="$(tr -d '[:space:]' < VERSION)"
tag="desktop-v$version"

tagged="$(remote_tag_commit "$tag")"
if [[ -z "$tagged" ]]; then
    git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        tag -a "$tag" -m "Crok Desktop $version" "$GITHUB_SHA"
    git push origin "refs/tags/$tag"
elif [[ "$tagged" != "$GITHUB_SHA" ]]; then
    fail "tag $tag names $tagged, not $GITHUB_SHA"
else
    printf 'Tag %s already names %s (left by an earlier run); publishing it.\n' "$tag" "$GITHUB_SHA"
fi

assets=()
while IFS= read -r file; do assets+=("$dir/$file"); done < <(release_files "$version")
assets+=("$dir/SHA256SUMS.txt" "$dir/SHA256SUMS.txt.sig")
gh release create "$tag" -R "$GITHUB_REPOSITORY" --verify-tag --latest \
    --title "Crok Desktop $version" --notes-file "$notes" "${assets[@]}"
url="$(gh release view "$tag" -R "$GITHUB_REPOSITORY" --json url --jq .url)"
printf '\n### Published\n\n%s\n' "$url" >> "$GITHUB_STEP_SUMMARY"

# What every install's updater will do next: follow releases/latest and verify the signed manifest.
check="$RUNNER_TEMP/upgrade-check"
mkdir -p "$check/home"
tar -xzf "$dir/$(release_tarball "$version")" -C "$check" crok
for attempt in 1 2 3 4 5 6; do
    if CROK_HOME="$check/home" "$check/crok" upgrade --check --json 2>/dev/null | grep -q "\"latest\":\"$version\""; then
        printf 'crok upgrade --check sees %s as the latest release.\n' "$version"
        exit 0
    fi
    sleep $((attempt * 10))
done
printf '::warning::crok upgrade --check does not see %s as the latest release yet; check %s/latest\n' "$version" "${url%/tag/*}"
