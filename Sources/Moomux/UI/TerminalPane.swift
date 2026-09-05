import SwiftTerm
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
/// The terminal widget is deliberately reached only through this file, so
/// swapping SwiftTerm for libghostty later is one file, as the plan assumes.
struct TerminalPane: NSViewRepresentable {
    @Environment(AppState.self) private var app

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
    final class AttachedTerminalView: LocalProcessTerminalView, CachesAppliedFontTheme {
        var appliedFontKey: String?
        var appliedThemeName: String?

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
    ///
    /// `processDelegate` is `weak` in SwiftTerm, so `context.coordinator` —
    /// only owned by SwiftUI for as long as this representable stays mounted
    /// — can't be the delegate: it would deallocate on the next sidebar
    /// switch, and a background exit would have nobody to tell.
    /// `AppState.plainDelegates` keeps one alive per session instead.
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        if let existing = pool.plainPanes[sessionID] {
            existing.processDelegate = pool.plainDelegates[sessionID]
            return existing
        }
        let view = AttachedTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        view.applyFontIfNeeded(app.terminalFont)
        view.applyThemeIfNeeded(app.terminalTheme)
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
        (view as? AttachedTerminalView)?.applyFontIfNeeded(app.terminalFont)
        (view as? AttachedTerminalView)?.applyThemeIfNeeded(app.terminalTheme)
    }

    /// Does nothing: the process and its delegate both keep working in the
    /// background — see `makeNSView`. Only `AppState.detach(_:)` tears them
    /// down.
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

/// A named background/foreground/ANSI-palette triple, independent of system
/// appearance. `nativeBackgroundColor` defaults to `NSColor.textBackgroundColor`,
/// which is white in light mode — that's why panes never looked like this
/// before any theme was installed at all.
public enum TerminalColorTheme: String, CaseIterable, Identifiable {
    case vibrant, classic, dracula, nord, solarizedDark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vibrant: return "Vibrant"
        case .classic: return "Classic"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        case .solarizedDark: return "Solarized Dark"
        }
    }

    var background: NSColor {
        switch self {
        case .vibrant: return NSColor(red8: 0x1a, green8: 0x1b, blue8: 0x26)
        case .classic: return .black
        case .dracula: return NSColor(red8: 0x28, green8: 0x2a, blue8: 0x36)
        case .nord: return NSColor(red8: 0x2e, green8: 0x34, blue8: 0x40)
        case .solarizedDark: return NSColor(red8: 0x00, green8: 0x2b, blue8: 0x36)
        }
    }

    var foreground: NSColor {
        switch self {
        case .vibrant: return NSColor(red8: 0xc0, green8: 0xcb, blue8: 0xf4)
        case .classic: return .white
        case .dracula: return NSColor(red8: 0xf8, green8: 0xf8, blue8: 0xf2)
        case .nord: return NSColor(red8: 0xd8, green8: 0xde, blue8: 0xe9)
        case .solarizedDark: return NSColor(red8: 0x83, green8: 0x94, blue8: 0x96)
        }
    }

    /// The 16 ANSI colors, dark then bright. Only `vibrant` and `classic` reuse
    /// SwiftTerm's own tables — the other three are each a real theme's actual
    /// terminal mapping, not this file's invention.
    var ansiPalette: [SwiftTerm.Color] {
        switch self {
        case .vibrant, .classic: return SwiftTerm.Color.vgaColors
        case .dracula:
            return [0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
                    0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff]
                .map(SwiftTerm.Color.init(hex:))
        case .nord:
            return [0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
                    0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4]
                .map(SwiftTerm.Color.init(hex:))
        case .solarizedDark:
            return [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                    0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3]
                .map(SwiftTerm.Color.init(hex:))
        }
    }
}

extension TerminalColorTheme {
    /// `Terminal.installPalette` silently no-ops if given anything but exactly
    /// 16 colors (`Terminal.swift`), so a typo dropping or duplicating one hex
    /// literal in a palette above would install nothing and leave the
    /// *previous* theme's palette in place — with no error anywhere. This is
    /// the check that catches it.
    static func demo() {
        for theme in allCases {
            assert(theme.ansiPalette.count == 16, "\(theme.rawValue) palette must have 16 colors")
        }
    }
}

private extension SwiftTerm.Color {
    convenience init(hex: Int) {
        self.init(red8: UInt16((hex >> 16) & 0xff), green8: UInt16((hex >> 8) & 0xff),
                   blue8: UInt16(hex & 0xff))
    }
}

private extension NSColor {
    convenience init(red8: UInt8, green8: UInt8, blue8: UInt8) {
        self.init(red: CGFloat(red8) / 255, green: CGFloat(green8) / 255,
                   blue: CGFloat(blue8) / 255, alpha: 1)
    }
}

extension TerminalView {
    func install(theme: TerminalColorTheme) {
        nativeBackgroundColor = theme.background
        nativeForegroundColor = theme.foreground
        caretColor = theme.foreground
        terminal.installPalette(colors: theme.ansiPalette)
    }
}

/// Adopted by every custom `TerminalView` subclass this app creates, so a
/// `SwiftUI` `updateNSView` can reapply the current font/theme every render
/// (they're read from `@Observable` state, so there's no cheaper place to put
/// the check) without actually touching the view unless the value changed.
///
/// This isn't just an optimization: SwiftTerm's `font` setter unconditionally
/// calls `selectNone()` (dropping a user's in-progress text selection) and
/// `resetFont()`, which — whenever the view already has a real size —
/// calls `resize()`, which calls `terminal.softReset()`. Reapplying an
/// unchanged font on every re-render would silently soft-reset the terminal
/// and drop selections on every unrelated event (a 2s poll tick, any pane's
/// `%window-renamed`), not just on an actual font change.
protocol CachesAppliedFontTheme: AnyObject {
    var appliedFontKey: String? { get set }
    var appliedThemeName: String? { get set }
}

extension CachesAppliedFontTheme where Self: TerminalView {
    func applyFontIfNeeded(_ newFont: NSFont) {
        let key = "\(newFont.fontName)@\(newFont.pointSize)"
        guard appliedFontKey != key else { return }
        appliedFontKey = key
        font = newFont
    }

    func applyThemeIfNeeded(_ theme: TerminalColorTheme) {
        guard appliedThemeName != theme.rawValue else { return }
        appliedThemeName = theme.rawValue
        install(theme: theme)
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
