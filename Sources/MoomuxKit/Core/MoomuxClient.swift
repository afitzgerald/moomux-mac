import Foundation

/// The Swift half of `internal/ipc`. One JSON request line in, one JSON
/// response line out, connection closed — except `Watch`, which streams
/// snapshot lines until the client hangs up.
///
/// The Go `ipc.Client` is the reference implementation; keep the two honest
/// against each other. Anything this cannot do is a hole in the socket
/// boundary, not a reason to link the Go core.
public final class MoomuxClient: Sendable {

    public enum Failure: Error, LocalizedError {
        /// An error the server returned for a call it understood.
        case server(String)
        /// `AddProject` against a path that is not a git repository —
        /// `gitwt.ErrNotGitRepo`, tagged `code: "not_git_repo"` on the wire
        /// because `errors.Is` cannot survive a string round trip.
        ///
        /// Its own case and not a `.server` string: it is the one server error
        /// that is a *question* rather than a failure, and the caller answers it
        /// with `initProjectAndAdd` or `addPlainProject`. The TUI branches on
        /// the same sentinel to open its init-choice dialog.
        case notGitRepo(String)
        case emptyResponse
        case disconnected
        /// An attachment over `maxSaveFile`, refused before it is uploaded.
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case let .server(message): return message
            case let .notGitRepo(message): return message
            case .emptyResponse: return "the server closed the connection without answering"
            case .disconnected: return "the status stream ended"
            case .tooLarge: return "larger than \(MoomuxClient.maxSaveFile >> 20) MB"
            }
        }
    }

    public let endpoint: Endpoint

    /// Where a core is. The unix socket is the local case and stays the
    /// default; TCP is how a phone on the tailnet reaches the same server,
    /// which answers identically on both — see `ipc.Server.Serve`.
    public enum Endpoint: Sendable, Equatable, CustomStringConvertible {
        case unix(path: String)
        case tcp(host: String, port: UInt16)

        func connect() throws -> StreamSocket {
            switch self {
            case let .unix(path): return try StreamSocket(path: path)
            case let .tcp(host, port): return try StreamSocket(host: host, port: port)
            }
        }

        public var description: String {
            switch self {
            case let .unix(path): return path
            case let .tcp(host, port): return "\(host):\(port)"
            }
        }
    }

    /// The `Watch` connection currently open, so `nudge()` can write on it.
    private let live = LiveWatch()

    public init(socketPath: String = MoomuxClient.defaultSocketPath) {
        endpoint = .unix(path: socketPath)
    }

    /// `ipc.TailnetPort`: where a core's tailnet listener always is.
    public static let tailnetPort = 45876

    /// A core reached over TCP — another machine, as far as this client can
    /// tell. What decides whether a pane may attach locally (`AttachRoute`).
    public var isRemote: Bool {
        if case .tcp = endpoint { return true }
        return false
    }

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    /// Mirrors `ipc.DefaultSocket`. `NSHomeDirectory()` is the real home only
    /// because this app is not sandboxed — a sandboxed build would get its
    /// container here and never find the socket.
    public static var defaultSocketPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/moomux/moomux.sock")
    }

    // MARK: - Wire shapes

    /// The subset of `ipc.Args` this app sends. Everything is optional and
    /// `omitempty` on the Go side, so unset fields simply do not appear.
    ///
    /// Every field has to stay Optional. A non-optional `Bool` would encode
    /// `false` on every call, and `on:false` on a call that never meant to say
    /// anything about it is a different message.
    struct Args: Encodable {
        var id: String?
        /// `ReorderSessions`' fully-resolved final order.
        var ids: [String]?
        var name: String?
        /// `RenameFolder`'s target name — `name` carries the old one there,
        /// same as every other folder method's single folder-name parameter.
        var newName: String?
        /// The project a method acts on — `SetProjectCollapsed` and the
        /// project CRUD. No folder method sends it any more: the namespace is
        /// global, and the core would accept and ignore the key rather than
        /// refuse it.
        var project: String?
        var agent: String?
        var ticket: String?
        var pr: String?
        var theme: String?
        var appearance: String?
        var delta: Int?
        var dangerous: Bool?
        var on: Bool?
        /// `CreateSession`'s whole transaction. One field rather than a dozen
        /// flat ones, because the core runs the sequence end to end.
        var req: CreateRequest?
        /// A whole `config.Project`, for the four project writes. `Project`'s
        /// own encoder decides which of its fields cross.
        var proj: Project?
        /// `Attach`'s initial pty size, and `ResizeAttach`'s new one. A core
        /// too old for `ResizeAttach` sets it once, and a client that changes
        /// size there detaches and reattaches. Always send real numbers — the
        /// Go side reads a missing or absurd value as 80x24, which is not what
        /// a phone wants.
        var cols: Int?
        var rows: Int?
        /// `SaveFile`'s contents — base64 on the wire, which is both
        /// `JSONEncoder`'s default for `Data` and Go's for `[]byte`.
        var data: Data?
        /// `ReadFile`'s path, as tapped in a pane.
        var path: String?
        /// `ResizeAttach`: which live attach to resize — the token its `Attach`
        /// answered with.
        var attach: String?

        // Every `ipc.Args` key this app sends already matches its property
        // name. A missing entry here would be invisible in both directions —
        // Go ignores the unknown key and uses the zero value.
        enum CodingKeys: String, CodingKey {
            case id, ids, name, agent, ticket, pr, delta, dangerous, on, theme, appearance, req, proj
            case newName = "new_name"
            case project
            case cols, rows
            case data, path, attach
        }
    }

    struct Request: Encodable {
        let method: String
        var args: Args?
    }

    /// `ipc.Result` plus the error fields, all optional — one union type, the
    /// same trade the Go side makes.
    struct Response: Decodable {
        var result: CallResult?
        var err: String?
        var code: String?
    }

    struct CallResult: Decodable {
        /// The updated row, from every mutating setter. Discarded today — see
        /// the mutations below.
        var session: Session?
        var sessions: [Session]?
        var cfg: Config?
        var agents: [AgentOption]?
        var themes: [ThemePalette]?
        /// Project name → the glyph to draw: the project's own `emoji` when it
        /// set one, and `config.ProjectEmojiPalette`'s deterministic pick when
        /// it did not. A sibling of `cfg` rather than a field on each project,
        /// because `UpdateProject` replaces the whole record — a front end that
        /// round-tripped it would save a palette pick as the user's own choice,
        /// the trap `collapsed` already has. Serve-only: never sent back.
        var projectEmoji: [String: String]?
        var hint: String?
        var ok: Bool?
        /// `Capture`: session id → the pane's text. `omitempty` on the Go
        /// side, so nothing-captured omits the key rather than sending `{}`,
        /// and an individual id that could not be captured is absent rather
        /// than present-and-empty. Both mean "keep what you last drew".
        var screens: [String: String]?
        var dirty: Bool?
        var unpushed: Bool?
        var files: Int?
        var commits: Int?
        /// `SaveFile`: where the upload landed; `ReadFile`: the path it resolved to.
        var path: String?
        /// `ReadFile`'s contents, base64 on the wire.
        var data: Data?
        /// `Diff`: raw `git diff` text, `diff --git` headers included, and
        /// whether the core cut it at a file boundary to stay under its cap.
        var patch: String?
        var truncated: Bool?
        /// `Diff`: the ref the patch was taken against — "HEAD" when no base
        /// branch shares history with the session's, so uncommitted work only.
        var base: String?
        /// `GhosttyConfig`: the core machine's Ghostty config, concatenated in
        /// ghostty's own load order, and the files it came from.
        var ghostty: ServedGhostty?
        /// `Attach`: the token that names this attach to `ResizeAttach`. Absent
        /// from a core older than it, which is the signal to fall back to
        /// reattaching on a size change.
        var attach: String?

        enum CodingKeys: String, CodingKey {
            case session, sessions, cfg, agents, themes, hint, ok, dirty, unpushed, files, commits, path, data
            case patch, truncated, base, attach, ghostty
            case screens
            case projectEmoji = "project_emoji"
        }
    }

    struct ServedGhostty: Decodable {
        var text: String?
        var files: [String]?
    }

    /// What the core can say about a session's worktree, on demand.
    ///
    /// The snapshot stream carries the same dirty/unpushed bits (and the PR),
    /// but up to a minute old — this is the fresh check the delete dialog runs
    /// before removing a worktree, and the file/commit counts it shows.
    ///
    /// `known` is the `ok` the Go side returns from both calls: false for
    /// an unknown session, a plain (non-git) project, or a lookup that failed.
    /// Kept as a flag rather than making the whole thing optional so "we asked
    /// and the answer is nothing" is distinguishable from "we never asked".
    public struct SessionStatus: Equatable, Sendable {
        public var known = false
        public var dirty = false
        public var unpushed = false
        public var filesChanged = 0
        public var unpushedCommits = 0

        /// Empty when the worktree is clean, so the row can be hidden.
        public var changeSummary: String {
            var parts: [String] = []
            if filesChanged > 0 {
                parts.append("\(filesChanged) file\(filesChanged == 1 ? "" : "s") changed")
            } else if dirty {
                parts.append("uncommitted changes")
            }
            if unpushedCommits > 0 {
                parts.append("\(unpushedCommits) commit\(unpushedCommits == 1 ? "" : "s") unpushed")
            } else if unpushed {
                parts.append("unpushed commits")
            }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Calls
    //
    // These block. Call them off the main actor.

    @discardableResult
    private func call(_ method: String, _ args: Args? = nil) throws -> CallResult {
        let socket = try endpoint.connect()
        defer { socket.close() }
        try socket.write(Wire.lineEncoded(Request(method: method, args: args)))
        // Then say so. The server reads this request to EOF, and without the
        // half-close there is no EOF — the connection is still open because
        // this side is waiting for the answer on it. Nothing at all comes
        // back, which presents as a core that is up and silent.
        socket.closeWrite()
        let data = try socket.readToEnd()
        guard !data.isEmpty else { throw Failure.emptyResponse }
        let response = try Wire.decoder.decode(Response.self, from: data)
        if let err = response.err, !err.isEmpty {
            // `code` names the sentinel the caller branches on; every other
            // error is just its message.
            throw response.code == "not_git_repo" ? Failure.notGitRepo(err) : Failure.server(err)
        }
        return response.result ?? CallResult()
    }

    /// The config, and the emoji table that comes with it — empty from a core
    /// too old to send one, which is what leaves the sidebar drawing the
    /// project's own emoji or nothing, exactly as it did before.
    public func config() throws -> (config: Config, projectEmoji: [String: String]) {
        let result = try call("Config")
        guard let cfg = result.cfg else { throw Failure.emptyResponse }
        return (cfg, result.projectEmoji ?? [:])
    }

    /// Which agents the core can launch, and the model/thinking choices worth
    /// offering for each. Fetched once at startup — it is a static table on the
    /// Go side, and re-polling it every two seconds would buy nothing.
    public func agentOptions() throws -> [AgentOption] {
        try call("AgentOptions").agents ?? []
    }

    /// The core's color palettes — the agent-state colors this app renders
    /// with, and the list the theme picker offers. Fetched once, like
    /// `agentOptions`: a static table in `internal/config`.
    public func themes() throws -> [ThemePalette] {
        try call("Themes").themes ?? []
    }

    /// Uploads a file to the core's machine and returns the path it was
    /// written to — how both front ends attach a file to a first prompt. A
    /// photo picked on the phone has no path an agent on the Mac could open,
    /// and the Mac sends its dropped files the same way so there is one path.
    ///
    /// A core from before `SaveFile` answers "unknown method", which says
    /// nothing to someone attaching a photo; that one is reworded.
    public func saveFile(name: String, data: Data) throws -> String {
        let result: CallResult
        do {
            result = try call("SaveFile", Args(name: name, data: data))
        } catch let Failure.server(message) where message.hasPrefix("unknown method") {
            throw Failure.server("this moomux core is too old to take attachments — upgrade it")
        }
        guard let path = result.path else { throw Failure.emptyResponse }
        return path
    }

    /// A file on the core's machine, for a path tapped in a session's pane.
    /// The core resolves it — a relative path against the pane's directory and
    /// then the worktree, `~` expanded, a trailing `:line:col` dropped — and
    /// serves only the worktree, its own upload dir and `/tmp`, so this is the
    /// one place the phone reads the core's disk.
    public func readFile(id: String, path: String) throws -> (path: String, data: Data) {
        let result: CallResult
        do {
            result = try call("ReadFile", Args(id: id, path: path))
        } catch let Failure.server(message) where message.hasPrefix("unknown method") {
            throw Failure.server("this moomux core is too old to open files — upgrade it")
        }
        // No `data` key is an empty file: Go's `omitempty` drops a zero-length
        // `[]byte`. The path is always there on success.
        guard let resolved = result.path else { throw Failure.emptyResponse }
        return (resolved, result.data ?? Data())
    }

    /// `readFile`'s resolution without the bytes, for the Mac: it shares the
    /// core's disk and opens the file itself, but only the core knows the
    /// pane's directory a relative path was printed against.
    public func resolveFile(id: String, path: String) throws -> String {
        let result: CallResult
        do {
            result = try call("ResolveFile", Args(id: id, path: path))
        } catch let Failure.server(message) where message.hasPrefix("unknown method") {
            throw Failure.server("this moomux core is too old to open relative paths — upgrade it")
        }
        guard let resolved = result.path else { throw Failure.emptyResponse }
        return resolved
    }

    /// The largest file `saveFile` sends — the core's `maxSaveFile`, copied so
    /// a phone can refuse a video before uploading all of it just to hear no.
    /// The core still enforces its own; if the two drift, the core's wins.
    public static let maxSaveFile = 32 << 20

    public func sessions() throws -> [Session] {
        try call("Sessions").sessions ?? []
    }

    /// Just the worktree half of `status(id:)`: one round trip and one
    /// `git status` on the Go side, with no `git log`. It also refreshes the
    /// remote ref, which `ChangeSummary` does not.
    public func worktreeStatus(id: String) throws -> SessionStatus {
        var status = SessionStatus()
        let worktree = try call("WorktreeStatus", Args(id: id))
        status.known = worktree.ok ?? false
        status.dirty = worktree.dirty ?? false
        status.unpushed = worktree.unpushed ?? false
        return status
    }

    /// Worktree state and change counts for one session.
    ///
    /// Two round trips, both shelling out to git on the Go side — the delete
    /// dialog's guard and the detail pane's Changes row. Everything a *list*
    /// needs is on the snapshot stream instead; this is the on-demand check.
    public func status(id: String) throws -> SessionStatus {
        var status = try worktreeStatus(id: id)
        let changes = try call("ChangeSummary", Args(id: id))
        if changes.ok == true {
            status.filesChanged = changes.files ?? 0
            status.unpushedCommits = changes.commits ?? 0
        }
        return status
    }

    /// Recreates the session's tmux session and relaunches its agent if the
    /// tmux session is gone — `OpenSession` minus the terminal tab. The only
    /// way this app starts a session back up: `OpenSession` itself is never
    /// sent, since nothing here hands a session to another terminal app.
    /// A no-op on a live session; returns a hint the caller should surface.
    @discardableResult
    public func ensureTmux(id: String) throws -> String {
        try call("EnsureTmux", Args(id: id)).hint ?? ""
    }

    /// Every tile in one call — the core batches it into a single tmux
    /// invocation, so splitting this up buys nothing and costs a process each.
    /// Keyed by session id; no front end needs a tmux session name.
    public func capture(ids: [String]) throws -> [String: String] {
        try call("Capture", Args(ids: ids)).screens ?? [:]
    }

    /// The session's changes against its merge base, untracked files included —
    /// what `Review` shows in tmux, as text. Needs no tmux, so a parked session
    /// answers too. nil when the worktree is not a git repo (`ok=false`).
    public func diff(id: String) throws -> (patch: String, base: String, truncated: Bool)? {
        let result: CallResult
        do {
            result = try call("Diff", Args(id: id))
        } catch let Failure.server(message) where message.hasPrefix("unknown method") {
            throw Failure.server("this moomux core is too old to show diffs — upgrade it")
        }
        guard result.ok == true else { return nil }
        // Every field is `omitempty`: no `patch` is a clean worktree.
        return (result.patch ?? "", result.base ?? "", result.truncated ?? false)
    }

    /// Opens the review window in the session's tmux, reusing an existing one.
    /// The base branch is resolved core-side — session's own, then the
    /// project's, then `main` — so nothing is passed for it here.
    @discardableResult
    public func review(id: String) throws -> String {
        try call("Review", Args(id: id)).hint ?? ""
    }

    // MARK: - Mutations
    //
    // Ordered as `internal/ipc/server.go` dispatches them, so the two files
    // diff against each other. The `Session` the setters answer with is thrown
    // away on purpose: `AppState.mutate` reloads everything a beat later, and
    // splicing one row in by hand would be a second source of truth.

    /// The whole "new session" transaction in one call: a worktree and a
    /// branch, the worktree-create userscripts, a tmux session with the agent
    /// in it, the PR tag, and the composed first prompt typed into the pane.
    /// Tens of seconds, and the only call here that is.
    ///
    /// Returns the new session plus the server's hint — userscript warnings,
    /// "attach with: tmux attach -t …", and any step that degraded *after* the
    /// pane existed (a PR tag or a first prompt that didn't land). Those are
    /// guidance, never a failed create: the session is real from the pane on.
    ///
    /// Every empty field means "the core decides": an empty `agent` takes the
    /// project's, an empty `baseBranch` the project's base, an empty
    /// `model`/`thinking` passes no flag at all.
    public func createSession(_ req: CreateRequest) throws -> (Session, String) {
        let result = try call("CreateSession", Args(req: req))
        guard let session = result.session else { throw Failure.emptyResponse }
        return (session, result.hint ?? "")
    }

    /// Kills tmux, removes the worktree and runs the worktree-delete
    /// userscripts. The hint is those scripts' warnings, not an error.
    @discardableResult
    public func deleteSession(id: String) throws -> String {
        try call("DeleteSession", Args(id: id)).hint ?? ""
    }

    /// Resizes a live attach's pty in place, so a size change on the phone is
    /// a SIGWINCH for tmux rather than a new connection. Throws on a core that
    /// does not know the method or the token; the caller falls back to
    /// reattaching.
    public func resizeAttach(token: String, cols: Int, rows: Int) throws {
        var args = Args()
        args.attach = token
        args.cols = max(1, cols)
        args.rows = max(1, rows)
        try call("ResizeAttach", args)
    }

    /// The core machine's Ghostty config text, for a pane with no config files
    /// of its own to read — the phone's. Empty when the core has none; nil
    /// from a core too old to serve it, which is not an error to show: the
    /// pane just keeps its built-in look.
    public func ghosttyConfig() throws -> String? {
        do {
            return try call("GhosttyConfig").ghostty?.text ?? ""
        } catch let Failure.server(message) where message.hasPrefix("unknown method") {
            return nil
        }
    }

    /// Leaves the worktree and the session record; only the tmux server side goes.
    public func killTmux(id: String) throws {
        try call("KillTmux", Args(id: id))
    }

    public func rename(id: String, to name: String) throws {
        try call("RenameSession", Args(id: id, name: name))
    }

    /// An empty ticket or PR is how a tag gets cleared, so both are sent as
    /// typed rather than mapped to nil.
    public func setTags(id: String, ticket: String, pr: String) throws {
        try call("SetSessionTags", Args(id: id, ticket: ticket, pr: pr))
    }

    public func setArchived(id: String, _ archived: Bool) throws {
        try call("SetSessionArchived", Args(id: id, on: archived))
    }

    /// Switches which agent CLI a session launches, from its next open onward —
    /// a running pane keeps whatever it started. `dangerous` is always explicit
    /// here (the server reads a nil as false), because the agent and its
    /// permission flag are one choice.
    public func setAgent(id: String, agent: String, dangerous: Bool) throws {
        try call("SetSessionAgent", Args(id: id, agent: agent, dangerous: dangerous))
    }

    /// The project's whole session order, as this app is displaying it —
    /// hidden and archived rows included.
    ///
    /// Not a session plus a delta (`MoveSession`, which the core keeps only as
    /// a deprecated shim for this app): the core would have to re-derive the
    /// sibling order from a list a client may be filtering differently, and two
    /// quick moves could complete out of order and revert one another. Ids left
    /// out keep a stale `Order` that then interleaves with the renumbered ones,
    /// which is why `Layout.reorder` returns the whole project.
    public func reorderSessions(_ ids: [String]) throws {
        try call("ReorderSessions", Args(ids: ids))
    }

    // MARK: - Folders
    //
    // The split the core makes: a folder's display state lives in config under
    // `Config.folders` — one flat *global* namespace, which is why none of
    // these takes a project — and its membership on each session. So a rename
    // or a delete rewrites both, in every project, and `SetSessionFolder` is
    // the one session mutator that also creates a folder.

    /// An empty `folder` files the session back at the top level. A name that
    /// does not exist yet is created by this call.
    public func setSessionFolder(id: String, folder: String) throws {
        try call("SetSessionFolder", Args(id: id, name: folder))
    }

    /// Refused if any project is already using the name — the namespace is
    /// global, so a second `auth` is a collision rather than a second folder.
    public func createFolder(name: String) throws {
        try call("CreateFolder", Args(name: name))
    }

    public func renameFolder(from old: String, to new: String) throws {
        try call("RenameFolder", Args(name: old, newName: new))
    }

    /// Deletes the folder and files every member back at the top level; no
    /// session is removed.
    public func deleteFolder(name: String) throws {
        try call("DeleteFolder", Args(name: name))
    }

    public func setFolderCollapsed(name: String, _ on: Bool) throws {
        try call("SetFolderCollapsed", Args(name: name, on: on))
    }

    /// Whether the project's own sidebar group is folded away. Display state,
    /// but config: the choice survives a restart and every front end sees it.
    public func setProjectCollapsed(project: String, _ on: Bool) throws {
        try call("SetProjectCollapsed", Args(project: project, on: on))
    }

    // MARK: - Projects

    /// Requires `p.repo` to already be a git repository: it throws
    /// `.notGitRepo` otherwise, which is the caller's cue to offer
    /// `initProjectAndAdd` or `addPlainProject` — not to report a failure.
    public func addProject(name: String, _ p: Project) throws {
        try call("AddProject", Args(name: name, proj: p))
    }

    /// `mkdir -p`, `git init` on the project's base branch, one empty commit,
    /// then saves the project as a git one.
    public func initProjectAndAdd(name: String, _ p: Project) throws {
        try call("InitProjectAndAdd", Args(name: name, proj: p))
    }

    /// A non-git project: sessions run directly in the folder, with no
    /// branches and no worktrees. The core clears base branch and branch
    /// prefix itself.
    public func addPlainProject(name: String, _ p: Project) throws {
        try call("AddPlainProject", Args(name: name, proj: p))
    }

    /// The project's kind is not editable — the core keeps the existing one and
    /// refuses a worktree-mode flip while the project still has sessions.
    public func updateProject(name: String, _ p: Project) throws {
        try call("UpdateProject", Args(name: name, proj: p))
    }

    /// Config only: the repository and every worktree on disk are left alone.
    /// The core refuses while the project still has sessions, archived ones
    /// included.
    public func removeProject(name: String) throws {
        try call("RemoveProject", Args(name: name))
    }

    public func moveProject(name: String, delta: Int) throws {
        try call("MoveProject", Args(name: name, delta: delta))
    }

    // MARK: - Settings

    /// The TUI's palette and its light/dark override — this app draws itself
    /// with semantic colors and ignores both. Here because it is the same
    /// config file, and a front end that can edit projects but not the theme
    /// would be an odd place to stop.
    public func setTheme(_ theme: String, appearance: String) throws {
        try call("SetTheme", Args(theme: theme, appearance: appearance))
    }

    public func setAutoSubmitDefault(_ on: Bool) throws {
        try call("SetAutoSubmitDefault", Args(on: on))
    }

    public func setSortRecentFirst(_ on: Bool) throws {
        try call("SetSortRecentFirst", Args(on: on))
    }

    public func setAutoTmux(_ on: Bool) throws {
        try call("SetAutoTmux", Args(on: on))
    }

    /// `on` keeps the shell pane beside the agent; the config stores it negated.
    public func setTerminalPane(_ on: Bool) throws {
        try call("SetTerminalPane", Args(on: on))
    }

    // MARK: - Status stream

    /// Yields a snapshot per tick until the connection drops, then finishes
    /// throwing. Reconnecting is the caller's job — see `AppState.watchLoop`,
    /// which mirrors `ipc.Client.Run`.
    ///
    /// This is the whole render path: sessions in display order, and a view per
    /// session carrying state, label, quip, prompt, git and PR status. Nothing
    /// on it is polled for, and nothing on it is re-derived here.
    public func watch() -> AsyncThrowingStream<Snapshot, Error> {
        AsyncThrowingStream { continuation in
            let holder = SocketHolder()
            // Closing the fd is what unblocks the read; cancelling the task is
            // not enough, since `bytes.lines` is parked inside read(2).
            continuation.onTermination = { _ in holder.close() }
            Task.detached { [endpoint, live] in
                do {
                    let socket = try endpoint.connect()
                    guard holder.adopt(socket) else { return continuation.finish() }
                    live.adopt(socket)
                    defer { live.drop(socket) }
                    // Newline-terminated and *not* half-closed: `nudge()`
                    // writes on this connection later, so its write half has
                    // to stay open and the newline is what ends the request.
                    try socket.write(Wire.lineEncoded(Request(method: "Watch")))
                    for try await line in socket.lines {
                        guard !line.isEmpty else { continue }
                        continuation.yield(
                            try Wire.decoder.decode(Snapshot.self, from: Data(line.utf8)))
                    }
                    // The server only stops sending when it goes away.
                    continuation.finish(throwing: Failure.disconnected)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Asks the core for a snapshot now rather than at its next tick — the
    /// client's half of the `Watch` stream (`ipc.nudgeRequest`). For the
    /// moments where waiting out the interval is visible: a session just
    /// created, renamed, archived or parked.
    ///
    /// Best effort by design. No stream open, or one the server has already
    /// hung up on, just means the next tick does the job — which is also why
    /// this neither blocks nor throws, and can be called from the main actor.
    public func nudge() {
        live.nudge()
    }

    /// The live stream's socket, shared between the detached task that owns it
    /// and whoever calls `nudge()`.
    ///
    /// Cleared by identity rather than unconditionally: a stream that ends
    /// after its replacement has already connected must not take the new
    /// connection's socket down with it.
    private final class LiveWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var socket: StreamSocket?

        func adopt(_ socket: StreamSocket) { lock.withLock { self.socket = socket } }

        func drop(_ socket: StreamSocket) {
            lock.withLock { if self.socket === socket { self.socket = nil } }
        }

        func nudge() {
            guard let socket = lock.withLock({ socket }) else { return }
            try? socket.write(Data(#"{"nudge":true}"#.utf8))
        }
    }

    /// Bridges "the stream was torn down" to "close the fd", including the race
    /// where termination lands before the connect finishes.
    private final class SocketHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var socket: StreamSocket?
        private var closed = false

        /// Takes ownership. Returns false if close already happened, in which
        /// case the socket is closed here and the caller should give up.
        func adopt(_ socket: StreamSocket) -> Bool {
            lock.withLock {
                if closed {
                    socket.close()
                    return false
                }
                self.socket = socket
                return true
            }
        }

        func close() {
            let socket: StreamSocket? = lock.withLock {
                closed = true
                defer { self.socket = nil }
                return self.socket
            }
            socket?.close()
        }
    }

    // MARK: Checks

    public static func demo() {
        // `Watch` is the one request that is not a `call()`, so it is pinned
        // straight off the encoder. Unset args must vanish, not serialize as
        // null: the stream is dispatched on method alone.
        let watch = String(decoding: try! JSONEncoder().encode(Request(method: "Watch")), as: UTF8.self)
        assert(watch == #"{"method":"Watch"}"#, watch)

        var summary = SessionStatus(known: true, dirty: true, unpushed: true,
                                    filesChanged: 3, unpushedCommits: 1)
        assert(summary.changeSummary == "3 files changed, 1 commit unpushed", summary.changeSummary)
        summary = SessionStatus(known: true, dirty: true, unpushed: false)
        assert(summary.changeSummary == "uncommitted changes", summary.changeSummary)
        assert(SessionStatus(known: true).changeSummary.isEmpty, "a clean worktree says nothing")

        callsDemo()
    }

    /// Every call, through the real `call()` against `FakeCore`: the method
    /// name and argument mapping in each wrapper, the half-close, and the error
    /// mapping. A wrapper that sends the wrong method or puts a value in the
    /// wrong key is silent on both sides — Go ignores the unknown key and uses
    /// the zero value — so each request is pinned whole.
    private static func callsDemo() {
        let core = FakeCore()
        let client = MoomuxClient(socketPath: core.path)

        func expect(_ want: String, answer: String = #"{"result":{}}"#,
                    file: StaticString = #file, line: UInt = #line, _ body: () throws -> Void) {
            let sent = core.requests(answering: answer) {
                do { try body() } catch { assertionFailure("\(error)", file: file, line: line) }
            }
            assert(sent == want, sent, file: file, line: line)
        }
        // `assert`'s autoclosure cannot throw; an ordinary argument can.
        func check(_ ok: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
            assert(ok, message, file: file, line: line)
        }
        func refused(_ answer: String, file: StaticString = #file, line: UInt = #line,
                     _ body: () throws -> Void) -> Failure? {
            var caught: Failure?
            _ = core.requests(answering: answer) {
                do { try body() } catch let f as Failure { caught = f } catch {
                    assertionFailure("not a Failure: \(error)", file: file, line: line)
                }
            }
            return caught
        }

        // MARK: Reads

        expect(#"{"method":"Config"}"#,
               answer: #"{"result":{"cfg":{"order":["a"]},"project_emoji":{"a":"🐄"}}}"#) {
            let (cfg, emoji) = try client.config()
            assert(cfg.order == ["a"] && emoji == ["a": "🐄"])
        }
        expect(#"{"method":"AgentOptions"}"#, answer: """
            {"result":{"agents":[{"name":"claude","models":["default","opus"],"thinking":["default","ultrathink"]}]}}
            """) {
            check(try client.agentOptions().first?.thinking == ["default", "ultrathink"])
        }
        expect(#"{"method":"Themes"}"#) { check(try client.themes().isEmpty) }
        expect(#"{"method":"Sessions"}"#,
               answer: #"{"result":{"sessions":[{"id":"p:a","name":"a","project":"p"}]}}"#) {
            check(try client.sessions().map(\.id) == ["p:a"])
        }

        // An upload's bytes go as base64, which is what Go's []byte decodes.
        expect(#"{"args":{"data":"AAH/","name":"a.png"},"method":"SaveFile"}"#,
               answer: #"{"result":{"path":"/tmp/moomux-images/ab-a.png"}}"#) {
            check(try client.saveFile(name: "a.png", data: Data([0, 1, 0xff])) == "/tmp/moomux-images/ab-a.png")
        }
        // No `data` key is an empty file: Go's omitempty drops a zero-length []byte.
        expect(#"{"args":{"id":"s1","path":"a.txt"},"method":"ReadFile"}"#,
               answer: #"{"result":{"path":"/w/a.txt"}}"#) {
            let file = try client.readFile(id: "s1", path: "a.txt")
            assert(file.path == "/w/a.txt" && file.data.isEmpty)
        }
        expect(#"{"args":{"id":"s1","path":"a.txt"},"method":"ResolveFile"}"#,
               answer: #"{"result":{"path":"/w/a.txt"}}"#) {
            check(try client.resolveFile(id: "s1", path: "a.txt") == "/w/a.txt")
        }

        // Two round trips, and an absent field must not read as a zero:
        // `unpushed` was never sent, so it is false rather than guessed.
        expect(#"{"args":{"id":"s1"},"method":"WorktreeStatus"}"# + "\n"
               + #"{"args":{"id":"s1"},"method":"ChangeSummary"}"#,
               answer: #"{"result":{"ok":true,"dirty":true,"files":3,"commits":2}}"#) {
            check(try client.status(id: "s1") == SessionStatus(
                known: true, dirty: true, unpushed: false, filesChanged: 3, unpushedCommits: 2))
        }
        // "We asked and the core does not know" — the delete dialog's guard
        // must never read that as clean.
        expect(#"{"args":{"id":"s1"},"method":"WorktreeStatus"}"#) {
            check(try client.worktreeStatus(id: "s1").known == false)
        }

        expect(#"{"args":{"id":"s1"},"method":"EnsureTmux"}"#, answer: #"{"result":{"hint":"revived"}}"#) {
            check(try client.ensureTmux(id: "s1") == "revived")
        }
        expect(#"{"args":{"ids":["a","b"]},"method":"Capture"}"#, answer: #"{"result":{"screens":{"a":"$ "}}}"#) {
            check(try client.capture(ids: ["a", "b"]) == ["a": "$ "])
        }
        expect(#"{"args":{"id":"s1"},"method":"Diff"}"#,
               answer: #"{"result":{"ok":true,"patch":"diff --git","base":"main"}}"#) {
            let diff = try client.diff(id: "s1")
            assert(diff?.patch == "diff --git" && diff?.base == "main" && diff?.truncated == false)
        }
        expect(#"{"args":{"id":"s1"},"method":"Diff"}"#) {
            check(try client.diff(id: "s1") == nil, "ok=false is a non-git worktree, not an empty diff")
        }
        expect(#"{"args":{"id":"s1"},"method":"Review"}"#) { check(try client.review(id: "s1") == "") }

        expect(#"{"method":"GhosttyConfig"}"#, answer: #"{"result":{"ghostty":{"text":"font-size = 13\n"}}}"#) {
            check(try client.ghosttyConfig() == "font-size = 13\n")
        }
        expect(#"{"method":"GhosttyConfig"}"#) {
            check(try client.ghosttyConfig() == "", "no config is empty, not absent")
        }
        // A core too old to serve it is not an error: the pane keeps its built-in look.
        expect(#"{"method":"GhosttyConfig"}"#, answer: #"{"err":"unknown method \"GhosttyConfig\""}"#) {
            check(try client.ghosttyConfig() == nil)
        }

        // MARK: Session writes

        // A create rides entirely inside `req`. `Dangerous` is spelled out
        // because this app's form asks; nil would mean "the project's
        // default", a different answer — how a `dangerous` project once got
        // sessions without the flag. `Wire.demo` pins every key's spelling.
        expect(#"{"args":{"req":{"Agent":"","AutoSubmit":false,"BaseBranch":"","#
               + #""Branch":"","Dangerous":false,"Model":"","Name":"macos","PR":"","#
               + #""Project":"moomux","Prompt":"","Thinking":"","Ticket":""}},"#
               + #""method":"CreateSession"}"#,
               answer: #"{"result":{"session":{"id":"moomux:macos","name":"macos","project":"moomux"},"hint":"h"}}"#) {
            let (session, hint) = try client.createSession(CreateRequest(project: "moomux", name: "macos", dangerous: false))
            assert(session.id == "moomux:macos" && hint == "h")
        }
        expect(#"{"args":{"id":"s1"},"method":"DeleteSession"}"#) { try client.deleteSession(id: "s1") }
        // A pty is never smaller than 1x1; the core reads a zero as 80x24.
        expect(#"{"args":{"attach":"t0","cols":1,"rows":1},"method":"ResizeAttach"}"#) {
            try client.resizeAttach(token: "t0", cols: 0, rows: -3)
        }
        expect(#"{"args":{"id":"s1"},"method":"KillTmux"}"#) { try client.killTmux(id: "s1") }
        expect(#"{"args":{"id":"s1","name":"new"},"method":"RenameSession"}"#) { try client.rename(id: "s1", to: "new") }
        // An empty tag is how a tag is cleared, so it goes over as "".
        expect(#"{"args":{"id":"s1","pr":"","ticket":"T-1"},"method":"SetSessionTags"}"#) {
            try client.setTags(id: "s1", ticket: "T-1", pr: "")
        }
        expect(#"{"args":{"id":"s1","on":false},"method":"SetSessionArchived"}"#) { try client.setArchived(id: "s1", false) }
        // `dangerous:false` explicit: the agent and its permission flag are one choice.
        expect(#"{"args":{"agent":"codex","dangerous":false,"id":"s1"},"method":"SetSessionAgent"}"#) {
            try client.setAgent(id: "s1", agent: "codex", dangerous: false)
        }
        // The project's whole resulting order, never a delta.
        expect(#"{"args":{"ids":["a","b"]},"method":"ReorderSessions"}"#) { try client.reorderSessions(["a", "b"]) }

        // MARK: Folders — global, so no `project` key on any of them

        // An empty folder un-files the session, so "" must reach the core.
        expect(#"{"args":{"id":"s1","name":""},"method":"SetSessionFolder"}"#) { try client.setSessionFolder(id: "s1", folder: "") }
        expect(#"{"args":{"name":"wip"},"method":"CreateFolder"}"#) { try client.createFolder(name: "wip") }
        expect(#"{"args":{"name":"wip","new_name":"done"},"method":"RenameFolder"}"#) { try client.renameFolder(from: "wip", to: "done") }
        expect(#"{"args":{"name":"wip"},"method":"DeleteFolder"}"#) { try client.deleteFolder(name: "wip") }
        expect(#"{"args":{"name":"wip","on":true},"method":"SetFolderCollapsed"}"#) { try client.setFolderCollapsed(name: "wip", true) }
        expect(#"{"args":{"on":false,"project":"p"},"method":"SetProjectCollapsed"}"#) {
            try client.setProjectCollapsed(project: "p", false)
        }

        // MARK: Projects — a whole config.Project in `proj`, encoded by `Project`

        let site = Project(repo: "/src/site", baseBranch: "main")
        let proj = #""proj":{"base_branch":"main","collapsed":false,"dangerous":false,"#
            + #""no_worktree":false,"prompt_agent":false,"repo":"/src/site"}"#
        expect(#"{"args":{"name":"site","# + proj + #"},"method":"AddProject"}"#) { try client.addProject(name: "site", site) }
        expect(#"{"args":{"name":"site","# + proj + #"},"method":"InitProjectAndAdd"}"#) { try client.initProjectAndAdd(name: "site", site) }
        expect(#"{"args":{"name":"site","# + proj + #"},"method":"AddPlainProject"}"#) { try client.addPlainProject(name: "site", site) }
        expect(#"{"args":{"name":"site","# + proj + #"},"method":"UpdateProject"}"#) { try client.updateProject(name: "site", site) }
        expect(#"{"args":{"name":"site"},"method":"RemoveProject"}"#) { try client.removeProject(name: "site") }
        expect(#"{"args":{"delta":-1,"name":"site"},"method":"MoveProject"}"#) { try client.moveProject(name: "site", delta: -1) }

        // MARK: Settings — `on:false` must arrive, not vanish as unset

        expect(#"{"args":{"appearance":"","theme":"gruvbox"},"method":"SetTheme"}"#) { try client.setTheme("gruvbox", appearance: "") }
        expect(#"{"args":{"on":true},"method":"SetAutoSubmitDefault"}"#) { try client.setAutoSubmitDefault(true) }
        expect(#"{"args":{"on":false},"method":"SetSortRecentFirst"}"#) { try client.setSortRecentFirst(false) }
        expect(#"{"args":{"on":true},"method":"SetAutoTmux"}"#) { try client.setAutoTmux(true) }
        expect(#"{"args":{"on":false},"method":"SetTerminalPane"}"#) { try client.setTerminalPane(false) }

        // MARK: Failures

        // A server error must throw, never read as "no sessions" — one nil
        // list would look like every session was deleted.
        if case .server("tmux: no server running")? = refused(#"{"result":{},"err":"tmux: no server running","code":""}"#, {
            _ = try client.sessions()
        }) {} else { assertionFailure("a server error must surface") }
        // `code` is how the one question-shaped error survives the round trip.
        if case .notGitRepo? = refused(#"{"err":"/tmp/x: not a git repository","code":"not_git_repo"}"#, {
            try client.addProject(name: "x", Project(repo: "/tmp/x"))
        }) {} else { assertionFailure("not_git_repo must map to .notGitRepo") }
        // A closed connection with no answer is a failure, not an empty result.
        if case .emptyResponse? = refused("", { _ = try client.sessions() }) {} else {
            assertionFailure("no answer must be .emptyResponse")
        }
        if case .emptyResponse? = refused(#"{"result":{}}"#, {
            _ = try client.createSession(CreateRequest(project: "p", name: "n"))
        }) {} else { assertionFailure("a create with no session is not a success") }
        // An old core's "unknown method" is reworded into something a user can act on.
        for (method, call) in [("SaveFile", { _ = try client.saveFile(name: "a", data: Data()) }),
                               ("ReadFile", { _ = try client.readFile(id: "s", path: "a") }),
                               ("ResolveFile", { _ = try client.resolveFile(id: "s", path: "a") }),
                               ("Diff", { _ = try client.diff(id: "s") })] as [(String, () throws -> Void)] {
            if case let .server(message)? = refused(#"{"err":"unknown method \"\#(method)\""}"#, call) {
                assert(message.contains("too old"), message)
            } else { assertionFailure("\(method): unknown method must be reworded") }
        }

        // MARK: The status stream

        // One snapshot per line, blank lines skipped; a `nudge()` lands on the
        // open connection; and the server hanging up ends the stream with
        // `.disconnected` rather than a quiet finish, which is what tells
        // `AppState.watchLoop` to reconnect.
        final class Seen: @unchecked Sendable {
            var snapshots: [Snapshot] = []
            var nudge = ""
            var end: Error?
        }
        let seen = Seen()
        core.on("Watch") { socket in
            try? socket.write(Data((#"{"views":{},"sessions":[{"id":"p:a","name":"a","project":"p"}]}"#
                                    + "\n\n").utf8))
            seen.nudge = String(decoding: (try? socket.readChunk()) ?? Data(), as: UTF8.self)
            // `null` is an answer — a core with no sessions — not an old core.
            try? socket.write(Data((#"{"views":null}"# + "\n").utf8))
        }
        let ended = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                for try await snapshot in client.watch() {
                    seen.snapshots.append(snapshot)
                    if seen.snapshots.count == 1 { client.nudge() }
                }
            } catch { seen.end = error }
            ended.signal()
        }
        assert(ended.wait(timeout: .now() + 3) == .success, "a stream the server closed must end")
        assert(seen.snapshots.map(\.sessions.count) == [1, 0], "\(seen.snapshots.map(\.sessions))")
        assert(seen.snapshots.allSatisfy(\.derived))
        assert(seen.nudge == #"{"nudge":true}"#, seen.nudge)
        if case .disconnected? = seen.end as? Failure {} else {
            assertionFailure("a closed stream must throw .disconnected, got \(String(describing: seen.end))")
        }
        // With no stream open, a nudge is a no-op rather than an error or a hang.
        client.nudge()
    }
}
