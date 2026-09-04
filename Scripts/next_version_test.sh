#!/usr/bin/env bash
# Regression test for next_version.sh's bump rules. Run directly:
#   ./scripts/next_version_test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0

# A repo with commits but no v* tag at all: `git tag -l ... | grep -E ...`
# finds nothing and exits 1, which used to kill the whole script under
# `pipefail` before it ever got to print a version.
cd "$tmp"
git init -q
git config user.email test@test.com
git config user.name test
git commit -q --allow-empty -m "feat: first commit, no tags yet"
got="$("$script_dir/next_version.sh")"
if [ "$got" != "v0.0.1" ]; then
  echo "FAIL: untagged repo -> got '$got', want 'v0.0.1'"
  fail=1
else
  echo "ok: untagged repo -> $got"
fi

rm -rf "$tmp"
mkdir -p "$tmp"
cd "$tmp"
git init -q
git config user.email test@test.com
git config user.name test

git commit -q --allow-empty -m "chore: initial"
git tag v0.5.0

assert_next() {
  local msg="$1" want="$2"
  git commit -q --allow-empty -m "$msg"
  got="$("$script_dir/next_version.sh")"
  if [ "$got" != "$want" ]; then
    echo "FAIL: commit '$msg' -> got '$got', want '$want'"
    fail=1
  else
    echo "ok: '$msg' -> $got"
  fi
  git tag "$got"
}

# feat: is used on nearly every commit in this repo's history, so it must
# NOT trigger a minor bump on its own anymore.
assert_next "feat: add widget" "v0.5.1"
assert_next "fix: widget crash" "v0.5.2"

git commit -q --allow-empty -m "feat!: breaking widget rewrite"
got="$("$script_dir/next_version.sh")"
if [ "$got" != "v1.0.0" ]; then
  echo "FAIL: breaking change -> got '$got', want 'v1.0.0'"
  fail=1
else
  echo "ok: breaking change -> $got"
fi

exit "$fail"
