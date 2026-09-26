#!/usr/bin/env bash
# Screenshot the running app — the GUI equivalent of the Go side's
# scripts/screenshot.sh, and the same rule applies: look at the PNG before
# calling a UI change done, and send it to the user as a file:// link.
#
# Usage: Scripts/shot.sh [out.png]
#
# The app must already be running (`make dev`). Screen Recording permission is
# required for screencapture to see another app's window; without it macOS
# silently captures the desktop instead. Against a locked screen this captures
# the lock screen, so a blank-looking shot is not evidence of a broken UI.
set -euo pipefail

cd "$(dirname "$0")/.."

# The half that runs inside Ghostty (see the fallback at the bottom): bring the
# build back in front of the Ghostty window that is running this, then capture.
if [ "${1:-}" = "--capture" ]; then
  pid=$2 frame=$3 out=$4 status=$5
  swift -e "import AppKit; NSRunningApplication(processIdentifier: $pid)?.activate()" 2>/dev/null
  sleep 1.5
  screencapture -x -R "$frame" "$out" 2>/dev/null && echo 0 > "$status" || echo 1 > "$status"
  exit 0
fi

out="${1:-/tmp/moomux-macos.png}"

# This worktree's own build, not any Moomux: the installed app and other
# worktrees' builds run alongside it, and matching one of those would photograph
# the wrong window while a dev build that died on launch looked healthy — the
# silent-crash-on-launch trap CLAUDE.md warns about. `[M]` keeps the pattern from
# matching this script's own command line.
pid="$(pgrep -f "$PWD/.build/Moomux.app/Contents/MacOS/[M]oomux" | head -1)" \
  || { echo "no Moomux running from $PWD/.build — try 'make dev'"; exit 1; }

# Without Accessibility (the usual case under tmux — CLAUDE.md) `ui.swift frame`
# has no window to read, so fall back to the window server, which needs none,
# and bring the build forward the same way.
frame="$(swift Scripts/ui.swift frame 2>/dev/null)" || frame="$(swift -e "
import AppKit
NSRunningApplication(processIdentifier: $pid)?.activate()
let ws = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let w = ws.filter { \$0[kCGWindowOwnerPID as String] as? Int32 == $pid && \$0[kCGWindowLayer as String] as? Int == 0 }
  .compactMap { \$0[kCGWindowBounds as String] as? [String: CGFloat] }
  .max { \$0[\"Width\", default: 0] * \$0[\"Height\", default: 0] < \$1[\"Width\", default: 0] * \$1[\"Height\", default: 0] }
if let b = w { print(\"\\(Int(b[\"X\"]!)),\\(Int(b[\"Y\"]!)),\\(Int(b[\"Width\"]!)),\\(Int(b[\"Height\"]!))\") }
" 2>/dev/null; sleep 1)"
[ -n "$frame" ] || { echo "could not read the window frame"; exit 1; }

screencapture -x -R "$frame" "$out" 2>/dev/null && { echo "$out"; exit 0; }

# Screen Recording is checked against the *responsible* process, which for a
# pane under tmux is the tmux server — and Homebrew's tmux is ad-hoc signed, so
# a grant is pinned to one build's cdhash and silently stops matching after a
# `brew upgrade tmux` (or never applies to a server started before it). Rather
# than restart the server under live agent sessions, run the capture as a child
# of Ghostty, which holds its own grant: `open` makes Ghostty responsible.
[ -d /Applications/Ghostty.app ] \
  || { echo "screencapture failed and there is no Ghostty to borrow a grant from — give tmux Screen Recording and restart its server"; exit 1; }
status="$(mktemp -t moomux-shot)"; : > "$status"
open -na Ghostty --args -e "$PWD/Scripts/shot.sh" --capture "$pid" "$frame" "$out" "$status"
for _ in $(seq 30); do [ -s "$status" ] && break; sleep 1; done
rc="$(cat "$status")"; rm -f "$status"
[ "$rc" = 0 ] || { echo "screencapture failed, directly and under Ghostty"; exit 1; }
echo "$out"
