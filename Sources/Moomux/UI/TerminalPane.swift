import SwiftTerm
import SwiftUI

/// A live tmux client, hosted in the app.
///
/// This is substrate A from `docs/native-macos-rewrite.md`: tmux still owns the
/// process, so sessions survive quitting the app, and the very same session is
/// still `tmux attach`-able from a phone. The app is a viewport, not an owner.
///
/// ponytail: a plain `tmux attach`, not control mode (`tmux -CC`). tmux draws
/// its own splits and status line inside this one view and the app cannot see
/// the layout — so no native tabs, no native splits, no per-pane titles. That
/// buys nothing until there is UI to put a layout into.
///
/// The ceiling that does bite: **every client on a session shares one window
/// size**, so while this pane is attached, the user's iTerm window and phone
/// are letterboxed down to whatever this view happens to be. Measured, not
/// assumed — grouped sessions (`new-session -t`) do not fix it, because a group
/// shares the windows themselves, and the size does not spring back when the
/// larger client is used again. It only recovers on detach. That is why
/// attaching is an explicit action rather than a consequence of selecting a row.
///
/// Control mode does **not** fix this either, contrary to what the plan doc
/// assumed: a `-CC` client sets its size with `refresh-client -C` and the
/// window follows it exactly the same way. Measured both ways — see
/// `TmuxControlClient`.
///
/// The terminal widget is deliberately reached only through this file, so
/// swapping SwiftTerm for libghostty later is one file, as the plan assumes.
struct TerminalPane: NSViewRepresentable {

    let executable: String
    let sessionID: Session.ID
    /// The tmux session name to attach to, e.g. `moomux-macos-1a2b`.
    let tmuxSession: String
    let pool: AppState
    /// Called when the tmux client exits — detached, or the session went away.
    var onExit: (Int32?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    /// A terminal nobody can type into is not a terminal, and SwiftUI leaves
    /// first responder on the sidebar list when this pane appears — the
    /// accessibility API reported `AXOutline` as focused, and keystrokes went
    /// to the list. Taking focus from `updateNSView` does not work: the view
    /// has no window yet the one time that runs, so this hooks the moment it
    /// gets one. With it, characters, control keys and the tmux prefix all
    /// reach the client (checked against `capture-pane` and `client_prefix`).
    final class AttachedTerminalView: LocalProcessTerminalView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After SwiftUI finishes installing the pane, not during.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            sender.moomux_hasFilePaths ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let text = sender.moomux_filePathsForDrop else { return false }
            insertText(text, replacementRange: NSRange(location: 0, length: 0))
            return true
        }
    }

    /// Reuses a pooled view for this session if one is already running,
    /// rather than starting a fresh `tmux attach` — see `AppState.plainPanes`.
    /// Switching the sidebar selection away and back must not pay for a new
    /// process and an empty screen when the old one is still alive.
    ///
    /// `processDelegate` is declared `weak` in SwiftTerm, so `context.coordinator`
    /// — owned by SwiftUI only for as long as this representable stays
    /// mounted — cannot be the delegate: it would deallocate the moment the
    /// sidebar selection moves elsewhere, and a client that exits in the
    /// background afterwards would have nobody to tell. `AppState.plainDelegates`
    /// keeps one delegate alive per session for exactly as long as the pooled
    /// process is, so a background exit still reaches `AppState.detach(_:)`.
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        if let existing = pool.plainPanes[sessionID] {
            existing.processDelegate = pool.plainDelegates[sessionID]
            return existing
        }
        let view = AttachedTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        view.registerForDraggedTypes([.fileURL])
        let delegate = context.coordinator
        view.processDelegate = delegate
        pool.plainDelegates[sessionID] = delegate
        // `-u` forces UTF-8: the client's environment here is SwiftTerm's
        // minimal one, so tmux cannot infer it from LANG the way a login shell
        // would. Without it, box drawing and any non-ASCII output corrupt.
        view.startProcess(executable: executable, args: ["-u", "attach", "-t", tmuxSession])
        pool.plainPanes[sessionID] = view
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        pool.plainDelegates[sessionID]?.onExit = onExit
    }

    /// Deliberately does **not** terminate the process, and does not touch
    /// `onExit` either: the view going away here just means the sidebar
    /// selection moved to another session, and both the pooled client in
    /// `AppState.plainPanes` and its delegate in `AppState.plainDelegates` are
    /// meant to keep working the whole time it is backgrounded.
    /// `AppState.detach(_:)` is the only thing that actually tears either
    /// down — a real detach, not a navigation away.
    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {}

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: (Int32?) -> Void

        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onExit(exitCode)
        }

        // tmux redraws itself on SIGWINCH, so there is nothing to do for a
        // resize, and the window title is the app's own.
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}

/// Dropping Finder files onto a terminal types their (shell-quoted) paths, the
/// same convention iTerm and Terminal.app use. Shared by the plain-attach view
/// here and the control-mode panes in `ControlModeView.swift`.
extension NSDraggingInfo {
    var moomux_hasFilePaths: Bool {
        draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    var moomux_filePathsForDrop: String? {
        guard let urls = draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil)
                as? [URL], !urls.isEmpty else { return nil }
        return urls.map { url in
            "'\(url.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ")
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
                        tmuxSession: session.tmuxSession, pool: app) { _ in
                // SwiftTerm reports termination off the main thread.
                Task { @MainActor in onDetach() }
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
