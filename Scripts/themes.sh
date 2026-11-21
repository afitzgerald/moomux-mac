#!/usr/bin/env bash
# Refresh Resources/ghostty-themes from upstream.
#
# ghostty's built-in themes live in Ghostty.app, which Moomux does not depend
# on: libghostty-spm ships the engine and no themes at all, so `theme = <name>`
# in a user's config resolves against nothing, and `prepareConfig` throws the
# *whole* config away on that one diagnostic (see AppState.paneConfig). These
# files are that gap, filled by hand.
#
# Upstream is where ghostty itself gets them — the `ghostty/` directory of
# mbadolato/iTerm2-Color-Schemes, vendored into ghostty as a submodule.
#
# Curated, not all 607: the full set is 2.4MB on an 11MB app. The cost of
# curation is that a theme not listed here still kills the config it is named
# in, so add rather than argue when someone asks for one.
set -euo pipefail
cd "$(dirname "$0")/.."
dest=Resources/ghostty-themes
# Pinned: bump by hand, and keep it 72h old (Scripts/dependency_age.sh's rule for our other pins).
sha=c806b1bea6c8d0dee8848e37015ba5b6e357bd8b
url=https://github.com/mbadolato/iTerm2-Color-Schemes/archive/$sha.tar.gz

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" | tar xz -C "$tmp" --strip-components=2 "iTerm2-Color-Schemes-$sha/ghostty/*"

rm -rf "$dest"; mkdir -p "$dest"
missing=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if [ -f "$tmp/$name" ]; then cp "$tmp/$name" "$dest/$name"
  else echo "gone from upstream: $name" >&2; missing=1; fi
done < Scripts/themes.txt
# A theme file is colours only; anything else (a `command =`, an include) would reach every pane.
if bad=$(grep -rvE '^(palette|background|foreground|cursor-color|cursor-text|selection-background|selection-foreground) = |^$' "$dest"); then
  echo "unexpected lines in themes:" >&2; echo "$bad" >&2; exit 1
fi
find "$dest" -type f | wc -l | xargs echo "themes:"
exit $missing
