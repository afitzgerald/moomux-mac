#!/usr/bin/env bash
# Computes the next release tag from conventional-commit messages since the
# last vX.Y.Z tag reachable from HEAD, and prints it (e.g. "v0.2.9") to
# stdout. Prints nothing if HEAD is already tagged, or if there are no
# commits since the last tag — either way, there's nothing new to release.
#
# Bump rules, checked against every commit subject since the last tag:
#   - "type!: ..." or a "BREAKING CHANGE" footer -> major
#   - anything else (feat:, fix:, chore:, ...)    -> patch
#
# feat: used to bump minor, but nearly every commit here is written as
# feat:, so that rule was firing on almost every release. Minor bumps are
# now a manual call (tag/push vX.Y.0 yourself) instead of inferred.
set -euo pipefail

if [ -n "$(git tag --points-at HEAD)" ]; then
  exit 0
fi

# Only exact vX.Y.Z tags reachable from HEAD count as a release baseline —
# a stray "v*" tag with a different shape (v1, v1.2.3-rc1) or one that lives
# on an unrelated branch must not be picked as the last release.
last_tag=$(git tag -l --merged HEAD 'v*' | { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -V | tail -n1)

if [ -z "$last_tag" ]; then
  range=""
  version="0.0.0"
else
  range="${last_tag}..HEAD"
  version="${last_tag#v}"
fi

subjects=$(git log $range --pretty=%s)

if [ -z "$subjects" ]; then
  exit 0
fi

# "type!:" is a subject-level marker; "BREAKING CHANGE:" is a footer that
# only ever appears in the commit body, so it needs the full message, not
# just the subject line.
bodies=$(git log $range --pretty=%B)

bump=patch
if echo "$subjects" | grep -qE '^[a-zA-Z]+(\([^)]+\))?!:' || echo "$bodies" | grep -qE '^BREAKING CHANGE:'; then
  bump=major
fi

IFS='.' read -r major minor patch <<<"$version"
case "$bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac

echo "v${major}.${minor}.${patch}"
