import GhosttyTerminal
import MoomuxKit
import PhotosUI
import SwiftUI
import UIKit

/// A live `tmux attach`, over the socket.
///
/// The phone has no `.exec` backend — iOS forbids spawning the `login`/`tmux`
/// the Mac pane runs — so the pty lives on the core's machine and this is the
/// host-managed `.inMemory` backend with a socket where its process would be:
/// `AttachChannel.read()` into `session.receive`, and the session's `write`
/// closure back out as keystrokes. Same VT engine as the Mac's attached pane.
///
/// Two consequences of the pty being remote, both good: there is no `TERM` to
/// get wrong here (the core fixes it at `xterm-256color`, because the terminfo
/// has to exist on *its* machine) and nothing is shell-quoted into a command
/// line, because this end spawns nothing at all.
struct TerminalScreen: View {
    let app: AppState
    let sessionID: Session.ID

    @Environment(\.dismiss) private var dismiss

    /// The size a pane *opens* at, and therefore the attached session's width
    /// — see the note on `fontSize` below. Pinch-zoom adjusts a live pane and
    /// is the right tool for "I need a closer look at this line"; this is the
    /// starting point, so it lives in the list's menu rather than taking a
    /// slot in the pane's toolbar. It has to be here as well because the
    /// package reads the size when the surface is built.
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.default
    @State private var pane = PaneHandle()
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var importingFiles = false
    @State private var attachments = AttachQueue()

    var body: some View {
        AttachedTerminal(controller: app.terminalController,
                         client: app.client,
                         sessionID: sessionID,
                         fontSize: fontSize,
                         pane: pane,
                         // The far end going away is the end of the screen's
                         // reason to exist: tmux exited, the session was
                         // killed, the core went down. Leaving a dead pane up
                         // makes the user dismiss a window to learn nothing.
                         onEnded: { dismiss() })
            // Rebuilding the surface is the whole mechanism: the package takes
            // its font size from `TerminalSurfaceOptions` at construction and
            // publishes no setter, so changing it means a new surface — which
            // re-attaches at the new width anyway, which a size change has to
            // do regardless.
            .id(fontSize)
            // **Not** `.ignoresSafeArea(.bottom)`. The surface sizes its grid
            // to the view, so extending under the home indicator buys two more
            // rows that are drawn behind it — and tmux puts the status line
            // and the cursor at the bottom, which is exactly what goes
            // missing. Reported as "the cursor is two lines below where it
            // should be", which is precisely the inset in rows.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The cow, saying the session's quip — the Mac's `CowQuip`,
                // and its reasoning: the name and state are what you picked
                // the session by and already know, while the quip is the
                // core's live answer to "what is it doing". It re-renders on
                // every snapshot.
                ToolbarItem(placement: .principal) {
                    if let session = app.session(id: sessionID) {
                        CowQuip(saying: app.quip(for: session) ?? app.label(for: session))
                    }
                }
                // Attached is exactly when you want the branch, the PR state
                // and the worktree — the swipe on the row reaches detail too,
                // but not once you are already in here.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.detail(sessionID)) {
                        Image(systemName: "info.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if attachments.pending > 0 {
                        ProgressView()
                    } else {
                        Menu {
                            // A `Button` and not a `PhotosPicker`: inside a
                            // `Menu` the picker lays its label out itself, so
                            // its icon sat at a different gap from Files'.
                            Button { pickingPhotos = true } label: {
                                Label("Photos", systemImage: "photo.on.rectangle")
                            }
                            Button { importingFiles = true } label: {
                                Label("Files", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "paperclip")
                        }
                        .accessibilityLabel("Attach")
                    }
                }
            }
            // The New Session sheet's pickers, with the path pasted into the
            // pane rather than appended to a form: the agent is already
            // running, so this is a file dropped on its terminal.
            .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .images)
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photos = []
                attach(app.attachJobs(items))
            }
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { attach(app.attachJobs($0)) }
            // No form to put it under, and the pane is the program's screen.
            .alert("Couldn't attach",
                   isPresented: Binding(get: { attachments.error != nil },
                                        set: { if !$0 { attachments.clearError() } })) {
                Button("OK") {}
            } message: {
                Text(attachments.error ?? "")
            }
            // No `onDisappear` cancel, unlike the sheet: pushing the info
            // screen disappears this one too, and would drop a batch mid-way.
            // A batch outliving the pane pastes into a nil view — the files
            // still land on the core, and its temp sweep takes them.
    }

    /// A paste, not keystrokes: `paste(text:)` frames it as bracketed paste
    /// when the program asked for that, which is how claude tells a dropped
    /// file from typing — an image path pasted becomes `[Image #1]`. It goes
    /// out through the surface's `write`, so it keeps its place among keys.
    /// The core names the file with nothing that needs shell quoting.
    private func attach(_ jobs: [AttachJob]) {
        attachments.run(jobs) { pane.view?.paste(text: $0 + " ") }
    }
}

/// The live surface, for the toolbar to paste into. A class so rebuilding the
/// surface on a font change repoints it without re-rendering the screen.
final class PaneHandle {
    weak var view: UITerminalView?
}

private struct AttachedTerminal: UIViewRepresentable {
    let controller: TerminalController
    let client: MoomuxClient
    let sessionID: Session.ID
    let fontSize: Double
    let pane: PaneHandle
    let onEnded: () -> Void

    func makeUIView(context: Context) -> UITerminalView {
        let view = LinkTapView(frame: .init(x: 0, y: 0, width: 390, height: 600))
        pane.view = view
        view.delegate = context.coordinator
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(context.coordinator.session),
            // The window reflows to this client (see IPHONE.md §5), so the
            // font decides the attached session's *width*, not just how much
            // of a fixed grid is visible: 8pt is ~62 columns, 11pt ~43, and a
            // diff or an agent TUI hard-wraps mid-token below about 50. That
            // is why this is a control rather than a constant — there is no
            // value that is right for both reading prose and reading code on a
            // phone. Pinch-zoom changes it live too, but the package publishes
            // no setter to read that back, so a pinch does not persist.
            fontSize: Float(fontSize),
            // Same reason the Mac pane sets it: ghostty coalesces resizes on a
            // 25ms trailing-only window, and an alt-screen agent TUI composites
            // a stale grid into the new bounds without this.
            resizeThrottleMilliseconds: 96
        )
        return view
    }

    func updateUIView(_: UITerminalView, context _: Context) {}

    /// Explicit teardown, exactly as `AppState.detach` needs on the Mac:
    /// dropping the view does not free the surface, and here it would also
    /// leave the attach socket open — so tmux would keep a client that nothing
    /// is reading, and the session would stay sized to a phone that left.
    static func dismantleUIView(_ view: UITerminalView, coordinator: Coordinator) {
        coordinator.teardown()
        view.controller = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, sessionID: sessionID, onEnded: onEnded)
    }

    /// A tap on a link opens it.
    ///
    /// ghostty follows a link only on a ⌘-click — its URL matcher's hover mods
    /// are `ctrlOrSuper`, and the `link` config that would change that "can't
    /// currently be set" — and a finger tap carries no modifiers, so no link
    /// ever opened on the phone. So a clean tap (the one the package would
    /// spend toggling the keyboard) first asks ghostty what is under it as if
    /// ⌘ were held. `mouse_over_link` answers synchronously on the main thread.
    ///
    /// Shift as well while the program captures the mouse, which tmux with
    /// `mouse on` does: ghostty only refreshes links under capture when shift
    /// is held and not being reported, then strips it before matching. The
    /// off-screen positions either side reset its `link_point` cache — a probe
    /// at the cell it last checked would otherwise be skipped — and clear the
    /// underline afterwards. Ceiling: `link-previews = false` in the user's
    /// config suppresses `mouse_over_link` for plain URLs, so taps stop finding
    /// them; the upgrade is a ⌘-click through `open_url` instead.
    final class LinkTapView: UITerminalView {
        private var tap: CGPoint?

        /// ghostty reports a wheel to tmux at the last pointer position and
        /// drops it when there is none — and the package's finger-scroll pan
        /// sends no position (its trackpad one does), while the probe below
        /// parks the pointer off-screen after every tap. So a swipe never
        /// reached tmux at all. Aim the pointer at the finger as it lands,
        /// before the pan begins; momentum after lift keeps that position.
        /// The Mac pane's `scrollWheel` override is the same fix. Delete once
        /// `handleTouchScrollGesture` sends a position itself.
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first, touch.type == .direct {
                let point = touch.location(in: self)
                sendMousePos(x: point.x, y: point.y)
            }
            super.touchesBegan(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            tap = touches.first?.location(in: self)
            super.touchesEnded(touches, with: event)
            tap = nil
        }

        override func toggleSoftwareKeyboard() {
            guard let tap, let coordinator = delegate as? Coordinator else {
                return super.toggleSoftwareKeyboard()
            }
            sendMousePos(x: -1, y: -1)
            coordinator.hoverLink = nil
            sendMousePos(x: tap.x, y: tap.y, modifiers: isMouseCaptured ? [.super_, .shift] : .super_)
            let link = coordinator.hoverLink
            sendMousePos(x: -1, y: -1)
            guard let link, Coordinator.open(link) else { return super.toggleSoftwareKeyboard() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, TerminalSurfaceResizeDelegate,
                             TerminalSurfaceOpenURLDelegate,
                             TerminalSurfaceHoverLinkDelegate,
                             TerminalSurfaceClipboardConfirmationDelegate {
        private let client: MoomuxClient
        private let sessionID: Session.ID
        private let onEnded: () -> Void
        private var channel: AttachChannel?
        private var reader: Task<Void, Never>?
        private var settle: Task<Void, Never>?
        /// Once the pane is gone, or the far end has, this coordinator must
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
        lazy var session: InMemoryTerminalSession = InMemoryTerminalSession(
            write: { [live] data in live.send(data) },
            resize: { _ in }
        )

        init(client: MoomuxClient, sessionID: Session.ID, onEnded: @escaping () -> Void) {
            self.client = client
            self.sessionID = sessionID
            self.onEnded = onEnded
        }

        /// The attach follows the surface's size, and the *settled* one.
        ///
        /// `cols`/`rows` are the only size a given attach ever gets — the core
        /// sets the pty once — so the size we send has to be the real one. The
        /// surface resizes at least twice on the way up (measured: 62x62 from
        /// the first layout pass, then 62x53 once safe areas are applied), and
        /// attaching on the first left the pty disagreeing with the grid for
        /// the rest of the session. Hence: debounce, then attach; and if the
        /// size changes later — rotation, a keyboard appearing — reattach,
        /// which is what the wire's initial-size-only contract asks a client
        /// to do.
        /// The three-way decision is `AttachSizing`, in the Kit, so it can be
        /// asserted by `--selftest` — nothing in this target can be.
        func terminalDidResize(columns: Int, rows: Int) {
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
        /// "attach failed:" until the screen was popped and re-pushed.
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
            attachedSize = size
            stop()
            start(columns: size.columns, rows: size.rows)
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
        func teardown() {
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

        /// Read back by `LinkTapView`'s probe.
        var hoverLink: String?

        func terminalDidUpdateHoverLink(_ url: String?) { hoverLink = url }

        /// A ⌘-click from a hardware mouse or trackpad. The delegate must exist
        /// even so: without one ghostty core opens the link itself, straight
        /// past the allowlist in `open`.
        func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
            Coordinator.open(url)
        }

        /// Through `WebLink`, the allowlist. `UIApplication.open` hands an
        /// https link to the app that claims it (GitHub, Asana) before Safari.
        @discardableResult
        static func open(_ link: String) -> Bool {
            guard let url = WebLink.url(link) else { return false }
            UIApplication.shared.open(url)
            return true
        }

        /// With no delegate the bridge answers `false` silently, which breaks
        /// the user's own paste with no dialog and nothing logged. Split on
        /// initiator, same as the Mac pane: a paste is the user, OSC 52 is the
        /// program in the pane asking.
        func terminalDidRequestClipboardConfirmation(
            _ request: TerminalClipboardConfirmationRequest
        ) {
            request.respond(allow: request.kind == .paste)
        }
    }
}


// MARK: - The cow

/// The cow mark plus its quip in a speech bubble, standing in for a title.
///
/// The bubble is the Kit's `SpeechBubble` so it matches the Mac exactly. The
/// mark cannot be: the Mac loads `moomux-terminal-nose.svg` straight from its
/// bundle and `UIImage` does not read SVG, so `make ios` rasterizes the same
/// file to a PNG (`Scripts/rasterize.swift`) rather than a second asset being
/// checked in to drift.
struct CowQuip: View {
    let saying: String

    var body: some View {
        HStack(spacing: 6) {
            if let cow = CowQuip.mark {
                Image(uiImage: cow).resizable().scaledToFit().frame(width: 22, height: 22)
            }
            Text(saying)
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.leading, 6 + 6)
                .padding(.trailing, 9)
                .padding(.vertical, 3)
                .background(SpeechBubble().fill(Color.secondary.opacity(0.15)))
        }
    }

    /// Decoded once: the image never changes and a toolbar redraws often.
    static let mark: UIImage? = Bundle.main
        .url(forResource: "moomux-terminal-nose", withExtension: "png")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap(UIImage.init(data:))
}
