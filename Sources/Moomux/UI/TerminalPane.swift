import AppKit
import GhosttyTerminal
import SwiftUI

/// A live tmux client, hosted in the app.
///
/// This is substrate A from `docs/native-macos-rewrite.md`: tmux still owns the
/// process, so sessions survive quitting the app, and the very same session is
/// still `tmux attach`-able from a phone. The app is a viewport, not an owner.
///
/// tmux draws its own splits and status line inside this one view and the
/// app cannot see the layout — so no native tabs, no native splits, no
/// per-pane titles. That buys nothing until there is UI to put a layout into.
///
/// The ceiling that does bite: **every client on a session shares one window
/// size**, so while this pane is attached, the user's iTerm window and phone
/// are letterboxed down to whatever this view happens to be. Measured, not
/// assumed — grouped sessions (`new-session -t`) do not fix it, because a group
/// shares the windows themselves, and the size does not spring back when the
/// larger client is used again. It only recovers on detach. That is why
/// attaching is an explicit action rather than a consequence of selecting a row.
///
/// The terminal is libghostty: `AppTerminalView` owns the pty, the VT emulator
/// and a Metal renderer, so `command` is the whole of what this file asks for.
/// `AppState.terminalController` supplies the config; nothing here styles it.
struct TerminalPane: NSViewRepresentable {
    @Environment(AppState.self) private var app

    let executable: String
    let sessionID: Session.ID
    /// The tmux session name to attach to, e.g. `moomux-macos-1a2b`.
    let tmuxSession: String
    let pool: AppState
    /// Called when the tmux client exits — detached, or the session went away.
    var onExit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    /// A terminal nobody can type into is not a terminal, and SwiftUI leaves
    /// first responder on the sidebar list when this pane appears — the
    /// accessibility API reported `AXOutline` as focused, and keystrokes went
    /// to the list. Taking focus from `updateNSView` does not work: the view
    /// has no window yet the one time that runs, so this hooks the moment it
    /// gets one. With it, characters, control keys and the tmux prefix all
    /// reach the client (checked against `capture-pane` and `client_prefix`).
    ///
    /// `super` first, and it matters: `AppTerminalView.viewDidMoveToWindow` is
    /// what builds the ghostty surface, starts its display link and — for a
    /// SwiftUI host that detaches and reattaches a view while diffing — decides
    /// *not* to rebuild one that already exists, which is what keeps the
    /// scrollback across a sidebar switch.
    final class AttachedTerminalView: AppTerminalView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After SwiftUI finishes installing the pane, not during.
            DispatchQueue.main.async { [weak self] in
                self?.acquireProgrammaticFocus()
            }
        }

        /// Dropping Finder files onto a terminal types their shell-quoted
        /// paths, the same convention iTerm and Terminal.app use. libghostty's
        /// own drop handling is UIKit-only, so this stays ours.
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            sender.moomux_hasFilePaths ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let text = sender.moomux_filePathsForDrop else { return false }
            // The text path, not keystrokes: a program with bracketed paste on
            // sees a paste, so a path is never mistaken for typed control keys.
            return paste(text: text)
        }
    }

    /// Reuses a pooled view for this session if one is already running,
    /// rather than starting a fresh `tmux attach` — see `AppState.plainPanes`.
    ///
    /// `delegate` is `weak` on `AppTerminalView`, so `context.coordinator` —
    /// only owned by SwiftUI for as long as this representable stays mounted
    /// — can't be the delegate: it would deallocate on the next sidebar
    /// switch, and a background exit would have nobody to tell.
    /// `AppState.plainDelegates` keeps one alive per session instead.
    func makeNSView(context: Context) -> AttachedTerminalView {
        if let existing = pool.plainPanes[sessionID] {
            existing.delegate = pool.plainDelegates[sessionID]
            existing.setSurfaceVisible(true)
            return existing
        }
        let view = AttachedTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        view.registerForDraggedTypes([.fileURL])
        let delegate = context.coordinator
        view.delegate = delegate
        pool.plainDelegates[sessionID] = delegate
        view.controller = pool.terminalController
        // **Quoting is load-bearing.** This string is run by a shell — the
        // surface spawns `login -flp <user> /bin/bash --noprofile --norc -c
        // exec -l <command>` — so an unquoted session name carrying `;` or
        // `$(…)` would execute. The name arrives over the socket from the core,
        // which is not a reason to trust it with a shell.
        //
        // ghostty's *config* has a `direct:` prefix that skips the shell
        // entirely, and it does **not** work here: measured, the surface config
        // takes a plain command string and never runs it through ghostty's
        // `Config.command` parser, so the pane reported that it was looking for
        // a binary literally named `direct:/opt/homebrew/bin/tmux`. Hence
        // quoting, not argv.
        //
        // `-u` forces UTF-8: the client's environment here is the one
        // libghostty gives a child, so tmux cannot infer it from LANG the way a
        // login shell would. Without it, box drawing and any non-ASCII output
        // corrupt.
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            // The child gets `TERM=xterm-ghostty` whether or not anything on the
            // machine can describe it. libghostty-spm ships the compiled
            // terminfo in its resource bundle and points the child at the
            // *shell integration* half (`GHOSTTY_RESOURCES_DIR`) but never at
            // this half — so on a machine with no Ghostty.app installed, tmux
            // exits in ~70ms with "missing or unsuitable terminal:
            // xterm-ghostty" and the pane shows ghostty's "failed to launch the
            // requested command" screen. Nil path means the bundle did not come
            // along, which is a different bug (`make app` copies it); no env is
            // then the same behaviour as before.
            envVars: GhosttyRuntimeResources.terminfoDirectoryURL
                .map { ["TERMINFO": $0.path] } ?? [:],
            command: "\(executable.shellQuoted) -u attach -t \(tmuxSession.shellQuoted)",
            // Explicit `false`, not nil. Nil means "whatever the user's ghostty
            // config says", and a user with `wait-after-command = true` would
            // keep the surface open after the tmux client exits — so
            // `terminalDidClose` never fires, `onExit` never runs, and the
            // session stays listed in `attachedSessions` with a dead client.
            // Same reasoning as sending `Dangerous` explicitly on a create.
            //
            // It is **not** sufficient, and measured so: this build of
            // libghostty reports a child exit as
            // `GHOSTTY_ACTION_SHOW_CHILD_EXITED`, which libghostty-spm does
            // not handle, so ghostty writes "Process exited. Press any key to
            // close the terminal." into the grid and keeps the surface
            // whatever this says. `AppState.adopt` detaches off the snapshot
            // for that reason; a keypress here is the only thing that gets a
            // `terminalDidClose` out of a pane whose tmux is still alive.
            waitAfterCommand: false,
            // ~96ms, on the dependency's own advice for this exact workload:
            // ghostty's IO thread coalesces resizes on a 25ms trailing-only
            // window, and an alt-screen agent TUI that fully repaints on every
            // winsize posts sizes faster than that resolves, so a live divider
            // drag composites a stale grid into the new bounds. 0 (the default)
            // is right for a transcript that never re-emits its scrollback; a
            // pane holding an agent is the other case.
            resizeThrottleMilliseconds: 96
        )
        pool.plainPanes[sessionID] = view
        return view
    }

    func updateNSView(_ view: AttachedTerminalView, context: Context) {
        pool.plainDelegates[sessionID]?.onExit = onExit
    }

    /// Stops the renderer, keeps the session. The pty and its tmux client both
    /// go on running in the background — see `makeNSView` — so switching back
    /// to this session is instant. Only `AppState.detach(_:)` tears them down.
    static func dismantleNSView(_ view: AttachedTerminalView, coordinator: Coordinator) {
        view.setSurfaceVisible(false)
    }

    final class Coordinator: NSObject, TerminalSurfaceCloseDelegate,
                             TerminalSurfaceOpenURLDelegate,
                             TerminalSurfaceClipboardConfirmationDelegate {
        var onExit: () -> Void

        init(onExit: @escaping () -> Void) { self.onExit = onExit }

        /// The tmux client went away: the user pressed the prefix key and `d`,
        /// or the session ended under them.
        func terminalDidClose(processAlive: Bool) { onExit() }

        /// libghostty finds the links — its own implicit-URL matcher plus OSC 8
        /// payloads — and asks before opening one. `TerminalLink` is the
        /// allowlist. Without a delegate nothing opens at all, so this is the
        /// only thing standing between `cat hostile.txt` and the system.
        func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
            TerminalLink.open(url)
        }

        /// ghostty asks before a protected clipboard operation, and with no
        /// delegate the bridge answers `false` — silently. That is right for a
        /// program reading the clipboard and wrong for the ⌘V the user just
        /// pressed: per the package's `handleClipboardConfirmation`, an
        /// unanswered paste simply does not happen, with no dialog and nothing
        /// in the log.
        ///
        /// So the cases are split on their initiator rather than lumped: a
        /// paste is the user's own keystroke and is allowed, while OSC 52 is the
        /// *program* in the pane asking to read or write the system clipboard,
        /// which is the thing worth refusing — pane output is
        /// attacker-influenceable, the same premise as `TerminalLink`.
        func terminalDidRequestClipboardConfirmation(
            _ request: TerminalClipboardConfirmationRequest
        ) {
            request.respond(allow: request.kind == .paste)
        }
    }
}

/// Dropping Finder files onto a terminal types their (shell-quoted) paths, the
/// same convention iTerm and Terminal.app use.
extension NSDraggingInfo {
    var moomux_hasFilePaths: Bool {
        draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    var moomux_filePathsForDrop: String? {
        guard let urls = draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil)
                as? [URL], !urls.isEmpty else { return nil }
        return urls.map(\.path).map(\.shellQuoted).joined(separator: " ")
    }
}

extension String {
    /// This string as a single shell word, safe to interpolate into a command
    /// line a shell will parse.
    ///
    /// Single quotes, because inside them a shell expands nothing at all — no
    /// `$`, no backtick, no `;`, no glob. The one character that cannot appear
    /// between them is `'` itself, so each one closes the quote, emits an
    /// escaped literal quote and reopens. Used by the `tmux attach` command
    /// line and by dropped file paths, both of which carry text this app did
    /// not author.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The escaping is the security boundary, so it gets asserted rather than
    /// eyeballed: getting the embedded-quote case wrong is exactly how a
    /// quoting helper becomes the injection it was written to prevent.
    static func shellQuotedDemo() {
        assert("lgok".shellQuoted == "'lgok'")
        // The whole point: a metacharacter stays data.
        assert("a; touch /tmp/x".shellQuoted == "'a; touch /tmp/x'")
        assert("$(id)".shellQuoted == "'$(id)'")
        assert("/opt/home brew/bin/tmux".shellQuoted == "'/opt/home brew/bin/tmux'")
        assert("".shellQuoted == "''")
        // A quote has to break out of the quoting and come back.
        assert("it's".shellQuoted == #"'it'\''s'"#, "it's".shellQuoted)
        // The break-out attempt: closing the quote and appending a command must
        // end up as one quoted word again, with no unquoted `;` anywhere.
        let hostile = #"x'; touch /tmp/pwned; '"#
        let quoted = hostile.shellQuoted
        assert(quoted == #"'x'\''; touch /tmp/pwned; '\'''"#, quoted)
        assert(quoted.hasPrefix("'") && quoted.hasSuffix("'"), quoted)
        // Every `'` in the output is either a quote boundary or preceded by a
        // backslash, which is what makes the word unbreakable.
        assert(!quoted.replacingOccurrences(of: #"'\''"#, with: "").dropFirst().dropLast()
            .contains("'"), quoted)
    }
}

/// The terminal for one session. Only reached once the user has deliberately
/// attached, so the "nothing to attach to" cases live on the button instead.
struct SessionTerminal: View {
    @Environment(AppState.self) private var app
    let session: Session
    /// The tmux client went away — the user pressed the prefix key and `d`, or
    /// the session ended under them.
    var onDetach: () -> Void

    var body: some View {
        if let tmux = ToolPath.find("tmux") {
            TerminalPane(executable: tmux, sessionID: session.id,
                        tmuxSession: session.tmuxSession, pool: app) {
                onDetach()
            }
            // Identifies the view per session so SwiftUI does not confuse one
            // session's representable for another's — the actual process
            // reuse is `AppState.plainPanes`, keyed the same way.
            .id(session.id)
        } else {
            ContentUnavailableView {
                Label("Can't find tmux", systemImage: "terminal")
            } description: {
                Text("""
                    An app launched from Finder doesn't inherit your shell's PATH, and tmux \
                    isn't in any of the usual places either.
                    """)
            }
        }
    }
}
