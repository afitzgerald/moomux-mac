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

        public var errorDescription: String? {
            switch self {
            case let .server(message): return message
            case let .notGitRepo(message): return message
            case .emptyResponse: return "the server closed the connection without answering"
            case .disconnected: return "the status stream ended"
            }
        }
    }

    public let socketPath: String

    /// The `Watch` connection currently open, so `nudge()` can write on it.
    private let live = LiveWatch()

    public init(socketPath: String = MoomuxClient.defaultSocketPath) {
        self.socketPath = socketPath
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
        var name: String?
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

        // Every `ipc.Args` key this app sends already matches its property
        // name. A missing entry here would be invisible in both directions —
        // Go ignores the unknown key and uses the zero value.
        enum CodingKeys: String, CodingKey {
            case id, name, agent, ticket, pr, delta, dangerous, on, theme, appearance, req, proj
        }
    }

    private struct Request: Encodable {
        let method: String
        var args: Args?
    }

    /// `ipc.Result` plus the error fields, all optional — one union type, the
    /// same trade the Go side makes.
    private struct Response: Decodable {
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
        var hint: String?
        var ok: Bool?
        var dirty: Bool?
        var unpushed: Bool?
        var files: Int?
        var commits: Int?
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
        let socket = try UnixSocket(path: socketPath)
        defer { socket.close() }
        try socket.write(Wire.encoder.encode(Request(method: method, args: args)))
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

    public func config() throws -> Config {
        guard let cfg = try call("Config").cfg else { throw Failure.emptyResponse }
        return cfg
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

    /// Attaches the session in the user's terminal. Returns the server's hint —
    /// a user-facing instruction such as "run: tmux attach -t …", not an error.
    @discardableResult
    public func openSession(id: String) throws -> String {
        try call("OpenSession", Args(id: id)).hint ?? ""
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

    /// ±1, within the project group. A move off either end is a no-op on the Go
    /// side rather than an error.
    public func move(id: String, delta: Int) throws {
        try call("MoveSession", Args(id: id, delta: delta))
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
            Task.detached { [socketPath, live] in
                do {
                    let socket = try UnixSocket(path: socketPath)
                    guard holder.adopt(socket) else { return continuation.finish() }
                    live.adopt(socket)
                    defer { live.drop(socket) }
                    try socket.write(Wire.encoder.encode(Request(method: "Watch")))
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
        private var socket: UnixSocket?

        func adopt(_ socket: UnixSocket) { lock.withLock { self.socket = socket } }

        func drop(_ socket: UnixSocket) {
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
        private var socket: UnixSocket?
        private var closed = false

        /// Takes ownership. Returns false if close already happened, in which
        /// case the socket is closed here and the caller should give up.
        func adopt(_ socket: UnixSocket) -> Bool {
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
            let socket: UnixSocket? = lock.withLock {
                closed = true
                defer { self.socket = nil }
                return self.socket
            }
            socket?.close()
        }
    }

    // MARK: Checks

    public static func demo() {
        let encoder = JSONEncoder()
        // `.withoutEscapingSlashes` only so a path in an expected literal below
        // reads as a path; the shipping encoder writes "\/" and Go is indifferent.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        // Unset args must vanish, not serialize as null: the Go side decodes
        // into a struct union where an explicit null is fine but an unexpected
        // key is not, and `Watch` is dispatched on method alone.
        let watch = String(decoding: try! encoder.encode(Request(method: "Watch")), as: UTF8.self)
        assert(watch == #"{"method":"Watch"}"#, watch)

        let open = String(
            decoding: try! encoder.encode(Request(method: "OpenSession", args: Args(id: "s1"))),
            as: UTF8.self)
        assert(open == #"{"args":{"id":"s1"},"method":"OpenSession"}"#, open)

        // An empty tag is how a tag is cleared, so it has to go over the wire
        // as "" rather than being dropped — and every field nobody set must be
        // absent, never null.
        let tags = String(
            decoding: try! encoder.encode(
                Request(method: "SetSessionTags", args: Args(id: "s1", ticket: "T-1", pr: ""))),
            as: UTF8.self)
        assert(tags == #"{"args":{"id":"s1","pr":"","ticket":"T-1"},"method":"SetSessionTags"}"#, tags)
        assert(!tags.contains("name"), "unset fields must vanish")

        // Unarchiving sends `on:false` explicitly. Go's omitempty would drop it
        // and the zero value is the same false, so both spellings are correct —
        // this pins which one we send, so a reader isn't left guessing.
        let unarchive = String(
            decoding: try! encoder.encode(
                Request(method: "SetSessionArchived", args: Args(id: "s1", on: false))),
            as: UTF8.self)
        assert(unarchive == #"{"args":{"id":"s1","on":false},"method":"SetSessionArchived"}"#, unarchive)

        // A create rides entirely inside `req` — one transaction the core runs
        // end to end, rather than a dozen flat args and five follow-up calls.
        // `Dangerous` is spelled out because this app's form asks; leaving it
        // nil would mean "the project's default", which is a different answer.
        let create = String(
            decoding: try! encoder.encode(Request(method: "CreateSession", args: Args(
                req: CreateRequest(project: "moomux", name: "macos", dangerous: false)))),
            as: UTF8.self)
        assert(create == #"{"args":{"req":{"Agent":"","AutoSubmit":false,"BaseBranch":"","#
               + #""Branch":"","Dangerous":false,"Model":"","Name":"macos","PR":"","#
               + #""Project":"moomux","Prompt":"","Thinking":"","Ticket":""}},"#
               + #""method":"CreateSession"}"#, create)

        // A whole config.Project rides in `proj`, encoded by `Project` itself.
        let addProject = String(
            decoding: try! encoder.encode(Request(method: "AddProject", args: Args(
                name: "site", proj: Project(repo: "/src/site", baseBranch: "main")))),
            as: UTF8.self)
        assert(addProject == #"{"args":{"name":"site","proj":{"base_branch":"main","#
               + #""dangerous":false,"no_worktree":false,"prompt_agent":false,"#
               + #""repo":"/src/site"}},"method":"AddProject"}"#, addProject)

        // The theme call is the only one sending both of these, and clearing
        // the appearance override means sending "" rather than dropping it.
        let theme = String(
            decoding: try! encoder.encode(
                Request(method: "SetTheme", args: Args(theme: "gruvbox", appearance: ""))),
            as: UTF8.self)
        assert(theme == #"{"args":{"appearance":"","theme":"gruvbox"},"method":"SetTheme"}"#, theme)

        // A mutating call answers with the updated session, not a bare ok.
        let renamed = #"{"result":{"session":{"id":"p:new","name":"new","project":"p"}}}"#
        let rr = try! Wire.decoder.decode(Response.self, from: Data(renamed.utf8))
        assert(rr.result?.session?.name == "new")

        // A server-side error arrives as a string beside an empty result; it
        // must surface as a thrown error rather than as "no sessions".
        let failed = """
        {"result":{},"err":"tmux: no server running","code":""}
        """
        let response = try! Wire.decoder.decode(Response.self, from: Data(failed.utf8))
        assert(response.err == "tmux: no server running")
        assert(response.result?.sessions == nil)

        // `code` is how a sentinel survives the round trip, and this one is a
        // question rather than a failure: "not a git repo" is what the app
        // answers with "init one" or "add it as a plain folder". Without the
        // code it would be an unactionable error string, exactly as it would be
        // for the TUI.
        let notRepo = try! Wire.decoder.decode(
            Response.self,
            from: Data(#"{"err":"/tmp/x: not a git repository","code":"not_git_repo"}"#.utf8))
        assert(notRepo.code == "not_git_repo")

        // The agent table, as `AgentOptions` answers it.
        let agentsJSON = """
        {"result":{"agents":[{"name":"claude","models":["default","opus"],
                              "thinking":["default","ultrathink"]}]}}
        """
        let served = try! Wire.decoder.decode(Response.self, from: Data(agentsJSON.utf8))
        assert(served.result?.agents?.count == 1)
        assert(served.result?.agents?.first?.thinking == ["default", "ultrathink"])

        // The status calls share one Result union, so an absent field must not
        // read as a zero: `ok:false` with no counts means "don't know", which
        // is different from "clean".
        let statusJSON = #"{"result":{"dirty":true,"ok":true,"files":3,"commits":2}}"#
        let st = try! Wire.decoder.decode(Response.self, from: Data(statusJSON.utf8))
        assert(st.result?.dirty == true)
        assert(st.result?.unpushed == nil, "omitempty means absent, not false")
        assert(st.result?.files == 3 && st.result?.commits == 2)

        var summary = SessionStatus(known: true, dirty: true, unpushed: true,
                                    filesChanged: 3, unpushedCommits: 1)
        assert(summary.changeSummary == "3 files changed, 1 commit unpushed", summary.changeSummary)
        summary = SessionStatus(known: true, dirty: true, unpushed: false)
        assert(summary.changeSummary == "uncommitted changes", summary.changeSummary)
        assert(SessionStatus(known: true).changeSummary.isEmpty, "a clean worktree says nothing")

        // A plain successful call: no error, and the fields it did not fill
        // stay nil rather than reading as zeros.
        let good = try! Wire.decoder.decode(
            Response.self, from: Data(#"{"result":{"hint":"attach with: tmux attach -t x"}}"#.utf8))
        assert(good.err == nil)
        assert(good.result?.hint == "attach with: tmux attach -t x")
        assert(good.result?.sessions == nil)
    }
}
