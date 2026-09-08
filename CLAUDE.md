# Moomux.app

The native macOS front end. SwiftUI, SwiftPM executable, one dependency (libghostty), driving the
Go core over the `moomux serve` unix socket — see `docs/native-macos-rewrite.md` for why this shape
and not a rewrite. This file is for working on it; the Go side's `AGENTS.md` still governs
everything outside `macos/`.

Today it lists sessions, streams their live agent state, shows detail, banners and dock-badges the
ones that start waiting on you, attaches a session's tmux inside the app as one plain `tmux attach`
— reviving a parked one first if its tmux is gone — shows every live session at once as read-only
snapshots, hands a session to the user's terminal,
opens its diff for review in a tmux window of its own, and
creates, renames, retags, re-agents, archives, reorders, kills and deletes them. Creating one asks
the same questions the TUI's dialog does — agent, model, thinking level, branch and base branch
included — because the core serves the table those pickers are built from (`AgentOptions`). ⌘,
manages projects (add, edit, remove, reorder, and the "that path isn't a git repo" choice) and the
config flags both front ends share. ⌘F searches the sidebar by session name, ⌃⌘S hides it, and
⌘↓/⌘↑ step the selection through it — the keyboard equivalent of the sidebar `List`'s own
arrow-key navigation, which a terminal's first responder always outranks.

## The environment decides more than you'd think

**Xcode is installed but not selected** — `xcode-select -p` still says
`/Library/Developer/CommandLineTools`, and everything here is built to work that way. Nothing in
this repo needs Xcode; treat that as the standing arrangement rather than a limitation to route
around, and if you genuinely need `xcodebuild` say so first, because switching it on
(`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`) changes the toolchain under
every other worktree too.

- `xcodebuild` errors out as things stand ("requires Xcode, but active developer directory
  … is a command line tools instance"). `swift build` is the only build, so there is **no
  `.xcodeproj`** and there is no reason to add one. `make app` assembles and signs the bundle
  by hand.
- **`#Preview` and XCTest/`Testing` compile only if Xcode is selected.** Both shipped as
  hard "cannot be done" facts for most of this app's life, and the code still assumes neither
  exists: there are no SwiftUI previews and no test target. See "the harness is `demo()`" below —
  that is now a choice rather than a constraint.
- SwiftUI, AppKit, `@Observable`, `MenuBarExtra`, `Settings`, UserNotifications and Network all
  compile fine. So does libghostty, as a prebuilt binary target.
- Notarization needs no Xcode — `notarytool` and `stapler` are in CommandLineTools — so `make dist`
  and `make notarize` work here, and `.github/workflows/release.yml` runs the same `notarize`
  target on a `macos-15` runner. A Developer ID certificate is the only piece Xcode would not have
  supplied, and there is one.

## Commands

```sh
make build                                   # swift build -c release. Must stay at zero warnings.
make selfcheck                               # the assert-based demo() checks — run after touching logic
make warnings                                # every distinct warning in Sources/, without a clean build
make dev ARGS="--socket /tmp/mmx.sock"       # debug bundle, sign, relaunch
make run                                     # same, release
make shot OUT=/tmp/x.png                     # screenshot the running app
```

The app needs a running core:

```sh
go build -o /tmp/moomux . && /tmp/moomux serve -socket /tmp/mmx.sock
make dev ARGS="--socket /tmp/mmx.sock"
```

With no `--socket` it uses `ipc.DefaultSocket` (`~/.local/share/moomux/moomux.sock`), same as
`moomux ui`.

The bundle is not optional for anything that wants a bundle identifier — `swift run` produces an
unbundled binary, and `UNUserNotificationCenter.current()` **traps** without one. `Notifier` is
guarded on `Bundle.main.bundleIdentifier` for exactly that reason: `make selfcheck` runs the
unbundled `.build` binary.

## UI changes

Same rule as the Go TUI, different tool: you cannot see SwiftUI render by reading it. After any
change under `UI/`, run the app and look at a screenshot before calling it done, then send the
user a clickable `file://` link to the PNG.

```sh
make dev ARGS="--socket /tmp/mmx.sock" && sleep 8
make shot OUT=/tmp/moomux-macos.png
swift Scripts/ui.swift dump                  # the AX tree: labels, roles, frames
swift Scripts/ui.swift click "moo-hardness"  # drive it without a mouse
swift Scripts/ui.swift press "Agent, model"  # click the leading edge — for a disclosure chevron
swift Scripts/ui.swift type "a-name"         # into whatever has focus
swift Scripts/ui.swift key return            # return|tab|space|escape|up|down
```

`Scripts/ui.swift` walks the AXUIElement tree directly — System Events' `entire contents` returns
an empty list against SwiftUI windows. It is how a screen other than the empty state gets
photographed at all.

Two traps when checking by screenshot:

- A **crash on launch is silent** through `open`. Confirm the process is still alive a few seconds
  later — and match *this worktree's* build, not any Moomux, since the installed app and other
  worktrees' builds are now routinely running alongside it and would satisfy a bare `pgrep -x`:
  `make dev && sleep 6 && pgrep -f "$PWD/.build/Moomux.app/Contents/MacOS/[M]oomux"`.
  `Scripts/ui.swift` refuses to drive anything but this worktree's build — its synthetic clicks land
  at coordinates where the real app's buttons kill, archive and delete live sessions.
  `Scripts/shot.sh` only *frames* that build: it passes the rect to `screencapture -R`, so another
  worktree's window on top of it is what gets photographed. Bring this build to the front first.
- Against a **locked screen**, `screencapture` photographs the lock screen and `osascript ... get
  count of windows` returns 0 for a perfectly healthy app. Neither is evidence of a problem.
- Other apps' menu-bar popovers float above ours and land in the shot. Retake rather than debug a
  layout that is not ours.

## Verifying a terminal change

A screenshot proves a terminal *drew* something. It does not prove keystrokes arrive, that the
right pane got them, or that detaching left the session alone — and all three have broken here.
tmux is the oracle for those, so ask it rather than squinting at pixels.

```sh
S=moomux-<session>-<hash>                       # from the session's Info pane
tmux list-clients -t $S -F '#{client_tty} #{client_termname} #{client_pid}'
# Ours reports xterm-ghostty; if the user runs Ghostty too, settle it by walking
# #{client_pid} up its parents to the app (libghostty spawns via `login`, so it is
# tmux <- login <- Moomux). Client *count* is the oracle for attach and detach:
# 1 after attaching, 0 after Detach, and the UI looks correct either way.
tmux list-panes  -t $S -F '#{pane_id} #{pane_width}x#{pane_height} active=#{pane_active}'
tmux list-windows -t $S -F '#{window_width}x#{window_height} #{window_layout}'
tmux display-message -t $S -p '#{pane_id}'      # which pane tmux thinks is active
tmux capture-pane -p -t $S.2 | tail -3          # what a pane actually contains
```

### Test against a throwaway session, not the user's

**Do not attach the app to a real moomux session to try something out.** Those are live agent
sessions someone is working in: attaching resizes them, synthetic keystrokes land in an agent's
prompt box, and a split or a kill is not yours to make. Stand up an isolated one instead — both the
config and the session store honour `XDG_CONFIG_HOME`, so a scratch core sees only what you give
it, and the real one is untouched:

```sh
rm -rf /tmp/mmxtest && mkdir -p /tmp/mmxtest/moomux /tmp/mmxtest/wt
tmux new-session -d -s cmtest -x 120 -y 40 && tmux split-window -h -t cmtest

cat > /tmp/mmxtest/moomux/config.toml <<'EOF'
[projects.testproj]
repo = "/tmp/mmxtest/wt"
EOF

cat > /tmp/mmxtest/moomux/sessions.json <<'EOF'
{"version":1,"sessions":{"testproj:panes":{
  "id":"testproj:panes","project":"testproj","name":"scratch","branch":"test/panes",
  "worktree_path":"/tmp/mmxtest/wt","tmux_session":"cmtest",
  "created_at":"2026-09-02T12:00:00Z","last_opened":"0001-01-01T00:00:00Z"}}}
EOF

XDG_CONFIG_HOME=/tmp/mmxtest moomux serve -socket /tmp/mmx2.sock &
make dev ARGS="--socket /tmp/mmx2.sock"
```

The session record is hand-written on purpose: nothing has to exist for it but a directory and a
tmux session of that name, so you can build any layout you want to test — four panes, two windows,
a zoomed pane — in seconds. Tear down with `tmux kill-session -t cmtest && rm -rf /tmp/mmxtest`.

Three things to know about that scratch home:

- **`moomux serve` caches `config.toml` in process.** Editing it and waiting for the app's 2s poll
  changes nothing — restart the core. `sessions.json` is the opposite: re-read per request, which is
  what makes "unknown session" reproducible by deleting an entry under a running server.

- **`XDG_CONFIG_HOME` isolates more than moomux.** `gh` keeps its credentials in
  `$XDG_CONFIG_HOME/gh`, so the PR status on every `View` silently comes back empty — the scratch home
  has logged `gh` out. `ln -s ~/.config/gh /tmp/mmxtest/gh` fixes it. Anything else the core shells
  out to that reads XDG will have the same problem.
- **Give the worktree a real git repo** if you want the worktree rows to say anything:
  `git init`, one commit, then dirty it. `WorktreeStatus` and `ChangeSummary` return `ok=false` for
  a plain directory, which correctly renders as no row at all — indistinguishable from a bug you
  did not write.

If you ever do have to touch a real session, **type into the shell pane, never the agent pane** —
text at a `zsh` prompt is harmless and erasable, text in an agent's prompt box is not. Select it
first (`tmux select-pane -t $S.2`), check with `capture-pane`, clear the line with `C-u`, and put
the active pane back. Leave it as you found it.

**Synthetic key events need a real event source.** `CGEvent(keyboardEventSource: nil, …)` silently
drops modifier flags, so a scripted `C-b` arrives as a bare `b` and whatever you are testing looks
broken when it is fine. Pass `CGEventSource(stateID: .hidSystemState)`. This cost an hour chasing a
focus bug that had already been fixed.

```swift
let src = CGEventSource(stateID: .hidSystemState)
let e = CGEvent(keyboardEventSource: src, virtualKey: 11, keyDown: true)!  // 'b'
e.flags = .maskControl
e.post(tap: .cghidEventTap)
```

Useful oracles that do not require reading the screen: `#{client_prefix}` goes to 1 after the tmux
prefix key reaches our client, and `#{pane_in_mode}` goes to 1 in copy or clock mode. Both are
unambiguous where a screenshot is a judgement call.

**Count the characters before believing a wrap is wrong.** A repainted pane can legitimately wrap
where tmux already did: `capture-pane -p` hands back screen rows pre-wrapped to the pane's width, so
a row that fills the pane exactly is tmux's wrap and not ours. Several rounds went into a
one-column bug that did not exist; `python3 -c "print(len(line), repr(line[:56]))"`
would have settled it immediately.

## Verification tricks that matter here

**A warning count from an incremental build is meaningless.** `swift build` only re-emits
diagnostics for files it recompiles, so a second build reports zero while the warning is still in
the source — and a clean build double-reports (module-emit and compile passes both). `make
warnings` counts distinct causes. It touches `Sources/` rather than `rm -rf .build`: nuking the
build directory also re-downloads libghostty's 77MB xcframework and rebuilds the Swift layer
around it, none of which can produce a warning that is ours to fix. Same output, seconds instead
of minutes.

**The harness is `demo()`, because there is no test framework.** Each file with non-trivial pure
logic gets a `static func demo()` full of `assert`s, called from nowhere in production and run
through the real binary by `Moomux --selftest` (`App/SelfTest.swift`). When you add one, add its
call there.

**`assert` is compiled out entirely at `-O`**, so a release binary would print `selftest: ok`
having executed nothing. `SelfTest` proves asserts are live before running anything and exits 1
if they aren't; `make selfcheck` builds debug for this reason. Both directions are verified —
the release binary refuses, and inverting one assertion fails with a file and line. Do that
inversion check whenever you add a check that matters.

**Do not run concurrent `swift build`s** in this directory — they corrupt the shared `.build`. Use
`swiftc -parse <file>` for a syntax check while something else is building.

**Spike a dependency before adopting it.** A throwaway package settles in under a minute what the
README won't tell you — this is how `#Preview`-using libraries get caught. Both terminal
dependencies were spiked this way before going into `Package.swift`: SwiftTerm first, then
libghostty-spm (links clean under CommandLineTools, the binary runs unbundled so `make selfcheck`
survives, no `#Preview` anywhere in it). It is the only dependency; keep it that way for as long
as possible.

**`NSLog` does not reach `log show` / `log stream` from this bundle.** Two rounds of debugging went
into a predicate that was never going to match. When you need to trace something inside the running
app, append to a file from the code and `cat` it — crude, instant, and it actually works. Every
non-obvious bug in the terminal work was found this way and by nothing else, usually by logging one
number (a frame, a column count, a pending-command depth) rather than by reading harder.

## Architecture

One-way flow, no exceptions:

```
moomux serve  (unix socket, JSON)
      |
MoomuxClient           one request line in, one response line out; Watch streams
      |
AppState               @MainActor @Observable root store — watch loop + a config poll
      |
Views                  read AppState and nothing else
```

**The core computes, this app renders.** The `Watch` stream carries
`sessionview.Snapshot`: the session list *already in display order*, plus a `View` per session id
with the effective state (tmux liveness folded in), label, quip, recovered first prompt, git status
and PR status. Nothing on it is re-derived here and nothing on it is polled for — see
`docs/wire-protocol.md` in the Go repo, which is the contract. If a front end has to work something
out to draw it, that is a hole in the protocol, not a thing to implement here.

```
Core/UnixSocket.swift    AF_UNIX plumbing; blocking, closed to cancel
Core/Models.swift        the wire types + JSON coding + Wire.demo()
Core/MoomuxClient.swift  the Swift half of internal/ipc
Core/ToolPath.swift      finding tmux without a shell's PATH
App/Forms.swift          the two multi-field forms' state and defaulting rules, pure
App/AppState.swift       the single root store, snapshot loop, config poll
App/Notifier.swift       the only file allowed to touch UNUserNotificationCenter
App/MoomuxApp.swift      scenes: main window + MenuBarExtra
App/SelfTest.swift       --selftest
App/GhosttyResourceBundle.swift  makes Bundle.module resolvable from inside the .app
UI/RootView.swift        split view, rows, detail, inspector, menu-bar content
UI/TerminalPane.swift    libghostty hosting a plain `tmux attach`
UI/TerminalLinks.swift   what a ⌘-clicked link in a pane is allowed to open
UI/SettingsView.swift    project CRUD and the shared config flags, on two tabs
UI/SessionGrid.swift     every live session at once, as capture-pane snapshots
```

libghostty is reached **only** through `UI/TerminalPane.swift` (the live attached session, on the
`.exec` backend), `UI/SessionGrid.swift` (read-only `capture-pane` snapshots, on the host-fed
`.inMemory` backend) and one line of `App/GhosttyResourceBundle.swift` (which forces the package's
resource bundle to resolve at launch — see the bullet below). The one shared piece is
`AppState.terminalController`: a single
`TerminalController`, so every surface answers to the same config and the same `ghostty_app_t`.

`internal/ipc/client.go` is the reference implementation of `MoomuxClient`. Keep the two honest
against each other — anything the Swift side cannot do over the socket is a hole in the boundary
to fix in Go, not a reason to link the core.

## Things that will bite you

- **A tap gesture on a `List` row's content beats the `List`'s own selection.** A
  `.onTapGesture(count: 2)` added to a project row for double-click-to-edit stopped single clicks
  selecting it at all, which left Edit and Remove permanently disabled with no hint why. Removed;
  the buttons are the feature. Check a new row-level gesture by clicking a row and confirming the
  buttons that key off `selection` actually enable.
- **A `DisclosureGroup` in a grouped `Form` ignores a click at its centre.** Only the chevron
  responds, and the AX element spans the whole row, so `Scripts/ui.swift click` lands on empty
  space and the value stays 0 — indistinguishable from a disclosure that does not work. `press`
  exists for this; it aims at the leading edge.
- **`Scripts/ui.swift click` matches the first element with that label, which is rarely the alert's.**
  A "Remove" in an alert over a pane whose button is also "Remove" gets the pane's, behind the
  alert, and the stray click dismisses the alert — so the action silently never runs. Click an
  alert's button by coordinate (`find` prints them) rather than by label.
- **`session.CreateRequest` has no json tags**, so it is the one thing this app *sends* that Go
  decodes off its own Go field names — `Project`, `BaseBranch`, `AutoSubmit`, `PR`. Everything else
  on the wire, `prstatus.Info` included, is snake_case. A key that stops matching is silent on both
  sides: the session is created with that field simply unset, which is how a `dangerous` project
  once got sessions without `--dangerously-skip-permissions`. `CreateRequest`'s encoding is pinned
  by an assert in `Wire.demo()`.
- **A snapshot is absolute state; replace the view map, never merge it.** It used to be the
  opposite — `watcher.MultiWatcher` fans out one *path*-keyed snapshot per agent, each carrying only
  its own agent's sessions, so a client had to merge and prune. `internal/sessionview` does that
  join now, along with the tmux-liveness one that decides "parked", and hands out one finished map
  keyed by session id. A client that missed a snapshot loses nothing; the next supersedes it.
- **A failed call must not read as "empty".** `AppState.refresh` leaves the last-good lists in place
  and reports the failure through `connection`. The Go client caches for the same reason: one nil
  `Sessions()` would otherwise read as "every session was deleted".
- **Go's zero `time.Time` arrives as a real timestamp.** `omitempty` does nothing for a struct, so a
  never-opened session sends `"0001-01-01T00:00:00Z"` rather than omitting the key. The date
  strategy is lenient on purpose — a strict one would fail the whole `Sessions` call over it.
- **Go emits up to nine fractional digits**, `ISO8601DateFormatter` accepts three and returns nil
  on the rest. `Wire.parseTimestamp` drops the fraction; nothing displays sub-second time.
- **`close` on a socket class shadows the global.** Write `Darwin.close(fd)` inside a type that has
  its own `close()`, or the compiler resolves to the instance method and errors.
- **`sockaddr_un.sun_path` is 104 bytes.** Scratchpad paths blow past that — `UnixSocket` refuses
  rather than connecting to a truncated path, and this already happened once in practice. Put test
  sockets somewhere short, e.g. `/tmp/mmx.sock`.
- **Every `MoomuxClient` call blocks.** Anything touching git or tmux takes seconds on the Go side.
  Run them through `Task.detached` (`withoutBlockingTheUI`), never on the main actor.
- **`@main` conflicts with a file named `main.swift`**, which is why the entry point is
  `App/MoomuxApp.swift`.
- **`@Observable` fires on any assignment, equal or not.** Guard writes that repeat every tick
  (`AppState.set(statusError:)`) or every row re-renders on each watcher poll.
- **The app is not sandboxed**, which is the only reason `NSHomeDirectory()` finds the real socket —
  and the only reason the terminal pane can spawn anything at all. Sandboxing it means finding
  another way to the core.
- **A GUI app does not inherit your shell's `PATH`.** Launched from Finder it gets launchd's
  (`/usr/bin:/bin:/usr/sbin:/sbin`), so Homebrew's `tmux` is invisible and `Process` just reports
  that the executable does not exist. `ToolPath` searches `PATH` and then the usual prefixes. Every
  tool this app ever shells out to goes through it.
- **Every tmux client on a session shares one window size.** While the app is attached, the user's
  iTerm and phone are letterboxed down to the app's dimensions, and it only springs back on detach —
  not when the bigger client is used again. Grouped sessions (`new-session -t`) do **not** fix this;
  a group shares the windows themselves. All measured. This is why attaching is an explicit action
  and not a consequence of selecting a row.
- **The `.exec` backend's `command` is run by a shell, so every interpolated value needs
  quoting.** The surface spawns `login -flp <user> /bin/bash --noprofile --norc -c exec -l
  <command>`, so an unquoted tmux session name carrying `;` or `$(…)` executes. Proven both ways: a
  live tmux session literally named `lgok; touch /tmp/PWNED` attaches cleanly and creates no file
  with `String.shellQuoted` in place, while the same line unquoted in `bash -c` creates it.
  ghostty's `direct:` prefix, which skips the shell, does **not** help here — the surface config
  never goes through ghostty's `Config.command` parser, so the pane just reports that
  `direct:/opt/homebrew/bin/tmux` does not exist. Note the session's *liveness* guard will hide
  this from a casual test: a name the core reports as not running never reaches the attach path at
  all, so the payload has to name a session that really exists.
- **A focused libghostty pane eats the app's ⌘-shortcuts.** ghostty ships its own keybinds and a
  focused surface answers them before AppKit's menu is consulted. Measured: with a pane focused,
  ⌘, opened nothing at all (ghostty's `open_config` swallowed it) while the identical keystroke
  with the sidebar focused opened Settings; ⌘T, ⌘N and ⌘W would have gone the same way.
  `AppState.paneKeybinds` is `keybind = clear` plus the three a terminal is genuinely expected to
  answer (⌘C/⌘V/⌘A), rendered *after* the user's own config so a `keybind` they set is cleared too.
  Anything new that binds a ⌘ key in a pane has to be added there, and if a menu item ever "does
  nothing but only sometimes", this is the first place to look.
- **Every surface needs explicit teardown, panes and tiles alike; dropping the view does not.** Measured: the UI
  detached, and `tmux list-clients` still showed our client, because something in the package (the
  display link is the likely holder) outlives the view and keeps the surface coordinator alive with
  it — so the user's iTerm and phone stay letterboxed, which is the exact thing detach exists to
  undo. libghostty-spm publishes no `free()`; `AppState.detach` assigns `controller = nil`, which
  runs `rebuildIfReady(removingBridgeFrom:)`, and a non-nil previous controller skips the
  keep-the-surface early return so teardown runs. `SessionGrid.dismantleNSView` does the same for
  a tile, or a grid toggled open and shut leaks a surface, a wakeup observer and a display link
  per tile every time. **`tmux list-clients` before and after is the only proof** for the pane —
  the UI looks right either way.
- **Two `TerminalSurfaceOptions` fields must be set explicitly, not left nil/default.**
  `waitAfterCommand: false`, because nil means "whatever the user's ghostty config says" and
  `wait-after-command = true` keeps the surface open after the tmux client exits — so
  `terminalDidClose` never fires and the session sits in `attachedSessions` with a dead client
  (same reasoning as sending `Dangerous` explicitly on a create). And
  `resizeThrottleMilliseconds: 96`, which the dependency's own note recommends by name for
  alt-screen agent TUIs: ghostty coalesces resizes on a 25ms trailing-only window, so a live
  divider drag otherwise composites a stale grid into the new bounds.
- **The SwiftPM resource bundle has to be copied into the app by hand, and `Bundle.module` still
  cannot find it there.** libghostty's terminfo and shell integration ship as
  `GhosttyKit_GhosttyTerminal.bundle` next to the binary; `make app` copies it into
  `Contents/Resources`. Without it a pane's child gets `TERM=xterm-ghostty` with no terminfo to
  match it — `tmux list-clients` naming `xterm-ghostty` is the check that it landed. But SwiftPM's
  generated accessor looks in exactly two places, neither of them that one: the **root** of
  `Bundle.main.bundleURL` (`Moomux.app/GhosttyKit_GhosttyTerminal.bundle`) and the absolute
  `.build` path baked in at compile time — and it `fatalError`s when both miss. The root is not
  available: `codesign` refuses to sign an app bundle with anything but `Contents` there
  ("unsealed contents present in the bundle root" → "code object is not signed at all"), for a
  directory and for a symlink alike, measured. So `App/GhosttyResourceBundle.warm()` swaps
  `-[NSBundle initWithPath:]` for the length of one lookup, redirects that path to
  `Contents/Resources`, and forces `Bundle.module` to settle before anything builds a
  `TerminalController`. `Unmanaged` on both ends of that hook is not decoration: an `init`
  consumes `self` and returns +1, and letting ARC touch either segfaults the app on launch —
  measured, at exactly the point this was meant to fix.
  **This is invisible on a build machine**, which is why 0.0.38 shipped with it: the second
  candidate, `.build/.../GhosttyKit_GhosttyTerminal.bundle`, is right there on the machine that
  made the binary. Everywhere else it is CI's `/Users/runner/...`, and the app dies the moment a
  session is selected. So the check is: build the app, **move `.build/<triple>/release/
  GhosttyKit_GhosttyTerminal.bundle` out of the way**, and run the bundle. Launching at all is the
  proof — `warm()` touches the same `static let` the terminal does, so it either resolves or takes
  the process with it.
- **Shipping the terminfo is not the same as the child finding it.** The package sets
  `GHOSTTY_RESOURCES_DIR` (shell integration) and *never* `TERMINFO`, which Ghostty.app sets for
  its own children — so on a machine with no Ghostty installed the pane's `tmux attach` exits in
  ~70ms with `missing or unsuitable terminal: xterm-ghostty` and ghostty paints its "failed to
  launch the requested command" screen. `TerminalPane` passes `TERMINFO` through
  `TerminalSurfaceOptions.envVars`, from `GhosttyRuntimeResources.terminfoDirectoryURL`. It looks
  exactly like an attach bug, and it only reproduces where Ghostty.app is absent.
- **A pane that dies in ~70ms is terminfo, not tmux nesting.** `make dev` runs `open`, which hands
  the app the launching shell's environment — so started from a moomux pane it inherits `TMUX` and
  `TMUX_PANE`, and a dead pane reads exactly like tmux refusing to nest. It is not: measured, the
  app attaches fine with `TMUX` set, *including* to the very session it was launched from, because
  tmux's nesting check compares the client's tty against the session's panes and a ghostty surface
  is neither. Two hours went into that theory. Get the real message before theorising — run the
  failing command yourself in a pane that has a terminal:
  `tmux send-keys -t probe "env -u TMUX TERM=xterm-ghostty bash -c \"exec tmux -u attach -t X\"" Enter`,
  then `capture-pane`. Ghostty's "failed to launch the requested command" screen names the command
  and the runtime and nothing else, which is not enough to debug from.
- **ghostty's themes are not in the package either — this repo vendors them.**
  `theme = <name>` resolves under `GHOSTTY_RESOURCES_DIR/themes`, which libghostty-spm ships empty,
  so every named theme was unresolvable and (see the `prepareConfig` bullet) took the user's whole
  config down with it. `Resources/ghostty-themes` holds 69 of the 607 upstream ones, ~276KB;
  `Scripts/themes.sh` refreshes them from `mbadolato/iTerm2-Color-Schemes` (ghostty's own source
  for them) against the allowlist in `Scripts/themes.txt`, and names anything upstream renamed.
  `make app` copies them *into* the resource bundle before the bundle is copied on, so the
  unbundled `.build` binary resolves them too. A theme not on the list is now merely dropped
  rather than fatal — adding one is a line in `themes.txt` and a re-run.
- **A `TerminalController`'s `theme:` is layered on top of its config**, and
  `TerminalTheme.default` is a full Afterglow/Alabaster palette — so passing the default silently
  overwrites every colour the user's config just set. Pass an empty `TerminalTheme` (and an empty
  `terminalConfiguration`); the controller then uses the base verbatim instead of re-rendering.
- **ghostty looks for four config files, not one, and the current name is `config.ghostty`.**
  `Config.loadDefaultFiles`: legacy `config` then `config.ghostty`, under the XDG directory and
  then `~/Library/Application Support/com.mitchellh.ghostty`, loading *all* of them and letting
  the later ones override. `AppState.ghosttyConfigPaths` mirrors that; checking only `config` and
  taking the first hit was wrong twice over — it missed `config.ghostty` entirely (the only
  ghostty config on this machine is one, so the whole feature was silently dead while Settings
  said "No Ghostty config found") and where two exist it picked the one ghostty ranks *lowest*.
  `XDG_CONFIG_HOME` **replaces** `~/.config`, it does not add to it.
- **libghostty-spm calls only `ghostty_config_load_file`** — never
  `ghostty_config_load_recursive_files`, never `load_default_files`. So a `config-file =` include
  in a user's config is silently ignored however the config is loaded, which is also why
  "just emit `config-file =` lines" is not a way to layer configs here. `AppState.paneConfig`
  concatenates the files' text instead; the ceiling is that a directive naming a path relative to
  its config (`theme = mine` beside a `themes/`) resolves against the generated file's directory.
- **`prepareConfig` rejects a config on *any* diagnostic.** One unknown or deprecated key throws
  the whole thing away and the panes fall back to built-in defaults. It does not "load without the
  bad line" — so `AppState` does that itself: only when the first load fails, `narrowedConfig`
  re-offers the config a line at a time through `updateConfigSource` and keeps the ones ghostty
  accepts, and Settings → Terminal lists the rest under "Ignored". Blank and comment lines are kept
  without asking; the happy path is still one load. `lastConfigurationIssue` survives for the case
  where even the narrowed config will not load.
- **A surface with no `TerminalSurfaceOpenURLDelegate` does not refuse to open links — ghostty
  core opens them itself.** `TerminalController+Callbacks.swift` reports the action unhandled and
  the core spawns `/usr/bin/open`, straight past `TerminalLink`'s allowlist. Every surface this
  app creates conforms, tiles included, even though a tile's `hitTest` already refuses the click —
  otherwise it is fail-open by luck.
- **A surface with no `TerminalSurfaceClipboardConfirmationDelegate` silently denies every
  protected clipboard operation.** The bridge answers `completion(false)`, so with ghostty's
  default `clipboard-paste-protection` a multi-line ⌘V does nothing at all: no paste, no dialog,
  nothing logged. `TerminalPane.Coordinator` answers it, splitting on initiator — a paste is the
  user's keystroke and is allowed, OSC 52 is the program asking and is refused. Verified with a
  two-line clipboard, which is the case that was being dropped.
- **Read the dependency's source from `.build/checkouts/`, not a fresh clone**, and the *pinned*
  version at that. A SwiftTerm scroller bug once cost an extra round because the property was read
  from its `main`, where it behaved differently. `git clone --branch <tag>` also falls back to the
  default branch if the tag is missing, silently giving you the wrong source.
- **`capture-pane -p` returns screen rows, not logical lines** — already wrapped to the pane's
  width. `-J` is the flag that joins them back into logical lines. Measured on tmux 3.7c in a
  40-column pane: a 50-character line comes back as a 40-char row plus a 10-char row plain, and as
  one 50-char line under `-J`. So a wrap in captured output is usually tmux's own rather than a bug
  in whatever reads it — count the characters against the pane width before believing it is ours.
  (An hour went into talking myself out of a wrap that was fine.) It also returns the pane's **full
  height**, blank rows below the cursor included — never trimmed — which is what `TmuxSnapshot.screen`
  has to drop before feeding a tile.
- **SwiftUI does not give the terminal first responder.** Focus stays on the sidebar list, so
  everything typed after "Attach" goes to the list instead. `updateNSView` is too early (no window
  yet); `AttachedTerminalView.viewDidMoveToWindow` is the hook that works. Call `super` first —
  `AppTerminalView`'s own override is what builds the surface, starts the display link, and decides
  *not* to rebuild one that already exists, which is what keeps scrollback across a sidebar switch.
- **`Scripts/shot.sh` frames the right window but photographs whatever is on top of it.** It gets
  the rect from `ui.swift frame` (correctly scoped to this worktree's build) and hands it to
  `screencapture -R`, so another worktree's Moomux sitting at those coordinates lands in the PNG
  and looks like your build behaving strangely. `Scripts/ui.swift` is *not* affected — it matches by
  executable path and refuses anything else. Bring this build to the front before shooting, and if a
  shot shows sessions you do not recognise, check `pgrep -fl Moomux.app` before debugging the UI.
- **`open` against an app that is still terminating does nothing at all**, which reads exactly like
  a crash on launch. `make run`/`make dev` wait out the old process for this reason — do not
  "simplify" that loop away.
- **`make dev`/`make run` build `app.moomux.Moomux.dev`, not `app.moomux.Moomux`.** They used to
  share the installed app's identifier, which meant `open .build/Moomux.app` could reactivate
  `/Applications/Moomux.app` instead of the build you just made — and the `pkill -x Moomux` that
  worked around it killed *every* Moomux on the machine: the installed app and every other
  worktree's. With several sessions on this project at once that is an app vanishing every few
  minutes, and because it is SIGTERM there is no crash report to find, so it reads exactly like a
  crash. Both targets now kill only `$(CURDIR)/.build/Moomux.app`'s own process. The cost is that
  the dev bundle earns its **own** notification grant — authorization is keyed by bundle
  identifier, so a debug build prompts once and does not inherit the installed app's answer.
- **Notification authorization needs a bundle LaunchServices has registered, and that means `open`
  from a real location.** Exec'ing the binary inside the bundle
  (`./Moomux.app/Contents/MacOS/Moomux`) fails instantly with `UNErrorDomain Code=1 "Notifications
  are not allowed for this application"` even though `Bundle.main.bundleIdentifier` is right, and so
  does a bundle sitting under `/tmp` — no prompt, same error, both measured. `.build/Moomux.app`
  opened by `make dev` is fine, and so is `~/Applications`. That error is very easy to misread as
  "ad-hoc signing doesn't work" (it isn't — see the signing bullet below).
- **The Dock badge is not free of authorization.** `NSDockTile.badgeLabel` looks like a plain
  property and reads like the fallback for when notifications are denied, but macOS silently drops
  it unless the app holds the **badge** permission — System Settings → Notifications has to say
  "Badges", not just "Sounds, Desktop". Requesting `[.alert, .sound]` and assigning `badgeLabel`
  gives you a bare Dock icon and no error anywhere. `Notifier` asks for `.badge` too, and asks in
  `init` rather than at the first banner: a session already waiting when the app opens sets the
  badge without ever being a *transition*, so no banner would have done the asking. The answer is
  sticky per bundle id, so a build that already earned an alert-only grant keeps it — flip Badges on
  by hand, or reset the app in System Settings, before deciding the code is wrong.
- **`center.add` returns no error while authorization is denied.** Measured: status denied, `add`
  err nil, nothing on screen. A missing banner gives you no signal at all, and denial is *sticky*
  per bundle identifier — quitting while the prompt is up is enough to earn it permanently. Read
  `getNotificationSettings().authorizationStatus` (0 notDetermined, 1 denied, 2 authorized) before
  believing the code is broken, and reset in System Settings → Notifications. Focus/DND does the
  same thing for a different reason.

## Conventions

- `public` on anything crossing a file boundary; one module, so this documents intent.
- Comments explain *why*, not *what*. Be sparing.
- `MARK:` sections in files over ~200 lines.
- Semantic colors only, via `Theme` in `UI/RootView.swift`. No literal hex — it breaks dark mode.
  Every primary action gets a `.keyboardShortcut`.
- New pure logic gets a `static func demo()` with `assert`s and a call in `SelfTest`. Trivial code
  gets nothing.
- Deliberate shortcuts get a plain comment naming the ceiling and the upgrade path.

## Deliberately not done

Decisions, not oversights. Don't "fix" these without being asked.

- **Nothing this app does in a normal flow makes the core touch a terminal app.** The core's
  `OpenSession` does two things — revive the tmux session and agent if they are gone, *and* open an
  iTerm tab — which is right for the TUI and wrong here: Attach would have popped a window somewhere
  else as a side effect. So the core grew `EnsureTmux`, `OpenSession` minus the terminal step, and
  that is what `AppState.attach` calls when the session is parked. "Open in terminal" is the only
  caller of `OpenSession` left, and it is **disabled** without a live tmux rather than reviving one:
  it is a link out, not a second way to start an agent. Two consequences worth keeping straight —
  the sidebar's auto-attach stays gated on `isAlive` (browsing must not relaunch agents; starting one
  back up is a button press), and `attach` only inserts into `attachedSessions` *after* the revive
  and the next snapshot, or `SessionTerminal` would run `tmux attach` against a session that isn't
  there yet.

- **No font, size or theme settings — panes read the user's own Ghostty config.**
  All four files ghostty itself reads — `config` then `config.ghostty`, under `$XDG_CONFIG_HOME`
  (or `~/.config`) and then `com.mitchellh.ghostty`, concatenated in that order — so a Ghostty
  user's panes look like their terminal, and a built-in dark fallback when there is none. There is deliberately no picker: libghostty is configured by ghostty
  config text, and a second place to set the same values would have to either lose to the file or
  silently override it — a user editing their config and seeing nothing change is worse than no
  control at all. The Settings → Terminal tab says which files were read and lists any line ghostty
  refused under "Ignored" — the rest of the config still loads — and that is the whole pane. The
  cost: a config change needs a restart, because a live surface is not reconfigured.
- **libghostty comes prebuilt, from `Lakr233/libghostty-spm` (MIT), pinned to an exact version.**
  Upstream publishes releases for libghostty-*vt* only — a VT parser with no renderer and no pty.
  The embeddable library that has both is built with `zig build -Demit-xcframework=true`, ending in
  `xcodebuild -create-xcframework`, and *that is the easy half*: the C API hands over no AppKit
  surface, so key translation, IME, mouse, selection and the app runtime would all be ours.
  Ghostty's own are ~250KB of Swift; cmux's are ~25,000 lines on top of a ghostty fork. This
  package is that layer, already written. Pinned with `exact:` and not `from:` because it ships
  weekly `1.5.<YYYYMMDD>` snapshots of an API upstream says is not stable yet — a bump is a
  deliberate act with a screenshot behind it. The escape hatch if it ever goes stale is the source
  build above, which needs zig 0.16 (brew has exactly that) and Xcode selected.
- **The app is ~11MB rather than ~5MB**, all of it the statically linked engine (the archive's
  macOS slice is 39MB universal; the linker keeps about 6MB of it). One-time ~190MB in `.build`
  for the downloaded xcframework. Measured, and accepted knowingly: Homebrew cask users
  re-download the difference on every upgrade.
- **The sidebar's ⌃⌘S is ours, not SwiftUI's.** `NavigationSplitView` ships a toolbar button and
  **no** View-menu item, and on macOS a shortcut needs a menu item — so ⌃⌘S, which every other Mac
  app spells this way, did nothing at all here. Measured before and after. The fix is a
  `CommandGroup(after: .sidebar)` item over `AppState.sidebarVisible`, which `RootView` maps onto
  `columnVisibility`; the built-in toolbar button writes back through the same binding, so the two
  cannot disagree. Keep it a `Bool` on the store rather than a `NavigationSplitViewVisibility`, or
  `AppState` imports SwiftUI for one enum.
- **Search matches names and nothing else**, case-insensitively, over the *whole* store — archived
  sessions included, whatever the Archived toggle says. Both halves are `internal/tui/search.go`'s
  `matchSessions`: the session you cannot remember is disproportionately likely to be one you
  archived and forgot, and a front end that quietly also matched branch or prompt would rank
  differently for the same typing. ⌘F needs `.searchFocused`, which is macOS 15 while the bundle
  targets 14, so the shortcut *and* its menu item are behind an availability check — the field
  itself is there and clickable on 14, and a menu item that could only no-op is worse than none.
- **Delete asks once, and the dialog names what is at stake.** `internal/tui` makes you press `y`
  twice past a dirty/unpushed warning (`confirmAck`); this app does not, because a second
  "are you sure" click is a reflex rather than a safeguard — the information is. `askDelete` opens
  one alert and re-fetches the worktree status behind it (`loadStatus(force:)`), and
  `AppState.deleteWarning` leads with a flagged line per hazard ("⚠︎ 2 FILES CHANGED", "⚠︎ 1 COMMIT
  UNPUSHED", split out of `changeSummary` so one place decides the wording) before the sentence
  about the worktree and branch. Upper case because **an alert's message renders markdown `**…**`
  at the same weight as the rest** — measured, twice; caps are the only emphasis it has. Until the
  status lands the message says it is checking rather than implying a check that never ran (whether
  the alert re-renders that line in place when the status arrives is **not** measured — treat the
  first frame as what the user reads). A worktree nobody has checked must never read as clean — that is the one thing
  `demo()` pins.
- **Every write the socket serves is wired up**, session and config alike, with two exceptions:
  `SetCompactDetail`, which trims a detail panel this app does not have, and `SetSessionPrompt`,
  which is now only what `CreateSession` calls internally — this app has no other moment that would
  rewrite a session's first prompt. (`SetSessionStatusTitle`
  and `StartFirstPrompt` are gone from the wire entirely — the core keeps tmux window titles in
  step itself, and the first prompt is part of the `CreateSession` transaction.) The other TUI-only
  settings (theme, appearance, auto-tmux) are here because they are one-line flags on a shared
  config file and a front end that could edit projects but not those would stop somewhere odd; a
  flag whose *only* meaning is the shape of the TUI's own panel is over that line.
  **No drag-to-reorder**, though, for sessions or projects: `MoveSession`/`MoveProject` take a ±1
  delta, the lists are plain `List`s, and `onMove` wants index sets over a bound array, so ⌃⌘↑/↓ and
  two chevron buttons are the whole feature for a day less work.
- **No client-side validation beyond `ProjectForm.problem`.** No `sanitizeName`, no `~` expansion,
  no duplicate-name check, no `IsRepo`, no base-branch defaulting, no worktree-mode-flip check: the
  core does all of it and its refusal is the message the user reads. Two validators are two rules to
  drift, and `problem`'s strings are `validateProjectLocked`'s verbatim for the same reason.
- **Project management is a sheet, and everything it can raise is hosted on that sheet.** One
  `.sheet(item:)` presents one thing, so the project form hangs off `SettingsSheet`'s own
  `@State`, not off `app.sheet` — and the two alerts it can raise (`not_git_repo`, remove
  confirmation) are declared there too. An alert bound on a view that a sheet is covering does not
  appear; SwiftUI defers it until the sheet closes. That is also why a *refused* project write shows
  as an inline row in the sheet rather than through `RootView`'s "Couldn't do that" alert, and why
  the sheet clears `actionError` on the way out: left set, the deferred alert fires the moment it
  closes and says the same thing twice. All three measured, in that order, each one a button that
  looked like it did nothing.
- **Settings is a sheet and not a `Settings` scene.** A scene is the macOS-native answer and both
  alternatives to this were written that way — but a second window breaks the only screenshot path
  there is (`Scripts/ui.swift` walks the *first* AX window, and `shot.sh` frames it), and a UI
  change that cannot be photographed cannot be checked. ⌘, still opens it, via
  `CommandGroup(replacing: .appSettings)`.
- **No project emoji palette.** `config.ProjectEmojiPalette` is a Go table nothing serves over IPC,
  so a copy here would drift — the exact rule below. A free-text field plus macOS's own ⌃⌘Space
  gets there. The cost is that an empty emoji shows nothing in this app's sidebar while the TUI
  computes a deterministic glyph; the field's help text says so rather than pretending otherwise.
  There is **no hardcoded table left**: `Themes` serves `internal/config`'s palettes, so the picker
  offers the served names (`AppState.themeNames`) and `Theme` in `RootView.swift` draws the state
  icons from the served colors, which is what makes the two front ends' dots agree at last. The
  picker still unions whatever is stored, so a theme *this* core has not heard of (an older core, a
  newer config.toml) is neither rendered blank nor silently overwritten.
  Three things the wire format encodes and this app honours: a color's `system` name ("accent",
  "green", "orange", "secondary") wins over its hex, so the dots follow the user's live system
  accent rather than a frozen `#007aff`; the `ansi` flag marks the "terminal" theme's halves as
  palette *indices*, which nothing here can resolve, so `ThemePalette.resolved` hands back
  "default" for it; and `warn` — the ± / ↑ git badges — is amber in every theme, split out of
  `done` precisely because `done` is now green everywhere.
- **The New Session sheet asks three questions up front and hides the other nine.** Project, name
  and first prompt are the fast path; agent, the dangerous flag, model, thinking level, existing
  branch, base branch, ticket and PR live under a `DisclosureGroup`, which opens by itself only for
  a `prompt_agent` project — where nothing can be submitted until an agent is chosen, so a collapsed
  section would hide the only control that unblocks it.
  **The rule for growing this form is unchanged: the core must be able to hand over the list it
  validates against.** That is now true of the picker-shaped fields — `AgentOptions` serves
  `internal/app`'s own table, and `AppState.agentNames`/`models(for:)`/`thinking(for:)` mirror
  `internal/tui`'s three lookup helpers *including their fallbacks*, over the same data. A field the
  app can fill from `Config`, from that table, or from free text is fair game; one that needs a
  hardcoded table is still not.
  **Creating a session is one call.** `CreateSession` takes a whole `session.CreateRequest` and the
  core runs the sequence — worktree and branch, tmux pane and agent, PR tag, composed first prompt
  (thinking-level prefix for the agents with no launch flag for it, then the ticket and PR lines),
  typed into the pane. This app replayed all of it step by step until the core owned it, and
  drifting from the TUI's copy of the same sequence is exactly how `moomux spawn` ended up storing
  no prompt at all. Do not reintroduce any of those steps here.
  The two things still on this side: a changed auto-submit toggle is persisted as the new default
  (best effort — a failed config write must not block a session), and `Dangerous` is sent as an
  explicit `true`/`false` rather than left nil. Nil means "the project's default", which is a
  different answer from the one the form just showed the user. `OpenTerminal` stays unset, so a new
  session lands in the sidebar rather than in iTerm.
- **A slow write reports in the toolbar, not in its sheet.** `AppState.busy` is set by `mutate` for
  every action and rendered by `ConnectionBadge`, so the New Session sheet closes on Create rather
  than sitting there for the tens of seconds a worktree plus the worktree-create userscripts take.
  A refusal still lands in the "Couldn't do that" alert. A step that degrades *after* the pane
  exists — a PR tag or a first prompt that did not land — comes back on the result's `hint` rather
  than as an error, and the core is what decides that: once the pane exists the session is real, and
  reporting it as a failed creation invites a retry that answers "session already exists".
- **No Sparkle.** A tag ships a Developer ID-signed, notarized `.dmg` and a Homebrew cask
  (`release.yml` → `afitzgerald/homebrew-moomux-mac`); `brew upgrade` is the update mechanism.
  **`app`, and therefore `make install`, still signs ad-hoc** (`--sign -`) — deliberately: only
  `dist`/`notarize` re-sign with the Developer ID, and a locally built bundle carries no
  `com.apple.quarantine`, so Gatekeeper never assesses it and the ad-hoc signature costs nothing.
  (`spctl --assess` on one still says *rejected*; that is spctl answering a hypothetical, not what
  happens on launch.) The catch is that `make install` over a downloaded copy swaps a Developer ID
  signature for an ad-hoc one and so changes the designated requirement — harmless until something
  depends on a stable one, which means launch-at-login, still unproven.
  **Notification authorization does not depend on it**: measured with a throwaway bundle of
  exactly `make app`'s shape (hand-assembled, `codesign --force --sign -`), the prompt appears
  normally, `add` succeeds, and the grant survives a rebuild that changes the CDHash and a move
  between `~/Applications` and `.build/`. It is keyed by bundle identifier, not by signature.
- **A notarization ticket is stapled to the app *and* to the image, in that order.** Stapling only
  the `.dmg` covers the image and nothing inside it, so the app dragged to `/Applications` has no
  ticket and opens solely while Gatekeeper can reach Apple to look the notarization up — offline or
  on a slow CloudKit day it is "Apple could not verify Moomux is free of malware", on a build that
  `spctl --assess` calls `accepted` on the machine that made it. 0.0.26 shipped that way. Hence
  `notarize`'s shape: `signapp`, submit the zipped `.app`, staple *that*, then `dmg` around the
  stapled bundle and submit the image too. Two submissions, and there is no fixing it afterwards —
  a mounted image is read-only. `spctl` on the image is not the check; `xcrun stapler validate` on
  the `.app` is, and both are asserted because either passing alone is the bug.
- **The cask drops `com.apple.quarantine` in `postflight_steps`**, which is not the default and
  Homebrew discourages it. brew copies the downloaded image's quarantine record onto all 13 files
  of the installed bundle, so every install and upgrade gates the first launch behind "Moomux is an
  app downloaded from the Internet. Are you sure?" — and over a stale policy record for that path
  (0.0.26, unstapled) the process is instead spawned and killed ~2s later with no window and, after
  the first time, no dialog at all. Both measured. The staple is what proves provenance offline, so
  the xattr asserts nothing brew's sha256 check and the ticket don't already. Use
  `postflight_steps`, **not** `postflight` — the block form is deprecated and warns on every
  install; `args` are template-expanded, which is what makes `{{appdir}}` work there.
- **Config is re-fetched on every 2s poll** rather than only after a change. One extra socket
  round trip, and it keeps project order and emoji fresh with no invalidation logic.
- **Review happens in a tmux window, not in a patch viewer.** "Review Changes" runs
  `new-window -n review` in the session with `git diff --merge-base <base>` plus a
  `git status --short --branch`, and leaves a shell behind (`AppState.reviewScript`). Reviewing
  twice reuses that window (`respawn-window -k`, then `select-window`; `new-window` only when there
  is nothing to reuse) — two tabs both called "review" with nothing to tell them apart is worse than
  either. `respawn-window` and not kill-then-create, because killing the last window of a session
  kills the session. A native
  viewer was designed and rejected: ~400 lines across two languages — a new `gitwt.Diff`, an
  `App.Diff`, a `Patch` field on `ipc.Result`, a `Server` hook, a `main.go` line and a two-pane
  SwiftUI sheet — to end up a *worse* pager than the shell pane this app already renders natively,
  with no colour config, no word diff and no `delta`. Going through tmux costs one `Process` call,
  and tmux's own window switching (the prefix key works fine over a plain attach) is what makes it
  reachable. The tradeoffs it keeps: no diff without a live tmux
  session (`canReview`), the base branch comes from the *project*, not the session, so a session
  created with an explicit `-base` diffs against the project default, and untracked files show as a
  `git status` listing rather than as patches — `git add -N` would get them into the diff and is not
  worth mutating a live worktree's index for.
- **The session grid is snapshots, not live views, and that is the feature.** ⌘⇧G swaps the detail
  column for a tile per live session, each one a `tmux capture-pane` fed every five seconds into a
  libghostty surface on the host-managed `.inMemory` backend — no process, no pty, nothing to
  attach, and `hitTest` refuses the click so the tile underneath stays clickable. A grid of
  *attached* clients — the obvious reading of
  "several sessions at once" — would be **destructive**: every tmux client on a session sets the
  shared window size (see the bullet above; measured for plain attach and grouped sessions alike),
  so six live tiles would letterbox six real sessions someone else is working in until the
  grid closed. `capture-pane` attaches nothing. What that costs is one short-lived tmux process per
  visible tile per tick, which is why the interval is 5s rather than the store's 2s and why the task
  belongs to the tile, so closing the grid stops it; the upgrade if it ever bites is one invocation
  with `;`-joined captures, never a client per tile. What it gives up: typing into a tile (the thing
  the size problem makes unaffordable anyway — click one, then Attach), multi-pane tiles (the
  session's active pane is the agent), zoom, and scrollback. `TmuxSnapshot.screen` **truncates** each
  captured row to the tile's column count rather than letting it wrap: an agent pane is 150-210
  columns and a tile is nearer 50, so wrapping shows the bottom quarter of the last few lines as
  mush. It also drops the trailing blank rows `capture-pane` returns below the cursor, which would
  otherwise scroll the content out of a short tile.
- **No notification actions, and no "Approve" button.** Tapping a banner selects the session and
  brings the app forward; that is the whole interaction. An action button would have to send keys
  into the agent's pane, and there is no write path for that. A banner already *is* an Open button.
- **SwiftUI views have no coverage** and cannot have any. Screenshots are the check.
