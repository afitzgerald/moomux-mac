import Foundation
import GhosttyTerminal

/// A live `tmux attach` over the core's `Attach` stream, for a pane whose
/// pty is on another machine: the phone always, and the Mac when its core is
/// remote (docs/macos-vs-ios.md D25).
///
/// The host-managed `.inMemory` backend with a socket where its process would
/// be: `AttachChannel.read()` into `session.receive`, and the session's
/// `write` closure back out as keystrokes. Everything subtle about that —
/// the settled first size, resizing in place, reconnecting a dropped link
/// without reviving a killed session, keys typed across a reconnect — lives
/// here once, so both apps' panes get the same fixes. The pane's delegate
/// forwards `terminalDidResize` here and calls `teardown()` when it goes.
@MainActor
public final class RemoteAttach {
    private let client: MoomuxClient
    private let sessionID: Session.ID
    private let onEnded: () -> Void
    private var channel: AttachChannel?
    private var reader: Task<Void, Never>?
    private var settle: Task<Void, Never>?
    /// Once the pane is gone, or the far end has, this must
    /// never attach again — because `Attach` runs `EnsureTmux` core-side,
    /// so a stray reattach does not fail against a killed session, it
    /// **recreates** it. Measured: killing an attached session produced a
    /// new tmux session ~1s later under moomux's canonical name
    /// (`moomux-<name>-<hash>`), with a fresh agent in it.
    ///
    /// Not an ordinary property: the read loop runs off the main actor and
    /// has to mark this the instant it sees the socket close, before it
    /// hops to the main actor to dismiss. A pending settle task firing in
    /// that window is exactly the race that revives the session.
    private let done = Flag()

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
    private var pendingSize: Size?
    private var attachedSize: Size?
    /// Whether a channel has ever landed — from then on, every reattach
    /// checks the session is still alive first (`Reattach`).
    private var everAttached = false

    /// The live channel, reachable without the main actor.
    ///
    /// `write` below is called by the surface on whatever thread it likes,
    /// and it must not hop to an *actor*: two `Task { @MainActor … }`s have
    /// no ordering guarantee between them, so held keys and pastes could
    /// arrive at the pty out of order. A serial queue does have that
    /// guarantee, so this box is all the sharing needed.
    private let live = LiveChannel()

    final class LiveChannel: @unchecked Sendable {
        /// One serial queue is both the exclusion and the ordering, and no
        /// caller waits on it. That last part matters: the work ends in a
        /// blocking `write(2)`, so a core that stops draining would freeze
        /// the keystroke thread until the 30s keepalive fires.
        private let queue = DispatchQueue(label: "app.moomux.attach.send")
        private var channel: AttachChannel?
        /// What was typed between a `stop()` and the next channel landing.
        ///
        /// That gap is a blocking `attach` round trip — a rotation's 250ms
        /// settle plus a tailnet RTT, or 2s per `retry` cycle — and
        /// dropping it is *silent*, since `send` swallows failures by
        /// design. Capped because a core that never comes back would
        /// otherwise buffer forever; a phone's worth of held keys is far
        /// below it.
        private var buffered = Data()
        private static let limit = 4096

        /// Sent on the queue, deliberately: `AttachChannel.send` is
        /// thread-safe on its own, but ordering against the flush is not,
        /// and keystrokes arriving at the pty out of order is the bug this
        /// box exists to avoid.
        func send(_ data: Data) {
            queue.async { [self] in
                guard let channel else {
                    buffered.append(data.prefix(Self.limit - buffered.count))
                    return
                }
                channel.send(data)
            }
        }

        func install(_ channel: AttachChannel?) {
            queue.async { [self] in
                self.channel = channel
                guard let channel, !buffered.isEmpty else { return }
                channel.send(buffered)
                buffered.removeAll()
            }
        }
    }

    /// `write` is the keystroke path: the surface hands over the bytes it
    /// would have written to a pty, and they go down the socket instead.
    public private(set) lazy var session: InMemoryTerminalSession = InMemoryTerminalSession(
        write: { [live] data in live.send(data) },
        resize: { _ in }
    )

    /// `onEnded`: the far end went away for good — tmux exited, the session
    /// was killed. The pane's reason to exist went with it.
    public init(client: MoomuxClient, sessionID: Session.ID, onEnded: @escaping () -> Void) {
        self.client = client
        self.sessionID = sessionID
        self.onEnded = onEnded
    }

    /// The attach follows the surface's size, and the *settled* one.
    ///
    /// `cols`/`rows` are an attach's first size — and its only one on a
    /// core too old for `ResizeAttach` — so the size we send has to be the
    /// real one. The
    /// surface resizes at least twice on the way up (measured: 62x62 from
    /// the first layout pass, then 62x53 once safe areas are applied), and
    /// attaching on the first left the pty disagreeing with the grid for
    /// the rest of the session. Hence: debounce, then attach; and if the
    /// size changes later — rotation, a keyboard appearing — resize the
    /// live attach (`ResizeAttach`), or reattach against a core too old
    /// to resize one.
    /// The three-way decision is `AttachSizing`, so it can be asserted by
    /// `--selftest`.
    public func terminalDidResize(columns: Int, rows: Int) {
        switch AttachSizing.decide(columns: columns, rows: rows,
                                   attached: attachedSize.map { ($0.columns, $0.rows) },
                                   done: done.isSet) {
        case .ignore:
            return
        case .disarm:
            settle?.cancel()
            settle = nil
            pendingSize = nil
        case let .settle(columns, rows):
            pendingSize = Size(columns: columns, rows: rows)
            settle?.cancel()
            settle = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, let size = self.pendingSize else { return }
                self.restart(size)
            }
        }
    }

    struct Size: Equatable { let columns: Int; let rows: Int }

    /// Try the same size again shortly. Nothing else would: `restart` is
    /// only ever reached from the settle task, which needs a *real* size
    /// change, so a core restarting or a tailnet blip left the pane on
    /// "attach failed:" until it was closed and reopened.
    ///
    /// Also how a dropped link comes back, with `start` checking the
    /// session survived before each attempt.
    ///
    /// Rides the settle slot, so a genuine resize arriving first cancels
    /// it and wins. Fixed 2s and forever, like `AppState`'s own retry
    /// loops — the task dies with the screen. Back off if a down core ever
    /// costs something here.
    private func retry(_ size: Size) {
        guard !done.isSet else { return }
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.restart(size)
        }
    }

    private func restart(_ size: Size) {
        guard !done.isSet, size != attachedSize else { return }
        // A live attach from a core that can resize one: a SIGWINCH for
        // tmux, not a new connection, so the keyboard appearing or a
        // rotation no longer redraws the pane from nothing.
        if let channel, let token = channel.token, attachedSize != nil {
            attachedSize = size
            resize(channel, token: token, to: size)
            return
        }
        attachedSize = size
        stop()
        start(columns: size.columns, rows: size.rows)
    }

    /// One serial queue, so two quick size changes reach the core in the
    /// order they happened and the last one wins. A refusal — the attach
    /// is gone, or the core forgot the token — falls back to what an older
    /// core always gets: a reattach at the new size.
    private let resizes = DispatchQueue(label: "app.moomux.attach.resize")

    private func resize(_ channel: AttachChannel, token: String, to size: Size) {
        let client = client
        resizes.async { [weak self] in
            do {
                try client.resizeAttach(token: token, cols: size.columns, rows: size.rows)
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, !self.done.isSet, self.channel === channel else { return }
                    self.stop()
                    self.start(columns: size.columns, rows: size.rows)
                }
            }
        }
    }

    private func start(columns: Int, rows: Int) {
        let client = client
        let id = sessionID
        let done = done
        let everAttached = everAttached
        reader = Task.detached(priority: .userInitiated) {
            // Every reattach, whatever caused it — a dropped link, a
            // rotation, the keyboard — goes through here, so this is the
            // one place the gate has to be. A session killed between this
            // check and the attach below still gets recreated; the window
            // is one round trip.
            let alive = everAttached ? (try? client.capture(ids: [id])).map { $0[id] != nil } : nil
            guard !Task.isCancelled else { return }
            switch Reattach.decide(everAttached: everAttached, alive: alive) {
            case .attach:
                break
            case .wait:
                await MainActor.run { [weak self] in
                    self?.attachedSize = nil
                    self?.retry(Size(columns: columns, rows: rows))
                }
                return
            case .end:
                done.set()
                await MainActor.run { [weak self] in self?.onEnded() }
                return
            }
            let channel: AttachChannel
            do {
                channel = try client.attach(id: id, cols: columns, rows: rows)
            } catch {
                // A reattach that started while this one was in flight has
                // already taken over — same reason the success path below
                // checks. Reporting this failure would paint an error into
                // a healthy pane, nil the size it just attached at, and
                // schedule a `restart` back to the stale one.
                guard !Task.isCancelled else { return }
                // Before the switch to raw bytes an error is still
                // expressible, so this is the one place a failure has
                // words. Paint them into the terminal itself — there is no
                // other surface here to put them on.
                let message = "\r\n  attach failed: \(error.localizedDescription)\r\n"
                await MainActor.run { [weak self] in
                    self?.session.receive(message)
                    // Forget the size this attach never reached, or the
                    // only retry is a *different* one: `restart` and
                    // `terminalDidResize` both early-return on a size
                    // equal to the attached one, so the pane would sit
                    // dead until the screen was left and re-entered.
                    self?.attachedSize = nil
                    self?.retry(Size(columns: columns, rows: rows))
                }
                return
            }
            // Cancellation cannot interrupt the blocking `attach`, so a
            // reattach that started while this one was in flight comes
            // back to a `stop()` that had no channel to close. Close it
            // here, or tmux keeps a client nobody can reach and sizes the
            // window to it.
            guard !Task.isCancelled else { return channel.close() }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return channel.close() }
                self.channel = channel
                self.everAttached = true
                self.live.install(channel)
                // The bytes that arrived with the response line are the
                // first frame tmux drew. Feeding them before the read loop
                // is the whole reason `AttachChannel` keeps them.
                if !channel.pending.isEmpty { self.session.receive(channel.pending) }
            }
            var lost: Error?
            while !Task.isCancelled {
                let data: Data
                do { data = try channel.read() } catch {
                    lost = error
                    break
                }
                if data.isEmpty { break }
                await MainActor.run { [weak self] in self?.session.receive(data) }
            }
            // A read that *failed* is not a detach: the link died under
            // us — the phone slept, the app sat behind Safari long enough
            // for its socket to be reclaimed, the tailnet blipped. Say so
            // and reattach once the core answers; `start`'s gate ends the
            // screen instead if the session died meanwhile. `stop` first,
            // so keys typed in the gap buffer rather than hit a dead socket.
            if let lost, !Task.isCancelled {
                let message = "\r\n  connection lost: \(lost.localizedDescription) — reconnecting\r\n"
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.session.receive(message)
                    self.stop()
                    self.attachedSize = nil
                    self.retry(Size(columns: columns, rows: rows))
                }
                return
            }
            // After `{"ok":true}` the wire has nowhere to put an error, so
            // the socket closing *is* the message — and the answer to it is
            // to leave, not to narrate. Not on cancellation: that is this
            // view being torn down already, either by Back or by a resize
            // reattaching, and dismissing again would pop the list too.
            guard !Task.isCancelled else { return }
            // Set *before* the hop, not inside it: a settle task that
            // fires while this is waiting for the main actor would
            // otherwise reattach and recreate the session.
            done.set()
            await MainActor.run { [weak self] in self?.onEnded() }
        }
    }

    /// Permanent: the pane is going away. Anything that could start a new
    /// attach has to be refused from here on, not merely cancelled.
    public func teardown() {
        done.set()
        stop()
    }

    func stop() {
        settle?.cancel()
        settle = nil
        reader?.cancel()
        reader = nil
        live.install(nil)
        channel?.close()
        channel = nil
    }
}

/// Whether a pane attaches here, by running `tmux attach` on this machine, or
/// over the core's `Attach` stream (docs/macos-vs-ios.md D25).
///
/// Local whenever it can be: the pty and tmux client run here, nothing
/// crosses the socket, and the terminal gets `xterm-ghostty` with its
/// terminfo. A core on a unix socket is on this machine by construction. One
/// reached over TCP may be too — this Mac's own tailnet address — so the
/// session counts as local only if this machine's tmux has it.
public enum AttachRoute: Equatable, Sendable {
    case local
    case remote
    /// A local core and no tmux binary to attach with.
    case unavailable

    /// `localSession` is nil when it was not checked (no tmux to ask).
    public static func decide(remoteCore: Bool, tmuxFound: Bool, localSession: Bool?) -> AttachRoute {
        guard remoteCore else { return tmuxFound ? .local : .unavailable }
        return tmuxFound && localSession == true ? .local : .remote
    }

    public static func demo() {
        assert(decide(remoteCore: false, tmuxFound: true, localSession: nil) == .local,
               "a unix-socket core is on this machine: today's attach, unchanged")
        assert(decide(remoteCore: false, tmuxFound: false, localSession: nil) == .unavailable)
        assert(decide(remoteCore: true, tmuxFound: true, localSession: true) == .local,
               "a TCP core that is this machine still attaches locally")
        assert(decide(remoteCore: true, tmuxFound: true, localSession: false) == .remote)
        assert(decide(remoteCore: true, tmuxFound: false, localSession: nil) == .remote,
               "a remote core needs no tmux here at all")
    }
}

// MARK: - Checks

extension RemoteAttach {
    /// The far end of one attach: records what was typed, and hangs up when
    /// told to. `closed` once either side has left.
    private final class FarEnd: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var socket: StreamSocket?
        private var ended = false
        var typed: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
        var closed: Bool { lock.withLock { ended } }

        /// The core leaving: the attach's read sees EOF, as for a killed session.
        func hangUp() { lock.withLock { socket }?.close() }

        /// `Attach` answered as a core does: the response line, the first
        /// frame in the same write, then raw bytes until one side leaves.
        func serve(on core: FakeCore, token: String?) {
            let header = token.map { #"{"result":{"ok":true,"attach":"\#($0)"}}"# } ?? #"{"result":{"ok":true}}"#
            core.on("Attach") { [self] socket in
                lock.withLock { self.socket = socket }
                try? socket.write(Data((header + "\n" + "drawn").utf8))
                while let chunk = try? socket.readChunk(), !chunk.isEmpty { lock.withLock { bytes.append(chunk) } }
                lock.withLock { ended = true }
            }
        }
    }

    private final class Count: @unchecked Sendable { var value = 0 }

    /// The three things here that once went wrong in a way no screenshot
    /// shows: the first layout pass's size kept, keys lost across the attach,
    /// and a killed session brought back to life by a reattach.
    public static func demo() {
        func quiet() { _ = FakeCore.spin(0.6) { false } }  // > the 250ms settle

        // MARK: Settle, keys, resize in place, the far end leaving

        do {
            let core = FakeCore(), far = FarEnd(), ended = Count()
            far.serve(on: core, token: "t0")
            let pane = RemoteAttach(client: MoomuxClient(socketPath: core.path), sessionID: "p:a") { ended.value += 1 }
            pane.session.sendInput(Data("early ".utf8))  // before any channel: buffered, not dropped
            pane.terminalDidResize(columns: 62, rows: 62)
            pane.terminalDidResize(columns: 62, rows: 53)
            assert(FakeCore.spin { core.count("Attach") == 1 }, "a settled size must attach")
            quiet()
            assert(core.log.filter { $0.contains("Attach") }
                == [#"{"args":{"cols":62,"id":"p:a","rows":53},"method":"Attach"}"#],
                   "one attach, at the settled size — not the first layout pass's: \(core.log)")
            pane.session.sendInput(Data("late".utf8))
            assert(FakeCore.spin { far.typed == "early late" }, "keys arrive once, in order: \(far.typed)")

            // A core that named the attach resizes it in place: no reconnect.
            pane.terminalDidResize(columns: 80, rows: 24)
            assert(FakeCore.spin { core.count("ResizeAttach") == 1 })
            assert(core.log.contains(#"{"args":{"attach":"t0","cols":80,"rows":24},"method":"ResizeAttach"}"#))
            assert(core.count("Attach") == 1)

            // The far end closing is the session ending: leave, once, and
            // never attach again — `Attach` would recreate a killed session.
            far.hangUp()
            assert(FakeCore.spin { ended.value == 1 }, "a closed attach ends the pane")
            pane.terminalDidResize(columns: 100, rows: 30)
            quiet()
            assert(core.count("Attach") == 1 && ended.value == 1, "an ended pane must not reattach")
        }

        // MARK: A reattach checks the session is still there

        do {
            // No token: an older core, so a resize is a reattach. Its `Capture`
            // answers without the session — killed meanwhile — so the pane ends
            // instead of attaching, which would have revived it.
            let core = FakeCore(), far = FarEnd(), ended = Count()
            far.serve(on: core, token: nil)
            let pane = RemoteAttach(client: MoomuxClient(socketPath: core.path), sessionID: "p:b") { ended.value += 1 }
            pane.terminalDidResize(columns: 80, rows: 24)
            assert(FakeCore.spin { core.count("Attach") == 1 })
            assert(FakeCore.spin { pane.channel != nil }, "the attach must land before the resize")
            pane.terminalDidResize(columns: 100, rows: 30)
            assert(FakeCore.spin { ended.value == 1 }, "a reattach to a dead session ends the pane")
            assert(core.count("Capture") == 1, "every reattach asks first")
            assert(core.count("Attach") == 1, "and never attaches to a session that is gone")
            assert(FakeCore.spin { far.closed }, "the old attach is closed, not left as a stray tmux client")
        }

        // MARK: A refused resize falls back to reattaching

        do {
            // The core forgot the token (restarted, or the attach is gone): the
            // pane reattaches at the new size rather than keeping the old one.
            let core = FakeCore(), far = FarEnd(), ended = Count()
            far.serve(on: core, token: "t0")
            core.on("ResizeAttach") { try? $0.write(Data(#"{"err":"unknown attach"}"#.utf8)) }
            // Still alive, so the reattach's check lets it through.
            core.on("Capture") { try? $0.write(Data(#"{"result":{"screens":{"p:d":"$ "}}}"#.utf8)) }
            let pane = RemoteAttach(client: MoomuxClient(socketPath: core.path), sessionID: "p:d") { ended.value += 1 }
            pane.terminalDidResize(columns: 80, rows: 24)
            assert(FakeCore.spin { pane.channel != nil })
            pane.terminalDidResize(columns: 100, rows: 30)
            assert(FakeCore.spin { core.count("Attach") == 2 }, "a refused resize must reattach")
            assert(core.log.last == #"{"args":{"cols":100,"id":"p:d","rows":30},"method":"Attach"}"#,
                   core.log.last ?? "")
            assert(ended.value == 0)
            pane.teardown()
        }

        // MARK: Teardown

        do {
            let core = FakeCore(), far = FarEnd(), ended = Count()
            far.serve(on: core, token: "t0")
            let pane = RemoteAttach(client: MoomuxClient(socketPath: core.path), sessionID: "p:c") { ended.value += 1 }
            pane.terminalDidResize(columns: 80, rows: 24)
            assert(FakeCore.spin { pane.channel != nil })
            pane.teardown()
            assert(FakeCore.spin { far.closed }, "teardown hangs up — that is the detach")
            pane.terminalDidResize(columns: 90, rows: 30)
            quiet()
            assert(core.count("Attach") == 1, "a torn-down pane never attaches again")
            assert(ended.value == 0, "leaving is not the far end ending")
        }
    }
}
