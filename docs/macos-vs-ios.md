# Mac and iPhone: what differs, and why

One engine, two apps. This is the record of every place the macOS and iPhone apps deliberately
behave differently, the reason for each, and the places they differ by accident. It replaces
`IPHONE.md`, the plan for building the phone app. The plan is done, and what survives of it is
the decisions and the measurements behind them, which are here.

**Keep it current.** A change that makes one app do something the other does not, or brings
them back into line, updates this file in the same change. Decisions are numbered so a comment
or commit message can cite one ("see docs/macos-vs-ios.md D24") without quoting it. Never
renumber. Retire a decision by striking it through and saying what replaced it.

`CLAUDE.md` owns how to build and verify either app. `docs/native-macos-rewrite.md` owns why the
Mac app has the shape it has. `docs/wire-protocol.md` in the Go repo owns the socket contract.
This file owns the *difference* between the two shells, and says so briefly where one of those
files already says it at length.

---

## The shape

The Mac app is **where you work alongside the agents**:
- a sidebar of every session
- a live pane attached to one
- a grid of all of them
- project and config management
- a keyboard shortcut for every write

The iPhone app is **how you check in on them away from the desk**:
- what an agent is asking
- what it has changed
- a way to answer it
- starting another

Read feature by feature, the phone got the features that serve checking in, and the ones that
set things up or need a large screen stayed on the Mac.

```
Sources/MoomuxKit/    one library, both platforms: wire types, client, store, layout, forms,
                      notifier, theme, attachments, link rules
Sources/Moomux/       the Mac shell   (SwiftPM executable, AppKit allowed)
Sources/MoomuxiOS/    the iPhone shell (not a SwiftPM target; swiftc or Xcode)
```

Two facts decide most of what follows:
- **Where the core is.** The Mac reaches it on the same machine over a unix socket. The phone
  reaches it across a tailnet over TCP.
- **Whether the app can start a process.** The Mac can, and runs a local `tmux attach`. iOS
  cannot, so the phone streams the pty from the core. The dividing line in the code is therefore
  AppKit plus `Process`, not "is it a view". Everything else is in the Kit.

```sh
for d in Sources/Moomux Sources/MoomuxiOS Sources/MoomuxKit; do printf '%s ' $d; fd -e swift . $d -x cat | wc -l; done
# Sources/Moomux 3980   Sources/MoomuxiOS 1953   Sources/MoomuxKit 6487   (2026-09-28)
```

---

## A. Scope

**D1. The phone ships the check-in-and-answer subset, not a small Mac app.**
- **In:** the session list in both lenses, search, the archived view, a live attached pane,
  creating a session (attachments included), rename, tags, archive, filing into folders (by drag
  or from detail, new folders included), folder rename/archive/delete, Kill tmux, delete, a native
  diff, and opening files a pane names.
- **Out:** D2–D8.

**D2. No session grid on the phone.** The grid exists to see many live sessions at once, and a
6-inch screen has no "at once". The phone uses the grid's `Capture` call only as a liveness probe
(D28).

**D3. No Settings and no project management on the phone.** Adding a project, and every flag in
`config.toml`, is a desk task, and the core applies those flags to the phone anyway (D47). The
phone's ⋯ menu carries only its own per-device choices (§J). With no projects at all, the list
says so and points at the Mac's Settings → Projects, and + stays disabled, rather than opening a
sheet with nothing to pick.

**D4. No menu bar extra, no Dock, and no commands of its own on the phone.** A hardware keyboard
reaches the pane (the same `paneKeybinds`), but the app defines no shortcuts.

**D5. Background refresh, not push.** Real-time delivery means APNs, which means a push server,
a certificate, and a Mac that is awake to notice the transition anyway. That is out of scope by
decision. The phone polls instead, through `BGAppRefreshTask` (D48). Banners from the pocket are
late by however long iOS waits, never less than the 15 minutes asked for.

**D6. No iPad layout.** It is iPhone only: `UIDeviceFamily` 1 on the `make ios` path, and
`TARGETED_DEVICE_FAMILY = 1` in the Xcode project. Portrait and both landscapes are allowed, and
each rotation costs a reattach (D27). An iPad would mostly work as a split view, but it is not
the use case. Decide it separately if the phone app gets used.

```sh
rg -c 'TARGETED_DEVICE_FAMILY = 1' Moomux.xcodeproj/project.pbxproj                    # 2
/usr/libexec/PlistBuddy -c 'Print :UISupportedInterfaceOrientations' Resources/iOS-Info.plist
```

**D7. TestFlight, never the App Store.** An app whose purpose is driving agents on your own
computer is an App Review conversation nobody needs to have.

**D8. No notification actions, on either.** An "Approve" button would have to send keys into an
agent's pane, and there is no write path for that. A banner is already an Open button.

**D9. One repository for the Swift side.** The value is the shared Kit, and two repos would mean
versioning it as a package. The Go core is a separate repo regardless, and most of the phone's
enabling work (the tailnet listener, `Attach`, `Capture`, `Review`, `Diff`, `SaveFile`,
`ReadFile`) landed there.

---

## B. Build, targets and distribution

| | Mac | iPhone |
|---|---|---|
| Minimum OS | macOS 14 | iOS 18 |
| Local build | `swift build` + Makefile bundle (`make app`) | `swift build --triple … --product MoomuxKit`, then one `swiftc` (`make ios`) |
| Local run | `make dev` / `make run`, bundle id `app.moomux.Moomux.dev` | `make ios-run`, real bundle id, one simulator per worktree |
| Configuration | release (`make app`), debug (`make dev`, `make selfcheck`) | release on both paths |
| Signing | ad-hoc locally; Developer ID for `dist`/`notarize` | ad-hoc for the simulator; Xcode-managed for TestFlight |
| Direct download | notarized `.dmg`, stapled app and image, Homebrew cask | none |
| TestFlight | not yet | `make testflight`, run by `release.yml` after the cask |
| Bundle id | `app.moomux.Moomux` | the same |

**D10. The Kit is a static library so the phone can link it; the Mac app stays an
`executableTarget`.** `make build`, `make selfcheck` and `make dev` work as they did before the
split, with no Xcode in the loop. `type: .static` is required, not a preference: an automatic
library product cannot be named by `swift build --product`, and without that the cross-build
drags in the macOS executable and fails on `import AppKit`.

**D11. SwiftPM builds the Mac app; nothing in SwiftPM builds the iPhone app.** SwiftPM cannot
exclude a target per platform, so a plain `swift build` would try to compile UIKit views and
fail. `make ios` cross-builds the Kit and every libghostty target for the simulator, links the
shell with one `swiftc`, and assembles the bundle by hand, the same recipe as `make app`. The
Makefile comments explain both halves: `SDKROOT` is unset for `swift build` and set for `swiftc`,
and the build engine is pinned to swiftbuild.

**D12. The Xcode project exists for distribution only.** `Moomux.xcodeproj` has one iOS target,
used by `make testflight` so Xcode can make the certificate, profile and App ID from a signed-in
Apple ID. The Mac app stays out of it until it ships through TestFlight too.

**D13. One bundle identifier for both platforms.** App Store Connect carries several platforms
under one record only when they share an id, and the id is fixed at the first upload. The iOS
record must keep "Make this app available on Mac" off, since the native Mac app owns the id.

**D14. Dev builds are isolated differently on each platform, for the same reason.** Several
worktrees build at once. The Mac gives dev builds their own identifier (`.dev`) and kills only
this worktree's process. The phone cannot change identifier without leaving the TestFlight
record, so each worktree gets its own simulator (`Moomux · <worktree>`, `Scripts/sim.sh`, pruned
when the worktree goes).

**D15. The phone builds release even for the simulator.** A debug iPhone build would ship the
`assert`s that `--selftest` exists to run, so an inverted invariant would abort the app on a
phone instead of drawing. It would also leave the VT byte path at `-Onone`.

**D16. The phone ships after the Mac and cannot hold it back.** `release.yml` runs
`testflight.yml` with `needs: release`. A TestFlight build goes out only for a release Homebrew
actually got, under the same version, and a failed upload does not block the cask.

**D17. Swift 5 language mode on both SwiftPM targets.** A new target defaults to Swift 6, and
strict concurrency would break the blocking-fd socket client first.

---

## C. The platform seam

**D18. Conditionals in the Kit, not a platform protocol.** Each place the Kit needs AppKit or
UIKit is an `#if` in the file that needs it:

| Site | Mac | iPhone |
|---|---|---|
| badge (`AppState.updateDockBadge`) | `NSApp.dockTile.badgeLabel` | `Notifier.setBadge` → `setBadgeCount`, only when the count moves |
| surface pool (`plainPanes`, `plainDelegates`) | present | compiled out (D26) |
| pane config (`paneConfig`) | user files + keybinds | + `phonePaneConfig` (D30) |
| system font size, font families | `NSFont`, `NSFontManager` | `UIFont`, none |
| `openDiffTool` | `ToolPath.run` | no-op |
| theme colours (`SessionTheme`) | `NSColor(name:)` dynamic provider | `UIColor { traits in … }` |
| foreground banner rule (`Notifier.report`) | none for the selected session in the active app | none for the pane on screen (`paneOnScreen`) |
| `willPresent` (`Notifier`) | not implemented: the system default | shows the banner in the foreground |
| notification tap (`Notifier`) | `NSApp.activate()`, order the window front | iOS brings the app forward itself |
| What's New sheet | fixed frame | detents |
| `ToolPath` | the whole file | compiled out (`Process` is unavailable) |

```sh
rg -c '#if (os|canImport)' Sources/MoomuxKit     # AppState 7, Notifier 3, SessionTheme 3, WhatsNew 1, ToolPath 1
```

`make ios` is the portability check: one unguarded AppKit symbol in the Kit breaks the phone,
and nothing in `swift build` notices.

**D19. The libghostty runtime is one per process, and the phone is why that is enforced.**
libghostty-spm publishes no `free()`. The Mac builds one `AppState` per process from `--socket`.
The phone builds a new one per Connect. So the `TerminalController` lives in a `static`
(`AppState.runtime`), and a second store reuses it rather than stranding a `ghostty_app_t`.

---

## D. Connection

| | Mac | iPhone |
|---|---|---|
| Endpoint | unix socket, `--socket <path>` or `~/.local/share/moomux/moomux.sock` | TCP `host:port` in `UserDefaults`, default port 45876 |
| Auth | file permissions | the core runs `tailscale whois` on the peer |
| Connect deadline | none needed; a unix socket fails fast | 5s non-blocking connect |
| Dead peer | EOF | keepalive, ~30s to `ETIMEDOUT` |
| Switch cores | relaunch with another `--socket`, or `coreHost`/`corePort` (D25) | Disconnect in the ⋯ menu |
| Lifecycle hooks | none | schedules background refresh on `.background`; reconnects on leaving it (D51) |

**D20. TCP over the tailnet, with no pairing, token or TLS.** WireGuard provides encryption and
machine identity, and the core authorizes each peer by `tailscale whois --json` against its own
login. The endpoint is therefore in `UserDefaults`, not the Keychain: an address is not a secret.
The core side, as built:
- **Opt-in at the machine.** `tailnet_listen = true` in `config.toml`, and it is not settable
  over the wire. Turning it on exposes `CreateSession`, with its userscripts and
  permission-skipping flag, to the tailnet, so that choice is made at the machine. The value is
  readable on every snapshot as a diagnostic.
- **Bind.** The tailnet address only, never `0.0.0.0`.
- **Peer cache.** Authorized peers are cached for 60s, so `tailscale` does not fork on every
  `Accept`.
- **Failure.** A failure to bind is logged and never fatal; the unix socket keeps serving.
- **`tsnet`: not used.** Making the core its own tailnet node is the more correct answer, but it
  pulls the whole `tailscale.com` module into a small `go.mod`. Reach for it if the bind proves
  fragile when the interface is down. Funnel stays off either way.

**D21. One `StreamSocket` for both families; Network.framework is not used.** The protocol is
"connect, write one line, read the answer", and `Watch` is line-delimited JSON, so an async
connection state machine is ceremony. The TCP path adds what a unix socket never needed:
- a 5s connect deadline, because a sleeping Mac parks `connect(2)` for ~75s
- keepalive at 15s idle / 5s interval / 3 probes, because a half-open link leaves `Watch` and
  `Attach` parked forever
- `SO_NOSIGPIPE`, because one keystroke after the link dies would otherwise kill the process
- `getaddrinfo`, with every answer tried, so MagicDNS names and dual-stack hosts work

Every one-shot request half-closes (`closeWrite`). A server that reads to EOF otherwise waits
forever. `Watch` and `Attach` are newline-terminated instead, because they keep writing.
*Where:* `Core/StreamSocket.swift`, `MoomuxClient.call`.

**D22. A port outside 1–65535 keeps Connect disabled.** `UInt16(clamping:)` would turn a typo
into 65535 and report "cannot connect" pointing at the wrong thing. The port is read with
`integer(forKey:)`, because a launch-argument value arrives as a string and `as? Int` silently
takes the default. *Where:* `EndpointStore`.

**D51. Leaving the background reconnects the list.** iOS suspends the app and often reclaims its
sockets while it is away, but a half-open stream says nothing until keepalive gives up, about
30s later. All that time the list showed the last snapshot and the badge said connected. So
`AppState.resume` restarts the watch stream on a fresh connection and pulls the config, which
answers at once with a whole snapshot, or with the reason the core is gone.
- **When it fires.** On *leaving* `.background`, not on reaching `.active`: a system alert
  (the notification prompt, a permission sheet) can hold the app at `.inactive` indefinitely. A
  pulled-down Notification Centre never passes through the background, so it does not reconnect.
- **Cost.** One reconnect when the old stream was healthy after all. The list is replaced only
  when the new snapshot lands, so nothing flickers. A cancelled loop exits before writing any
  state, so it cannot undo the new loop's `streaming`.
- **Measured** in the simulator: returning replaced the watch connection (a new client port, same
  app pid), and a session renamed in the store while the app was away showed its new name on
  return.

The pane's own connection has the same half-open window (D28 notices only when a read fails).
*Where:* `AppState.resume`, `MoomuxiOSApp`'s `scenePhase` handler.

---

## E. The terminal

| | Mac (`TerminalPane`) | iPhone (`TerminalScreen`) |
|---|---|---|
| Backend | `.exec`: `login … bash -c exec -l <reattach loop>` | `.inMemory`, fed by the core's `Attach` stream |
| `TERM` | `xterm-ghostty`, `TERMINFO` pointed at the bundle | `xterm-256color`, fixed core-side |
| Lifetime | pooled per session, survives selection changes | one screen, torn down when popped |
| Detach | toolbar Detach (`controller = nil`) | Back |
| Resize | live | 250ms settle, then `ResizeAttach` in place; reattach against an older core |
| Link drop | not a failure mode | "connection lost — reconnecting", 2s retry |
| Focus | taken on `viewDidMoveToWindow` | tap to type |
| Links | ⌘-click | tap, probed as ⌘-click |
| Look | the user's Ghostty config | built-in dark + phone padding |
| Size control | ⌘+ / ⌘− zoom (ghostty's own, kept in `paneKeybinds`) | Text Size in the pane's ⋯ menu, plus pinch; both saved |
| Files in | Finder drop types local shell-quoted paths | Photos/Files → `SaveFile` → pasted path |

**D23. Different backends, same VT engine.** The Mac spawns a local `tmux attach` through
libghostty's `.exec` backend. iOS cannot spawn anything, so the pty lives on the core's machine:
the attach socket feeds `session.receive`, and the session's `write` closure sends keystrokes
back. Two of the Mac's worst bugs therefore cannot happen on the phone:
- **Shell quoting.** The Mac's `String.shellQuoted` is a security boundary. The phone builds no
  command line.
- **Terminfo.** The Mac must set `TERMINFO` for the bundle's entry. The phone's `TERM` is fixed
  core-side, because the entry has to exist on the core's machine, and `TMUX`/`TMUX_PANE` are
  stripped there so a core started inside tmux is not refused for nesting.

**D24. The attach stream has no framing, deliberately.**
1. A second connection sends one newline-terminated `Attach` line (`id`, `cols`, `rows`).
2. It gets back one `{"result":{"ok":true}}` line.
3. From then on the connection *is* the pty, and closing it is the detach.

Three consequences:
- **Errors exist only before the switch.** After `ok` there is nowhere to put one, so a failure
  *is* the socket closing.
- **The bytes behind the response line are tmux's first frame.** `AttachChannel.pending` keeps
  them. `splitLine` must tell "no newline yet" (nil) from "line complete, nothing behind it" (an
  empty remainder). A quiet session produces the second case, and conflating the two blocks
  forever. Both were measured on real traffic.
- **Size.** A missing or absurd size becomes 80x24, never 0, which looks wrong on a phone.

`Attach` runs `EnsureTmux`, so opening a parked session revives it with no separate call. A core
that can resize a live attach puts a token in that one response line (`"attach":"<token>"`), and
`ResizeAttach {attach, cols, rows}` resizes the pty in place (D27). *Where:*
`Core/AttachChannel.swift`, `MoomuxClient.resizeAttach`.

**D25. The Mac attaches locally whenever it can, and over the core's stream when it can't.**
- **Local is the cheaper path.** The pty and tmux client run on this Mac, and bytes never cross
  the socket. The terminal gets `xterm-ghostty` with its terminfo, and there's no keepalive,
  reconnect or resize debounce to get wrong. So it stays the default.
- **Choosing a core.** `--socket <path>` first. Then a core on another machine, from `coreHost`
  and `corePort` (`defaults write`, or `-coreHost` on the launch line; the phone's keys, default
  port 45876). Then the default socket.
- **The rule (`AttachRoute`, asserted in `--selftest`).** A unix-socket core is on this machine
  by construction, so the pane attaches locally, or is unavailable with no tmux. A TCP core may
  also be this machine (its own tailnet address), so the pane attaches locally only if this
  Mac's tmux has the session (`tmux has-session`, checked once per attach, off the main actor).
  Otherwise it attaches over the core's `Attach` stream, and no local tmux is needed at all.
- **A remote pane is the phone's attach.** `RemoteAttach`, moved into the Kit, holds the settled
  first size, resize in place, reconnects that cannot revive a killed session, and keys buffered
  across a reconnect. It runs on libghostty's in-memory backend. It is pooled like a local pane,
  and `detach` closes its socket.
- **What changes with it on the Mac.**
  - A file link in the pane is fetched with `ReadFile` and opened locally.
  - A Finder drop is uploaded (D38).
  - The diff tool is off, since the worktree path names the core's disk.
  - Review, the grid, Copy Path and every write already went through the core.
- **Measured.** A core on a separate tmux server, reached over TCP. The Mac chose the remote
  route, and the client on that session was `tmux -u attach -t =moomux-macrz-1b95`, started by
  the core with `TERM=xterm-256color`, where a local attach would be `xterm-ghostty`. The pane
  drew the session's output.

There's no Settings field for the core address yet (§M 1). *Where:* `AttachRoute`,
`AppState.attach`, `RemoteAttach`, `SessionTerminal`, `MoomuxApp.client()`.

**D26. Mac panes are pooled; phone panes are single-use.**
- **Mac.** `plainPanes`/`plainDelegates` keep each attached session's surface and tmux client
  alive across sidebar switches, so switching back is instant and keeps scrollback. Only Detach
  tears one down, and it has to be explicit: dropping the view does not free the surface.
- **Phone.** The stack holds at most one `TerminalScreen`. `showTerminal` truncates to an
  existing pane, or drops another session's, because each screen is its own `Attach`: a buried
  one keeps a second tmux client on the session, holding a size for a phone nobody is looking at,
  and Back would lead to a stale copy of a pane. `dismantleUIView` closes the socket.

**D27. Resizing: live on the Mac, in place on the phone.** A size change on the phone is a
`ResizeAttach` on the live connection, so tmux gets a SIGWINCH and redraws. Showing the keyboard,
hiding it and rotating no longer tear the pane down. Against a core without `ResizeAttach` (no
token on the attach, or the call refused), the phone falls back to what it always did:
- **Debounce.** The phone debounces surface sizes by 250ms. The first layout pass is measurably
  wrong: 62x62 before safe areas settle it at 62x53.
- **Resize.** It resizes (or, on an older core, reattaches) whenever the settled size changes,
  which happens on rotation and when the keyboard appears. Resizes go out on one serial queue, so
  the last size wins.
- **Disarm.** `AttachSizing.disarm` cancels the settle when a size comes back to the attached one
  inside the debounce.
- **Safe area.** The pane does not `.ignoresSafeArea(.bottom)`. The two extra rows would be drawn
  behind the home indicator, and those are the rows where tmux puts its status line and the
  cursor.

Both apps set `resizeThrottleMilliseconds: 96`. *Where:* `TerminalScreen.Coordinator`,
`AttachSizing`, and `ResizeAttach` in the core since v0.6.38 (erickgnclvs/moomux#309). Measured
against v0.6.39: a text-size change moved the phone's tmux client from 33x25 to 47x35 with the
same pid and creation time, so the connection stayed up rather than being replaced.

**D28. The phone reconnects a dropped pane.** A failed read retries every 2s. Four rules keep it
safe:
- **First attach vs later.** The first attach may revive a parked session. Every later reattach
  first asks `Capture` whether the session is alive (`Reattach.decide`), because `Attach` runs
  `EnsureTmux` and would otherwise *recreate* a killed session, agent and all. That was measured
  as "a killed session keeps re-spawning".
- **Race.** A lock-guarded `done` flag, set off the main actor before the hop to dismiss, closes
  the race in which a pending settle task revived the session.
- **Gap.** Keys typed between channels are buffered, up to 4KB, on one serial queue so they keep
  their order.
- **Reads.** `readChunk` uses `read(2)`, not `FileHandle.availableData`. The latter raises an
  Objective-C exception when a parked read's fd is closed, and that took the app down on every
  detach.

**D29. Neither device takes a session from the other.** The phone and the Mac are ordinary tmux
clients side by side. Under tmux's default `window-size latest`, the window follows whichever
client typed last, so each takes the size back on its next keystroke. The core used to run the
phone's `Attach` as `tmux attach -d`, which kicked the Mac's pane. v0.6.38 dropped `-d`
(erickgnclvs/moomux#309). Measured: a second attach left the first client in place.

The Mac pane still runs its attach inside a bash loop that offers "Press any key to reattach, or
q to close" instead of sitting on "Process exited". Something else can still detach it: a
`tmux attach -d` from another terminal, prefix-D's client chooser, or an older core. Reattaching
is manual, because whoever kicked it asked for the session. *Where:* `TerminalPane.reattachLoop`.

The tmux `window-size` option was measured before this was settled, with two clients (200x50 and
80x24) on one session under tmux 3.7c:

| `window-size` | small client types | large client types |
|---|---|---|
| `latest` (default) | window → 80x23 | window → 200x49 |
| `largest` | stays 200x49 | 200x49 |

`largest` was implemented core-side and reverted. It spares the desktop, but it charges the
phone a permanently cropped 200-column window, panned one line at a time, which puts the cost on
the client least able to absorb it. Nothing is set. What still holds:
- **The window follows the client in use.** The phone gets a properly wrapped terminal at its own
  width while it is being used. Measured: a `-x 200 -y 50` session attached from the simulator
  became 62 columns, and `tput cols` in the pane agreed.
- **A detached session keeps its size under either setting**, so the grid's snapshots of agent
  panes are unaffected.
- **`window-size` is a per-window option that a new window does not inherit.**
- **Output already printed into a shell pane stays hard-wrapped at the narrow width.** A
  full-screen agent TUI redraws on SIGWINCH and recovers completely.

**D30. Both apps draw with the user's Ghostty config; the phone adds a text size.**
- **Mac.** It reads the user's four Ghostty config files (`config`, `config.ghostty`, under XDG
  and then `com.mitchellh.ghostty`), so its panes look like their terminal. A second place to
  set the same values would conflict with those files.
- **Phone.** It has no such files, so it asks the core for them. `GhosttyConfig`
  (erickgnclvs/moomux#311) serves the same files concatenated in the same order, read on the
  core's machine, with no settings screen on the phone. On top of it the phone adds:
  - `window-padding-x = 8`, `window-padding-y = 6` and `adjust-cell-height = 14%`, appended after
    the served config (a grid drawn to the edge of a phone reads as broken, and default leading is
    too tight at arm's length). A served padding still wins where it is set, since ghostty keeps
    the last value.
  - Text Size in the pane's ⋯ menu, 8–16pt, default 11pt, plus pinch. This wins over a served
    `font-size`, since a desktop's size is not a phone's.
- **Themes on the phone.** Its resource bundle ships none, so `theme = <name>` is rewritten to
  the absolute path of the app's own copy of that vendored theme (`AppState.localizedThemes`,
  asserted in `--selftest`). A name not vendored is dropped by narrowing, as on the Mac.
  `make ios` and the Xcode target both put `Resources/ghostty-themes` in the bundle.
- **No config, or an older core.** The built-in dark palette, as before. A config that lands
  after a pane is already open rebuilds that pane once (`paneConfigGeneration`).
- **Measured** against a core built from the core's `main`, serving a scratch config with
  `theme = Dracula`, `font-size = 17` and `window-padding-x = 30`. The phone's pane drew
  Dracula's palette and the wide padding, and tmux saw 43 columns, the phone's 11pt Text Size
  rather than the served 17.

The font size is a control and not a constant because, while attached, the font decides the
session's width: 8pt gives about 62 columns and 11pt about 43, and an agent TUI hard-wraps code
below about 50. No value suits both prose and code. The size is kept across sessions and
launches, whichever way it was set: the menu or a pinch. The menu is in the pane because the pane
is where you judge it.

The package tracks pinch in a private counter, with no getter or callback, so a pinch could not
be saved. So the phone's `LinkTapView` owns pinch instead. It switches the package's recognizer
off and steps the live surface with ghostty's `increase_font_size`/`decrease_font_size`, 6–24pt.
A menu change goes through the same call, so the surface is never rebuilt; the new width reaches
the pty as an ordinary resize (D27). *Where:* `AppState.paneConfig`, `TerminalFontSize`,
`LinkTapView.setFontSize`.

**D31. Focus: automatic on the Mac, tap-to-type on the phone.** The Mac takes first responder in
`viewDidMoveToWindow`, because SwiftUI leaves it on the sidebar. The phone deliberately does not:
the software keyboard covers half the pane, and most of the value there is reading what the agent
is asking. Raising the keyboard shrinks the surface, which triggers a reattach (D27). Suspect that
first if input misbehaves right after the keyboard appears.

**D32. Same scroll fix on both, for the same cause.** ghostty reports a wheel at the last pointer
position and drops it when there is none. The Mac forwards `scrollWheel` as a `mouseMoved` inside
the view. The phone calls `sendMousePos` on `touchesBegan`. Delete both once libghostty-spm sends
a position itself.

**D33. The same two surface delegates on both.**
- **Clipboard confirmation.** A paste is allowed and OSC 52 is refused. With no delegate, the
  bridge silently denies the user's own multi-line paste.
- **Open-URL.** Every surface installs a delegate, because without one ghostty core opens links
  itself and bypasses the allowlist.

**D52. Selecting text: in the pane on the Mac, in a sheet on the phone.** The Mac drags a
selection in the surface and copies with ⌘C. On the phone a finger drag is a scroll, and tmux owns
the mouse, so a long-press opens `SelectionSheet` instead: the visible screen as text in a
read-only `UITextView`, the word under the finger pre-selected, iOS's own handles and Copy. The
package's long-press recognizer refuses to begin unless the delegate conforms to
`TerminalSurfaceTextSelectionRequestDelegate`, which is why there was no selection at all before.
Known limit: the visible screen only, not scrollback.

---

## F. Links and files

| | Mac | iPhone |
|---|---|---|
| Allowlist | `TerminalLink`: http, https, file | `WebLink`: http, https |
| Absolute path in a pane | opens locally if it exists; in a remote pane, `ReadFile` → temp file → default app | `ReadFile` → temp file → Quick Look |
| Relative or `:line:col` path | `ResolveFile` on the core → opens locally; in a remote pane, `ReadFile` | `ReadFile` (the core resolves it) → Quick Look |
| Ticket/PR tag | `WebSheet` (in-app WKWebView) | `Link` → the claiming app, then Safari |
| Asana | rewritten to `asanadesktop://` | not rewritten |
| MergeRight | when on and a handler is registered | when on and `canOpenURL` (`LSApplicationQueriesSchemes`) |

**D34. Two allowlists, because a path means something different on each.** Pane output is
attacker-influenceable on both. On the Mac, a `file:` URL or a path names this disk, so it may
open. On the phone it names the core's disk, so `WebLink.filePath` sends it to `ReadFile`, and
the core decides what may be read. Quick Look needs a name it recognises, so `PreviewFile` appends
`.txt` to text files with no known type, such as `Makefile`, `.env` and `.go`.

**D35. A tap on the phone is probed as a ⌘-click.** ghostty follows a link only with ⌘ held, and
a finger carries no modifiers. On a clean tap, `LinkTapView` asks `mouse_over_link` with `super`
(plus `shift` while tmux captures the mouse), follows a link if one is there, and otherwise
toggles the keyboard as before. The Mac adds Shift to ⌘ events for the same mouse-capture reason
(`TerminalLink.addsShift`). Known limit: `link-previews = false` would stop taps finding plain
URLs.

**D36. Tags open in-app on the Mac and through the system on the phone.** On the Mac, `WebSheet`
closes with Esc and has "Open Externally" as the escape hatch. On the phone, `Link` hands an
https URL to whichever app claims it, which covers GitHub and Asana, before Safari. The Mac
rewrites Asana URLs because Asana's desktop app claims no universal link. The phone does not
rewrite them: the iPhone Asana app claims `app.asana.com`, so the plain https link already
reaches it. No comment in the code records that reason.

**D37. Every first-prompt attachment goes through the core, on both.** The phone has to upload,
since a phone path means nothing to an agent on the Mac. The Mac uploads too (`PromptEditor`,
`SaveFile`), so there is one path rather than two. The cost is that a dropped repo file arrives
as a copy, and folders cannot be attached. HEIC is re-encoded to JPEG, and other images the
agents cannot read to PNG (`Attachments.prepare`). Uploading is the point, not a cost to shave:
it is what makes a first prompt work against a core on another machine, which is the direction
both apps are going.

**D38. Files dropped on a *running* pane: an exception on the Mac.** A Finder drop onto a Mac pane
types local shell-quoted paths, the iTerm/Terminal convention, with no upload. The phone's "Attach
Photos/Files" in the pane's ⋯ menu uploads and pastes the returned path with `paste(text:)`, so
bracketed paste lets claude see a file rather than typing (an image becomes `[Image #1]`). The Mac
shortcut holds only because the Mac and the core share a disk. In a remote pane (D25) the drop
is uploaded and the core's path pasted, as on the phone.

---

## G. Navigation

| | Mac | iPhone |
|---|---|---|
| Structure | `NavigationSplitView` + inspector (⌘I) | `NavigationStack` over one `Route` enum |
| Screens | detail column: grid, pane, or info | list → detail / terminal / changes / file diff |
| Modals | one root `.sheet(item: $app.sheet)` | local `@State` sheets; alerts with text fields |
| Error alert | on the root | on the `NavigationStack`, so it shows over a pushed pane |
| Search | sidebar field, ⌘F on macOS 15+ | `.searchable` on the list |
| Notification tap | selects the row, raises the window | pushes the pane (or detail, if parked) |

**D39. One route type and one destination on the phone.** Mixing `navigationDestination(for:)`
with `(isPresented:)` pushed an *empty* screen on a deep link. So did resolving the session inside
the destination closure, because that closure is not a view body and registers no observation
dependency. So each screen looks its session up in its own `body`.

**D40. Modals: one root sheet on the Mac, local state on the phone.** The Mac's Session menu can
open any form with no row on screen, so every form goes through `app.sheet`. The phone has no menu
bar. Its Rename and Tags are alerts with fields ("one field, one question"). Its "Couldn't do
that" alert hangs off the stack, because a refused Review is raised from a screen that has already
navigated to the terminal.

---

## H. The list and its rows

| | Mac (`SessionList`) | iPhone (`SessionListView`) |
|---|---|---|
| Lenses | project-first / folder-first, ⇧⌘F | the same two, ⋯ → Group by Folder |
| Project header | plain `.selectionDisabled()` row | `Section` header (project-first) or row (folder-first) |
| Row | state icon + name; badges on a second line | state icon + name + badges on one line |
| Quip | toolbar title for the selection | toolbar title of the attached pane |
| Font | Settings → Appearance (family, size) | system, `SidebarGrid.phoneFont` |
| Tap | select, and auto-attach if alive; double-click attaches even parked | attach if alive, else open detail |
| Empty state | "Can't reach moomux" / "No projects yet" / "No sessions" | connection row; "No sessions" only once `.connected` |

**D41. A tap never starts an agent, on either.** Selecting a Mac row auto-attaches only when the
session is alive and tmux is found. That is deliberate and works well: a selected live session
is one you want to see, and with no kicking (D29) it costs the other devices nothing. Tapping a
parked row on the phone opens detail, because `Attach` revives, and a mis-tap while scrolling
would start an agent. A tapped phone notification follows the same gate. Reviving is always a
deliberate button: Attach in detail, or double-click on the Mac.

**D42. One row line on the phone, not two.** The Mac's second badge line cost about half a row of
height per session on a phone and pushed three sessions off the screen. So the badges sit
right-aligned on the name's line and the name truncates at the tail. The quip moved to the pane's
title, where it describes the session you are in.

**D43. Plain rows for Mac headers, `Section` headers on the phone.** A Mac sidebar `Section` keeps
its own hidden disclosure state, which falls out of phase with the core's collapsed flag at
launch. The phone's `Section` has no such state. The folder-first lens is one flat list on both.
Both lay rows out on `SidebarGrid`'s columns and rotate one chevron rather than swapping glyphs of
different widths.

**D44. Row actions follow the input device.**

| | Mac | iPhone |
|---|---|---|
| Attach | select / double-click / ⌘↩ | tap |
| Archive / Unarchive | ⌘E, context menu | trailing swipe |
| Details | inspector ⌘I | trailing swipe; ⋯ in the pane |
| Review | ⌘G, context menu, detail | leading swipe, detail |
| View changes (native diff) | none (D46) | leading swipe, pane toolbar, detail |
| File into a folder | context menu → Folder, drag | drag onto a folder header |
| Rename | Edit… ⇧⌘R (with agent) | detail → Rename… (name only) |
| Tags | ⌘T, context menu | detail → Tags… |
| Delete | ⌘⌫, context menu | detail |
| Kill tmux | ⇧⌘K, context menu (not confirmed) | detail (confirmed) |
| New Folder | project header, row → Folder | detail → Folder → New Folder… |
| Diff tool, Copy Path, Move Up/Down | yes | none, deliberately |
| Folder header menu | Rename, Archive All, Unarchive All, Delete | the same (long press) |

Kill tmux is confirmed on the phone and not on the Mac, because a phone row is a bigger target for
a mis-tap and this stops an agent mid-thought. On the phone it takes the session's pane out of the
stack first, so the pane's reconnect cannot stand the session straight back up (D28). The diff
tool needs `Process`, reordering is a desk task, and a worktree path means nothing on a phone.

The long press on a phone row belongs to `.draggable`. Review moved from a context menu to a
swipe because two things on one long press means one of them never fires. Folder headers are row
content with `onTapGesture`, not a `Button`, on both, because a `Button` swallows the long press
that `.contextMenu` needs.

**D45. New Session: the same form and the same single `CreateSession` call; different seeding and
exits.** Both build on `NewSessionForm` and the core's `AgentOptions`.
- **Seeding.** The Mac seeds the project from the selected row. The phone starts with no project,
  and Create waits until one is chosen, because a phone has no selection and defaulting to the
  first project put every session there unless you remembered to change it.
- **Closing.** Both close on Create and report progress through `busy`.
- **Focus after create.** The Mac selects the new session while `autoFocusNewSession` is on
  (§J). The phone always goes to it, with no control to turn that off: on a phone, landing in
  the session you just made is the point of making it. The one exception is that the user must
  still be on the list (`focus: { path.isEmpty }`), because a create takes tens of seconds and a
  jump would detach whatever pane they are typing in.
- **Dismissal.** The phone disables swipe-to-dismiss once anything is typed or uploading.

---

## I. Review and diff

**D46. Review is on both; a native diff is on the phone only.**
- **Review, both apps, on its way out.** Review opens a `review` window in the session's tmux
  (the core's `Review`). On the phone, the screen then follows to the pane, because a window
  opened inside tmux means nothing unless you see it. Review needs a live session (`canReview`).
  It is expected to be phased out in favour of the native diff, so do not build on it.
- **Native diff, phone only.** At 43–62 columns the tmux pager is the worse half, so the phone
  renders the diff itself with `DiffKit`, and the core grew `Diff`: the merge-base diff as text,
  untracked files included, with no tmux needed. So `canDiff` does not need a live session, and
  a parked session's diff opens.
- **The Mac instead.** It keeps the tmux pager plus a GUI diff tool (⌘D, `ToolPath`, which does
  not exist on iOS). On a desk those beat any viewer the app could draw.

*Where:* `ChangesScreen.swift`, `AppState.loadDiff`, `AppState.review`.

---

## J. Settings and preferences

**D47. Two kinds of setting, and only one is shared.**
- **Shared (`config.toml`).** Everything in `config.toml` lives on the core, so both apps see the
  same value, and the Mac is the only place to edit it.
- **Per device (`UserDefaults.standard`).** Everything else is in each app's own domain, and
  nothing carries it across.

```sh
rg -n 'static let \w+Key = ' Sources/MoomuxKit/App/AppState.swift     # the per-device keys
rg -n 'NSUbiquitousKeyValueStore' Sources                             # nothing: no sync
```

| Setting | Where it lives | Mac | iPhone |
|---|---|---|---|
| projects, agent, skip-permissions, base branch, branch prefix, emoji | core | ✅ Settings → Projects | applies, not editable |
| sort by last opened, send first prompt by default, relaunch TUI in tmux | core | ✅ Settings → General | applies, not editable |
| theme, TUI appearance | core | ✅ Settings → Appearance | theme colours apply to the rows |
| project collapsed, folder collapsed | core | ✅ | ✅ (both toggle the same flag) |
| group by folder (`folderFirst`) | device | ✅ toolbar, ⇧⌘F | ✅ ⋯ menu |
| folder-subheader folding (`folderProjectCollapsed`) | device | ✅ | ✅ |
| open PRs in MergeRight (`mergeRightLinks`) | device | ✅ Settings → General | ✅ ⋯ menu |
| select a new session when created (`autoFocusNewSession`) | device | ✅ Settings → General | n/a: always on (D45) |
| diff tool (`diffTool`) | device | ✅ | n/a (no `Process`) |
| sidebar font (`listFontFamily`, `listFontSize`) | device | ✅ Settings → Appearance | n/a |
| terminal size (`terminalFontSize`) | device | n/a (D30) | ✅ pane ⋯ menu, and pinch |
| core address (`coreHost`, `corePort`) | device | n/a (`--socket`) | ✅ connect screen |

The practical consequence: turning MergeRight links or folder grouping on at the desk does
nothing on the phone. That is harmless while each one has a control on both sides.

---

## K. Notifications

| | Mac | iPhone |
|---|---|---|
| Banner when a session starts waiting | yes, except for the selected session while the app is active | yes, except for the pane on screen, in the foreground too |
| While not running | n/a: the app stays up | background refresh, at iOS's discretion, 15 minutes at the earliest |
| Count | Dock badge + menu-bar extra | app-icon badge, as fresh as the last snapshot |
| Asked | at launch (`.alert`, `.sound`, `.badge`) | the same, so the prompt covers the first screenshot on a fresh simulator |
| Tap | selects the session, raises the window | pushes the pane, or detail if parked |

**D48. Same `Notifier` and the same rule, and a background refresh to reach the pocket.**
Transition detection is shared and asserted (`Notifier.transitions`).
- **Foreground.** `willPresent` shows banners while the app is in front, which iOS otherwise
  drops. `report` leaves out the session whose pane is on screen (`AppState.paneOnScreen`), the
  phone's version of the Mac's "not for what you are looking at".
- **Background.** iOS suspends the app and holds no connection for it, so `BackgroundRefresh`
  (`MoomuxiOSApp.swift`) runs a `BGAppRefreshTask`. It is registered in `App.init`, because
  `BGTaskScheduler` silently refuses a late registration. It is scheduled when the app goes to
  the background and rescheduled first thing in each run. Each run is `AppState.pollOnce`: one
  `Watch` snapshot through the same `apply` path as the stream, so a background banner follows
  the same rules as a foreground one, and the badge moves with it.
- **Cold launch.** If iOS relaunched the app cold, there is no earlier state to compare against.
  That run only seeds and sets the badge, the same launch guard the foreground has.
- **Badge.** It is an XPC round trip, so it is sent only when the count moves.

The ceiling is D5: polling, not push. A banner can be late by however long iOS waits, and the
badge is as fresh as the last refresh it granted.

---

## L. Verification

**D49. `--selftest` covers the Kit; nothing covers `MoomuxiOS/`.** The checks run through the
shipping Mac binary, which links the Kit. So **pure logic the phone needs goes in the Kit, with a
`demo()`**. `AttachSizing`, `Reattach`, `AttachChannel.splitLine`, `WebLink`, `PreviewFile` and
`Attachments` are there for exactly this reason. SwiftUI views have no coverage on either
platform.

**D50. Screens are reached differently because input is.** The Mac has `Scripts/ui.swift`, which
walks the AX tree and refuses to drive any build but this worktree's. The simulator cannot be
driven that way, so the phone reads launch arguments from `UserDefaults`' argument domain:
`-coreHost`, `-corePort`, `-openSession <id>`, `-attach 1`, `-changes YES`, `-diffFile <path>`
and `-newSession YES`. `simctl io screenshot` needs no Screen Recording grant; `make shot` does.

Traps on the phone side that are not written down anywhere else (`CLAUDE.md` has the simulator
basics):
- **`simctl launch` does not install.** Launching without `simctl install` tests the previous
  binary, so a fix and its absence both "pass". `make ios-run` installs.
- **A screenshot proves nothing about what happened after it.** Check
  `~/Library/Logs/DiagnosticReports/` for `Moomux-*.ips` after exercising a new path. That is how
  the detach crash in D28 was found.
- **`EnsureTmux` recreates a session under its canonical name** (`moomux-<name>-<hash>`), not the
  stored `tmux_session`, so `has-session` on the stored name says "gone" while the session is
  back. Diff the whole `tmux list-sessions` instead.
- **Timing the first screenshot.** At ~1.6s it beats the notification prompt but also the first
  snapshot, so every label reads "unknown". ~2.2s is the window between the two.
- **Held keys do not repeat in the simulator.** iOS sends one `pressesBegan` per hold. A device
  repeats in its HID layer, and the libghostty-spm fork handles both paths. `TerminalDebugLog.sink`
  with `.enable(.input)` sends the package's input log to a file.
- **`NSLog` does not reach `log show` from the iOS bundle either.** Append to a file under
  `URL.temporaryDirectory` and read it through `simctl get_app_container booted app.moomux.Moomux
  data`.

---

## Shared on purpose

These look like they could differ. Here is why they do not:

- **State colours and badges** come from the core's served palette through `SessionTheme`, so the
  rows agree by construction. The badge *views* are two copies (§N 2).
- **Folder semantics** are Kit logic: a global namespace, `SetFolderCollapsed` everywhere, and
  loose-block vs subheader folding (`Layout`, `AppState.collapsedGroups`). Both lenses branch on
  `folder.isEmpty`. This became a rule after the phone drew the loose block and a subheader with
  one view. Both arrive as `FolderSidebarRow.project`, but they mean different things. The wrong
  version persisted a loose-block key that nothing could clear, so `collapsedGroups` now drops
  those keys, and `setFolderProject` with an empty folder forwards to `setProject`.
- **Delete asks once**, and on both the message is the safeguard (`askDelete` → `deleteWarning`).
  It says it is checking until the worktree status lands.
- **Search** matches names only, over the whole store, archived sessions included, on both.
- **What's New** is one `WhatsNew` type and one baked `WhatsNew.md` per build.
- **The cow and quip title** uses the Kit's `SpeechBubble`. The phone rasterizes the Mac's SVG at
  build time rather than checking in a second asset.
- **Claude usage** (5h and weekly quota) is the snapshot's `usage`, which the core reads from
  agent-usage's file and grades itself (`level`, `stale`), drawn by the Kit's `UsageLine` on both.
  The detail is the same lines (`Usage.detail`, one per reset time) in a click-to-open popover on
  the Mac and a menu on the phone. Only the Mac's line says "used" — the phone's top bar is too
  narrow, the same call the TUI makes in its footer. No `usage` key — no agent-usage on the core's
  Mac, or an older core — draws nothing on either.
- **A failed call never reads as empty.** The phone's "No sessions" waits for `.connected`, not
  merely "not down".

---

## M. Open decisions

Differences that do not hold up from the user's side, whether or not the code gives a reason for
them. A documented reason is not the same as a good experience. Settle one by promoting it to a
decision above (or changing the code), and remove it from here.

1. **The Mac has no UI for choosing a remote core** (D25). It is `defaults write
   app.moomux.Moomux coreHost <host>` (plus `corePort`) or a launch argument, then a relaunch,
   because the Mac builds one store per process. A field in Settings → General, applied on
   relaunch, is the likely shape; the phone's connect screen is the model.

## N. Known drift

Not questions, just things out of step. Fix them and remove them from here.

1. **Background refresh has not been watched working.** It builds and registers, and `pollOnce`
   shares the foreground's `apply`, but a refresh only fires when iOS decides. In the simulator,
   the debugger's `_simulateLaunchForTaskWithIdentifier:` is the way to force one.
2. **The badge row and the cow title are two copies.** Each copy keeps the order and look only by
   comment.
   `rg -n '"plusminus"|struct CowQuip' Sources   # one of each per app`
