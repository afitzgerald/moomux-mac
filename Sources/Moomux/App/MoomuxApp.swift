import AppKit
import SwiftUI

@main
struct MoomuxApp: App {
    @State private var app = MoomuxApp.bootstrap()

    /// A property initialiser is the earliest hook a SwiftUI `App` gives us,
    /// and `--selftest` has to exit before any window comes up.
    @MainActor
    private static func bootstrap() -> AppState {
        SelfTest.runIfRequested() // exits the process when --selftest is passed
        GhosttyResourceBundle.warm() // before any TerminalController
        let socket = socketPathArgument() ?? MoomuxClient.defaultSocketPath
        return AppState(client: MoomuxClient(socketPath: socket))
    }

    /// `--socket <path>`, matching `moomux serve -socket` / `moomux ui -socket`.
    private static func socketPathArgument() -> String? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--socket"), args.indices.contains(flag + 1) else {
            return nil
        }
        return args[flag + 1]
    }

    var body: some Scene {
        Window("moomux", id: "main") {
            RootView().environment(app)
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            SessionCommands(app: app)
        }

        MenuBarExtra {
            MenuBarContent().environment(app)
        } label: {
            // The count is the payload: it is what makes this worth having
            // over the TUI, which cannot be seen from another app.
            MenuBarIcon.image
            if app.needsInputCount > 0 { Text("\(app.needsInputCount)") }
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar glyph: the same cow-terminal face as `AppIcon.icns`, reduced
/// to a template silhouette (eyes and the ">_" prompt nose are transparent
/// holes cut with an evenodd fill) so AppKit tints it for light/dark menu
/// bars automatically.
private enum MenuBarIcon {
    static let image: Image = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let nsImage = NSImage(contentsOf: url) else {
            return Image(systemName: "cup.and.saucer")
        }
        nsImage.isTemplate = true
        nsImage.size = NSSize(width: 18, height: 18)
        return Image(nsImage: nsImage)
    }()
}

/// The row-level writes, so every one of them has a keyboard shortcut and is
/// reachable without a right-click.
///
/// Each button is disabled on its own: `Commands` has no `.disabled`, and
/// applying one to a `CommandMenu` does not compile.
struct SessionCommands: Commands {
    let app: AppState

    /// The row the menu acts on. The context menu uses the row that was
    /// clicked; the menu bar has only the selection to go on.
    @MainActor
    private var selected: Session? {
        // Over every session, not the visible slice: a search can select an
        // archived row and the menu has to keep acting on it.
        app.session(id: app.selectedSessionID)
    }

    var body: some Commands {
        // Replacing .newItem drops the dead "New Window" AppKit puts there for
        // a single-Window scene, so ⌘N means the only thing it can mean.
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { app.sheet = .create }
                .keyboardShortcut("n")
        }
        // ⌘, is where every Mac app keeps this, and replacing the group is
        // what puts it in the app menu rather than in a menu of our own. A
        // sheet and not a `Settings` scene: `app.sheet` is how every other form
        // here is opened, and one path is fewer than two.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { app.sheet = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }
        // SwiftUI gives `NavigationSplitView` a toolbar button and no menu
        // item, and a shortcut needs a menu item — so ⌃⌘S, the system-wide
        // spelling of this, did nothing at all. Verified before and after.
        CommandGroup(after: .sidebar) {
            Button(app.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                app.sidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }
        CommandMenu("Session") {
            // The sidebar List's own up/down-arrow navigation stops working
            // the moment a terminal pane has focus (it always takes first
            // responder on attach, so typing works without a click first) —
            // these are the equivalent of `PaneCommands` for the sidebar.
            Button("Next Session") { app.selectAdjacentSession(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(app.sessionsByProject.isEmpty)
            Button("Previous Session") { app.selectAdjacentSession(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(app.sessionsByProject.isEmpty)
            Divider()
            // ⌘F is the find shortcut everywhere, and `f` is the TUI's. The
            // search field lives in the sidebar; this puts the caret in it.
            // Hidden below macOS 15, where `.searchFocused` does not exist and
            // the item could only be a no-op — the field is still clickable.
            if #available(macOS 15, *) {
                Button("Find Session…") { app.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
            }
            // ⌘R is Refresh and ⌘↩ is Attach, both already live here.
            // ⌘G was the last free one, and Review is the action most often
            // wanted while attached, where the SessionInfo button is off screen.
            Button("Review Changes") { if let s = selected { app.review(s) } }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(selected.map { !app.canReview($0) } ?? true)
            Divider()
            Button("Edit Session…") { if let s = selected { app.sheet = .edit(s) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(selected == nil)
            Button("Tags…") { if let s = selected { app.sheet = .tags(s) } }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(selected == nil)
            Button(selected?.archived == true ? "Unarchive" : "Archive") {
                if let s = selected { app.setArchived(s, !s.archived) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(selected == nil)
            Divider()
            // Disabled while the core sorts by last-opened: the move would
            // succeed and the next open would undo it, which reads as a bug.
            // The TUI disables shift+↑↓ for the same reason.
            Button("Move Up") { if let s = selected { app.move(s, by: -1) } }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(selected == nil || !app.canReorder)
            Button("Move Down") { if let s = selected { app.move(s, by: 1) } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(selected == nil || !app.canReorder)
            Divider()
            Button("Kill tmux") { if let s = selected { app.killTmux(s) } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(selected.map { !app.isAlive($0) } ?? true)
            Button("Delete…") { if let s = selected { app.askDelete(s) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selected == nil)
        }
    }
}
