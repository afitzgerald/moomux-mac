# Moomux.app

**Early alpha.** Built for one person's own daily use, not yet hardened for anyone else's — expect
rough edges, missing features (see `CLAUDE.md`'s "Deliberately not done"), and breaking changes
between releases without notice.

A native macOS front end for [moomux](https://github.com/erickgnclvs/moomux) — a TUI for managing
Claude Code / codex / opencode sessions across git worktrees. SwiftUI, SwiftPM executable, one
dependency (SwiftTerm), driving the moomux core over its `moomux serve` unix socket.

## Installing

```sh
brew install --cask afitzgerald/moomux-mac/moomux-mac
```

Signed with a Developer ID and notarized, but still an alpha release — see above.

This repo was split out of moomux's `macos/` directory (history preserved via `git subtree split`).
`docs/native-macos-rewrite.md` is the design doc that led to this shape; `CLAUDE.md` has the
day-to-day working notes (build commands, screenshot workflow, tmux control-mode gotchas).

## Building

There is no Xcode dependency — this is a plain SwiftPM package built and bundled by the Makefile
(see `CLAUDE.md` for why, and why there is no `.xcodeproj`).

```sh
make build      # swift build -c release
make selfcheck  # assert-based checks
make dev         # debug bundle, sign, relaunch
```

The app needs a running core to talk to:

```sh
go install github.com/erickgnclvs/moomux@latest
moomux serve -socket /tmp/mmx.sock
make dev ARGS="--socket /tmp/mmx.sock"
```

With no `--socket` it uses `~/.local/share/moomux/moomux.sock`, same default as `moomux ui`.

## Running the core at login

The app talks to `moomux serve`, but doesn't start it — you need something running that socket
before you open Moomux.app. A LaunchAgent does that at login instead of a terminal you have to
remember to leave open. Find the full path to your `moomux` binary first (`which moomux`), since
launchd does not use your shell's `PATH`:

```sh
cat > ~/Library/LaunchAgents/com.erickgnclvs.moomux.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.erickgnclvs.moomux</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which moomux)</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/com.erickgnclvs.moomux.plist
```

No `-socket` flag, so it serves the same default (`~/.local/share/moomux/moomux.sock`) the app
connects to when you don't pass `--socket` either. `launchctl unload` the same path to stop it, or
delete the plist to remove it for good.

## Compatibility

`Sources/Moomux/Core/Models.swift` decodes the core's `internal/ipc` JSON into Swift structs with
no schema check at build time — a protocol change on the moomux side won't fail this repo's build,
it'll just decode into `nil`/defaults at runtime. There's no version pinning yet; if session data
looks wrong after updating the core, check `internal/ipc` and `session.Session`'s JSON tags there
first.
