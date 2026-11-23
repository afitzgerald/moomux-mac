# Moomux.app

**Early alpha.** Built for one person's own daily use, not yet hardened for anyone else's — expect
rough edges, missing features (see `CLAUDE.md`'s "Deliberately not done"), and breaking changes
between releases without notice.

A native macOS front end for [moomux](https://github.com/erickgnclvs/moomux) — a TUI for managing
Claude Code / codex / opencode sessions across git worktrees. SwiftUI, SwiftPM executable, two
dependencies (libghostty, DiffKit), driving the moomux core over its `moomux serve` unix socket.

## Installing

```sh
brew install --cask afitzgerald/moomux-mac/moomux-mac
```

Signed with a Developer ID and notarized, but still an alpha release — see above.

This repo was split out of moomux's `macos/` directory (history preserved via `git subtree split`).
`docs/native-macos-rewrite.md` is the design doc that led to this shape; `CLAUDE.md` has the
day-to-day working notes (build commands, screenshot workflow, tmux and terminal gotchas).

## Displaying images in the terminal

Moomux's embedded Ghostty renderer displays Kitty graphics in live tmux panes.

1. Install `kitten` with Homebrew. You can keep using Moomux as your terminal.

   ```sh
   brew install --cask kitty
   ```

2. Enable passthrough. Run this inside a live Moomux pane to update the running tmux server.
   To keep the setting across restarts, add `set -g allow-passthrough on` to `~/.tmux.conf`.

   ```sh
   tmux set -g allow-passthrough on
   ```

3. Run this inside the live pane with the path to a PNG or JPEG on the machine running tmux.

   ```sh
   kitten icat --passthrough=tmux --transfer-mode=stream --stdin=no "/path/to/image.png"
   ```

If `icat` reports `Failed to open controlling terminal`, run it at a shell prompt in Moomux.
Session Grid uses tmux text snapshots, which omit image data.

To have your agent show images when you ask, add this instruction to your global
`AGENTS.md` and start a new session.

> When I ask to see a local image, find my tmux session from a valid `TMUX_PANE` or
> a unique worktree match. Check `tmux list-clients -F '#{client_session} #{client_termname}'`
> for an attached `xterm-ghostty` client on that session. Open a new `image-preview`
> window there and run `kitten icat --passthrough=tmux --transfer-mode=stream --stdin=no "$image"`
> inside it. Pass the absolute image path as a shell argument. Keep the window open
> until I press Enter. If the target session is ambiguous, ask me which one to use.

## Building

The Mac app has no Xcode dependency — it is a plain SwiftPM package built and bundled by the
Makefile (see `CLAUDE.md` for why). `Moomux.xcodeproj` exists only to archive the iPhone app for
TestFlight (`docs/macos-vs-ios.md` D12).

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
before you open Moomux.app.

If `moomux` came from Homebrew (`brew install erickgnclvs/moomux/moomux` — the cask above does not install it),
the formula ships a launchd service definition:

```sh
brew services start moomux
```

That runs `moomux serve` at login with no `-socket` flag, so it serves the same default
(`~/.local/share/moomux/moomux.sock`) the app connects to when you don't pass `--socket` either.
`brew services stop moomux` to stop it, `brew services list` to check.

If `moomux` came from `go install` instead, there's no formula to hook into — write your own
LaunchAgent. Find the full path to your `moomux` binary first (`which moomux`), since launchd does
not use your shell's `PATH`:

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

`launchctl unload` the same path to stop it, or delete the plist to remove it for good.

## Agent usage in the toolbar

The toolbar can show your Claude and Codex quota. Open the usage details to see when quota
windows roll over. The details also show any banked reset counts, grant expiry, and cooldown
the provider reports.
Usage comes from
[agent-usage](https://github.com/afitzgerald/agent-usage), a separate tool that is not installed
with Moomux or moomux. Install it on the Mac running `moomux serve`:

```sh
brew install afitzgerald/agent-usage/agent-usage
brew services start agent-usage
```

Allow its one Keychain prompt, and the numbers appear within five minutes. Until then the toolbar
shows nothing; Settings → General → Claude usage says what's missing.

## Codex scrolling on iOS

Codex handles terminal scrolling inside its TUI. If scrolling feels slow in the iOS terminal, set
its scroll speed in `~/.codex/config.toml` on the computer running the session:

```toml
[tui]
mouse_scroll_speed = 3.0
```

Restart Codex for the setting to take effect.

## Compatibility

`Sources/MoomuxKit/Core/Models.swift` decodes the core's `internal/ipc` JSON into Swift structs with
no schema check at build time — a protocol change on the moomux side won't fail this repo's build,
it'll just decode into `nil`/defaults at runtime. There's no version pinning yet; if session data
looks wrong after updating the core, check `internal/ipc` and `session.Session`'s JSON tags there
first.
