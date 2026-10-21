#!/bin/bash
# Decides whether this run of the release workflow makes a release. Writes these to $GITHUB_OUTPUT:
#   version, tag   VERSION and its tag, desktop-v<version>
#   release        true when that version has no release yet, so the builds run
#   publish        true when the run also tags and publishes it (not a dry run)
#   pr             the merged pull request that brought this commit to main (pushes only)
#
#   .github/scripts/release/plan.sh
# Environment: GH_TOKEN, DRY_RUN (the workflow_dispatch input, empty for a push) and GitHub's own variables.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
# shellcheck source=release/lib.sh
source release/lib.sh

version="$(tr -d '[:space:]' < VERSION)"
tag="desktop-v$version"
dry_run="${DRY_RUN:-false}"
output() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }
summary() { printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; }
skip() {
    printf '::notice title=No release::%s\n' "$1"
    summary "### No release" "" "$1"
    output release false
    output publish false
    exit 0
}

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION says \"$version\"; a release number is MAJOR.MINOR.PATCH"
output version "$version"
output tag "$tag"

pr=""
if [[ "$GITHUB_EVENT_NAME" == push ]]; then
    # "Protect main" lets only pull requests in; anything that reached main another way is not released.
    pr="$(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" \
        --jq '[.[] | select(.merged_at != null and .base.ref == "main")][0].number // empty')"
    [[ -n "$pr" ]] || skip "$GITHUB_SHA reached main without a merged pull request, so it is not released."
fi
output pr "$pr"

if gh release view "$tag" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    skip "Crok $version is released already ($tag). A pull request that bumps VERSION releases the next one."
fi
# A tag without a release is what a run that failed after tagging leaves; it may only name this commit.
tagged="$(remote_tag_commit "$tag")"
if [[ -n "$tagged" && "$tagged" != "$GITHUB_SHA" ]]; then
    fail "tag $tag names $tagged, not $GITHUB_SHA. Bump VERSION, or delete the tag if nothing was released from it."
fi
if [[ "$dry_run" != true && "$GITHUB_REF" != refs/heads/main ]]; then
    fail "releases are published from main; run the workflow from $GITHUB_REF as a dry run"
fi

# Checked before any build: a release without its notes in every language is not made.
release/notes/check.sh

output release true
if [[ "$dry_run" == true ]]; then output publish false; else output publish true; fi
if [[ -n "$pr" ]]; then from="pull request #$pr"; else from="$GITHUB_REF_NAME (run by hand)"; fi
if [[ "$dry_run" == true ]]; then what="Dry run of Crok $version"; else what="Releasing Crok $version"; fi
summary "### $what" "" "From $from at \`${GITHUB_SHA:0:12}\`, as \`$tag\`."
