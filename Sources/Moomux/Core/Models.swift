import Foundation

// The wire types for `moomux serve`. They mirror the Go core's JSON.
//
// Everything on the wire is snake_case now, `prstatus.Info` included — with
// one exception, `CreateRequest`, which has no json tags at all and so crosses
// as Go's own field names (see it below). Every type here still declares
// explicit `CodingKeys` rather than a shared `keyDecodingStrategy`, so a decode
// that starts coming back with nil fields has one obvious place to check first.
//
// These structs are also deliberately *partial* — they decode the fields this
// app shows and ignore the rest. That is safe in one direction only: nothing
// here is ever re-encoded and sent back. Requests carry scalars (see `Args`),
// never a whole session, so a dropped field cannot round-trip a value away.

// MARK: - Agent state

/// What a session's agent is doing. Mirrors `watcher.State`, which crosses the
/// wire as its *name* — the Go enum is deliberately ranked, so its integers
/// exist to be reordered and were never a wire format. The names are also the
/// per-state color keys `Themes` serves, so there is one vocabulary.
public enum AgentState: String, Decodable, Sendable, CaseIterable {
    case unknown
    case parked
    case done
    case working
    case needsInput = "needs-input"

    /// A name this build has never heard of must not throw: one unfamiliar
    /// state would otherwise tear down the whole snapshot.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentState(rawValue: raw) ?? .unknown
    }

    public var label: String {
        switch self {
        case .unknown: return "unknown"
        case .parked: return "parked"
        case .done: return "done"
        case .working: return "working"
        case .needsInput: return "needs input"
        }
    }

    /// SF Symbol shown in the list and the menu bar.
    public var symbol: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .parked: return "moon.zzz"
        case .done: return "checkmark.circle"
        case .working: return "circle.dotted"
        case .needsInput: return "exclamationmark.circle.fill"
        }
    }
}

// MARK: - Session

public struct Session: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var project: String
    public var name: String
    public var branch: String
    public var worktreePath: String
    public var tmuxSession: String
    public var createdAt: Date
    public var agent: String?
    public var dangerous: Bool
    public var ticket: String?
    public var pr: String?
    public var prompt: String?
    public var archived: Bool
    public var lastOpened: Date
    /// The folder this session is filed under within its project, "" for a
    /// loose one. Membership lives here; the folder's own display state lives
    /// in `Project.folders` — see `Row`.
    public var folder: String

    /// The agent actually used. Sessions created before moomux had a picker
    /// have no `agent` at all, and the Go side defaults them the same way.
    public var agentName: String { (agent?.isEmpty == false) ? agent! : "claude" }

    /// `last_opened` is a `time.Time`, and Go's `omitempty` does nothing for a
    /// struct — so a never-opened session arrives as the year-1 zero time
    /// rather than as an absent key.
    public var hasBeenOpened: Bool { lastOpened > Wire.goZeroTimeCutoff }

    enum CodingKeys: String, CodingKey {
        case id, project, name, branch, agent, dangerous, ticket, pr, prompt, archived, folder
        case worktreePath = "worktree_path"
        case tmuxSession = "tmux_session"
        case createdAt = "created_at"
        case lastOpened = "last_opened"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath) ?? ""
        tmuxSession = try c.decodeIfPresent(String.self, forKey: .tmuxSession) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        dangerous = try c.decodeIfPresent(Bool.self, forKey: .dangerous) ?? false
        ticket = try c.decodeIfPresent(String.self, forKey: .ticket)
        pr = try c.decodeIfPresent(String.self, forKey: .pr)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened) ?? .distantPast
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
    }
}

// MARK: - Config

/// `config.Project`, in both directions: it is read back inside `Config` and
/// sent whole as `ipc.Args.proj` by the project writes.
///
/// Encoding is explicit rather than synthesized so an unset optional vanishes
/// instead of crossing as `null`, and so the bools always go over as real
/// values — `dangerous: false` has to be distinguishable from "didn't say" for
/// `UpdateProject` to be able to turn the flag back off.
public struct Project: Codable, Hashable, Sendable {
    public var kind: String?
    public var repo: String
    public var branchPrefix: String?
    public var baseBranch: String?
    public var agent: String?
    public var dangerous: Bool
    /// Forces the new-session form to ask for an agent every time instead of
    /// preselecting `agent`. The Mac app honours it the way the TUI does.
    public var promptAgent: Bool
    public var noWorktree: Bool
    public var emoji: String?
    /// Display state for this project's session folders, keyed by name (the
    /// name *is* the id). Membership is on the session, not here.
    ///
    /// Carried in both directions for one reason: `UpdateProject` replaces the
    /// whole project record, so a project edited from this app that did not
    /// send its folders back would silently lose them.
    public var folders: [String: FolderMeta]?
    /// Whether the sidebar's group for this project is folded away. Config, not
    /// a local preference: the core serves it so the choice survives a restart
    /// and is the same in every front end.
    public var collapsed: Bool

    public var isPlain: Bool { kind == "plain" }
    public var usesWorktree: Bool { !isPlain && !noWorktree }
    /// Mirrors `config.Project.AgentName`: an empty agent means claude.
    public var agentName: String { (agent?.isEmpty == false) ? agent! : "claude" }

    public init(kind: String? = nil, repo: String = "", branchPrefix: String? = nil,
                baseBranch: String? = nil, agent: String? = nil, dangerous: Bool = false,
                promptAgent: Bool = false, noWorktree: Bool = false, emoji: String? = nil,
                folders: [String: FolderMeta]? = nil, collapsed: Bool = false) {
        self.kind = kind
        self.repo = repo
        self.branchPrefix = branchPrefix
        self.baseBranch = baseBranch
        self.agent = agent
        self.dangerous = dangerous
        self.promptAgent = promptAgent
        self.noWorktree = noWorktree
        self.emoji = emoji
        self.folders = folders
        self.collapsed = collapsed
    }

    enum CodingKeys: String, CodingKey {
        case kind, repo, agent, dangerous, emoji, folders, collapsed
        case branchPrefix = "branch_prefix"
        case baseBranch = "base_branch"
        case promptAgent = "prompt_agent"
        case noWorktree = "no_worktree"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        branchPrefix = try c.decodeIfPresent(String.self, forKey: .branchPrefix)
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        dangerous = try c.decodeIfPresent(Bool.self, forKey: .dangerous) ?? false
        promptAgent = try c.decodeIfPresent(Bool.self, forKey: .promptAgent) ?? false
        noWorktree = try c.decodeIfPresent(Bool.self, forKey: .noWorktree) ?? false
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        folders = try c.decodeIfPresent([String: FolderMeta].self, forKey: .folders)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(repo, forKey: .repo)
        try c.encodeIfPresent(branchPrefix, forKey: .branchPrefix)
        try c.encodeIfPresent(baseBranch, forKey: .baseBranch)
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encode(dangerous, forKey: .dangerous)
        try c.encode(promptAgent, forKey: .promptAgent)
        try c.encode(noWorktree, forKey: .noWorktree)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        try c.encodeIfPresent(folders, forKey: .folders)
        try c.encode(collapsed, forKey: .collapsed)
    }
}

/// `config.FolderMeta` — a folder's display state, and deliberately not its
/// position: a folder sits wherever its first member sits (`sessionview.BuildRows`),
/// so there is no order here to drift out of step with the sessions'.
public struct FolderMeta: Codable, Hashable, Sendable {
    public var collapsed: Bool

    public init(collapsed: Bool = false) { self.collapsed = collapsed }

    enum CodingKeys: String, CodingKey { case collapsed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}

/// `config.AgentOption` — one agent the core can launch, plus the model and
/// thinking-level choices worth offering for it.
///
/// The whole reason a picker can exist on this side of the socket: the table
/// lives in `internal/app` and is served by `AgentOptions`, so a copy here
/// cannot drift the next time the Go side gains an agent.
public struct AgentOption: Decodable, Hashable, Sendable {
    public var name: String
    /// Empty for an agent with no fixed list worth hardcoding (opencode) — a
    /// free-text field is the honest control there.
    public var models: [String]
    public var thinking: [String]

    enum CodingKeys: String, CodingKey { case name, models, thinking }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        thinking = try c.decodeIfPresent([String].self, forKey: .thinking) ?? []
    }

    public init(name: String, models: [String] = [], thinking: [String] = []) {
        self.name = name
        self.models = models
        self.thinking = thinking
    }
}

/// `config.Color` — one entry in a palette: a light/dark pair, plus the
/// optional name of a platform semantic color to prefer over it.
public struct ThemeColor: Decodable, Hashable, Sendable {
    /// "#rrggbb", except on an `ansi` palette where these are terminal
    /// indices ("11") — see `ThemePalette.ansi`.
    public var light: String
    public var dark: String
    /// "accent", "green", "orange", "secondary" — a real system color this
    /// app should follow instead of the frozen hex, so the state dots track
    /// the user's live accent. Set only on the "default" theme; the other
    /// palettes are designer sets that must render as themselves.
    public var system: String

    enum CodingKeys: String, CodingKey { case light, dark, system }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        light = try c.decodeIfPresent(String.self, forKey: .light) ?? ""
        dark = try c.decodeIfPresent(String.self, forKey: .dark) ?? ""
        system = try c.decodeIfPresent(String.self, forKey: .system) ?? ""
    }

    public init(light: String, dark: String, system: String = "") {
        self.light = light
        self.dark = dark
        self.system = system
    }
}

/// `config.Theme` — the full palette a front end renders moomux with, served
/// by `Themes` for the same reason `AgentOptions` is: neither side keeps its
/// own copy. This app used to hold two hardcoded tables; the core owns them.
public struct ThemePalette: Decodable, Hashable, Sendable {
    public var name: String
    /// The "terminal" theme's light/dark halves are ANSI indices, not hex,
    /// and there is no terminal colorscheme here to resolve them against —
    /// so `resolved(_:in:)` hands back "default" for it rather than parsing.
    public var ansi: Bool

    public var working: ThemeColor
    public var done: ThemeColor
    public var needsInput: ThemeColor
    public var parked: ThemeColor
    /// Non-fatal warnings — the sidebar's ± / ↑ badges. Amber in every
    /// theme, unlike `done`, which is green everywhere now.
    public var warn: ThemeColor

    // fg/mute/accent/danger/border/sel_bg are served too. Nothing here draws
    // with them (SwiftUI's own semantic colors do that job), so they are not
    // decoded — add them the day a view needs one.
    enum CodingKeys: String, CodingKey {
        case name, ansi, working, done, parked, warn
        case needsInput = "needs_input"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let color = { try c.decodeIfPresent(ThemeColor.self, forKey: $0) ?? ThemeColor(light: "", dark: "") }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        ansi = try c.decodeIfPresent(Bool.self, forKey: .ansi) ?? false
        working = try color(.working)
        done = try color(.done)
        needsInput = try color(.needsInput)
        parked = try color(.parked)
        warn = try color(.warn)
    }

    public func color(for state: AgentState) -> ThemeColor {
        switch state {
        case .working: return working
        case .done: return done
        case .needsInput: return needsInput
        case .parked, .unknown: return parked
        }
    }

    /// The palette to render `name` with — `config.ThemeByName`, plus this
    /// app's ANSI fallback. An empty or unrecognized name is "default", the
    /// same as the Go side; so is the ANSI theme, which nothing here can
    /// resolve. Nil only before `Themes` has answered.
    public static func resolved(_ name: String, in themes: [ThemePalette]) -> ThemePalette? {
        guard let fallback = themes.first else { return nil }
        let picked = themes.first { $0.name == name } ?? fallback
        return picked.ansi ? fallback : picked
    }
}

public struct Config: Decodable, Sendable {
    public var projects: [String: Project]
    /// The user's manual project order. Names missing from it sort
    /// alphabetically after the ordered ones — same rule as
    /// `config.OrderedProjectNames`.
    public var order: [String]
    public var theme: String?
    public var appearance: String?
    /// Relaunch the *TUI* inside a dedicated tmux session on startup. Nothing
    /// this app does, but the same config file, so it is editable from here.
    public var autoTmux: Bool
    /// The remembered starting state of the new-session form's auto-submit
    /// toggle — shared with the TUI's form, which is the point of persisting it.
    public var autoSubmitDefault: Bool
    /// Sessions sort most-recently-opened first, and manual reordering is off.
    /// The Go side applies the sort; this is what tells a front end that its
    /// move-up/move-down actions would be undone by the next open.
    public var sortRecentFirst: Bool

    enum CodingKeys: String, CodingKey {
        case projects, order, theme, appearance
        case autoTmux = "auto_tmux"
        case autoSubmitDefault = "auto_submit_default"
        case sortRecentFirst = "sort_recent_first"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([String: Project].self, forKey: .projects) ?? [:]
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance)
        autoTmux = try c.decodeIfPresent(Bool.self, forKey: .autoTmux) ?? false
        autoSubmitDefault = try c.decodeIfPresent(Bool.self, forKey: .autoSubmitDefault) ?? false
        sortRecentFirst = try c.decodeIfPresent(Bool.self, forKey: .sortRecentFirst) ?? false
    }

    public var orderedProjectNames: [String] {
        var seen = Set<String>()
        var out = order.filter { projects[$0] != nil && seen.insert($0).inserted }
        out.append(contentsOf: projects.keys.filter { !seen.contains($0) }.sorted())
        return out
    }
}

// MARK: - Pull request

/// `prstatus.Info`, arriving inside a `SessionView` rather than from a call of
/// its own — the core caches and jitters the `gh pr view` behind it.
public struct PRInfo: Decodable, Equatable, Sendable {
    /// OPEN, MERGED, CLOSED
    public var state: String
    /// MERGEABLE, CONFLICTING, UNKNOWN
    public var mergeable: String
    /// PASSING, FAILING, PENDING, NONE
    public var ci: String
    /// Open review threads nobody has answered. Only counted for OPEN PRs.
    public var unresolved: Int

    enum CodingKeys: String, CodingKey { case state, mergeable, ci, unresolved }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        mergeable = try c.decodeIfPresent(String.self, forKey: .mergeable) ?? ""
        ci = try c.decodeIfPresent(String.self, forKey: .ci) ?? ""
        unresolved = try c.decodeIfPresent(Int.self, forKey: .unresolved) ?? 0
    }

    /// A one-line summary, lower-cased the way the rest of the UI reads.
    /// Empty when the core knew nothing, so the caller can hide the row.
    public var summary: String {
        var parts: [String] = []
        if !state.isEmpty { parts.append(state.lowercased()) }
        switch ci {
        case "PASSING": parts.append("checks passing")
        case "FAILING": parts.append("checks failing")
        case "PENDING": parts.append("checks running")
        default: break
        }
        if unresolved > 0 {
            parts.append("\(unresolved) open comment" + (unresolved == 1 ? "" : "s"))
        }
        // Only worth saying when it is a problem; MERGEABLE is the boring case.
        if mergeable == "CONFLICTING" { parts.append("conflicts") }
        return parts.joined(separator: " · ")
    }

    /// `internal/tui/detail.go`'s `prGlyph`, in the same precedence: the state
    /// wins, then conflicts, then failing CI. The TUI draws emoji and this app
    /// draws SF Symbols, so the mapping — not the glyph — is what the two
    /// front ends share.
    public enum Badge: Sendable {
        case open, merged, closed, conflicts, failing, comments, pending

        public var symbol: String {
            switch self {
            case .open: return "arrow.triangle.pull"
            case .merged: return "checkmark.circle.fill"
            case .closed: return "nosign"
            case .conflicts: return "exclamationmark.triangle.fill"
            case .failing: return "xmark.octagon.fill"
            case .comments: return "bubble.left.fill"
            case .pending: return "clock"
            }
        }

        public var help: String {
            switch self {
            case .open: return "Pull request"
            case .merged: return "Pull request merged"
            case .closed: return "Pull request closed"
            case .conflicts: return "Pull request has conflicts"
            case .failing: return "Pull request checks failing"
            case .comments: return "Pull request has unresolved review comments"
            case .pending: return "Pull request checks running"
            }
        }
    }

    /// nil is no status yet, or a lookup that failed — the plain open icon,
    /// same as the TUI: "unknown" isn't worth a glyph of its own.
    public static func badge(_ info: PRInfo?) -> Badge {
        guard let info else { return .open }
        switch info.state {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: break
        }
        if info.mergeable == "CONFLICTING" { return .conflicts }
        if info.ci == "FAILING" { return .failing }
        // Unlike CI, nothing clears an open review thread on its own.
        if info.unresolved > 0 { return .comments }
        // The one place this app says more than the TUI's prGlyph, which has
        // no pending glyph: a PR whose checks are still running is not yet
        // worth walking over to.
        if info.ci == "PENDING" { return .pending }
        return .open
    }
}

// MARK: - The snapshot stream

/// `sessionview.View` — everything about a session that isn't stored on the
/// session record: what it's doing, and what that costs a subprocess to find
/// out. The core derives all of it once and both front ends render it; nothing
/// here is recomputed on this side.
public struct SessionView: Decodable, Equatable, Sendable {
    public var id: String
    /// The *effective* state: tmux liveness is already folded in, so a session
    /// whose tmux window is gone reads `.parked` whatever its agent last wrote.
    public var state: AgentState
    public var label: String
    /// The flavor-text quip the TUI's cow says, picked server-side so both
    /// front ends show a session byte-identical text.
    public var quip: String
    /// The first prompt: the one captured at creation, or one recovered from
    /// the agent's own logs for a session moomux didn't start.
    public var prompt: String
    /// False when the worktree's status couldn't be determined (not a git
    /// repo, or not checked yet) — `dirty` and `unpushed` mean nothing then.
    public var gitOK: Bool
    public var dirty: Bool
    public var unpushed: Bool
    public var pr: PRInfo?

    enum CodingKeys: String, CodingKey {
        case id, state, label, quip, prompt, dirty, unpushed, pr
        case gitOK = "git_ok"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        state = try c.decodeIfPresent(AgentState.self, forKey: .state) ?? .unknown
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        quip = try c.decodeIfPresent(String.self, forKey: .quip) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        gitOK = try c.decodeIfPresent(Bool.self, forKey: .gitOK) ?? false
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
        unpushed = try c.decodeIfPresent(Bool.self, forKey: .unpushed) ?? false
        pr = try c.decodeIfPresent(PRInfo.self, forKey: .pr)
    }
}

/// One tick of `sessionview.Snapshot`: the whole session list **in display
/// order**, plus a view per session id.
///
/// Absolute state, never a delta — a client that misses one loses nothing, and
/// the whole map is replaced rather than merged. (The old path-keyed
/// `watcher.Snapshot` had to be merged, because each sub-watcher reported only
/// its own agent's paths. The core does that join now.)
/// `sessionview.Row` — one line of a project's session list as the core lays
/// it out: a folder header (`id` empty) or a session.
///
/// The grouping is derived once, in the core, for the same reason `sessions`
/// arrives sorted: a second front end computing it in its own language is a
/// second chance to disagree about what a project looks like. Clients walk
/// these and render.
public struct Row: Decodable, Hashable, Sendable {
    /// The session this row draws; empty on a folder header.
    public var id: String
    /// The folder this row is the header for, or the one the session is filed
    /// under. Empty on a loose session.
    public var folder: String
    /// A header's state. Its members are still here, marked `hidden`.
    public var collapsed: Bool
    /// A member of a collapsed folder. Present rather than dropped because it
    /// still holds a position: a manual reorder sends the project's *whole*
    /// order back, or the rows left out keep stale `Order` values.
    public var hidden: Bool
    /// A header's member counts, one per view a client can be filtered to.
    public var count: Int
    public var archivedCount: Int

    public var isFolder: Bool { id.isEmpty }

    public init(id: String = "", folder: String = "", collapsed: Bool = false,
                hidden: Bool = false, count: Int = 0, archivedCount: Int = 0) {
        self.id = id
        self.folder = folder
        self.collapsed = collapsed
        self.hidden = hidden
        self.count = count
        self.archivedCount = archivedCount
    }

    enum CodingKeys: String, CodingKey {
        case id, folder, collapsed, hidden, count
        case archivedCount = "archived_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        archivedCount = try c.decodeIfPresent(Int.self, forKey: .archivedCount) ?? 0
    }
}

public struct Snapshot: Decodable, Sendable {
    /// Already sorted by the core, live-first tiebreak included. A client
    /// filters this and renders it; it does not sort.
    public var sessions: [Session]
    /// Session id → its derived view.
    public var views: [String: SessionView]
    /// Project name → its sessions laid out as display rows, folder headers
    /// spliced in. Absent from a core older than folders, which is what the
    /// caller's fallback (one loose row per session) is for.
    public var rows: [String: [Row]]
    public var pollTime: Date
    public var err: String?
    /// False when the snapshot carried no `views` key at all: a core older
    /// than the derived-state protocol, still sending path-keyed `states` and
    /// `quips`. Its snapshot has no session list either, so decoding one
    /// yields an *empty* list that is indistinguishable from "every session
    /// was deleted" unless absence is tracked separately — which is what this
    /// is. There is no version handshake on this socket; this is the only
    /// signal there is.
    public var derived: Bool

    enum CodingKeys: String, CodingKey {
        case sessions, views, rows, err
        case pollTime = "poll_time"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        views = try c.decodeIfPresent([String: SessionView].self, forKey: .views) ?? [:]
        rows = try c.decodeIfPresent([String: [Row]].self, forKey: .rows) ?? [:]
        pollTime = try c.decodeIfPresent(Date.self, forKey: .pollTime) ?? Date()
        err = try c.decodeIfPresent(String.self, forKey: .err)
        // Present-but-null counts: a core with no sessions at all sends
        // `"views": null`, and that is an answer.
        derived = c.contains(.views)
    }
}

// MARK: - Creating a session

/// `session.CreateRequest` — the whole "new session" transaction, in one
/// object. The core cuts the worktree and branch, starts the agent, attaches
/// the PR tag, composes the first prompt (thinking-level prefix, ticket and PR
/// lines) and types it into the pane. None of that is this app's to replay.
///
/// **It has no `json` tags on the Go side**, so unlike everything else here it
/// crosses as Go's own field names. `PR` is spelled exactly that.
public struct CreateRequest: Encodable, Sendable {
    public var project: String
    public var name: String
    /// Empty means the project's default agent.
    public var agent: String
    /// An existing branch to check out; empty cuts a new one.
    public var branch: String
    public var baseBranch: String
    public var ticket: String
    public var pr: String
    public var model: String
    public var thinking: String
    /// The first task for the agent. Empty types nothing into the pane.
    public var prompt: String
    public var autoSubmit: Bool
    /// nil means "use the project's own default" — which is why the Go field
    /// is a pointer. This app sends an explicit choice, since its form shows
    /// one; it never opens a terminal tab, so `OpenTerminal` is never sent.
    public var dangerous: Bool?

    enum CodingKeys: String, CodingKey {
        case project = "Project"
        case name = "Name"
        case agent = "Agent"
        case branch = "Branch"
        case baseBranch = "BaseBranch"
        case ticket = "Ticket"
        case pr = "PR"
        case model = "Model"
        case thinking = "Thinking"
        case prompt = "Prompt"
        case autoSubmit = "AutoSubmit"
        case dangerous = "Dangerous"
    }

    public init(project: String, name: String, agent: String = "", branch: String = "",
                baseBranch: String = "", ticket: String = "", pr: String = "",
                model: String = "", thinking: String = "", prompt: String = "",
                autoSubmit: Bool = false, dangerous: Bool? = nil) {
        self.project = project
        self.name = name
        self.agent = agent
        self.branch = branch
        self.baseBranch = baseBranch
        self.ticket = ticket
        self.pr = pr
        self.model = model
        self.thinking = thinking
        self.prompt = prompt
        self.autoSubmit = autoSubmit
        self.dangerous = dangerous
    }
}

// MARK: - Coding

public enum Wire {

    /// Anything at or before this is Go's zero `time.Time`
    /// ("0001-01-01T00:00:00Z"), meaning "never", not "in the year 1".
    public static let goZeroTimeCutoff = Date(timeIntervalSince1970: 0)

    public static let encoder = JSONEncoder()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            // Lenient on purpose: `last_opened` on a never-opened session is
            // the year-1 zero time, and a strict strategy would fail the whole
            // Sessions call over it.
            return parseTimestamp(raw) ?? .distantPast
        }
        return d
    }()

    /// Parses Go's RFC 3339, by hand.
    ///
    /// `ISO8601DateFormatter` was measured at 23 µs a call against 0.06 µs for
    /// this — 420x — and with 30 sessions the watcher pushes ~2 snapshots a
    /// second, each carrying two timestamps per session. That was 7% of the
    /// app's entire CPU, idle, forever (Instruments, Time Profiler). ICU is the
    /// wrong tool for a fixed-width numeric format.
    ///
    /// Deliberately narrow: `YYYY-MM-DDTHH:MM:SS`, an optional fraction (Go
    /// emits up to nine digits; nothing here displays sub-second time, so it is
    /// skipped), then `Z` or `±HH:MM`. Anything else returns nil and the
    /// decoder falls back to `.distantPast`, exactly as before.
    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    public static func parseTimestamp(_ raw: String) -> Date? {
        let b = Array(raw.utf8)
        guard b.count >= 19 else { return nil }
        func digits(_ start: Int, _ width: Int) -> Int? {
            var value = 0
            for i in start..<(start + width) {
                let d = Int(b[i]) - 48
                guard (0...9).contains(d) else { return nil }
                value = value * 10 + d
            }
            return value
        }
        guard b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              b[10] == UInt8(ascii: "T") || b[10] == UInt8(ascii: "t"),
              b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"),
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year),
              hour <= 23, minute <= 59, second <= 60 else { return nil }

        var i = 19
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            while i < b.count, (48...57).contains(b[i]) { i += 1 }
        }
        // A zone is required, exactly as `.withInternetDateTime` required one:
        // Go always sends `Z` or an offset, and a bare local-looking time is a
        // wire change worth noticing rather than silently reading as UTC.
        guard i < b.count else { return nil }
        var offset = 0
        if b[i] != UInt8(ascii: "Z"), b[i] != UInt8(ascii: "z") {
            let sign = b[i] == UInt8(ascii: "-") ? -1 : 1
            guard b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-"),
                  b.count >= i + 6, b[i + 3] == UInt8(ascii: ":"),
                  let offsetHours = digits(i + 1, 2), let offsetMinutes = digits(i + 4, 2)
            else { return nil }
            offset = sign * (offsetHours * 3600 + offsetMinutes * 60)
        }

        // Days from 1970-01-01 in the proleptic Gregorian calendar (Hinnant's
        // days_from_civil). No calendar object, no time zone database: every
        // timestamp on this wire carries its own offset.
        let shiftedYear = year - (month <= 2 ? 1 : 0)
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Date(timeIntervalSince1970:
            Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset))
    }

    // MARK: Checks

    /// Every assumption above that the Go side could quietly change under us.
    public static func demo() {
        // The hand-rolled parser, against the ICU formatter it replaced: same
        // answer on every shape the Go side emits, or it is not a drop-in.
        // Pre-Gregorian dates are excluded deliberately — Foundation reads
        // year 1 through the Julian calendar and lands two days off ours, which
        // matters to nothing, since the only such timestamp is Go's zero time
        // and all anyone asks of it is whether it precedes the cutoff.
        let icu = ISO8601DateFormatter()
        icu.formatOptions = [.withInternetDateTime]
        for raw in ["2026-09-02T10:11:12Z", "2026-09-02T10:11:12.123456789Z",
                    "2026-09-02T10:11:12.5+01:00", "2024-02-29T23:59:59Z",
                    "1970-01-01T00:00:00Z", "2026-12-31T00:00:00-05:30",
                    "1999-03-01T12:00:00+00:00"] {
            let mine = parseTimestamp(raw)
            let theirs = icu.date(from: raw) ?? icu.date(from: raw.replacingOccurrences(
                of: #"\.\d+"#, with: "", options: .regularExpression))
            assert(mine == theirs, "\(raw): \(mine as Any) != \(theirs as Any)")
        }
        assert(parseTimestamp("2000-02-29T00:00:00Z") != nil, "2000 is a leap year")
        assert(parseTimestamp("1900-02-29T00:00:00Z") == nil, "1900 is not")
        assert(parseTimestamp("0001-01-01T00:00:00Z").map { $0 <= goZeroTimeCutoff } ?? false,
               "Go's zero time must parse, and must read as before the cutoff")
        // Malformed input is nil, not a wrong date: the decoder turns nil into
        // .distantPast, and a garbled timestamp must not become a real one.
        for bad in ["", "2026-09-02", "2026-09-02T10:11", "2026-13-02T10:11:12Z",
                    "2026-09-02 10:11:12Z", "2026-09-0aT10:11:12Z",
                    "2026-09-02T10:11:12+0100", "2026-09-02T25:11:12Z",
                    // A date that does not exist must not roll over into one
                    // that does, and a time with no zone is not this wire's.
                    "2026-02-31T10:11:12Z", "2025-02-29T10:11:12Z",
                    "2026-04-31T10:11:12Z", "2026-09-02T10:11:12",
                    "2026-09-02T10:11:12.5"] {
            assert(parseTimestamp(bad) == nil, "\(bad) must not parse")
        }

        // A session as `moomux serve` actually sends one, zero time included.
        let sessionJSON = """
        {"id":"abc","project":"moomux","name":"macos","branch":"alan/macos",
         "worktree_path":"/tmp/wt","tmux_session":"moomux-macos",
         "created_at":"2026-09-02T10:11:12.987654321Z",
         "last_opened":"0001-01-01T00:00:00Z","dangerous":true}
        """
        let s = try! decoder.decode(Session.self, from: Data(sessionJSON.utf8))
        assert(s.id == "abc")
        assert(s.worktreePath == "/tmp/wt")
        assert(s.tmuxSession == "moomux-macos")
        assert(s.dangerous)
        assert(s.agentName == "claude", "a session with no agent field must default to claude")
        assert(!s.hasBeenOpened, "the Go zero time must read as never opened")
        assert(s.createdAt > goZeroTimeCutoff)

        let configJSON = """
        {"projects":{"moomux":{"repo":"/src/moomux","agent":"codex","emoji":"🐮"},
                     "site":{"repo":"/src/site","kind":"plain"}},
         "order":["site","moomux"],"theme":"gruvbox"}
        """
        let cfg = try! decoder.decode(Config.self, from: Data(configJSON.utf8))
        assert(cfg.projects["moomux"]?.repo == "/src/moomux")
        assert(cfg.projects["moomux"]?.emoji == "🐮")
        assert(cfg.projects["site"]?.isPlain == true)
        assert(cfg.projects["moomux"]?.usesWorktree == true)
        assert(cfg.orderedProjectNames == ["site", "moomux"], "Order must win over alphabetical")
        // A project missing from Order sorts alphabetically, after the ordered ones.
        let extraJSON = """
        {"projects":{"b":{"repo":"/b"},"a":{"repo":"/a"},"z":{"repo":"/z"}},"order":["z"]}
        """
        let extra = try! decoder.decode(Config.self, from: Data(extraJSON.utf8))
        assert(extra.orderedProjectNames == ["z", "a", "b"])

        // Every settings flag is `omitempty` on the Go side, so "off" arrives
        // as an absent key and must not decode as nil-shaped garbage.
        assert(cfg.autoTmux == false && cfg.sortRecentFirst == false)
        assert(cfg.autoSubmitDefault == false)
        let flagsJSON = """
        {"projects":{},"auto_tmux":true,"auto_submit_default":true,
         "sort_recent_first":true,"appearance":"dark"}
        """
        let flags = try! decoder.decode(Config.self, from: Data(flagsJSON.utf8))
        assert(flags.autoTmux && flags.autoSubmitDefault && flags.sortRecentFirst)
        assert(flags.appearance == "dark")

        // prompt_agent is the one Project field the app has to honour rather
        // than merely display: it means "ask for an agent every time" and the
        // new-session form must not preselect one.
        let askJSON = """
        {"projects":{"p":{"repo":"/p","prompt_agent":true,"dangerous":true,"no_worktree":true}}}
        """
        let ask = try! decoder.decode(Config.self, from: Data(askJSON.utf8))
        assert(ask.projects["p"]?.promptAgent == true)
        assert(ask.projects["p"]?.dangerous == true)
        assert(ask.projects["p"]?.usesWorktree == false, "no_worktree means sessions run in the repo")
        assert(cfg.projects["moomux"]?.promptAgent == false, "absent means preselect the default")
        assert(cfg.projects["moomux"]?.agentName == "codex")
        assert(cfg.projects["site"]?.agentName == "claude", "an unset agent is claude")

        // A Project goes back out as `ipc.Args.proj`, so its encoding is a wire
        // contract too: unset optionals must vanish rather than cross as null
        // (Go would read "" for a string but the shape is the thing being
        // pinned), and every bool must be explicit so `dangerous: false` can
        // actually turn the flag off through UpdateProject.
        let out = JSONEncoder()
        // Slashes unescaped only so the expected literal below stays readable —
        // the real encoder writes "\/", which Go decodes identically.
        out.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sent = String(decoding: try! out.encode(
            Project(repo: "/src/x", baseBranch: "main", agent: "codex", dangerous: true)),
            as: UTF8.self)
        assert(sent == #"{"agent":"codex","base_branch":"main","collapsed":false,"dangerous":true,"#
               + #""no_worktree":false,"prompt_agent":false,"repo":"/src/x"}"#, sent)
        // Folders and the collapse flag ride along because UpdateProject
        // replaces the whole record: a save that dropped them would delete the
        // project's folders. `folders` is absent when there are none, the same
        // as every other unset optional.
        assert(!sent.contains("folders"), "no folders means no key")
        let withFolders = String(decoding: try! out.encode(
            Project(repo: "/x", folders: ["wip": FolderMeta(collapsed: true)], collapsed: true)),
            as: UTF8.self)
        assert(withFolders.contains(#""folders":{"wip":{"collapsed":true}}"#), withFolders)
        assert(withFolders.contains(#""collapsed":true"#), withFolders)
        assert(!sent.contains("null"), "an unset field must vanish, never encode as null")
        assert(!sent.contains("kind"), "kind is the core's to decide, not ours to send")

        // The agent table the pickers are built from. opencode has no model
        // list — that is what makes its model control a free-text field.
        let agents = try! decoder.decode([AgentOption].self, from: Data("""
        [{"name":"claude","models":["default","sonnet"],"thinking":["default","think"]},
         {"name":"opencode","thinking":["default"]}]
        """.utf8))
        assert(agents.count == 2)
        assert(agents[0].models == ["default", "sonnet"])
        assert(agents[1].models.isEmpty, "an absent model list must be empty, not a crash")
        assert(agents[1].thinking == ["default"])

        // The served palettes. `needs_input` is snake_case on the wire, the
        // ANSI theme must resolve to default rather than trying to read "12"
        // as hex, and an unrecognized name falls back the way ThemeByName
        // does.
        let palettes = try! decoder.decode([ThemePalette].self, from: Data("""
        [{"name":"default","working":{"light":"#007aff","dark":"#007aff","system":"accent"},
          "done":{"light":"#34c759","dark":"#30d158","system":"green"},
          "needs_input":{"light":"#ff8d28","dark":"#ff9230","system":"orange"},
          "parked":{"light":"#808080","dark":"#99999a","system":"secondary"},
          "warn":{"light":"#946f1a","dark":"#e0af68"}},
         {"name":"terminal","ansi":true,"working":{"light":"12","dark":"12"},
          "done":{"light":"10","dark":"10"},"needs_input":{"light":"11","dark":"11"},
          "parked":{"light":"7","dark":"7"},"warn":{"light":"11","dark":"11"}},
         {"name":"gruvbox","working":{"light":"#076678","dark":"#83a598"},
          "done":{"light":"#79740e","dark":"#b8bb26"},
          "needs_input":{"light":"#af3a03","dark":"#fe8019"},
          "parked":{"light":"#a89984","dark":"#665c54"},
          "warn":{"light":"#b57614","dark":"#fabd2f"}}]
        """.utf8))
        assert(palettes.count == 3)
        assert(palettes[0].needsInput.light == "#ff8d28", "needs_input is snake_case on the wire")
        assert(palettes[0].working.system == "accent", "the live system accent beats the frozen hex")
        assert(palettes[2].working.system.isEmpty, "only default names system colors")
        assert(palettes[0].color(for: .unknown) == palettes[0].parked)
        assert(ThemePalette.resolved("gruvbox", in: palettes)?.name == "gruvbox")
        assert(ThemePalette.resolved("terminal", in: palettes)?.name == "default",
               "ANSI indices are not hex — fall back rather than parse them")
        assert(ThemePalette.resolved("", in: palettes)?.name == "default")
        assert(ThemePalette.resolved("nope", in: palettes)?.name == "default")
        assert(ThemePalette.resolved("default", in: []) == nil, "nil only before Themes answered")
        assert(palettes[0].warn.light != palettes[0].done.light,
               "warn is amber and done is green; the git badges follow warn")

        // prstatus.Info: lowercase keys now, like everything else on the wire.
        let pr = try! decoder.decode(
            PRInfo.self,
            from: Data(#"{"state":"OPEN","mergeable":"CONFLICTING","ci":"FAILING"}"#.utf8))
        assert(pr.state == "OPEN" && pr.ci == "FAILING" && pr.mergeable == "CONFLICTING")
        assert(pr.summary == "open · checks failing · conflicts", pr.summary)
        let merged = try! decoder.decode(
            PRInfo.self, from: Data(#"{"state":"MERGED","mergeable":"UNKNOWN","ci":"NONE"}"#.utf8))
        assert(merged.summary == "merged", merged.summary)
        // prGlyph's precedence, which is state first: a merged PR whose last
        // CI run failed is merged, not failing.
        assert(PRInfo.badge(nil) == .open, "no status yet is a plain open PR")
        assert(PRInfo.badge(pr) == .conflicts, "conflicts outrank failing CI")
        assert(PRInfo.badge(merged) == .merged)
        let mergedFailing = try! decoder.decode(
            PRInfo.self, from: Data(#"{"state":"MERGED","mergeable":"CONFLICTING","ci":"FAILING"}"#.utf8))
        assert(PRInfo.badge(mergedFailing) == .merged, "the state wins over both")
        let failing = try! decoder.decode(
            PRInfo.self, from: Data(#"{"state":"OPEN","mergeable":"MERGEABLE","ci":"FAILING"}"#.utf8))
        assert(PRInfo.badge(failing) == .failing)
        let commented = try! decoder.decode(
            PRInfo.self,
            from: Data(#"{"state":"OPEN","mergeable":"MERGEABLE","ci":"PASSING","unresolved":2}"#.utf8))
        assert(PRInfo.badge(commented) == .comments)
        assert(commented.summary == "open · checks passing · 2 open comments", commented.summary)
        let failingCommented = try! decoder.decode(
            PRInfo.self,
            from: Data(#"{"state":"OPEN","mergeable":"MERGEABLE","ci":"FAILING","unresolved":2}"#.utf8))
        assert(PRInfo.badge(failingCommented) == .failing, "a red check outranks open comments")
        let oneComment = try! decoder.decode(
            PRInfo.self,
            from: Data(#"{"state":"OPEN","mergeable":"MERGEABLE","ci":"NONE","unresolved":1}"#.utf8))
        assert(oneComment.summary == "open · 1 open comment", oneComment.summary)

        let closed = try! decoder.decode(
            PRInfo.self, from: Data(#"{"state":"CLOSED","mergeable":"UNKNOWN","ci":"NONE"}"#.utf8))
        assert(PRInfo.badge(closed) == .closed)
        let pending = try! decoder.decode(
            PRInfo.self, from: Data(#"{"state":"OPEN","mergeable":"UNKNOWN","ci":"PENDING"}"#.utf8))
        assert(PRInfo.badge(pending) == .pending, "UNKNOWN mergeable is not a conflict")
        let noChecks = try! decoder.decode(
            PRInfo.self, from: Data(#"{"state":"OPEN","mergeable":"MERGEABLE","ci":"NONE"}"#.utf8))
        assert(PRInfo.badge(noChecks) == .open, "a repo with no CI is a plain open PR")
        // A struct Go could not fill in at all must read as "nothing to show",
        // not as a row full of blanks.
        let empty = try! decoder.decode(PRInfo.self, from: Data("{}".utf8))
        assert(empty.summary.isEmpty)

        // A snapshot as sessionview.Snapshot sends one: the session list in
        // display order, plus a view per session id. States are *names* — an
        // int would be the old wire format, and an unfamiliar name must
        // degrade rather than tear the stream down.
        let snapJSON = """
        {"sessions":[{"id":"p:a","project":"p","name":"a","worktree_path":"/wt/a"},
                     {"id":"p:b","project":"p","name":"b","worktree_path":"/wt/b"}],
         "views":{"p:a":{"id":"p:a","state":"needs-input","label":"mooing for you",
                         "quip":"moo-ve this along","prompt":"fix the thing",
                         "git_ok":true,"dirty":true,
                         "pr":{"state":"OPEN","mergeable":"MERGEABLE","ci":"PASSING"}},
                  "p:b":{"id":"p:b","state":"parked","label":"in the barn"},
                  "p:c":{"id":"p:c","state":"grazing"}},
         "poll_time":"2026-09-02T10:11:12Z"}
        """
        let snap = try! decoder.decode(Snapshot.self, from: Data(snapJSON.utf8))
        assert(snap.sessions.map(\.id) == ["p:a", "p:b"], "the order served is the order shown")
        assert(snap.views["p:a"]?.state == .needsInput, "needs-input is hyphenated on the wire")
        assert(snap.views["p:a"]?.quip == "moo-ve this along")
        assert(snap.views["p:a"]?.prompt == "fix the thing")
        assert(snap.views["p:a"]?.gitOK == true && snap.views["p:a"]?.dirty == true)
        assert(snap.views["p:a"]?.unpushed == false, "omitempty means absent, not unknown")
        assert(snap.views["p:a"]?.pr?.ci == "PASSING")
        assert(snap.views["p:b"]?.state == .parked)
        assert(snap.views["p:b"]?.gitOK == false, "no git_ok means don't draw a badge")
        assert(snap.views["p:b"]?.pr == nil, "no PR attached is nil, not a blank row")
        assert(snap.views["p:c"]?.state == .unknown, "an unknown state name must degrade, not throw")
        assert(snap.err == nil)
        assert(snap.derived)

        // A core too old to have `internal/sessionview` streams the previous
        // shape — path-keyed `states`, no session list. It decodes without
        // throwing (every field is optional), so `derived` is the only thing
        // between it and a client rendering an empty sidebar over 22 real
        // sessions. Measured against a live one: keys were `["poll_time",
        // "states"]` exactly.
        let old = try! decoder.decode(Snapshot.self, from: Data(#"""
        {"states":{"/wt/a":3},"quips":{"/wt/a":"moo-mentum building"},
         "poll_time":"2026-09-02T10:11:12Z"}
        """#.utf8))
        assert(!old.derived, "no views key means this core does not speak the new protocol")
        assert(old.sessions.isEmpty && old.views.isEmpty)
        // …and an *empty* answer from a core that does speak it is still an
        // answer, null map included.
        let none = try! decoder.decode(
            Snapshot.self, from: Data(#"{"sessions":null,"views":null,"poll_time":"2026-09-02T10:11:12Z"}"#.utf8))
        assert(none.derived, "present-but-null is an answer, not an older core")
        assert(none.sessions.isEmpty)

        // A CreateRequest is the one thing this app sends that Go decodes off
        // its *field names* — CreateRequest carries no json tags. A key that
        // stops matching is silent on both sides: the session is created with
        // the field simply unset.
        let req = String(decoding: try! out.encode(CreateRequest(
            project: "moomux", name: "macos", agent: "codex", baseBranch: "develop",
            ticket: "T-1", pr: "http://p/1", model: "gpt", thinking: "high",
            prompt: "fix it", autoSubmit: true, dangerous: true)), as: UTF8.self)
        assert(req == #"{"Agent":"codex","AutoSubmit":true,"BaseBranch":"develop","Branch":"","#
               + #""Dangerous":true,"Model":"gpt","Name":"macos","PR":"http://p/1","#
               + #""Project":"moomux","Prompt":"fix it","Thinking":"high","Ticket":"T-1"}"#, req)
        assert(!req.contains("OpenTerminal"), "a new session belongs in this app, not in iTerm")
    }
}
