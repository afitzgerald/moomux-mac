import AppKit
import Foundation
import GhosttyTerminal
import Observation

/// One-way flow, no exceptions:
///
///     MoomuxClient (unix socket) -> AppState -> Views
///
/// A single `@Observable` root store rather than a tree of view models. Views
/// read this and nothing else; nothing derived is stored in a view.
@MainActor
@Observable
public final class AppState {

    public enum Connection: Equatable {
        case connecting
        case connected
        case down(String)

        public var isDown: Bool { if case .down = self { return true }; return false }
    }

    // MARK: Server state

    /// The session list, **in the order the core served it**. Filtered here
    /// (by project, by archived, by search) and never sorted — the live-first
    /// tiebreak on top of the manual/recent-first order is the core's, so that
    /// two front ends cannot list the same project differently.
    public private(set) var sessions: [Session] = []
    /// Session id → everything derived about it: effective state (tmux
    /// liveness already folded in), label, quip, recovered first prompt, git
    /// and PR status. Replaced wholesale on every snapshot — it is absolute
    /// state, not a delta, and no longer a per-agent partial to merge.
    public private(set) var views: [Session.ID: SessionView] = [:]
    /// Project name → its sessions laid out as display rows, folder headers
    /// spliced in — `sessionview.Rows`, derived once in the core. Empty until
    /// the first snapshot, and empty from a core older than folders; both are
    /// what `layout(of:)`'s fallback covers.
    public private(set) var rows: [String: [Row]] = [:]
    public private(set) var config: Config?
    /// Which agents the core can launch, and what to offer in a model or
    /// thinking-level picker for each. Fetched once — it is a static table in
    /// `internal/app`, served over the socket precisely so a front end never
    /// keeps its own copy to drift.
    public private(set) var agentOptions: [AgentOption] = []
    /// The core's color palettes, fetched once for the same reason. Empty
    /// until `Themes` answers — `palette` is nil then, and the views fall
    /// back to SwiftUI's own semantic colors, which is what "default"
    /// encodes anyway.
    public private(set) var themes: [ThemePalette] = []
    /// Fresh worktree state and change counts, by session id, for sessions
    /// that have been looked at. The snapshot already carries dirty/unpushed
    /// for every row — this is the *on-demand* version: the delete dialog's
    /// guard before removing a worktree, and the file/commit counts the detail
    /// pane shows. Two shell-outs per entry, so it is fetched on selection
    /// rather than polled.
    public private(set) var statuses: [Session.ID: MoomuxClient.SessionStatus] = [:]

    public private(set) var connection: Connection = .connecting
    /// Set when the status stream drops. Without it the last states keep
    /// rendering, which reads as live rather than frozen.
    public private(set) var statusError: String?

    // MARK: UI state

    public var selectedSessionID: Session.ID?
    public var showArchived = false
    /// The sidebar's search field. Non-empty, it replaces `showArchived` as
    /// what the list shows — see `listedSessions`.
    public var searchQuery = ""
    /// Bumped to put the keyboard in the search field. A token rather than a
    /// Bool because the menu item has to work when focus is already there and
    /// the user simply wants to start over; `@FocusState` lives in the view.
    public private(set) var focusSearchToken = 0

    public func focusSearch() { focusSearchToken += 1 }
    /// Replace the detail column with a read-only snapshot of every live
    /// session. Snapshots and not clients: an attached client sizes the shared
    /// tmux window for everyone, so a grid of six would letterbox six real
    /// sessions. Clicking a tile selects it; Attach is still the full-size,
    /// deliberate thing. No snapshot text lives in the store — see `SessionGrid`.
    public var showGrid = false
    /// Whether the session list is showing. Here rather than in `RootView` for
    /// the usual reason: the View menu has to toggle it, and commands can only
    /// reach the store. A `Bool` and not a `NavigationSplitViewVisibility`, so
    /// this file does not have to import SwiftUI for one enum — `RootView` maps
    /// it, and the toolbar's own button writes back through the same binding.
    public var sidebarVisible = true
    /// Whatever the last `OpenSession` told the user to do, if anything.
    public var hint: String?
    /// A mutation the server refused, until the user dismisses it. See
    /// `failed(_:_:)` for why this is not `connection`.
    public var actionError: String?
    /// What a write is doing, while it does it. Only `create` takes long
    /// enough to matter, but every mutation reports here so nothing has to
    /// hold a sheet open waiting for one. Rendered by `ConnectionBadge`.
    public private(set) var busy: String?
    /// Which modal form is up. Presentation state lives on the store rather
    /// than in a view because the Session menu has to open these too, and views
    /// read AppState and nothing else.
    public enum Sheet: Identifiable, Hashable {
        case create
        /// Name, agent and the dangerous flag together — `internal/tui`'s
        /// edit-session form is one dialog over the same three fields, and
        /// `RenameSession` no-ops on an unchanged name, so there is nothing to
        /// gain from splitting them into two sheets and two shortcuts.
        case edit(Session)
        case tags(Session)
        /// A new folder in a project — and, when it was opened from a session's
        /// own menu, the session to file into it. `SetSessionFolder` creates a
        /// folder on first use, so that is one call rather than two.
        case newFolder(project: String, assign: Session?)
        case renameFolder(project: String, name: String)
        /// Settings *and* project management, on two tabs.
        ///
        /// The project add/edit form is deliberately not a case here: it is
        /// opened from inside this sheet, and one `.sheet(item:)` modifier can
        /// only present one thing — a nested form needs its own presentation on
        /// the settings sheet itself. Which also means there is exactly one
        /// place projects are managed from, and one host for the dialogs that
        /// managing them raises.
        case settings
        public var id: Self { self }
    }
    public var sheet: Sheet?
    /// The session the delete confirmation is asking about. Its own field, not
    /// a `Sheet` case: an alert is not a sheet and cannot share the modifier.
    /// Set it through `askDelete(_:)` rather than directly, or the unsaved-work
    /// step below is skipped.
    public var pendingDelete: Session?

    /// The project the remove confirmation is asking about. Same reason.
    public var pendingProjectDelete: String?

    /// A project whose repo path turned out not to be a git repository. Not an
    /// error — a question, and these are its two answers (`initProject` /
    /// `addPlainProject`), which is exactly what the TUI's init-choice dialog
    /// asks. Carries the form's own `Project` so answering does not need the
    /// sheet to still be open.
    public struct PendingProject: Identifiable, Hashable, Sendable {
        public let name: String
        public let project: Project
        public var id: String { name }
    }
    public var pendingProjectInit: PendingProject?

    /// Sessions the app has attached to, pinned at `attach(_:)` time rather
    /// than view-local `@State` so switching the sidebar selection away and
    /// back shows the terminal again immediately — see `attach(_:)`/`detach(_:)`.
    public private(set) var attachedSessions: Set<Session.ID> = []

    /// The actual tmux clients kept running in the background for attached
    /// sessions that aren't the one on screen, so switching back to one is
    /// instant instead of a fresh forkpty. `plainDelegates` exists because
    /// `AppTerminalView.delegate` is `weak`: without something else retaining
    /// the delegate, a client that exits while backgrounded has nobody to tell.
    @ObservationIgnored var plainPanes: [Session.ID: TerminalPane.AttachedTerminalView] = [:]
    @ObservationIgnored var plainDelegates: [Session.ID: TerminalPane.Coordinator] = [:]

    /// The one libghostty runtime: config, the `ghostty_app_t` behind it, and
    /// the wakeup fan-out every surface shares. One per process, so the
    /// attached pane and every grid tile answer to the same config.
    ///
    /// Built lazily rather than in `init` because creating it initialises the
    /// ghostty C runtime, and `--selftest` runs in a binary that never draws a
    /// terminal — see `SelfTest`.
    @ObservationIgnored public private(set) lazy var terminalController: TerminalController = {
        // One `.generated` source rather than two branches: the user's ghostty
        // config files concatenated in ghostty's own load order, then this
        // app's keybinds last so they win. An empty `TerminalTheme` is not a
        // detail — the controller layers `theme` *on top of* the base config,
        // and `TerminalTheme.default` is a full Afterglow/Alabaster palette
        // that would silently overwrite every colour the config just set.
        // `terminalConfiguration` is left empty for the same reason: with both
        // empty the controller uses the base verbatim instead of re-rendering.
        let controller = TerminalController(
            configSource: .generated(Self.paneConfig()),
            theme: TerminalTheme(light: TerminalConfiguration(), dark: TerminalConfiguration())
        )
        // `prepareConfig` rejects a config on *any* diagnostic — it does not
        // load it without the bad line — so one `theme = <something we did not
        // vendor>` costs the user every colour, font and setting they wrote.
        // Only on that path, drop the lines ghostty refuses and keep the rest.
        if controller.lastConfigurationIssue != nil {
            let (kept, dropped) = Self.narrowedConfig(Self.paneConfig()) {
                controller.updateConfigSource(.generated($0))
            }
            paneConfigDropped = dropped
            _ = controller.updateConfigSource(.generated(kept))
        }
        return controller
    }()

    /// Lines of the user's ghostty config that ghostty refused, dropped so the
    /// rest of it could load. Shown in Settings → Terminal; empty is the
    /// normal case. Reading it builds the controller, because that is when the
    /// narrowing happens.
    public var paneConfigDropped: [String] {
        get { _ = terminalController; return _paneConfigDropped }
        set { _paneConfigDropped = newValue }
    }

    @ObservationIgnored private var _paneConfigDropped: [String] = []

    /// The longest prefix-preserving subset of `text` that ghostty accepts,
    /// and the directives left out to get there.
    ///
    /// Line by line rather than by bisection: `accepts` is the whole cost and a
    /// config is tens of lines, so the clever version saves milliseconds on a
    /// path that only runs when the config was already broken. Blank and
    /// comment lines are kept without asking — they cannot be the diagnostic,
    /// and re-parsing for each of them is the one thing that would make this
    /// slow enough to notice.
    ///
    /// ponytail: O(n²) parsing, n = config lines. Bisect if a 1000-line config
    /// ever shows up.
    nonisolated static func narrowedConfig(
        _ text: String,
        accepts: (String) -> Bool
    ) -> (kept: String, dropped: [String]) {
        var kept: [String] = []
        var dropped: [String] = []
        for line in text.components(separatedBy: "\n") {
            let bare = line.trimmingCharacters(in: .whitespaces)
            if bare.isEmpty || bare.hasPrefix("#") {
                kept.append(line)
            } else if accepts((kept + [line]).joined(separator: "\n")) {
                kept.append(line)
            } else {
                dropped.append(bare)
            }
        }
        return (kept.joined(separator: "\n"), dropped)
    }

    /// The ghostty config text every pane and tile is built from: whatever the
    /// user's own config files say, then this app's keybinds.
    ///
    /// ponytail: the files' *text* is concatenated and handed over as one
    /// generated config, which is the only shape that both honours several
    /// files and gets the keybinds in last. Two ceilings, both inherent to the
    /// dependency rather than to this: a `config-file =` include is ignored
    /// (libghostty-spm only ever calls `ghostty_config_load_file`, never
    /// `ghostty_config_load_recursive_files`, so includes never resolve however
    /// the config is loaded), and a directive naming a path relative to the
    /// config — `theme = mine` looking for a sibling `themes/` — resolves
    /// against the generated file's own directory instead. The upgrade is a
    /// package that layers configs or calls the recursive loader.
    nonisolated static func paneConfig(files: [String] = ghosttyConfigPaths(),
                           read: (String) -> String? = {
                               try? String(contentsOfFile: $0, encoding: .utf8)
                           }) -> String {
        let user = files.compactMap(read).filter { !$0.isEmpty }
        // No config anywhere: a dark pane, matching what this app looked like
        // before it read one. Colours only — no 16-entry palette, because
        // ghostty's own default is better than a hand-copied table and a
        // machine with no ghostty config has expressed no opinion about it.
        let base = user.isEmpty ? [Self.builtInPaneConfig.rendered] : user
        return (base + [Self.paneKeybinds.rendered]).joined(separator: "\n") + "\n"
    }

    nonisolated private static let builtInPaneConfig = TerminalConfiguration(startingFrom: .default) {
        $0.withBackground("1a1b26")
        $0.withForeground("c0cbf4")
        // A Nerd Font so powerline/devicon glyphs in prompts and statuslines
        // render as icons rather than tofu. ghostty falls back on its own if
        // the family isn't installed.
        $0.withFontFamily("Hack Nerd Font Mono")
        $0.withFontSize(12)
    }

    /// The app owns ⌘-shortcuts; ghostty owns none of them.
    ///
    /// ghostty ships a full set of its own keybinds, and a focused surface eats
    /// them before AppKit's menu ever sees the event. Measured: with a pane
    /// focused, ⌘, opened nothing at all — ghostty's `open_config` swallowed it
    /// — while the same keystroke with the sidebar focused opened Settings. Its
    /// ⌘T, ⌘N and ⌘W would have gone the same way, all of them actions this app
    /// either owns or does not have.
    ///
    /// So: `keybind = clear` drops the lot, then the handful a terminal is
    /// genuinely expected to answer are put back. Rendered *after* the user's
    /// own config, so a `keybind` they set is cleared too — deliberate, since
    /// the alternative is a menu item that silently does nothing depending on
    /// where focus happens to be.
    ///
    /// `clipboard-paste-protection` is deliberately *not* set here. It stays at
    /// ghostty's default (on) and `TerminalPane.Coordinator` answers the
    /// confirmation it raises — allowing the ⌘V the user just pressed and
    /// refusing a program's OSC 52. Turning the flag off would reach the same
    /// place today while moving the decision into a config line, where the
    /// reasoning cannot live and a future dialog could not hook in.
    nonisolated private static let paneKeybinds = TerminalConfiguration { builder in
        builder.withCustom("keybind", "clear")
        builder.withCustom("keybind", "super+c=copy_to_clipboard")
        builder.withCustom("keybind", "super+v=paste_from_clipboard")
        builder.withCustom("keybind", "super+a=select_all")
        // Zoom, ghostty's own defaults put back verbatim. A fixed pane font on
        // a large display is unreadable, and this is the one place the size can
        // be changed at all — there is deliberately no font setting (the user's
        // ghostty config owns it), so ⌘+/⌘-/⌘0 is the whole feature. ghostty
        // re-derives the grid and the pty size from it, so tmux follows.
        builder.withCustom("keybind", "super+equal=increase_font_size:1")
        builder.withCustom("keybind", "super+plus=increase_font_size:1")
        builder.withCustom("keybind", "super+minus=decrease_font_size:1")
        builder.withCustom("keybind", "super+zero=reset_font_size")
    }

    /// Every ghostty config file that exists, in the order ghostty loads them.
    ///
    /// All of them, not the first: ghostty loads each in turn and lets the
    /// later ones override, and it looks for **two** names per directory — the
    /// legacy `config` and then `config.ghostty`, which is the current one
    /// (`Config.loadDefaultFiles`). Checking only `config` and taking the first
    /// hit got both halves wrong: it misses a `config.ghostty` entirely — the
    /// only ghostty config on this machine is one — and where two exist it
    /// picks the one ghostty gives *lower* precedence.
    ///
    /// The filesystem probe is injected so `demo()` does not depend on what
    /// happens to be installed.
    nonisolated public static func ghosttyConfigPaths(
        home: String = NSHomeDirectory(),
        xdgConfigHome: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
        isReadable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
    ) -> [String] {
        // One XDG directory, not both: `XDG_CONFIG_HOME` *replaces* `~/.config`
        // when set, it does not add to it.
        let xdg = (xdgConfigHome?.isEmpty == false ? xdgConfigHome! : "\(home)/.config")
            + "/ghostty"
        let appSupport = "\(home)/Library/Application Support/com.mitchellh.ghostty"
        return [xdg, appSupport]
            .flatMap { ["\($0)/config", "\($0)/config.ghostty"] }
            .filter(isReadable)
    }

    nonisolated static func ghosttyConfigDemo() {
        let home = "/h"
        func paths(_ present: Set<String>, xdg: String? = nil) -> [String] {
            ghosttyConfigPaths(home: home, xdgConfigHome: xdg) { present.contains($0) }
        }
        assert(paths([]).isEmpty)
        // The current filename, which is the one that was being missed.
        assert(paths(["/h/.config/ghostty/config.ghostty"])
               == ["/h/.config/ghostty/config.ghostty"])
        // Legacy before current, XDG before Application Support: ghostty's
        // order, and later entries override earlier ones.
        assert(paths(["/h/.config/ghostty/config.ghostty", "/h/.config/ghostty/config"])
               == ["/h/.config/ghostty/config", "/h/.config/ghostty/config.ghostty"])
        assert(paths(["/h/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
                      "/h/.config/ghostty/config"])
               == ["/h/.config/ghostty/config",
                   "/h/Library/Application Support/com.mitchellh.ghostty/config.ghostty"])
        // XDG_CONFIG_HOME replaces ~/.config rather than adding to it.
        assert(paths(["/h/.config/ghostty/config", "/x/ghostty/config"], xdg: "/x")
               == ["/x/ghostty/config"])
        assert(paths(["/h/.config/ghostty/config"], xdg: "") == ["/h/.config/ghostty/config"],
               "an empty XDG_CONFIG_HOME is unset, not a path")

        // The keybinds must come last, or ghostty keeps the user's binding and
        // the app's menu shortcuts stay swallowed.
        let text = paneConfig(files: ["/a", "/b"], read: { $0 == "/a" ? "font-size = 9" : "x = 1" })
        assert(text.hasPrefix("font-size = 9\nx = 1\n"), text)
        assert(text.range(of: "keybind = clear")!.lowerBound
               > text.range(of: "font-size = 9")!.lowerBound, text)
        // Nothing readable falls back to the built-in dark, still with keybinds.
        let fallback = paneConfig(files: [], read: { _ in nil })
        assert(fallback.contains("background = 1a1b26"), fallback)
        assert(fallback.contains("keybind = clear"), fallback)
        // An unreadable or empty file must not blank the fallback.
        assert(paneConfig(files: ["/a"], read: { _ in "" }).contains("background = 1a1b26"))

        // Narrowing: one bad directive costs that directive, not the config.
        // The stand-in for ghostty refuses any config mentioning `theme`.
        func accepts(_ text: String) -> Bool { !text.contains("theme") }
        let (kept, dropped) = narrowedConfig(
            "# a comment\ntheme = Nope\nfont-size = 9\n\nkeybind = clear\n",
            accepts: accepts
        )
        assert(dropped == ["theme = Nope"], "\(dropped)")
        assert(kept == "# a comment\nfont-size = 9\n\nkeybind = clear\n", kept)
        // A config ghostty already accepts comes back byte for byte.
        let fine = "font-size = 9\nkeybind = clear\n"
        assert(narrowedConfig(fine, accepts: accepts) == (fine, []))
        // Everything refused still yields a loadable (empty) config rather
        // than nil — the caller has nothing else to fall back to.
        assert(narrowedConfig("theme = a\ntheme = b\n", accepts: accepts)
               == ("", ["theme = a", "theme = b"]))
    }

    public let client: MoomuxClient

    private var tasks: [Task<Void, Never>] = []
    /// Whether the snapshot stream is currently delivering. It owns the
    /// session list while it is; the poll loop takes over when it is not (a
    /// core with no `Source`, or one that is simply down), which is the only
    /// reason a pull of `Sessions` still happens on a schedule at all.
    @ObservationIgnored private var streaming = false
    /// No view reads this, and `@Observable` fires on any assignment.
    @ObservationIgnored private var notifier: Notifier?

    public init(client: MoomuxClient = MoomuxClient()) {
        self.client = client
    }

    // MARK: Derived

    /// The core's `sessionview.View.State` — already the *effective* one, with
    /// tmux liveness folded in. Unknown only before the first snapshot, or for
    /// a session the core has no view for yet.
    public func state(for session: Session) -> AgentState {
        views[session.id]?.state ?? .unknown
    }

    public func quip(for session: Session) -> String? {
        views[session.id]?.quip
    }

    /// What to *call* a session's state. The core serves the wording
    /// (`sessionview.Label`) so both front ends say the same thing about the
    /// same session; `AgentState.label` is only the fallback for before the
    /// first snapshot, when there is nothing served to say.
    public func label(for session: Session) -> String {
        let served = views[session.id]?.label ?? ""
        return served.isEmpty ? state(for: session).label : served
    }

    /// The row's ± / ↑ badges: the snapshot's git status normally, and the
    /// fresher on-demand answer for a session that has been looked at.
    ///
    /// The core caches git status for about a minute (jittered), so without
    /// this a session whose pane just committed and pushed shows "clean" in
    /// the detail pane and a dirty badge on its own row for up to another
    /// minute. nil means nobody could tell — draw nothing, which is not the
    /// same as clean.
    public func gitBadges(for session: Session) -> (dirty: Bool, unpushed: Bool)? {
        if let fresh = statuses[session.id], fresh.known {
            return (fresh.dirty, fresh.unpushed)
        }
        guard let view = views[session.id], view.gitOK else { return nil }
        return (view.dirty, view.unpushed)
    }

    /// The first prompt the core recovered (from the agent's own logs, for a
    /// session moomux did not start), falling back to the stored one — which is
    /// all there is before the first snapshot.
    public func prompt(for session: Session) -> String {
        let recovered = views[session.id]?.prompt ?? ""
        return recovered.isEmpty ? (session.prompt ?? "") : recovered
    }

    /// Parked *is* "its tmux session is gone" — the core does that join now,
    /// so this is a reading of the state rather than a second poll to correlate
    /// against it.
    public func isAlive(_ session: Session) -> Bool {
        guard let state = views[session.id]?.state else { return false }
        return state != .parked
    }

    /// `review(_:)` needs a live tmux session to add a window to, and something
    /// to diff. A no-worktree git project still diffs fine, so the predicate is
    /// `isPlain` and not `usesWorktree`.
    public func canReview(_ session: Session) -> Bool {
        isAlive(session) && config?.projects[session.project]?.isPlain != true
    }

    /// Sessions the user should look at. The menu bar's whole reason to exist.
    public var needsInputCount: Int {
        visibleSessions.filter { state(for: $0) == .needsInput }.count
    }

    public var visibleSessions: [Session] {
        showArchived ? sessions : sessions.filter { !$0.archived }
    }

    /// What the sidebar lists: the visible slice normally, and while a search
    /// is running every session whose name matches — **archived ones
    /// included**, whatever the Archived toggle says. `internal/tui`'s
    /// `matchSessions` runs over the whole store for the same reason: the
    /// session you cannot remember is disproportionately likely to be one you
    /// archived and forgot.
    public var listedSessions: [Session] {
        AppState.matchSessions(searching ? sessions : visibleSessions, query: searchQuery)
    }

    public var searching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `internal/tui/search.go`'s `matchSessions`: case-insensitive substring
    /// against the name and nothing else. Not the branch, not the project, not
    /// the prompt — the TUI settled on names, and a front end that quietly
    /// matched more would rank differently for the same typing.
    nonisolated static func matchSessions(_ all: [Session], query: String) -> [Session] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(query) }
    }

    /// The session behind an id, from *every* session rather than the visible
    /// slice: a search can select an archived row, and the detail pane and the
    /// Session menu both have to keep working on it.
    public func session(id: Session.ID?) -> Session? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Project name → its sessions, in the order the server returned them
    /// (which is the user's manual ordering), projects in config order.
    public var sessionsByProject: [(project: String, sessions: [Session])] {
        let grouped = Dictionary(grouping: listedSessions, by: \.project)
        let ordered = config?.orderedProjectNames ?? []
        let known = Set(ordered)
        return (ordered + grouped.keys.filter { !known.contains($0) }.sorted())
            .compactMap { name in
                guard let sessions = grouped[name], !sessions.isEmpty else { return nil }
                return (name, sessions)
            }
    }

    public func emoji(for project: String) -> String? {
        config?.projects[project]?.emoji
    }

    /// A search must never be answered by a section the user cannot see, so
    /// collapsing is ignored while there is a query — same reason search
    /// matches archived sessions whatever the Archived toggle says.
    public func projectExpanded(_ name: String) -> Bool {
        searching ? true : config?.projects[name]?.collapsed != true
    }

    /// Collapse is config, not a local preference — `SetProjectCollapsed`
    /// exists precisely for a front end that renders projects as a tree, so the
    /// choice survives a restart and reads the same everywhere. Applied here
    /// first because the round trip is visible on a chevron.
    public func setProject(_ name: String, expanded: Bool) {
        applyProjectCollapsed(name, !expanded)
        mutate(expanded ? "Expand" : "Collapse") {
            try $0.setProjectCollapsed(project: name, !expanded)
            return nil
        }
    }

    /// The optimistic half of `setProject`, on its own so the checks can drive
    /// it without a socket.
    func applyProjectCollapsed(_ name: String, _ collapsed: Bool) {
        config?.projects[name]?.collapsed = collapsed
    }

    /// The rows a project shows: all of them when expanded, and the selected
    /// session's when collapsed — folding away the session whose terminal is
    /// on screen reads as the collapse having lost it. Selected *and*
    /// attached, not merely attached: a pane outlives switching away from it
    /// (see `SessionDetail`), so every session ever opened would otherwise
    /// pile up under a collapsed project.
    public func shownSessions(of project: String, in sessions: [Session]) -> [Session] {
        if projectExpanded(project) { return sessions }
        return sessions.filter { $0.id == selectedSessionID && attachedSessions.contains($0.id) }
    }

    /// The core's layout for a project, or one loose row per session when it
    /// has not sent one — an older core, or the pull path, which answers with
    /// sessions and no rows.
    public func layout(of project: String, in sessions: [Session]) -> [Row] {
        rows[project] ?? sessions.map { Row(id: $0.id) }
    }

    /// What the sidebar draws under a project header: the core's row layout,
    /// filtered to this window's view. A collapsed project keeps only the
    /// pinned row, as it always did.
    public func sidebarRows(of project: String, in sessions: [Session]) -> [Layout.SidebarRow] {
        let shown = shownSessions(of: project, in: sessions)
        guard projectExpanded(project) else { return shown.map { .session($0, folder: "") } }
        return Layout.rows(layout(of: project, in: allSessions(of: project)), shown: shown,
                           searching: searching)
    }

    /// Every session of a project, filtered by nothing — what a reorder has to
    /// renumber, and the fallback layout has to cover.
    private func allSessions(of project: String) -> [Session] {
        sessions.filter { $0.project == project }
    }

    /// The project's folder names, in the order they are drawn (a folder sits
    /// wherever its first member does), for the "file this session under…" menu.
    public func folders(of project: String) -> [String] {
        let named = layout(of: project, in: allSessions(of: project))
            .filter(\.isFolder).map(\.folder)
        guard named.isEmpty else { return named }
        // No layout yet (an older core, or the pull path): config still knows.
        return (config?.projects[project]?.folders?.keys).map { $0.sorted() } ?? []
    }

    /// Moves the selection to the next/previous row in sidebar order,
    /// wrapping. The Session menu's replacement for the sidebar `List`'s own
    /// arrow-key navigation, which stops reaching the list the instant a
    /// terminal pane takes first responder — which it does deliberately, so
    /// typing works without clicking first (`PaneTerminalView.viewDidMoveToWindow`).
    public func selectAdjacentSession(by delta: Int) {
        // Rows inside a collapsed section are not on screen; stepping the
        // selection onto one would look like the keystroke did nothing.
        let ids = sessionsByProject
            .flatMap { sidebarRows(of: $0.project, in: $0.sessions).compactMap { $0.session?.id } }
        guard !ids.isEmpty else { return }
        guard let current = selectedSessionID, let index = ids.firstIndex(of: current) else {
            selectedSessionID = ids[0]
            return
        }
        selectedSessionID = ids[(index + delta + ids.count) % ids.count]
    }

    /// Manual reordering is meaningless while the core sorts by last-opened —
    /// the next open would undo it. The TUI disables shift+↑↓ for the same
    /// reason rather than letting a move silently do nothing.
    public var canReorder: Bool { config?.sortRecentFirst != true }

    // MARK: Agent table
    //
    // These three mirror `internal/tui`'s `agentNames` / `modelNamesFor` /
    // `thinkingNamesFor` exactly, fallbacks included, over the same table the
    // TUI reads. The point is that neither side owns a copy of the *contents*.

    public var agentNames: [String] {
        // A core that answered with nothing at all would otherwise leave every
        // picker empty and unselectable; claude is what the TUI falls back to.
        agentOptions.isEmpty ? ["claude"] : agentOptions.map(\.name)
    }

    /// The model choices for `agent`, falling back to claude's list. Empty
    /// means the agent has no fixed list worth offering (opencode) and the
    /// control should be a free-text field instead of a picker.
    public func models(for agent: String) -> [String] {
        if let own = agentOptions.first(where: { $0.name == agent })?.models, !own.isEmpty {
            return own
        }
        return agentOptions.first { $0.name == "claude" }?.models ?? []
    }

    /// The thinking-level choices for `agent`, falling back to claude's.
    public func thinking(for agent: String) -> [String] {
        agentOptions.first { $0.name == agent }?.thinking
            ?? agentOptions.first { $0.name == "claude" }?.thinking
            ?? []
    }

    /// The palette to draw with: the config's theme, resolved against the
    /// served list. `config.ThemeByName`'s fallbacks, plus the ANSI one.
    public var palette: ThemePalette? {
        ThemePalette.resolved(config?.theme ?? "", in: themes)
    }

    /// What the theme picker offers, plus whatever is stored if the core has
    /// not heard of it — an older core against a newer config.toml, which is
    /// rarer than it was when this list was hardcoded but still possible.
    ///
    /// Never empty: a core too old to answer `Themes` would otherwise leave
    /// the picker with no rows at all, which is the same "renders blank and
    /// writes nothing" trap as an unmatched tag — and permanent, since
    /// `loadThemes` would retry that core forever.
    public var themeNames: [String] {
        let known = themes.isEmpty ? ["default"] : themes.map(\.name)
        guard let stored = config?.theme, !stored.isEmpty, !known.contains(stored) else { return known }
        return known + [stored]
    }

    // MARK: Lifecycle

    public func start() {
        guard tasks.isEmpty else { return }
        // Here rather than in `init`: `--selftest` exits inside `bootstrap()`
        // from an unbundled binary, where reaching the notification center at
        // all would trap.
        notifier = Notifier(app: self)
        tasks = [
            // The cold-start pull: the stream is the render path, but the
            // first snapshot is a beat away and a core too old to stream at
            // all would otherwise show an empty sidebar forever.
            Task { [weak self] in await self?.refresh() },
            Task { [weak self] in await self?.pollLoop() },
            Task { [weak self] in await self?.watchLoop() },
            Task { [weak self] in await self?.loadAgentOptions() },
            Task { [weak self] in await self?.loadThemes() },
        ]
    }

    /// Retries until it lands: the app can start before `moomux serve` does,
    /// and without the table the new-session form has no pickers at all. Once
    /// fetched it is never refetched — the Go side's table is a `var` in the
    /// binary, so it cannot change without a restart of the core.
    private func loadAgentOptions() async {
        while !Task.isCancelled, agentOptions.isEmpty {
            if let options = try? await withoutBlockingTheUI({ [client] in
                try client.agentOptions()
            }), !options.isEmpty {
                agentOptions = options
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Same retry-until-answered loop as `loadAgentOptions`, and for the same
    /// reason: a static table in the core's binary, and without it every state
    /// icon renders in the fallback colors.
    private func loadThemes() async {
        while !Task.isCancelled, themes.isEmpty {
            if let served = try? await withoutBlockingTheUI({ [client] in
                try client.themes()
            }), !served.isEmpty {
                themes = served
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    /// Config has no push channel; everything else arrives on the stream.
    /// One small round trip every two seconds, which is what keeps project
    /// order, emoji and the shared settings fresh with no invalidation logic.
    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshConfig()
            // Only while nothing is streaming. A core too old to serve `Watch`
            // (or one whose stream just dropped) would otherwise show the list
            // as it stood at startup, forever, while `connection` said
            // "connected" — sessions created or deleted elsewhere never
            // arriving is not something the user can see is happening.
            if !streaming { await refreshSessions() }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// ⌘R, and every mutation once it lands: the config now, and a *snapshot*
    /// now rather than at the core's next tick.
    ///
    /// It deliberately does not pull `Sessions` while the stream is healthy.
    /// The pulled list is ordered by `App.Sessions()` alone — the "sessions
    /// with a live tmux window float to the top" tiebreak is applied by
    /// `internal/sessionview`, on the stream — so adopting one would re-sort
    /// the sidebar and let the next snapshot sort it back a beat later. A
    /// nudge answers with the same list the stream would have sent, in the
    /// order it would have sent it.
    public func refresh() async {
        await refreshConfig()
        if streaming {
            client.nudge()
        } else {
            await refreshSessions()
        }
    }

    private func refreshConfig() async {
        do {
            config = try await withoutBlockingTheUI { [client] in try client.config() }
            connection = .connected
        } catch {
            // Deliberately leaves the last-good config in place; a failed call
            // must never read as "every project was removed".
            connection = .down(error.localizedDescription)
        }
    }

    private func refreshSessions() async {
        guard let fresh = try? await withoutBlockingTheUI({ [client] in try client.sessions() })
        else { return }  // `connection` already carries the failure
        adopt(sessions: fresh)
    }

    /// Loads (or reloads) worktree state and change counts for one session.
    public func loadStatus(for id: Session.ID, force: Bool = false) async {
        guard force || statuses[id] == nil else { return }
        do {
            let status = try await withoutBlockingTheUI { [client] in
                try client.status(id: id)
            }
            statuses[id] = status
        } catch {
            // Leave whatever was there; `connection` already carries the
            // failure, and a missing status row is not worth a second alarm.
        }
    }

    /// Takes a new session list, from either channel, and prunes everything
    /// keyed by an id that is no longer in it — a session can disappear
    /// without going through this app (the TUI, the CLI, another front end),
    /// and a pooled tmux client left behind would leak forever.
    private func adopt(sessions fresh: [Session]) {
        // `@Observable` fires on any assignment, equal or not, and this lands
        // on every raw watcher event — several a second while an agent is
        // writing its log — so an unguarded write re-renders every row that
        // often for a list that rarely changes.
        if fresh != sessions { sessions = fresh }
        let live = Set(fresh.map(\.id))
        let pruned = statuses.filter { live.contains($0.key) }
        if pruned.count != statuses.count { statuses = pruned }
        for id in attachedSessions where !live.contains(id) { detach(id: id) }
        // tmux went away under an attached pane — `/kill`, `moomux park`, a
        // kill from the TUI. libghostty does **not** close the surface when
        // its child exits: measured, with `waitAfterCommand: false` on the
        // surface *and* in the pane config, this build reports the exit as
        // `GHOSTTY_ACTION_SHOW_CHILD_EXITED`, which libghostty-spm does not
        // handle, so ghostty writes "Process exited. Press any key to close
        // the terminal." into the grid and keeps the surface — no
        // `close_surface_cb`, so no `terminalDidClose`. The snapshot already
        // knows tmux is gone; detach off that rather than off a callback that
        // never comes. `.parked` exactly and never `!isAlive`: unknown means
        // "no snapshot yet", which must not tear a live pane down.
        for id in attachedSessions where views[id]?.state == .parked { detach(id: id) }
        updateDockBadge()  // needsInputCount filters visibleSessions
    }

    /// The render path: sessions in display order and a view per session, one
    /// snapshot per tick, reconnecting until stopped. Mirrors `ipc.Client.Run`,
    /// backoff included.
    ///
    /// A snapshot is absolute state, so the whole view map is replaced rather
    /// than merged. (It used to be merged, because `watcher.MultiWatcher` fans
    /// out one path-keyed snapshot per agent and each carried only its own
    /// agent's sessions. `internal/sessionview` does that join now, along with
    /// the tmux-liveness one that decided "parked".)
    private func watchLoop() async {
        var backoff = Duration.milliseconds(200)
        // A watcher tick that races an agent's half-written status file
        // reports Err for that one tick and clears on the next (see the Go
        // watcher's parseFile) — surfacing it immediately just flashes the
        // banner in step with normal agent activity. Requiring it twice in a
        // row tells a real problem (unreadable dir, persistent parse
        // failure) from that self-clearing race.
        var pendingWatcherError: String?
        while !Task.isCancelled {
            do {
                for try await snapshot in client.watch() {
                    backoff = .milliseconds(200) // a working connection earns a fast retry
                    // A core older than the derived-state protocol streams the
                    // previous shape, which decodes into an *empty* snapshot
                    // rather than failing. Adopting it blanks a sidebar the
                    // pull just filled, and the reconnect flickers it back —
                    // so hand the list back to the poll loop and say why.
                    guard snapshot.derived else {
                        streaming = false
                        set(statusError: "this moomux core is too old for this app"
                            + " — update it, or the session list is all you get")
                        continue
                    }
                    streaming = true
                    if snapshot.views != views {
                        let previous = views
                        views = snapshot.views
                        notifier?.report(previous: previous, current: views)
                    }
                    if snapshot.rows != rows { rows = snapshot.rows }
                    adopt(sessions: snapshot.sessions)
                    if let err = snapshot.err, err == pendingWatcherError {
                        set(statusError: err)
                    } else {
                        set(statusError: nil)
                    }
                    pendingWatcherError = snapshot.err
                }
                throw MoomuxClient.Failure.disconnected
            } catch {
                streaming = false
                guard !Task.isCancelled else { return }
                pendingWatcherError = nil
                set(statusError: "status stream lost (\(error.localizedDescription)); reconnecting")
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(5))
        }
    }

    /// `@Observable` fires on any assignment, equal or not, so an unchanged
    /// error re-renders every list row once per watcher tick.
    private func set(statusError message: String?) {
        if statusError != message { statusError = message }
    }

    /// The quiet half of the notification surface: no sound, no banner, just a
    /// count that is there when you look. It is **not** free of authorization —
    /// macOS drops `badgeLabel` on the floor unless the app has the badge
    /// permission, which is why `Notifier` asks for `.badge` alongside `.alert`.
    /// `nil` rather than "0" — a zero badge is still a badge.
    private func updateDockBadge() {
        let count = needsInputCount
        // `NSApp?`: there is no application object under `--selftest`, and
        // `demo()` drives the snapshot path that lands here.
        NSApp?.dockTile.badgeLabel = count == 0 ? nil : "\(count)"
    }

    nonisolated static func demo() {
        assert(fontFamilies(["Menlo"], selected: "") == ["Menlo"], "the system font is not a family")
        assert(fontFamilies(["Menlo"], selected: "Menlo") == ["Menlo"], "installed once, listed once")
        assert(fontFamilies(["Menlo"], selected: "Gone") == ["Gone", "Menlo"],
               "an uninstalled stored family stays selectable, or the Picker renders blank")

        // The review window's command line. Measured against a real worktree:
        // the merge-base form catches committed *and* uncommitted work, the
        // fallbacks fire on exit 128 from an unresolvable ref, and the status
        // line is what makes an untracked file and a clean tree both visible.
        let script = reviewScript(base: "main")
        assert(script.hasPrefix("git diff --merge-base 'origin/main' 2>/dev/null"
                                + " || git diff --merge-base 'main' 2>/dev/null"
                                + " || git diff HEAD; git status --short --branch;"), script)
        assert(script.hasSuffix(#"exec "${SHELL:-/bin/sh}""#), script)
        // A branch name out of the user's config is interpolated into a shell
        // command, so it is quoted rather than trusted.
        assert(reviewScript(base: "a'b").contains(#"'origin/a'\''b'"#), reviewScript(base: "a'b"))

        // The diff tool command is argv, never a shell line: a program name and
        // its flags, with the worktree appended by the caller.
        assert(diffToolArguments("  ") == [])
        assert(diffToolArguments("diffier") == ["diffier"])
        assert(diffToolArguments(" code  --diff ") == ["code", "--diff"])

        // Search matches `internal/tui/search.go`: name, case-insensitively,
        // substring — and an all-whitespace query is not a search, or typing a
        // space would empty the sidebar.
        // `Session` decodes and is never constructed, so a fixture is JSON.
        func sample(_ name: String) -> Session {
            try! Wire.decoder.decode(Session.self, from: Data(
                #"{"id":"p:\#(name)","project":"p","name":"\#(name)","branch":"feature/x"}"#.utf8))
        }
        // `SessionView` decodes and is never constructed either.
        func view(_ id: String, state: String, quip: String = "", prompt: String = "",
                  label: String = "", gitOK: Bool = false, dirty: Bool = false,
                  unpushed: Bool = false) -> SessionView {
            try! Wire.decoder.decode(SessionView.self, from: Data(#"""
            {"id":"\#(id)","state":"\#(state)","quip":"\#(quip)","prompt":"\#(prompt)",
             "label":"\#(label)","git_ok":\#(gitOK),"dirty":\#(dirty),"unpushed":\#(unpushed)}
            """#.utf8))
        }
        let rows = [sample("Alpha"), sample("beta"), sample("gamma-ALPHA")]
        assert(matchSessions(rows, query: "").count == 3)
        assert(matchSessions(rows, query: "   ").count == 3, "whitespace is not a query")
        assert(matchSessions(rows, query: "alpha").map(\.name) == ["Alpha", "gamma-ALPHA"])
        assert(matchSessions(rows, query: "  ALPHA ").count == 2, "trimmed and case-folded")
        assert(matchSessions(rows, query: "zzz").isEmpty)
        // The branch is not searched, though it is the most tempting extra.
        assert(matchSessions(rows, query: "feature").isEmpty)

        // The core serves the effective state, and "parked" already means
        // "its tmux session is gone" — there is no second poll to join against
        // here any more, so `isAlive` is a reading of that one field.
        MainActor.assumeIsolated {
            let app = AppState()
            let s = sample("Alpha")
            assert(app.state(for: s) == .unknown, "no snapshot yet is unknown, not parked")
            assert(!app.isAlive(s), "and nothing is attachable until one arrives")
            assert(app.label(for: s) == "unknown", "with nothing served, the local name")
            app.views = [s.id: view(s.id, state: "working", quip: "moo-mentum building",
                                    label: "grazing")]
            assert(app.state(for: s) == .working)
            assert(app.isAlive(s))
            assert(app.quip(for: s) == "moo-mentum building")
            // The served wording wins, so both front ends say the same thing
            // about the same session.
            assert(app.label(for: s) == "grazing")
            app.views = [s.id: view(s.id, state: "parked")]
            assert(app.state(for: s) == .parked)
            assert(!app.isAlive(s), "parked is exactly \"tmux is gone\"")

            // The prompt the core recovered wins over the stored one, and the
            // stored one is all there is before the first snapshot.
            app.views = [s.id: view(s.id, state: "working", prompt: "recovered")]
            assert(app.prompt(for: s) == "recovered")
            app.views = [s.id: view(s.id, state: "working")]
            assert(app.prompt(for: s).isEmpty)

            // A pane whose tmux was killed under it has to be let go of: the
            // surface never tells us, so the snapshot is the only signal.
            app.attach(s)
            assert(app.attachedSessions.contains(s.id), "live: attach is immediate")
            app.adopt(sessions: [s])
            assert(app.attachedSessions.contains(s.id), "still live, still attached")
            app.views = [s.id: view(s.id, state: "parked")]
            app.adopt(sessions: [s])
            assert(!app.attachedSessions.contains(s.id), "tmux gone: pane goes with it")
            // Unknown is "no snapshot yet", not "tmux is gone", so a
            // snapshot that has lost the view must leave the pane alone.
            app.views = [s.id: view(s.id, state: "working")]
            app.attach(s)
            app.views = [:]
            app.adopt(sessions: [s])
            assert(app.attachedSessions.contains(s.id), "unknown is not parked")
        }

        // The agent table's fallbacks, which decide what every picker in the
        // new-session form contains. Same rules as `internal/tui`'s
        // agentNames / modelNamesFor / thinkingNamesFor.
        MainActor.assumeIsolated {
            let app = AppState()
            // A core that never answered must still leave the form usable.
            assert(app.agentNames == ["claude"], "\(app.agentNames)")
            assert(app.models(for: "claude").isEmpty)

            app.agentOptions = [
                AgentOption(name: "claude", models: ["default", "opus"],
                            thinking: ["default", "ultrathink"]),
                AgentOption(name: "codex", models: ["default", "gpt"], thinking: ["default", "high"]),
                AgentOption(name: "opencode", thinking: ["default", "think"]),
            ]
            assert(app.agentNames == ["claude", "codex", "opencode"])
            assert(app.models(for: "codex") == ["default", "gpt"])
            // opencode has no list of its own, so it falls back to claude's —
            // which is why its model control is a free-text field in the form
            // rather than this picker.
            assert(app.models(for: "opencode") == ["default", "opus"])
            assert(app.models(for: "nonesuch") == ["default", "opus"], "unknown agents fall back")
            assert(app.thinking(for: "codex") == ["default", "high"])
            assert(app.thinking(for: "nonesuch") == ["default", "ultrathink"])

            // Manual reordering is off while the core sorts by last-opened.
            assert(app.canReorder, "no config yet must not disable reordering")
        }

        // Collapsing a project hides its rows, so ⌘↓/⌘↑ must step past them —
        // a selection landing on a row nobody can see reads as a dead key.
        MainActor.assumeIsolated {
            let app = AppState()
            // Collapse lives in config now, and `setProject` would send it to a
            // socket — the checks drive the optimistic half directly, over a
            // config decoded here rather than the user's own.
            app.config = try! Wire.decoder.decode(Config.self, from: Data(
                #"{"projects":{"a":{"repo":"/a"},"b":{"repo":"/b"}},"order":["a","b"]}"#.utf8))
            func row(_ project: String, _ name: String) -> Session {
                try! Wire.decoder.decode(Session.self, from: Data(
                    #"{"id":"\#(project):\#(name)","project":"\#(project)","name":"\#(name)"}"#.utf8))
            }
            app.sessions = [row("a", "one"), row("a", "two"), row("b", "three")]
            assert(app.sessionsByProject.map(\.project) == ["a", "b"])

            app.applyProjectCollapsed("a", true)
            assert(!app.projectExpanded("a") && app.projectExpanded("b"))
            assert(app.shownSessions(of: "a", in: app.sessions).isEmpty)
            app.selectedSessionID = "b:three"
            app.selectAdjacentSession(by: 1)
            assert(app.selectedSessionID == "b:three", "the only visible row wraps to itself")

            // The selected session's terminal is on screen, so its row stays
            // whatever the collapse says — and ⌘↓ can still reach it.
            app.views = ["a:two": view("a:two", state: "working")]
            app.attach(row("a", "two"))
            app.selectedSessionID = "a:two"
            assert(app.shownSessions(of: "a", in: app.sessions).map(\.id) == ["a:two"])
            // Still attached, but no longer what the right pane shows: a pane
            // that outlived the switch away must not keep its row.
            app.selectedSessionID = "b:three"
            assert(app.shownSessions(of: "a", in: app.sessions).isEmpty)
            app.selectedSessionID = "a:two"
            app.selectAdjacentSession(by: 1)
            assert(app.selectedSessionID == "b:three", "the pinned row is in the rotation")
            app.detach(id: "a:two")
            app.views = [:]

            // A search must never be answered by a section the user cannot
            // see, so the query overrides the collapse — and whitespace is not
            // a query, exactly as `matchSessions` reads it.
            app.searchQuery = "one"
            assert(app.projectExpanded("a"))
            app.searchQuery = "   "
            assert(!app.projectExpanded("a"))
            app.searchQuery = ""

            app.applyProjectCollapsed("a", false)
            app.selectAdjacentSession(by: 1)
            assert(app.selectedSessionID == "a:one", "expanded again: back in the rotation")

            // With the core's layout in hand the sidebar draws its folders, and
            // ⌘↓ steps past the members a collapsed one is hiding.
            app.rows = ["a": [Row(folder: "wip", collapsed: true, count: 1),
                              Row(id: "a:one", folder: "wip", hidden: true),
                              Row(id: "a:two")]]
            let drawn = app.sidebarRows(of: "a", in: app.sessions.filter { $0.project == "a" })
            assert(drawn.map(\.id) == ["folder:wip", "a:two"], "\(drawn.map(\.id))")
            assert(app.folders(of: "a") == ["wip"])
            app.selectedSessionID = "a:two"
            app.selectAdjacentSession(by: 1)
            assert(app.selectedSessionID == "b:three", "a hidden member is not in the rotation")

            // No layout from the core (an older one, or the pull path) still
            // lists and reorders — one loose row per session.
            app.rows = [:]
            assert(app.sidebarRows(of: "a", in: app.sessions.filter { $0.project == "a" })
                .map(\.id) == ["a:one", "a:two"])
        }

        // The sidebar's git badges come off the snapshot now — no per-session
        // sweep, and no cache to prune. `git_ok` is the bit that matters: a
        // worktree nobody could stat must draw nothing, not "clean".
        MainActor.assumeIsolated {
            let app = AppState()
            app.views = [
                "p:a": view("p:a", state: "working", gitOK: true, dirty: true),
                "p:b": view("p:b", state: "working", gitOK: true, unpushed: true),
                "p:c": view("p:c", state: "done", gitOK: true, dirty: true, unpushed: true),
                "p:d": view("p:d", state: "parked"),
            ]
            // The two bits are independent — ± and ↑ are different work in
            // different places, and a row can want both icons at once.
            assert(app.views["p:a"]?.dirty == true && app.views["p:a"]?.unpushed == false)
            assert(app.views["p:b"]?.dirty == false && app.views["p:b"]?.unpushed == true)
            assert(app.views["p:c"]?.dirty == true && app.views["p:c"]?.unpushed == true)
            assert(app.views["p:d"]?.gitOK == false, "unknown is not clean")
            assert(app.gitBadges(for: sample("nosuch")) == nil, "no view is no badge")

            // A fresh on-demand status beats the snapshot's, which the core
            // caches for about a minute: a pane that just committed and pushed
            // must not keep a dirty badge while its own detail pane says clean.
            let dirtyRow = sample("a")
            app.views = [dirtyRow.id: view(dirtyRow.id, state: "working", gitOK: true, dirty: true)]
            assert(app.gitBadges(for: dirtyRow)?.dirty == true)
            app.statuses[dirtyRow.id] = .init(known: true)
            assert(app.gitBadges(for: dirtyRow)?.dirty == false, "the fresher answer wins")
            // …but a status nobody could determine is not an answer at all.
            app.statuses[dirtyRow.id] = .init(known: false)
            assert(app.gitBadges(for: dirtyRow)?.dirty == true)
        }

        // The delete dialog is one click over a message, so the message is
        // the safeguard: it must never read as "nothing to lose" for a
        // worktree nobody has checked.
        MainActor.assumeIsolated {
            let app = AppState()
            let s = sample("doomed")

            assert(app.deleteWarning(for: s).contains("Checking"),
                   "an unchecked worktree must not read as clean")

            app.statuses[s.id] = .init(known: true)
            assert(app.deleteWarning(for: s).contains("Nothing uncommitted or unpushed"))

            app.statuses[s.id] = .init(known: true, dirty: true, unpushed: true,
                                       filesChanged: 2, unpushedCommits: 1)
            let warning = app.deleteWarning(for: s)
            assert(warning.hasPrefix("⚠︎ 2 FILES CHANGED\n⚠︎ 1 COMMIT UNPUSHED"), warning)
            assert(warning.contains("removes the worktree"), warning)
        }

        // A mutation the server refuses is an answer, not a dead socket. It has
        // to reach the user as its own message and leave `connection` exactly
        // where the poll loop left it, or one declined action blanks the
        // sidebar into "Can't reach moomux". `--selftest` runs on the main
        // thread, from MoomuxApp.bootstrap().
        MainActor.assumeIsolated {
            let app = AppState()
            app.connection = .connected
            app.failed("Rename", MoomuxClient.Failure.server(#"session "x" already exists"#))
            assert(app.actionError == #"Rename failed: session "x" already exists"#,
                   app.actionError ?? "nil")
            assert(app.connection == .connected, "a refused action must not read as a dead socket")
        }
    }

    // MARK: Actions

    /// The one way a write reaches the server. Runs the blocking call off the
    /// main actor, then reloads — `refresh()` is the whole-world poll, so there
    /// is nothing finer-grained to invalidate, and it is what makes a mutation
    /// visible now rather than up to two seconds later.
    ///
    /// A non-nil return replaces `hint`; nil means the action had nothing to
    /// say and leaves whatever is there.
    private func mutate(_ what: String, _ work: @Sendable @escaping (MoomuxClient) throws -> String?) {
        Task {
            busy = what
            defer { busy = nil }
            do {
                if let hint = try await withoutBlockingTheUI({ [client] in try work(client) }) {
                    self.hint = hint.isEmpty ? nil : hint
                }
                await refresh()
            } catch {
                failed(what, error)
            }
        }
    }

    /// A refused action and an unreachable socket are not the same condition
    /// and must not render the same. This used to be `connection = .down(…)`,
    /// which blanked the whole sidebar into "Can't reach moomux" because one
    /// action was declined — and then the next poll, two seconds later, quietly
    /// put it back, so the server's actual reason flashed past unread.
    /// `connection` belongs to the poll loop and to nothing else.
    private func failed(_ what: String, _ error: Error) {
        actionError = "\(what) failed: \(error.localizedDescription)"
    }

    /// Creates a session. One call: the core cuts the worktree and branch,
    /// starts the agent, attaches the PR tag, composes the first prompt
    /// (thinking-level prefix for the agents with no launch flag for it, then
    /// the ticket and PR lines) and types it into the pane.
    ///
    /// All of that used to be replayed here, step by step, and drifting from
    /// the TUI's copy of the same sequence was exactly how `moomux spawn` ended
    /// up storing no prompt at all. The one thing left on this side is
    /// remembering a changed auto-submit toggle, which is a config write and
    /// not part of the transaction.
    ///
    /// `dangerous` is the caller's to compute rather than left nil, because the
    /// form shows a real toggle: nil would mean "the project's default", which
    /// is a different answer from the one the user just looked at.
    public func create(project: String, name: String, existingBranch: String = "",
                       baseBranch: String = "", agent: String = "", dangerous: Bool,
                       model: String = "", thinking: String = "", ticket: String = "",
                       pr: String = "", prompt: String, autoSubmit: Bool = false) {
        let rememberAutoSubmit = autoSubmit != (config?.autoSubmitDefault ?? false)
        let req = CreateRequest(project: project, name: name, agent: agent,
                                branch: existingBranch, baseBranch: baseBranch,
                                ticket: ticket, pr: pr, model: model, thinking: thinking,
                                prompt: prompt, autoSubmit: autoSubmit, dangerous: dangerous)
        mutate("Creating session") { client in
            if rememberAutoSubmit {
                // Best effort, exactly as the TUI treats it: remembering a
                // toggle is not worth failing a session creation over.
                try? client.setAutoSubmitDefault(autoSubmit)
            }
            return try client.createSession(req).1
        }
    }

    /// Reviewing a session's changes opens `git diff` in a new tmux **window**
    /// of that session, rather than rendering a patch natively — see the
    /// "Deliberately not done" note for why there is no patch viewer here.
    ///
    /// Not through `mutate`: this never touches the socket. `tmux new-window`
    /// from a second client also works whether or not the app is attached —
    /// attached, the window switch shows up in the terminal pane; detached,
    /// the hint set below is the only signal.
    public func review(_ session: Session) {
        guard let tmux = ToolPath.find("tmux") else {
            actionError = "Review failed: can't find a tmux binary."
            return
        }
        let base = config?.projects[session.project]?.baseBranch ?? "main"
        let script = AppState.reviewScript(base: base)
        let target = "\(session.tmuxSession):review"
        let create = ["new-window", "-t", session.tmuxSession,
                      "-c", session.worktreePath,
                      // -n also turns automatic-rename off for the window, so the
                      // tab keeps saying "review" and not "zsh".
                      "-n", "review", script]
        // Reviewing twice reuses the window rather than stacking a second one
        // called "review" with nothing to tell it from the first — the old one
        // holds a finished diff, which is exactly what is being replaced.
        // `respawn-window` and not kill-then-create: killing the last window of
        // a session kills the session. It does not select, hence the second
        // command; `new-window` does.
        let reuse = ["respawn-window", "-k", "-t", target,
                     "-c", session.worktreePath, script]
        Task {
            do {
                try await withoutBlockingTheUI {
                    do {
                        try ToolPath.run(tmux, reuse)
                        try ToolPath.run(tmux, ["select-window", "-t", target])
                    } catch {
                        try ToolPath.run(tmux, create)  // no review window yet
                    }
                }
                hint = "Opened a review window in \(session.tmuxSession)."
            } catch {
                failed("Review", error)
            }
        }
    }

    /// An external GUI diff tool, run against a session's worktree. Empty
    /// means the feature is off — there is no default, because a command that
    /// does not exist on this machine would only ever fail.
    ///
    /// In `UserDefaults` and not in the shared config: the core serves no such
    /// field, and a macOS app launcher is nothing the TUI could use.
    public var diffTool: String = UserDefaults.standard.string(forKey: diffToolKey) ?? "" {
        didSet { UserDefaults.standard.set(diffTool, forKey: Self.diffToolKey) }
    }

    static let diffToolKey = "diffTool"

    /// Point size for the sidebar's session rows; project and folder headers
    /// draw 2pt larger (`headerFontSize`). `UserDefaults` for the same reason
    /// as `diffTool` — the core serves no such field and the TUI has no use
    /// for it.
    public var listFontSize: Double = UserDefaults.standard.object(forKey: listFontSizeKey) as? Double
        ?? Double(NSFont.systemFontSize) {
        didSet { UserDefaults.standard.set(listFontSize, forKey: Self.listFontSizeKey) }
    }

    static let listFontSizeKey = "listFontSize"

    public var headerFontSize: Double { listFontSize + 2 }

    /// Font family for the sidebar. Empty means the system font, which is the
    /// default and what every other Mac app's sidebar uses.
    public var listFontFamily: String = UserDefaults.standard.string(forKey: listFontFamilyKey) ?? "" {
        didSet { UserDefaults.standard.set(listFontFamily, forKey: Self.listFontFamilyKey) }
    }

    static let listFontFamilyKey = "listFontFamily"

    /// Every installed family, plus whatever is stored if that font has since
    /// been uninstalled — a Picker whose selection matches no tag renders
    /// blank and writes nothing, the same trap as the theme picker.
    public var fontFamilies: [String] {
        AppState.fontFamilies(NSFontManager.shared.availableFontFamilies, selected: listFontFamily)
    }

    nonisolated static func fontFamilies(_ installed: [String], selected: String) -> [String] {
        guard !selected.isEmpty, !installed.contains(selected) else { return installed }
        return [selected] + installed
    }

    public func canOpenDiffTool(_ session: Session) -> Bool {
        !AppState.diffToolArguments(diffTool).isEmpty && !session.worktreePath.isEmpty
    }

    /// ponytail: whitespace split, so no shell and therefore no quoting or
    /// injection to get wrong — the cost is that an argument containing a space
    /// arrives as two. Parse quotes if that ever comes up.
    nonisolated static func diffToolArguments(_ command: String) -> [String] {
        command.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The worktree path is appended as the last argument, so `diffier` and
    /// `code --diff` both work as typed. Through `ToolPath` rather than a
    /// shell, since a GUI app's `PATH` would not find `/usr/local/bin`.
    public func openDiffTool(_ session: Session) {
        let argv = AppState.diffToolArguments(diffTool)
        guard let tool = argv.first else { return }
        guard let path = tool.hasPrefix("/") ? tool : ToolPath.find(tool) else {
            actionError = "Diff tool failed: can't find \(tool)."
            return
        }
        let args = Array(argv.dropFirst()) + [session.worktreePath]
        Task {
            do {
                try await withoutBlockingTheUI { _ = try ToolPath.run(path, args) }
            } catch {
                failed("Diff tool", error)
            }
        }
    }

    /// The shell line a review window runs.
    ///
    /// `git diff --merge-base` is everything not yet on the base branch —
    /// commits since the merge base *and* uncommitted work — in one command.
    /// `origin/` first because a local base branch goes stale in a worktree
    /// checkout, then the local one, then a plain `HEAD` diff for a project
    /// with neither. The `git status` line is not decoration: untracked files
    /// are invisible to every diff, an agent's new files are usually untracked,
    /// and `--branch` guarantees at least one line of output so a clean
    /// worktree reads as "nothing to review" rather than as a window that
    /// failed to run anything.
    ///
    /// No `--color` and no `| less`: output goes straight to a tty, so git
    /// colours and pages it with the user's own pager — a configured `delta`
    /// is honoured, which is most of the argument for reviewing here at all.
    /// It ends in a shell so the window survives the pager and is somewhere to
    /// run `git add -p` from.
    nonisolated static func reviewScript(base: String) -> String {
        let quoted = { (ref: String) in
            "'" + ref.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
        return "git diff --merge-base \(quoted("origin/" + base)) 2>/dev/null"
            + " || git diff --merge-base \(quoted(base)) 2>/dev/null"
            + " || git diff HEAD; git status --short --branch;"
            + #" exec "${SHELL:-/bin/sh}""#
    }

    /// Both halves of the edit-session form, in the TUI's order: the rename
    /// first (it no-ops when the name is unchanged, and fails loudly on a
    /// collision, which must stop the agent change too), then the agent.
    public func edit(_ session: Session, name: String, agent: String, dangerous: Bool) {
        mutate("Save session") { client in
            try client.rename(id: session.id, to: name)
            guard agent != session.agentName || dangerous != session.dangerous else { return nil }
            try client.setAgent(id: session.id, agent: agent, dangerous: dangerous)
            return "\(name) will launch \(agent) next time it's opened."
        }
    }

    public func setTags(_ session: Session, ticket: String, pr: String) {
        mutate("Set tags") { try $0.setTags(id: session.id, ticket: ticket, pr: pr); return nil }
    }

    public func setArchived(_ session: Session, _ archived: Bool) {
        mutate(archived ? "Archive" : "Unarchive") {
            try $0.setArchived(id: session.id, archived)
            return nil
        }
    }

    /// Sends the project's whole resulting order, worked out from the layout
    /// this window is displaying — see `MoomuxClient.reorderSessions`. A move
    /// with nowhere to go is silence, the same no-op `MoveSession` was.
    public func move(_ session: Session, by delta: Int) {
        let shown = Set(listedSessions.map(\.id))
        guard let order = Layout.reorder(
            layout(of: session.project, in: allSessions(of: session.project)),
            id: session.id, delta: delta, skip: { !shown.contains($0) }
        ) else { return }
        mutate("Move") { try $0.reorderSessions(order); return nil }
    }

    // MARK: Folders

    /// Files a session under `folder`, creating it on first use; an empty name
    /// puts the session back at the top level.
    public func setFolder(_ session: Session, to folder: String) {
        mutate(folder.isEmpty ? "Remove from folder" : "Move to folder") {
            try $0.setSessionFolder(id: session.id, folder: folder)
            return nil
        }
    }

    /// A sidebar drop: the payload is a plain session id, so anything that
    /// carries a string can land here — only an id this project owns is acted
    /// on, and a session already in `folder` is left alone. Returns whether
    /// the drop meant anything, which is what tells SwiftUI to accept it.
    public func drop(_ ids: [String], into folder: String, project: String) -> Bool {
        let moved = ids.compactMap(session(id:))
            .filter { $0.project == project && $0.folder != folder }
        // One `mutate` per session would race on `busy` and on `refresh`; the
        // sidebar is single-select, so one drop is one session in practice.
        guard let session = moved.first else { return false }
        setFolder(session, to: folder)
        return true
    }

    public func createFolder(project: String, name: String) {
        mutate("New folder") { try $0.createFolder(project: project, name: name); return nil }
    }

    public func renameFolder(project: String, from old: String, to new: String) {
        mutate("Rename folder") {
            try $0.renameFolder(project: project, from: old, to: new)
            return nil
        }
    }

    /// Deletes the folder only — every member is filed back at the top level,
    /// which is why this asks nothing.
    public func deleteFolder(project: String, name: String) {
        mutate("Delete folder") { try $0.deleteFolder(project: project, name: name); return nil }
    }

    public func setFolder(project: String, name: String, collapsed: Bool) {
        mutate(collapsed ? "Collapse" : "Expand") {
            try $0.setFolderCollapsed(project: project, name: name, collapsed)
            return nil
        }
    }

    // MARK: Projects

    /// The core insists the repo path already be a git repository, and answers
    /// "it isn't" as a sentinel rather than a plain failure — so this is the
    /// one write that can end in a question. `pendingProjectInit` is that
    /// question; `initProject` and `addPlainProject` are its answers.
    public func addProject(name: String, _ project: Project) {
        Task {
            busy = "Add project"
            defer { busy = nil }
            do {
                try await withoutBlockingTheUI { [client] in
                    try client.addProject(name: name, project)
                }
                await refresh()
            } catch MoomuxClient.Failure.notGitRepo {
                pendingProjectInit = PendingProject(name: name, project: project)
            } catch {
                failed("Add project", error)
            }
        }
    }

    /// `mkdir -p`, `git init`, one empty commit, then the project is saved as a
    /// git one — the "i" answer in the TUI's init-choice dialog.
    public func initProject(name: String, _ project: Project) {
        mutate("Init repo") { client in
            try client.initProjectAndAdd(name: name, project)
            return "Initialized a git repo at \(project.repo) and added \(name)."
        }
    }

    /// The "s" answer: no git at all, so no worktrees and no branches — every
    /// session runs in the folder itself.
    public func addPlainProject(name: String, _ project: Project) {
        mutate("Add project") { client in
            try client.addPlainProject(name: name, project)
            return "Added \(name) as a plain folder — no worktrees or branches."
        }
    }

    public func updateProject(name: String, _ project: Project) {
        mutate("Save project") { try $0.updateProject(name: name, project); return nil }
    }

    /// Config only — the repository on disk is untouched. The core refuses
    /// while the project still has sessions, archived ones included, and that
    /// refusal is the message the user sees.
    public func removeProject(name: String) {
        mutate("Remove project") { try $0.removeProject(name: name); return nil }
    }

    public func moveProject(name: String, by delta: Int) {
        mutate("Move project") { try $0.moveProject(name: name, delta: delta); return nil }
    }

    // MARK: Settings
    //
    // Each is one socket call that rewrites one field of the shared config, so
    // a change here shows up in the TUI's settings screen and vice versa.

    public func setAutoSubmitDefault(_ on: Bool) {
        mutate("Save setting") { try $0.setAutoSubmitDefault(on); return nil }
    }

    public func setSortRecentFirst(_ on: Bool) {
        mutate("Save setting") { try $0.setSortRecentFirst(on); return nil }
    }

    public func setAutoTmux(_ on: Bool) {
        mutate("Save setting") { try $0.setAutoTmux(on); return nil }
    }

    /// The TUI's palette, edited from here because it is one config file. This
    /// app draws itself with semantic colors and is unaffected by either value.
    public func setTheme(_ theme: String, appearance: String) {
        mutate("Save theme") { try $0.setTheme(theme, appearance: appearance); return nil }
    }

    /// Attaching is deliberate, never a side effect of selecting a row: a tmux
    /// client sizes the shared window down to its own dimensions for *every*
    /// other client on that session, so auto-attaching would silently squash
    /// the user's iTerm and phone windows as they browsed the list. See
    /// `TerminalPane` for why this is inherent to a plain attach.
    ///
    /// A parked session is revived first rather than refused. Recreating the
    /// tmux session and relaunching the agent is the core's job either way, so
    /// making the user press a different button for it was ceremony — but it is
    /// `EnsureTmux` and not `OpenSession`, because nothing this app does may
    /// make the core open a terminal window — the core is commonly a launchd
    /// daemon with no terminal to open one in.
    public func attach(_ session: Session) {
        guard !isAlive(session) else {
            attachedSessions.insert(session.id)
            return
        }
        Task {
            busy = "Starting tmux"
            defer { busy = nil }
            do {
                let hint = try await withoutBlockingTheUI({ [client] in
                    try client.ensureTmux(id: session.id)
                })
                if !hint.isEmpty { self.hint = hint }
                // Attach only once the snapshot agrees the session is live:
                // `SessionTerminal` spawns its `tmux attach` on appear, and a
                // stale "parked" view would also keep the row's dot grey.
                await refresh()
                attachedSessions.insert(session.id)
            } catch {
                failed("Attach", error)
            }
        }
    }

    /// Unlike merely navigating away in the sidebar, this actually kills
    /// whatever tmux client was kept running for the session.
    public func detach(_ session: Session) { detach(id: session.id) }

    /// `controller = nil` is what kills the client, and it has to be explicit.
    ///
    /// `AppTerminalView` owns the ghostty surface; freeing that closes the pty,
    /// which hangs up the tmux client on the other end. Dropping the view was
    /// the obvious way to get there and **does not work**: measured, the UI
    /// detached and `tmux list-clients` still showed our client, because
    /// something in the package (the display link is the likely holder)
    /// outlives the view and keeps the surface coordinator alive with it. So
    /// the user's iTerm and phone would have stayed letterboxed forever —
    /// exactly the thing detach exists to undo.
    ///
    /// libghostty-spm publishes no `free()`, but assigning `controller` runs
    /// `rebuildIfReady(removingBridgeFrom: oldValue)`, and a non-nil
    /// `previousController` skips the keep-the-surface early return, so the
    /// teardown runs before the rebuild bails on the missing controller. That
    /// is the public spelling of "let go of the pty".
    private func detach(id: Session.ID) {
        attachedSessions.remove(id)
        plainPanes.removeValue(forKey: id)?.controller = nil
        plainDelegates.removeValue(forKey: id)
    }

    public func killTmux(_ session: Session) {
        detachAndForget(session)
        mutate("Kill tmux") { try $0.killTmux(id: session.id); return nil }
    }

    /// Opens the delete confirmation, and refreshes the worktree status
    /// behind it.
    ///
    /// One dialog, not two: what is at stake belongs in the message, and a
    /// second "are you sure" click is a reflex, not a safeguard. The status is
    /// re-fetched because it is the whole point of the message — it lands a
    /// beat later and the message fills itself in, saying so meanwhile rather
    /// than implying a check that never ran.
    public func askDelete(_ session: Session) {
        pendingDelete = session
        Task { await loadStatus(for: session.id, force: true) }
    }

    public func dismissDelete() { pendingDelete = nil }

    /// What the delete dialog says is at stake. Pure, so `demo()` can hold it
    /// to saying the three different things it has to say.
    ///
    /// The at-risk work goes first, one flagged line each — this is a
    /// single-click destructive dialog, so what is lost has to be the first
    /// thing read, not a clause in a paragraph. Upper case rather than
    /// markdown bold: an alert's message renders `**…**` at the same weight as
    /// everything else (measured), so caps are the only emphasis it has.
    /// `changeSummary` is split rather than re-derived: one place still
    /// decides the wording.
    public func deleteWarning(for session: Session) -> String {
        let tail = "Kills tmux, removes the worktree at \(session.worktreePath), "
            + "and deletes the branch if moomux made it."
        guard let status = statuses[session.id], status.known else {
            return "Checking \(session.worktreePath) for uncommitted or unpushed work…\n\n"
                + tail
        }
        let lines = status.changeSummary.split(separator: ", ").map { "⚠︎ \($0.uppercased())" }
        guard !lines.isEmpty else { return "Nothing uncommitted or unpushed.\n\n" + tail }
        return lines.joined(separator: "\n") + "\n\nThat work goes with it. " + tail
    }

    public func delete(_ session: Session) {
        detachAndForget(session)
        mutate("Delete") { try $0.deleteSession(id: session.id) }
    }

    /// Killing or deleting a session must not leave its tmux client running
    /// in the pool, whether or not it's the one currently showing.
    private func detachAndForget(_ session: Session) {
        detach(session)
        if selectedSessionID == session.id { selectedSessionID = nil }
    }
}

/// Every `MoomuxClient` call is a blocking socket read. Running one on the main
/// actor freezes the window for as long as the Go side takes — which, for
/// anything touching git or tmux, is seconds.
private func withoutBlockingTheUI<T: Sendable>(
    _ work: @Sendable @escaping () throws -> T
) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: work).value
}
