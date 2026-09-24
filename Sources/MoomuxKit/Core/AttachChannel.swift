import Foundation

/// A live `tmux attach`, as a socket that stops speaking JSON.
///
/// `Attach` is the one method where the connection *becomes* the thing: one
/// request line, one `{"result":{"ok":true}}` line back, and from there raw pty
/// bytes both directions until somebody closes the socket. Closing is the
/// detach — tmux loses the client and keeps the session.
///
/// This cannot go through `MoomuxClient.call`, which reads to EOF and hands the
/// lot to a decoder. **The bytes already buffered past the response line are pty
/// bytes** — the first chunk of the screen tmux drew — and a decoder that
/// swallows them leaves a pane blank until the first keystroke repaints it.
/// `splitLine` is that seam, and it is the reason this file has a `demo()`.
public final class AttachChannel: @unchecked Sendable {

    private let socket: StreamSocket
    private let writing = NSLock()
    /// Whatever arrived in the same read as the response line. Handed to the
    /// terminal before the first `read()`, or the first frame is lost.
    public let pending: Data

    /// Blocking: connects, sends the request and waits for the response line.
    /// Call it off the main actor, like every other socket call here.
    ///
    /// `cols`/`rows` are the pty's size for the lifetime of the attach. A
    /// resize means a new `AttachChannel`.
    init(endpoint: MoomuxClient.Endpoint, id: String, cols: Int, rows: Int) throws {
        socket = try endpoint.connect()
        do {
            var args = MoomuxClient.Args()
            args.id = id
            args.cols = max(1, cols)
            args.rows = max(1, rows)
            // **Newline-terminated, explicitly.** Every other method ends its
            // request at EOF — `call` closes the connection after writing, so
            // the server can read to EOF. An attach never closes its write
            // half, because that half becomes the keystroke channel, so the
            // server reads exactly one *line*. Without the `\n` it waits
            // forever and the pane hangs with no error to show.
            try socket.write(Wire.lineEncoded(
                MoomuxClient.Request(method: "Attach", args: args)))

            var buffer = Data()
            while true {
                if let (line, rest) = AttachChannel.splitLine(buffer) {
                    let response = try Wire.decoder.decode(
                        MoomuxClient.Response.self, from: line)
                    if let err = response.err, !err.isEmpty {
                        throw MoomuxClient.Failure.server(err)
                    }
                    // `ok` as well as `err`: a refusal with no words would
                    // otherwise be taken as a live attach, flip the socket to
                    // raw bytes, read empty, and dismiss the screen without
                    // saying anything.
                    guard response.result?.ok == true else {
                        throw MoomuxClient.Failure.server("attach refused")
                    }
                    pending = rest
                    return
                }
                let chunk = try socket.readChunk()
                // EOF before the response line: the core refused and closed
                // without a body, which is the only way that can look.
                guard !chunk.isEmpty else { throw MoomuxClient.Failure.emptyResponse }
                buffer.append(chunk)
            }
        } catch {
            socket.close()
            throw error
        }
    }

    /// The response line and everything after it, split at the **first**
    /// newline. Pure, so the trap this exists to avoid is checkable.
    ///
    /// `nil` means no complete line yet — keep reading. An empty remainder is
    /// not the same answer: it means the line arrived alone and the pty bytes
    /// are still to come.
    static func splitLine(_ buffer: Data) -> (line: Data, rest: Data)? {
        guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return (buffer[buffer.startIndex..<newline], buffer[buffer.index(after: newline)...])
    }

    /// Blocking. Empty means the far end closed, which is the only way an
    /// attach can fail once it has started — after `{"ok":true}` there is
    /// nowhere on the wire to put an error.
    public func read() throws -> Data { try socket.readChunk() }

    /// Keystrokes, straight onto the pty, **in the order they were typed**.
    ///
    /// Callable from any thread and deliberately not actor-isolated: hopping
    /// each keystroke through `Task { @MainActor in … }` looked harmless and
    /// was not — separate `Task`s have no ordering guarantee, so a fast
    /// sequence (held backspace, a paste, anything autorepeating) could reach
    /// the pty scrambled. The lock keeps one writer at a time and preserves
    /// the order the surface handed them over in.
    ///
    /// Failures are dropped on purpose: the read loop is what notices a dead
    /// connection, and a write racing the close should not be a second,
    /// louder error about the same event.
    public func send(_ data: Data) {
        writing.lock()
        defer { writing.unlock() }
        try? socket.write(data)
    }

    public func close() { socket.close() }

    public static func demo() {
        // The whole point of this file: the remainder is kept, not discarded.
        let both = Data(#"{"result":{"ok":true}}"#.utf8) + Data("\n\u{1b}[2Jhello".utf8)
        guard let (line, rest) = splitLine(both) else {
            return assertionFailure("a buffer containing a newline must split")
        }
        assert(String(data: line, encoding: .utf8) == #"{"result":{"ok":true}}"#)
        assert(String(data: rest, encoding: .utf8) == "\u{1b}[2Jhello",
               "the pty bytes that arrived with the response line must survive")

        // The request this client sends must carry a trailing newline, or a
        // server that reads one line never gets a complete one.
        assert(Data(#"{"method":"Attach"}"#.utf8).last != UInt8(ascii: "\n"),
               "the encoder does not add one, which is why the caller must")

        // No newline yet is "keep reading", not "empty line".
        assert(splitLine(Data(#"{"result":"#.utf8)) == nil)

        // A line that arrives alone leaves an empty remainder — distinct from
        // nil, or the caller would block waiting for a line it already has.
        guard let (_, none) = splitLine(Data("{}\n".utf8)) else {
            return assertionFailure("a complete line must split even with nothing after it")
        }
        assert(none.isEmpty)

        // Only the *first* newline splits: a pty frame is full of them.
        guard let (first, tail) = splitLine(Data("{}\nrow1\nrow2\n".utf8)) else {
            return assertionFailure("must split")
        }
        assert(String(data: first, encoding: .utf8) == "{}")
        assert(String(data: tail, encoding: .utf8) == "row1\nrow2\n")
    }
}

extension MoomuxClient {
    /// Blocking — `Task.detached`, not the main actor.
    public func attach(id: String, cols: Int, rows: Int) throws -> AttachChannel {
        try AttachChannel(endpoint: endpoint, id: id, cols: cols, rows: rows)
    }
}

/// What a resize should do to a pending attach.
///
/// Lives here, in the Kit, rather than inside the phone's terminal coordinator
/// for one reason: `Sources/MoomuxiOS` is not a SwiftPM target, so nothing
/// there can be reached by `demo()`/`--selftest` — and this is the subtle part
/// of that coordinator. `disarm` is the case that is not obvious: a size that
/// comes *back* to the attached one (a keyboard shown and dismissed inside the
/// debounce) has to cancel the settle, or it reattaches the pty to the size we
/// just left.
public enum AttachSizing: Sendable {
    /// Nothing to do: the pane is gone, or the surface has no real size yet.
    case ignore
    /// Cancel any pending settle; the attached size is already right.
    case disarm
    /// Debounce, then reattach at this size.
    case settle(columns: Int, rows: Int)

    public static func decide(columns: Int, rows: Int, attached: (Int, Int)?,
                              done: Bool) -> AttachSizing {
        guard !done, columns > 0, rows > 0 else { return .ignore }
        if let attached, attached == (columns, rows) { return .disarm }
        return .settle(columns: columns, rows: rows)
    }

    public static func demo() {
        assert(decide(columns: 62, rows: 53, attached: nil, done: false)
            == .settle(columns: 62, rows: 53))
        assert(decide(columns: 62, rows: 53, attached: (62, 53), done: false) == .disarm)
        assert(decide(columns: 62, rows: 62, attached: (62, 53), done: false)
            == .settle(columns: 62, rows: 62), "the first layout pass must not be kept")
        // A torn-down pane must never start another attach, whatever it is told.
        assert(decide(columns: 80, rows: 24, attached: nil, done: true) == .ignore)
        // A surface that has not been laid out yet has no size to attach at.
        assert(decide(columns: 0, rows: 24, attached: nil, done: false) == .ignore)
    }
}

extension AttachSizing: Equatable {}

/// What a pane does about to reattach after its link dropped.
///
/// `Attach` runs `EnsureTmux` core-side, so reattaching to a session that was
/// killed meanwhile does not fail — it **recreates** it, agent and all. So once
/// a pane has been attached, every reattach first asks whether the session is
/// still there (`alive`, from `Capture`, which omits dead sessions and revives
/// nothing; nil when the core could not be reached). Before the first attach
/// there is nothing to check against: opening a parked session is the user
/// asking for it to be revived.
public enum Reattach: Sendable, Equatable {
    case attach
    /// The core is unreachable; ask again shortly.
    case wait
    /// The session is gone; the pane's reason to exist went with it.
    case end

    public static func decide(everAttached: Bool, alive: Bool?) -> Reattach {
        guard everAttached else { return .attach }
        switch alive {
        case true?: return .attach
        case false?: return .end
        case nil: return .wait
        }
    }

    public static func demo() {
        assert(decide(everAttached: false, alive: nil) == .attach, "first open may revive")
        assert(decide(everAttached: false, alive: false) == .attach)
        assert(decide(everAttached: true, alive: true) == .attach)
        assert(decide(everAttached: true, alive: false) == .end,
               "a session killed while the link was down must not be recreated")
        assert(decide(everAttached: true, alive: nil) == .wait, "no answer is not a death")
    }
}
