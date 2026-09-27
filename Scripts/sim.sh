#!/bin/bash
# One iPhone simulator per worktree, so two worktrees' `make ios-run` stop
# installing over each other — they share a bundle id, so on one shared device
# the last install wins and the other session is looking at the wrong app.
#
#   sim.sh ensure NAME TYPE   create NAME (of device type TYPE) if it is missing
#   sim.sh prune              delete every per-worktree simulator whose worktree
#                             is gone from `git worktree list`
#
# Only devices named "$PREFIX<worktree>" are ever touched; the stock simulators
# and anything created by hand are not ours to delete.
set -euo pipefail

PREFIX="Moomux · "

devices() {
    # name<TAB>udid for every device, any runtime.
    xcrun simctl list devices -j | jq -r '.devices[][] | "\(.name)\t\(.udid)"'
}

case "${1:-}" in
ensure)
    name=$2 type=$3
    if ! devices | cut -f1 | rg -qxF -- "$name"; then
        xcrun simctl create "$name" "$type" >/dev/null
        echo "created simulator: $name"
    fi
    ;;
prune)
    live=$(git worktree list --porcelain | sed -n 's/^worktree //p' | xargs -I{} basename {})
    devices | while IFS=$'\t' read -r name udid; do
        [[ $name == "$PREFIX"* ]] || continue
        wt=${name#"$PREFIX"}
        if ! rg -qxF -- "$wt" <<<"$live"; then
            # `delete` refuses a booted device.
            xcrun simctl shutdown "$udid" 2>/dev/null || true
            xcrun simctl delete "$udid"
            echo "deleted simulator for removed worktree: $wt"
        fi
    done
    ;;
*)
    echo "usage: $0 ensure NAME TYPE | prune" >&2
    exit 2
    ;;
esac
