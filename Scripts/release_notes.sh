#!/usr/bin/env bash
# Writes the release notes for <tag> into <dir>, for both release workflows:
#   notes.md     GitHub's generated notes for the tag, grouped by
#                .github/release.yml — the GitHub release's body.
#   WhatsNew.md  those plus the last nine releases', each under "# vX.Y.Z",
#                newest first — what both apps bake in as their What's New
#                (WhatsNew.swift). Every merge is its own release, so an
#                upgrade that skips a few would otherwise show only the last PR.
# Needs GH_TOKEN and GITHUB_REPOSITORY, which every Actions job has.
set -euo pipefail
tag=$1 dir=$2

gh api "repos/${GITHUB_REPOSITORY}/releases/generate-notes" \
  -f tag_name="$tag" -q .body > "$dir/notes.md"
{
  echo "# $tag"
  cat "$dir/notes.md"
  # Not this tag: once its release exists (TestFlight runs after it, and a
  # re-run of Release) it would be listed twice.
  for t in $(gh release list --limit 10 --json tagName \
               -q ".[] | select(.tagName != \"$tag\") | .tagName" | head -n 9); do
    printf '\n# %s\n' "$t"
    gh release view "$t" --json body -q .body
  done
} > "$dir/WhatsNew.md"
