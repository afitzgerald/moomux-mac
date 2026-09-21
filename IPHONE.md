# Moomux for iPhone — plan

**Status: Phase 3 is done.** The app builds, installs and runs in the simulator against a real
`moomux serve`: session list grouped by project, detail, search, archived toggle, archive from a
swipe, and the connection badge. What is left needs the core (§2, §3) — attach, the grid and
review. Every claim below that could decay carries the command that produced it, per the repo's
own rule about prose that rots silently. Measured on this machine on 2026-09-19.

## The one-sentence version

The terminal is the easy part — the dependency already ships it for iOS — and the real work is
in the **Go core**, which today has no way to hand a byte stream to anything but a process on
the same machine.

---

## 0. Blockers to clear before a line of code

| Check | Result |
|---|---|
| `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer` ✅ |
| `xcodebuild -version` | `Xcode 27.0` ✅ |
| `xcrun simctl list runtimes \| rg '^iOS'` | `iOS 27.0` ✅ |
| `ls /Applications/Xcode.app/Contents/Developer/Platforms/` | includes `iPhoneOS.platform` ✅ |
| `security find-identity -v -p codesigning \| rg -c 'Apple Develop\|Developer ID'` | `2` ✅ |
| `tailscale status` | Mac `100.71.5.0`, `iphone181` `100.91.153.105`, same user ✅ |
| Paid Apple Developer account | see below ❌ |

1. **`CLAUDE.md` is stale about the toolchain.** Its whole "The environment decides more than
   you'd think" section opens with "Xcode is installed but not selected" and
   `xcode-select -p` still saying `CommandLineTools`. That is no longer true — another project
   on this machine needed Xcode and switched it globally, which is exactly the cross-worktree
   consequence `CLAUDE.md` warned about. Three entries need rewriting before anyone trusts it:
   the `#Preview`/XCTest "cannot be done" facts are now choices, `xcodebuild` works, and the
   `SDKROOT` pin should probably go.

   The pin still *resolves* — `ls /Library/Developer/CommandLineTools/SDKs/` shows
   `MacOSX26.sdk -> MacOSX26.5.sdk` — so `make build` is not broken, it is merely compiling
   against a 26.5 SDK with a 27 toolchain for a reason that no longer applies: Xcode ships the
   `SwiftUIMacros` plugin whose absence forced the pin. Verify and delete it, as its own change,
   before any iOS work confuses the two.

2. **A paid Apple Developer account ($99/yr).** Free provisioning expires in 7 days and needs
   Xcode plus the device to re-sign; TestFlight needs the paid account. Not a blocker for the
   simulator, so everything through Phase 3 proceeds without it. `README.md` already notes
   there is no paid account for Developer ID either — the `.dmg` is signed with a Developer ID
   certificate that came from somewhere else, so check what the two identities above actually
   are before assuming.

3. **Two repos move, not one.** The core is `erickgnclvs/moomux` (`~/personal/moomux`), a
   separate Go repository. Most of the work in this plan lands *there*. Plan the sequencing
   accordingly: the phone cannot be built against a core that has not shipped its half.

---

## 1. What ports for free

```sh
wc -l Sources/Moomux/*/*.swift | sort -rn
```

| | lines | ports? |
|---|---:|---|
| `Core/Models.swift` | 1161 | ✅ wire types, pure |
| `Core/MoomuxClient.swift` | 678 | ✅ minus the transport it sits on |
| `Core/StreamSocket.swift` | 87 | ✅ one extra initializer covers TCP — see §3 |
| `Core/ToolPath.swift` | 118 | ❌ meaningless — no `Process` on iOS |
| `App/AppState.swift` | 1830 | ✅ except two `ToolPath` call sites (§2) |
| `App/Layout.swift` | 362 | ✅ pure |
| `App/Forms.swift` | 278 | ✅ pure |
| `App/MoomuxApp.swift` | 181 | ❌ scenes, `MenuBarExtra` |
| `App/Notifier.swift` | 127 | ◐ `UNUserNotificationCenter` ports, `NSDockTile` does not |
| `App/GhosttyResourceBundle.swift` | 94 | ❌ macOS bundle layout only (§4) |
| `App/SelfTest.swift` | 55 | ✅ stays in the Mac executable, covers the shared code |
| `UI/*` | 2872 | ❌ all of it |
| **total** | **7843** | **~4,300 shared** |

The engine ports almost free; the app does not port at all, and shouldn't. Plan for a phone app
that shares a store and a protocol with the Mac one and nothing else.

---

## 2. The port exposes three places where the Mac app cheats

This is the most useful thing the exercise turns up, and it is worth fixing regardless of
whether the phone app ever ships.

`CLAUDE.md` states the boundary plainly: *"anything the Swift side cannot do over the socket is
a hole in the boundary to fix in Go, not a reason to link the core."* But three features
sidestep the socket and shell out to `tmux` directly:

```sh
rg -n 'ToolPath' Sources/Moomux/
```

| Feature | Where | What it runs |
|---|---|---|
| Session grid | `UI/SessionGrid.swift:118-146` | `tmux capture-pane -p -t <s>` every 5s |
| Review Changes | `App/AppState.swift:1357-1384` | `tmux new-window` / `respawn-window` |
| Attach | `UI/TerminalPane.swift:271` | `tmux attach` via libghostty's `.exec` backend |

All three are legal on a Mac talking to a local core and all three are impossible from a phone.
So the phone's requirements list and the boundary's to-do list are the *same list*: `Capture`,
`Review` and `Attach` become core methods.

**All three exist now** (written, green, not yet committed — `erickgnclvs/moomux`, and
`docs/wire-protocol.md` there is the long form). The contract:

```
{"method":"Capture","args":{"ids":["moomux:a","moomux:b"]}}
  -> {"result":{"screens":{"moomux:a":"row\nrow\n…"}}}
{"method":"Review","args":{"id":"moomux:a"}}
  -> {"result":{"hint":"Opened a review window in moomux-a."}}
{"method":"Attach","args":{"id":"moomux:a","cols":100,"rows":40}}
  -> {"result":{"ok":true}}   then raw pty bytes both ways — see §3
```

Keyed by **session id** throughout; no front end needs a tmux session name any more. Three
decoding rules on `Capture`, all the same instinct as `SessionGrid`'s existing `previous`
fallback: `screens` is `omitempty` so nothing-captured means the key is *absent* rather than
`{}`; an individual id that could not be captured is absent rather than present-and-empty; and
the method never sets `err`. Absent means keep what you last drew, never blank the tile. Send
every tile in one call — it is one tmux invocation server-side however many ids it carries.

The phone does **not** cap the id list — every live session, same as the Mac grid's comment
says — and the rows stay unsplit on the wire: `TmuxSnapshot.rows`/`screen` already truncate to
tile width, which is a rendering decision and belongs on the client.

`Review` resolves the base branch itself (session's own, then the project's, then `main`), so
the Mac app's `config?.projects[…]?.baseBranch ?? "main"` lookup goes away with the migration.
Keep `canReview` for UI gating; it still wants `isAlive`.

**The move fixes a live bug rather than being a wash.** `TmuxSnapshot.split` accepts an
unterminated trailing section, and tmux abandons the rest of a command sequence at the first
error *while still exiting 0* — so when a session dies mid-batch, its `can't find pane:` error
is appended to the **previous** session's screen and drawn into that tile. The core's version
emits a closing marker after the last capture and accepts only sections delimited on both
sides. It also keys its batch markers by session *index* rather than name: tmux expands
`#{…}` inside `display-message`, and a session name can contain one.

`ToolPath.find("tmux") != nil` is also used at `RootView.swift:1267/1291/1328` purely to *gate
UI*. On iOS that gate has to come from the snapshot instead, which is where it belonged anyway:
the core already folds tmux liveness into `sessionview`.

---

## 3. Transport — decided

**There is no tunnel to build. Tailscale is the tunnel.**

```sh
tailscale status
# 100.71.5.0      alans-macbook-pro  alanfitzgerald@  macOS
# 100.91.153.105  iphone181          alanfitzgerald@  iOS
```

WireGuard already gives encryption and machine identity, so there is no pairing flow, no TLS,
no token store to design. What it does not give is *authorization* — every node on the tailnet
can reach the listener, and this wire has `CreateSession`, `DeleteSession`, `KillTmux` and a
create path that passes `--dangerously-skip-permissions`.

The core's only listener today is one line:

```
internal/ipc/server.go:128    ln, err := net.Listen("unix", path)
internal/ipc/server.go:139    func (s *Server) Serve(ln net.Listener) error
```

`Serve` already takes a listener, so this is **two listeners and one handler** — the unix socket
stays exactly as it is for `moomux ui` and local clients. The new one binds the Tailscale
address and authorizes by asking Tailscale who is on the other end:

```sh
tailscale whois 100.91.153.105
# User:
#   Name:     alanfitzgerald@gmail.com
```

Match that against your own login, refuse everything else. The core already shells out to git,
tmux and gh constantly, so one more is in keeping — but use `tailscale whois --json <ip>` and
read `.UserProfile.LoginName`, not the indented text above, which is for humans.

As built:

- **Port 45876** (`ipc.TailnetPort`), fixed.
- **`tailnet_listen = true`**, a top-level bool in `config.toml` — so it has to appear *before*
  any `[projects]` table or TOML reads it as a project key. Off by default and deliberately
  **not settable over the wire**: turning it on exposes `CreateSession`, with its userscripts
  and its permission-skipping flag, to the tailnet. That is a decision made at the machine, so
  do not build a toggle for it. It is readable like any other config field
  (`cfg.tailnet_listen` on every snapshot), which is the "why can't the phone see anything"
  diagnostic.
- Binds the **tailnet address only**, never `0.0.0.0` — `127.0.0.1:45876` is refused at the OS
  level. Authorized peers are cached 60s, or `tailscale` forks once per call inside `Accept` at
  the client's poll rate. A mismatched peer has its connection closed and the listener lives on.
- **Failure to bind is never fatal.** No Tailscale, stopped daemon, logged-out node: all log and
  leave the unix socket serving.

One correction to what this section used to claim: `moomux ui -socket` over the tailnet
*could not* have been the test, because `ipc.Client` dialled `unix` unconditionally. It now
takes a `host:port` too — a leading `/` or `.` still means a path, so a socket path containing
a colon keeps working — which is the same shape as the Swift `Endpoint` enum.

**Why not `tsnet`.** It is the more correct answer — the core becomes its own tailnet node and
never touches the host's network stack, so there is no way to fat-finger a bind onto the LAN.
It also pulls the entire `tailscale.com` module into a `go.mod` that is currently nine direct
requirements. Start with the bind-plus-`whois` version; reach for `tsnet` if the bind turns out
to be fragile when the interface is down. Keep Funnel off either way.

**The transport cost one initializer, not a rewrite.** `UnixSocket` is a blocking fd wrapped in
`FileHandle`, and everything above the connect — `write`, `readToEnd`, `bytes.lines`, `close` —
is identical for TCP and works unchanged on iOS. So it became `StreamSocket` with a second
`init(host:port:)`, and `MoomuxClient` grew an `Endpoint` enum (`.unix` / `.tcp`) that the two
call sites ask to connect. `Network.framework` was considered and is not needed; the comment at
the top of that file already explained why its state machine is ceremony for a protocol that
closes the connection after every call. `getaddrinfo` rather than `inet_pton`, so a MagicDNS
name works and not only a `100.x` address, and every answer is tried — a node with both A and
AAAA records hands back two, and connecting only to the first is how a v6-only path looks like
a dead server.

### The attach stream

The laziest framing is no framing, and it survived contact. The phone opens a second
connection, sends one `Attach` line, gets **one** `{"result":{"ok":true}}` line back, and from
there **that connection is the pty** — raw bytes both ways, forever. No length prefixes, no
multiplexing, no protocol to design. Closing the socket is the detach; tmux loses the client
and keeps the session. Go side is `creack/pty`'s `pty.StartWithSize` around
`tmux attach -t <session>`.

**The trap, and it will bite the Swift side specifically.** After reading the response line,
whatever is already in the buffer past that `\n` is *pty bytes* — the first chunk of the screen
tmux drew. Read exactly to the first newline and keep the remainder. `MoomuxClient.call` reads
to EOF and hands the lot to a decoder, which would eat the first frame and leave the pane
blank-until-keypress; the Go client hands `dec.Buffered()` on to the reader for exactly this
reason. Attach needs its own read path, not `call`.

Three more things settled in the building:

- **Errors only exist before the switch.** Unknown session, a session with no tmux name, a pty
  that would not allocate — all arrive as an ordinary `{"err":…}` line and the connection
  closes. After `{"ok":true}` there is nowhere to put one, so a later failure *is* the socket
  closing.
- **Resize is initial-only**: `cols`/`rows` on the request, straight into `pty.Setsize`. A
  client that changes size mid-attach detaches and reattaches. Missing or absurd values become
  80x24 and never 0, since a zero-sized pty draws nothing and reads as a hang. **Always send
  real numbers** — 0 is legal and gets 80x24, which looks wrong on a phone. If rotation makes
  the reattach visibly bad, that is the moment to ask for an in-band path; it is deferred, not
  forgotten.
- **No `EnsureTmux` call first.** `Attach` does it, so attaching to a parked session revives
  it, and the tmux name is read after any name migration. `TERM` on the pty is fixed at
  `xterm-256color` — not negotiable from the client, because the terminfo entry has to exist on
  the *core's* machine. `TMUX`/`TMUX_PANE` are stripped from the child env, or a core started
  inside tmux would be refused for nesting.

---

## 4. The terminal — the dependency already does this

All verified at the **pinned** version, not at `main`:

```sh
git clone --depth 1 https://github.com/Lakr233/libghostty-spm.git
git fetch --depth 1 origin tag 1.5.20260906
git show 1.5.20260906:Package.swift | sed -n '/platforms/,/]/p'
#   .iOS(.v15), .macOS(.v13), .macCatalyst(.v15), .visionOS(.v1)
git ls-tree -r --name-only 1.5.20260906 Sources/GhosttyTerminal/Platform/UIKit/ | wc -l
#   17
```

Seventeen files of `UITerminalView`: `UITextInput`, keyboard, pointer, scroll, pinch-zoom,
clipboard, drop, key commands. No zig build, no hand-written key translation, no
`xcodebuild -create-xcframework`. The whole reason `CLAUDE.md`'s dependency bullet chose this
package over building libghostty from source applies a second time, for free.

The shipped binary really has the slices. Read from the release zip's central directory without
downloading the 77MB:

```sh
U=https://github.com/Lakr233/libghostty-spm/releases/download/upstream.c4e16970a803/GhosttyKit.xcframework.zip
L=$(curl -sIL "$U" | rg -i '^content-length' | tail -1 | tr -d '\r' | awk '{print $2}')
curl -sL -r $((L-300000))-$((L-1)) "$U" -o /tmp/tail.bin
strings /tmp/tail.bin | rg -o '(ios|macos|xros)[^/]*/' | sort -u
#   ios-arm64/  ios-arm64_x86_64-simulator/  ios-arm64_x86_64-maccatalyst/
#   macos-arm64_x86_64/  xros-arm64/  xros-arm64_x86_64-simulator/
strings /tmp/tail.bin | rg -o 'ios-arm64/[^ ]*' | sort -u
#   ios-arm64/Headers/libghostty/{ghostty.h,module.modulemap}  ios-arm64/libghostty.a
```

(Sampled on the neighbouring upstream tag; re-confirm on whatever `upstream.*` the pin resolves
to before relying on it.)

### The remote-pty contract already exists, and half of it is already in use

```sh
grep -n 'public func\|public init' Sources/GhosttyTerminal/InMemory/InMemoryTerminalSession.swift
#   public init(write: @escaping (Data) -> Void, resize: @escaping (InMemoryTerminalViewport) -> Void, …)
#   public func receive(_ data: Data)
#   public func sendInput(_ data: Data)
#   public func readViewportText() -> String?
```

That is exactly a network terminal: `receive` ← bytes from the Mac, the `write` closure →
keystrokes back to the Mac, the `resize` closure → a window-change message.
`UI/SessionGrid.swift` already drives this backend today and simply ignores the input half.
Point `receive`/`write` at the socket and it is a full interactive client.

**`.exec` is not needed and would not work.** No fork/exec in the iOS sandbox. The pty lives on
the Mac now, which quietly deletes two of this repo's nastiest bugs from the phone's surface:
`TERMINFO` (`CLAUDE.md`'s "a pane that dies in ~70ms") and `String.shellQuoted` on the
`.exec` command — the phone spawns nothing, so there is nothing to quote and no terminfo for a
child to find. Both remain the Mac's problem.

**`Bundle.module` resolves on iOS with no `warm()` hook** — confirmed by the app launching.
That hook exists because `codesign` refuses a *macOS* app bundle with anything but `Contents/`
at its root, forcing the resource bundle somewhere SwiftPM's generated accessor does not look.
An iOS bundle is flat, so `GhosttyKit_GhosttyTerminal.bundle` sits at the root, which is exactly
the accessor's first candidate. `make ios` copies it there. The accessor `fatalError`s when it
misses, so launching at all is the proof — the same check the macOS side uses.

---

## 5. tmux sizing — measured, and deliberately left alone

Every tmux client on a session shares one window size. `CLAUDE.md` calls this out as the reason
attaching is an explicit action and not a consequence of selecting a row, and notes the desktop
stays letterboxed "until detach — not when the bigger client is used again". A phone attaching
to a session someone is working in is the worst case for this, so it was measured properly: two
real clients, 200x50 and 80x24, on a throwaway server (`tmux -L t1`), tmux 3.7c.

| `window-size` | 80x24 client types | 200x50 client types |
|---|---|---|
| `latest` (the default) | window → **80x23** | window → 200x49 |
| `largest` | stays **200x49** | 200x49 |
| `manual` + `resize-window` | stays **200x50** | 200x50 |

Two findings:

1. **`latest` does spring back on the desktop's next keystroke**, not only on detach. The
   `CLAUDE.md` claim needs re-measuring — a live ghostty surface may have been counting as the
   latest-active client, which would explain it.
2. **`window-size largest` pins the window to the biggest client.** A phone attaching then costs
   the desktop nothing at all; the phone gets a cropped 200-column grid it pans and
   pinch-zooms, and `UITerminalView` ships both gestures.

**And the conclusion this section used to draw from that table was wrong.** It said to set
`window-size largest`; it was implemented core-side and then reverted. The measurements are
right — every cell reproduced independently — but `largest` is the wrong trade, and what
settled it was lived experience neither measurement had: the desktop being letterboxed by a
second client is a *transient* annoyance that fixes itself on the next keystroke, because
`latest` follows whoever typed last. `largest` spares the desktop that self-healing nuisance
and charges the **phone** a 200-column window cropped to its ~60, panned one line at a time,
permanently. The cost lands on the client least able to absorb it.

So the default stands and nothing is set. **This is good news for §4's terminal**: under
`latest` the window reflows to the attaching client, so the phone renders a properly wrapped
terminal at its own width rather than a cropped slice of the desktop's. Measured end to end —
a session created `-x 200 -y 50`, attached from the simulator: the window became 62x61, the
client reports `62x62`, and `tput cols` *inside the pane* says `62`. Pinch-zoom and pan are a
convenience now, not the only way to read a line.

Three details worth keeping rather than re-deriving:

- **It only differs with two clients attached at once.** A detached session keeps its size
  under either setting (verified specifically, because moomux creates every session with
  `new-session -d` and a shrink there would have rendered agent panes at 80 columns for the
  grid), and a single client is followed under either.
- **`window-size` is a *window* option and a new window does not inherit it.** So even if
  `largest` had been kept, "one line at session creation" would have come up `latest` on the
  first review window. This is the trap that survives the reversal.
- **What does not spring back:** plain output already emitted into a shell pane stays
  hard-wrapped at the narrow width. A full-screen TUI redraws on SIGWINCH and recovers
  completely, so the agent pane itself is unaffected — which is the pane that matters.

Reproduce:

```sh
tmux -L t1 new-session -d -s target -x 200 -y 50
tmux -L hb new-session -d -s hb -x 200 -y 50; tmux -L hb send-keys "tmux -L t1 attach -t target" Enter
tmux -L hs new-session -d -s hs -x 80  -y 24; tmux -L hs send-keys "tmux -L t1 attach -t target" Enter
tmux -L t1 set -g window-size largest
tmux -L hs send-keys "echo small" Enter; sleep 1
tmux -L t1 list-windows -F '#{window_width}x#{window_height}'
```

---

## 6. What the phone cannot read: config, themes, fonts

`CLAUDE.md`'s "No font, size or theme settings — panes read the user's own Ghostty config" is a
decision that does not survive the trip. The phone has no `~/.config/ghostty/config.ghostty`,
no `com.mitchellh.ghostty` directory, and no `XDG_CONFIG_HOME`. The reasoning behind the
decision — "a second place to set the same values would have to either lose to the file or
silently override it" — has no file to lose to.

Three options, in order of laziness:

1. **Ship the built-in dark fallback and one font-size control.** There is no config to conflict
   with, so the objection does not apply.
2. **Serve the Mac's config text over the wire.** `AppState.ghosttyConfigPaths` already finds
   and concatenates all four files; moving that to the core and serving the string means the
   phone's panes look like the desktop's with no new settings UI at all. Attractive, and it is
   the same shape as every other "the core computes, this app renders" call.
3. A settings pane on the phone. Don't.

Take (1) for Phase 3 and (2) if it grates. **(1) is what shipped**, plus a phone-only block
appended after the fallback: `window-padding-x = 8`, `window-padding-y = 6` and
`adjust-cell-height = 14%`, because a grid drawn to the edge of a phone reads as broken and the
default leading is too tight to track a wrapped line at arm's length. The surface's `fontSize`
is 11 rather than the Mac's 12 — and that number is not cosmetic: **the window reflows to this
client, so the font decides the session's width while attached.** 8pt gave 62 columns and was
unreadable; 11pt gives ~43, legible but narrow enough that an agent TUI hard-wraps code
mid-token. There is no good answer at phone width, only a choice; a font-size control is the
obvious next step if the default is wrong for a given pair of eyes. Note the vendored themes
(`Resources/ghostty-themes`, 69 files, ~276KB) travel with either — `make app` copies them into
the resource bundle and the iOS bundle would need the same step.

---

## 7. Notifications

The one feature that justifies a phone app at all: a banner when a session starts waiting on
you. `App/Notifier.swift` is 127 lines and `UNUserNotificationCenter` is cross-platform, so the
transition detection ports as-is; `NSDockTile.badgeLabel` becomes
`UNMutableNotificationContent.badge`.

What does not port is *when it runs*. iOS will not hold the `Watch` stream in the background, so
foreground-only notifications are what Phase 3 gets. Real background delivery means APNs, which
means a push server and a certificate — and the Mac has to be awake to notice the transition
regardless. **Out of scope by decision, not oversight** (the user has that covered separately).
Poll while foregrounded; reattach on resume.

Backgrounding also kills the pty connection, and tmux does not care — foregrounding reattaches,
which is the same code path as a cold open. That wants verifying early; it is the one place
where "it works in the simulator" is least convincing.

---

## 8. Repo and build structure

`Package.swift` is one `executableTarget` at `platforms: [.macOS(.v14)]`. It becomes:

```
Package.swift  →  platforms: [.macOS(.v14), .iOS(.v18)]

  MoomuxKit    library target   ← Models, MoomuxClient, StreamSocket, ToolPath,
                                   AppState, Layout, Forms, Notifier   (~4,400 lines)
  Moomux       executable       ← macOS app, unchanged; depends on Kit
  Sources/MoomuxiOS             ← the iOS shell, built by `make ios`, not a SwiftPM target
```

`MoomuxiOS` is deliberately **not** in `Package.swift`: SwiftPM has no per-target platform
exclusion, so a plain `swift build` on the Mac would try to compile UIKit views and fail. It is
compiled by `swiftc` against the cross-built Kit instead — see below.

Five places in `AppState` and `Notifier` needed `#if os(macOS)`: the dock badge, the two font
pickers, `review(_:)` and `openDiffTool(_:)`. `ToolPath` is compiled out entirely off macOS
(`Process` is unavailable on iOS), which is what forced the last two. Moving files across the
module boundary also turned up six members that were `internal` despite crossing a file
boundary — `demo()`, `ghosttyConfigDemo()`, `trimmed`, `nilIfEmpty`, `plainPanes`,
`plainDelegates` — so `CLAUDE.md`'s "public on anything crossing a file boundary" was nearly
but not quite true.

`plainPanes`/`plainDelegates` are now typed as libghostty's own `AppTerminalView` and
`any TerminalSurfaceViewDelegate` rather than `TerminalPane`'s subclasses: the pool is in the
Kit and the views are in the app target, so `TerminalPane` casts on the way out. macOS-only,
since `AppTerminalView` is the package's AppKit half.

Keep `swiftLanguageMode(.v5)` on the library target explicitly. A new target defaults to Swift 6
and silently turns strict concurrency on; here the blocking-fd socket client is the thing that
would break, for the reason already written at the top of `Package.swift`.

**An iOS app does not actually need an `.xcodeproj`.** The recipe is the same shape as `make app`
— assemble the bundle by hand — with `xcrun swiftc` in place of `swift build`:

```
xcrun swiftc -target arm64-apple-ios18.0-simulator -sdk $(xcrun --sdk iphonesimulator --show-sdk-path) \
    -swift-version 5 -module-name MoomuxKit -emit-module -emit-module-path <out>/MoomuxKit.swiftmodule \
    -emit-library -static -o <out>/libMoomuxKit.a $(KIT_SOURCES)
xcrun swiftc -target … -parse-as-library -I <out> -L <out> -lMoomuxKit -o Moomux.app/Moomux $(IOS_SOURCES)
cp Resources/iOS-Info.plist Moomux.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :UIDeviceFamily array" -c "Add :UIDeviceFamily:0 integer 1" Moomux.app/Info.plist
codesign --force --sign - Moomux.app        # ad-hoc is all a simulator asks for
```

**The dependency did not get in the way, which was the open question.**
`swift build --triple arm64-apple-ios18.0-simulator --product MoomuxKit` cross-compiles the Kit
*and* every libghostty target — `GhosttyKit`, `GhosttyTerminal`, `MSDisplayLink`, the
xcframework's iOS slice — into `.build/out/Products/Debug-iphonesimulator/`. So there is no
hand-maintained file list: one `swift build` for everything below the app, one `swiftc` for the
app shell linked against those products. That is `make ios`.

Two things that shaped the recipe, both of which cost a round to find:

- **`SDKROOT` has to be unset for `swift build` and set for `swiftc`, in the same target.**
  The macOS SDK pin at the top of the Makefile is `export`ed, and SwiftPM passes `SDKROOT` to
  the *manifest* compile too — which then builds `Package.swift` for `arm64-apple-macosx14.0`
  against an iPhone SDK and dies with "unable to load standard library for target". So the
  `swift build` runs under `env -u SDKROOT`. The `swiftc` line needs the opposite: `-sdk`
  reaches the Swift frontend but **clang takes its sysroot from the environment**, so with
  `SDKROOT` unset the C module and the link silently fall back to the macOS sysroot
  (`clang: warning: using sysroot for 'macOS 27.0' but targeting 'arm64-apple-ios18.0.0'`).
  Hence `env SDKROOT=$(IOS_SDK)` there. Opposite directions, ten lines apart.
- **`swiftc` needs the C module's headers pointed at by hand.** SwiftPM knows where the
  xcframework slice is; a bare `swiftc` does not, and the failure reads as
  `missing required module 'libghostty'`. The fix is
  `-I .build/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/ios-arm64_x86_64-simulator/Headers`.

The `.xcodeproj` is still where distribution ends up — certificates, provisioning profiles and
an App Store Connect record are several web forms by hand and automatic from a signed-in Apple
ID — but nothing about day-to-day development needs one.

`make build`, `make run`, `make selfcheck` keep working exactly as today.

**One repo or two?** One for the Swift side. The Go work is in the other repo regardless.

---

## 9. Verification

The `demo()`/`assert` harness survives the split for free: `Moomux --selftest` is a macOS binary
linking `MoomuxKit`, so `make selfcheck` covers every shared line the phone depends on. `Layout`,
`Forms`, `Models` and `Wire` — the parts that actually port — are exactly the parts that already
have checks.

```sh
rg '\bassert\(' Sources/ --no-filename -c | awk '{s+=$1} END {print s}'   # 325
rg -c 'demo\(\)' Sources/Moomux/App/SelfTest.swift                        # 13 suites
```

The screenshot loop becomes an `ios-run`/`ios-shot` pair, which preserves this repo's hardest
rule ("you cannot see SwiftUI render by reading it") on the new platform:

```
xcrun simctl boot "$(IOS_DEVICE)" 2>/dev/null || true
xcrun simctl bootstatus "$(IOS_DEVICE)" -b >/dev/null
xcrun simctl install booted $(IOS_APP)
xcrun simctl terminate booted $(IOS_BUNDLE_ID) 2>/dev/null || true
xcrun simctl launch booted $(IOS_BUNDLE_ID)
sleep 4 && xcrun simctl io booted screenshot .build/ios-shot.png
```

Name the device (`IOS_DEVICE ?= iPhone 18 Pro`) rather than using whichever simulator is open, or
a second worktree's run lands in the same one. A crash on launch shows up as a home screen in the
PNG — the iOS counterpart of the `pgrep` check in `CLAUDE.md`. `Scripts/ui.swift` does **not** port: it walks
`AXUIElement` on the Mac. The simulator's equivalent is XCUITest, which now exists but is a
bigger commitment; screenshots first.

**`simctl io screenshot` needs no Screen Recording grant**, which `make shot` does — it reads the
simulator's own framebuffer rather than the display. So the iOS loop works from a tmux pane in
cases where the Mac one returns `could not create image from display` and exits 1. (That error
is also what a locked screen gives; `ioreg -n Root -d1 -a | rg CGSSessionScreenIsLocked` tells
the two apart — the key is absent when the screen is unlocked. The grant is keyed to the
*responsible* process, which for a pane is the tmux server, same as Accessibility, and it takes
effect without restarting that server.)

**There is no way to tap a row from `simctl`, so the screens are reached by launch argument.**
`UserDefaults` reads `NSArgumentDomain`, so `-key value` on the launch line overrides a stored
default for that run without persisting anything:

```sh
make ios-run HOST=127.0.0.1 PORT=8765 SESSION=speedo:tune   # opens straight into the detail screen
```

`-coreHost`/`-corePort` skip the connect screen and `-openSession <id>` seeds the
`NavigationStack` path. Three lines of app code, and the alternative is a screen that can never
be photographed.

**The notification prompt covers the first screenshot.** `Notifier` asks in `init` — for the
badge reason `CLAUDE.md` gives — so a shot taken after ~2s catches a modal alert over the list
rather than the list. Answer it once per simulator (it is sticky per bundle id), or shoot at
~1.6s, which beats the prompt. Note a shot that early also beats the first `Watch` snapshot, so
every label reads "unknown"; ~2.2s is the window where the data has landed and the alert has
not.

**Testing without the core's tailnet listener.** Until §3 ships, a scratch core plus a TCP
bridge gets the whole client path under test, and `XDG_CONFIG_HOME` keeps it away from real
sessions exactly as `CLAUDE.md` describes for the Mac app:

```sh
XDG_CONFIG_HOME=/tmp/mmxios moomux serve -socket /tmp/mmxios.sock &
python3 <<'EOF' &                       # TCP in, unix out — socat is not installed here
import socket, socketserver, threading
class H(socketserver.BaseRequestHandler):
    def handle(self):
        u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); u.connect("/tmp/mmxios.sock")
        def pump(a, b):
            try:
                while (d := a.recv(65536)): b.sendall(d)
            except OSError: pass
            try: b.shutdown(socket.SHUT_WR)
            except OSError: pass
        threading.Thread(target=pump, args=(self.request, u), daemon=True).start()
        pump(u, self.request); u.close()
class S(socketserver.ThreadingTCPServer): allow_reuse_address = True; daemon_threads = True
S(("127.0.0.1", 8765), H).serve_forever()
EOF
```

The simulator shares the host's network stack, so `127.0.0.1` reaches it.

**`NSLog` does not reach `log show` from an iOS bundle either.** Same as the Mac, same fix:
append to a file and read it back. `URL.temporaryDirectory` inside the app, then
`cat "$(xcrun simctl get_app_container booted <bundle-id> data)/tmp/moomux.log"`. Every
non-obvious thing in the terminal work above was found that way and by nothing else — a view
body that never ran, a port that was not the one being passed.

**Nothing verifies the two repos against each other, and nothing will.** There is no CI link
between `moomux` and this repo, so a Go struct tag and its `Models.swift` mirror can drift with
no failure on either side — the failure is a field that silently decodes as its zero value,
which is exactly how a `dangerous` project once got sessions without
`--dangerously-skip-permissions`. `Wire.demo()` pins the encodings this app *sends*; there is no
equivalent for what it receives, and the honest mitigation is that `docs/wire-protocol.md` in
the Go repo is the contract and a change to either side is a change to that file first.

**The recurring bug in this port: two cases that look alike in the data and mean different
things.** Three of the day's bugs were this, and none of them was a typo — each came from
writing code against the *shape* of a value rather than what the case means.

- `TmuxSnapshot.split` treated a terminated and an unterminated trailing section as the same
  thing. tmux abandons a command sequence at the first error *and exits 0*, so a dead session's
  `can't find pane:` got appended to the previous tile's screen.
- `AttachChannel.splitLine` has to distinguish "no newline yet" from "line complete, empty
  remainder". Both are `Data` with nothing after the newline; conflating them blocks forever
  waiting for a line already in hand.
- The folder-first lens rendered the **loose block** and a project **subheader** with the same
  view, because both arrive as `FolderSidebarRow.project`. They are not the same: a subheader
  folds locally, and the loose block folds through the core's `SetProjectCollapsed`.

The third had a tail worth recording on its own, because it outlived the fix. The wrong version
wrote a loose-block key into the local `folderProjectCollapsed` set and **persisted it**;
`collapsedGroups` unions that set with the core-derived one, so after the fix the stale key
still won — the config said not collapsed, the list drew collapsed, and every tap wrote a flag
that was already correct. A fix that stops *writing* bad state does nothing about the copy
already on disk. So `collapsedGroups` now drops loose-block keys before adding the core's, and
`setFolderProject` with an empty folder forwards to `setProject` instead of writing a key
nothing can clear — the invariant is structural now rather than a thing to remember.

The general lesson, since it will recur: when the core hands over one row type covering several
meanings, branch on the meaning at the point of rendering, and make the wrong branch impossible
rather than merely unused.

Three things to re-verify on iOS rather than assume:

- `assert` is compiled out at `-O`. Same guard, same reason — `App/SelfTest.swift` proves asserts
  are live before running anything, and that logic is platform-independent.
- `Bundle.module` resolution without the `warm()` hook (§4).
- That the pty stream survives background → foreground. The likely answer is detach-and-reattach
  on resume; find out before building UI that assumes otherwise.

---

## 10. Phases

Each phase ends somewhere shippable, and the first two are worth doing whether or not the phone
app ever exists.

**Phase 0 — spike, no code.** Any off-the-shelf terminal client on the phone that can reach the
Mac over the tailnet, running `tmux attach`. That tests the whole terminal half for free:
whether the window reflowing to the phone is pleasant or disruptive in real use (§5), and what
backgrounding does to a live tmux client. If the answer is no, stop here; §2's core methods are
still worth having.

**Phase 1 — core: the tailnet listener.** ✅ **Written, green, not committed.** Second listener,
`tailscale whois --json` authorization, same handler, `tailnet_listen = true` to enable. The
test needed `ipc.Client` to learn `host:port` first — see §3.

**Phase 2 — core: close the three holes (§2).** ✅ **Written, green, not committed** —
`Capture`, `Review` and `Attach`, contract in §2. Still to do on the Mac side: switch
`SessionGrid` and `reviewScript` over to them, which is how they get tested and what retires
`ToolPath`'s last non-trivial callers.

**Phase 3 — Swift: the split and a phone app.** ✅ **Done**, minus the grid, which needs
`Capture`. `MoomuxKit`, the TCP transport, session list, detail, search, archived toggle and
archive-from-swipe. Every write the wire already serves works from the phone today; only the
three §2 features do not. `NWConnection` turned out to be unnecessary — see §3.

**Phase 4 — the terminal.** ✅ **Done and verified end to end.** `UITerminalView` +
`InMemoryTerminalSession` against the `Attach` stream, in `Sources/MoomuxiOS/TerminalScreen.swift`.
Proven against the core built from its own worktree, not a fake:
`tmux list-clients -t <s>` reports `xterm-256color 62x62`, the pane renders with colour and the
tmux status bar, and bytes sent down the same connection reach the shell
(`echo …` typed over the wire appears in `capture-pane`). The window reflows to the phone —
see §5, where the sizing conclusion reversed.

Four things the building taught, none of which were visible from reading:

- **`navigationDestination(for:)`'s closure is not a view body.** Resolving the session there —
  `if let session = app.session(id: id)` — registers no observation dependency, so a deep link
  that runs before the first snapshot renders an *empty* destination (a back chevron and
  nothing else) and never re-evaluates when the sessions arrive. The destination is
  unconditional now and each screen looks its session up in its own `body`. It looked identical
  and was wrong.
- **`UserDefaults.object(forKey:) as? Int` silently fails for a launch argument.** `-corePort
  8765` arrives in `NSArgumentDomain` as a *string*, the cast returns nil, and the default is
  used — which presents as the core being unreachable, on a port you can see yourself passing.
  `integer(forKey:)` coerces; 0 means unset.
- **The attach starts from the first resize, not from `init`.** `cols`/`rows` are the only size
  the pty ever gets and only the laid-out surface knows them. Connecting in `init` would have to
  guess 80x24, which is the documented way to make a phone pane look wrong.
- **Both halves of the remainder case are real traffic, and each has now been seen.** The
  response line sometimes arrives with pty bytes behind it (measured: 2 of them on a quiet
  session; the `\u{1b}[?25l` opening of a repaint is exactly what lands there, and discarding it
  is a pane that looks fine until it doesn't) and sometimes arrives alone, with the first frame
  in the next read — measured on the tailnet core: `pending=0`, then 258 / 736 / 628 bytes,
  1622 in the first three reads. So `splitLine` has to distinguish "no newline yet" (nil, keep
  reading) from "line complete, nothing behind it" (an *empty* remainder); conflating them
  blocks forever waiting for a line already in hand. Both the Go and Swift test suites had only
  ever produced the non-empty case, which is the wrong way round — a quiet session is what a
  phone opens onto.

**Two sizing bugs, both invisible in a screenshot until someone counted rows.** Reported as
"the cursor is two lines below where it should be":

- **Do not `.ignoresSafeArea(.bottom)` on a terminal.** The surface sizes its grid to the view,
  so extending under the home indicator buys two more rows that are drawn *behind* it — and the
  bottom rows are where tmux puts its status line and the cursor. The client went 62x53 → 62x51
  when the inset was restored, which is the reported two lines exactly.
- **The surface resizes more than once, and the first one is a lie.** Measured: `62x62` from the
  first layout pass, then `62x53` once safe areas apply. Attaching on the first left the pty
  disagreeing with the grid forever, because the wire's size is initial-only. `TerminalScreen`
  debounces 250ms for the size to settle, then attaches — and reattaches if it ever changes,
  which is what the contract asks a client to do about rotation.

**A one-shot request has to half-close, and nothing says so until a server stops guessing.**
`MoomuxClient.call` wrote its request and went straight to reading, never shutting its write
half — so a server that reads the request *to EOF* waits forever, because the connection is
still open for the answer. It worked for months against a core that parsed with a
`json.Decoder`, which returns as soon as the JSON value is complete and needs neither EOF nor
newline; the moment the core's framing tightened, every method went silent at once. It presents
as a core that is up and answering `nc` fine while the app shows nothing — because `nc` closes
its stdin, which is exactly the EOF the app never sent. `StreamSocket.closeWrite()` is that
`shutdown(SHUT_WR)`, and requests are newline-terminated as well (`Wire.lineEncoded`), which is
what `Watch` and `Attach` need since neither can half-close: both keep writing after the
request.

**A reattach does not fail against a killed session — it recreates it.** `Attach` calls
`EnsureTmux`, so any stray reattach after the far end goes away stands the session back up with
a fresh agent in it. Reported as "when a session is killed it still seems to be re-spawning".
The path was: kill → the read loop ends → dismiss, while a *pending resize* task fires in
between and reattaches. `TerminalScreen`'s coordinator now carries a lock-guarded `done` flag
that the read loop sets **off the main actor, before it hops** to dismiss — a first attempt
using an ordinary `@MainActor` property still lost the race, because the hop is the window.

Two testing traps came with it, and the first one made me report "cannot reproduce" about a bug
that was reproducing every time:

- **`EnsureTmux` creates the *canonical* name**, `moomux-<name>-<hash>`, not the
  `tmux_session` value in the store. So `tmux has-session -t <stored name>` answers "gone"
  while the session is very much back under another name. Diff the whole
  `tmux list-sessions` before and after instead.
- **`simctl launch` does not install.** Building and launching without `xcrun simctl install`
  silently tests the previous binary, which is how a fix and its absence both "passed".

**A crash that only a crash report would have found.** The first real attach from the phone
worked and then took the app down on detach, silently — the screenshot before it looked
perfect. `FileHandle.availableData` raises an `NSFileHandleOperationException` when the
descriptor goes away under a parked read, and that is an Objective-C exception, so Swift cannot
catch it and the process aborts. Since closing the socket *is* how a parked read gets cancelled
here (the pattern `StreamSocket`'s own doc comment describes), every detach hit it.
`readChunk` uses `read(2)` now, which reports EOF and EBADF instead of raising, and
`StreamSocket.demo()` has a socketpair check that a read cancelled by `close()` ends.

The lesson generalises past this bug: **`make ios-shot` says nothing about what happened after
the shutter.** Check `~/Library/Logs/DiagnosticReports/` for `Moomux-*.ips` after exercising a
new path — the stack there named the exact frame
(`availableData` → `_NSFileHandleRaiseOperationExceptionWhileReading` → `objc_exception_throw`
→ `abort`) in less time than reading the code would have taken.

**Typing works, and the pane is focused by a tap.** `UITerminalView` claims first responder in
`touchesBegan`, so a tap raises the keyboard and keystrokes run surface → the session's `write`
closure → `AttachChannel.send` → the pty. Confirmed by hand in the simulator.

There is deliberately **no auto-focus**: the package exposes `acquireProgrammaticFocus()` and
the Mac side calls the AppKit equivalent (`CLAUDE.md`'s "SwiftUI does not give the terminal
first responder"), but on a phone the software keyboard covers half the pane, and most of the
value here is reading what the agent is asking. Tap-to-type is the conventional behaviour and
costs a tap. Raising the keyboard does shrink the surface, which the debounce turns into a
reattach — the first thing to suspect if input misbehaves right after the keyboard appears.

In the simulator a *hardware* keyboard also needs ⌘⇧K (Connect Hardware Keyboard) as well as a
focused pane, or the keystrokes never leave macOS.

**Held keys do not repeat in the simulator, and that is the simulator.** Measured rather than
assumed, by routing the dependency's own input log to a file
(`TerminalDebugLog.sink` + `.enable(.input)` — it is settable, which beats adding tracing to
someone else's package): backspace held for 1.4s produced exactly **one** `pressesBegan` and
one release, and across the session 19 presses produced 19 releases and 19 `0x7F` bytes on the
wire. Nothing is dropped, reordered or coalesced on this side — iOS simply never delivers the
repeat. A real device generates repeats in its own HID layer, and the on-screen keyboard's
delete repeat arrives as repeated `deleteBackward()` calls instead, a path a connected hardware
keyboard suppresses entirely (zero `deleteBackward` lines in that trace).

That trace also validated the keystroke path end to end: 19 presses in, 19 bytes out, in order.

**Phase 5 — writes and polish.** Create, rename, archive, delete, folders; foreground
notifications; whatever §6 turned out to need.

---

## 11. Deliberately not doing

- **Background push.** §7. Needs a server and an awake Mac; out of scope by decision.
- **An iPad layout.** `NavigationSplitView` would mostly work and it is not the use case. Phone
  first; revisit if the phone app gets used.
- **Reimplementing `Scripts/ui.swift` for the simulator.** Screenshots are the check, same as the
  Mac UI, same as the existing "SwiftUI views have no coverage" policy.
- **A settings pane for fonts and themes.** §6 option (1) or (2), never (3).
- **Typing into grid tiles.** Same reasoning as the Mac: tap a tile, then attach.
- **App Store.** TestFlight at most. An app whose purpose is driving agents on your own computer
  is a review conversation nobody needs to have.
