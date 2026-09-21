import Foundation
import GhosttyTerminal
import SwiftUI
import MoomuxKit

/// Every live session at once, as read-only snapshots.
///
/// Deliberately **not** a grid of attached clients. Every tmux client on a
/// session sets the shared window size — measured for a plain attach, for
/// `-CC`, and for grouped sessions — so six live tiles would squash six real
/// agent sessions down to tile size until the grid closed, and would fight the
/// detail pane's own client over `refresh-client -C` where they overlap.
/// `capture-pane` attaches nothing and resizes nothing.
///
/// The price is that a tile cannot be typed into, which is the affordance the
/// size problem makes unaffordable anyway. Clicking one selects the session;
/// Attach is still where a real, full-size, deliberate client comes from.
struct SessionGrid: View {
    @Environment(AppState.self) private var app

    /// One `capture-pane` output per tmux session, keyed by session id and
    /// filled by the single loop below rather than per tile.
    @State private var screens: [String: [String]] = [:]

    /// Why the last capture came back with nothing, or nil while it worked.
    /// A tile that keeps its stale rows is right; a *grid* of them with no
    /// word anywhere is the "a failed call must not read as empty" trap —
    /// against a core too old to serve `Capture` there is no local fallback
    /// any more, so every tile would simply stay blank forever.
    @State private var captureError: String?

    /// Every live session, uncapped — measured, because the obvious reading of
    /// the numbers is wrong. Opening the grid costs ~190 MB of resident memory
    /// (120 MB → 308 MB at 30 live sessions), which looks like ~6 MB of
    /// libghostty surface per tile and is not: capping the grid at 12 tiles
    /// measured 311 MB against the same binary's 308 MB at 30, and two tiles
    /// still cost 265 MB. The jump is fixed set-up for the in-memory backend,
    /// paid on the first tile. A cap is a visible limitation
    /// ("+18 more live sessions") in exchange for nothing, so there isn't one.
    ///
    /// Where the memory actually goes is still unaccounted for; an Allocations
    /// run on the first tile is the next step if 300 MB ever matters.
    private var tiles: [Session] { app.visibleSessions.filter { app.isAlive($0) } }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                ForEach(tiles) { session in
                    SessionTile(session: session, rows: screens[session.id] ?? [])
                        .onTapGesture {
                            app.selectedSessionID = session.id
                            app.showGrid = false
                        }
                }
            }
            .padding(12)
        }
        .safeAreaInset(edge: .top) {
            if let captureError {
                Label(captureError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .overlay {
            if tiles.isEmpty {
                ContentUnavailableView("No live sessions", systemImage: "square.grid.2x2",
                                       description: Text("A session has to have a tmux session "
                                                         + "running before there is anything to show."))
            }
        }
        // Sorted, not in display order: the core hands out a fresh order on
        // every snapshot (map iteration, `session.Store.All`), and an id that
        // changed with it restarted this loop constantly — 33 captures where
        // 30 were due.
        .task(id: tiles.map(\.id).sorted().joined(separator: "\n")) {
            // One tmux process per tick for the whole grid, not one per tile.
            // Five seconds rather than the store's two because a snapshot is a
            // glance, not a live terminal. The loop belongs to the grid, so
            // closing it stops all of it.
            while !Task.isCancelled {
                (screens, captureError) = await capture(ids: tiles.map(\.id),
                                                        client: app.client, keeping: screens)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct SessionTile: View {
    @Environment(AppState.self) private var app
    let session: Session
    let rows: [String]

    var body: some View {
        let state = app.state(for: session)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: state.symbol).foregroundStyle(Theme.color(state, app.palette))
                Text(session.name).lineLimit(1)
                Spacer()
                Text(session.project).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption)
            SnapshotTerminal(rows: rows, controller: app.terminalController)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(session.id == app.selectedSessionID
                                      ? Color.accentColor : Color.secondary.opacity(0.3))
                }
        }
        .contentShape(Rectangle())
    }
}

/// The grid's screens, from the core.
///
/// This used to shell out to `tmux capture-pane` here — one of the three
/// places this app reached past the socket, and the boundary rule says a thing
/// the Swift side cannot do is a hole to fix in Go. `Capture` is that fix: one
/// request for the whole grid, which the core batches into a single tmux
/// invocation, keyed by **session id** so no front end needs a tmux name.
///
/// Blocking, like every other `MoomuxClient` call, so it runs off the main
/// actor.
///
/// Two things the move fixed rather than merely relocated. The local version
/// could mis-attribute a dead session's `can't find pane:` error to the
/// *previous* tile, because tmux abandons a command sequence at the first
/// error while still exiting 0 and the local splitter accepted an unterminated
/// trailing section. And the batch and the per-session retry disagreed about a
/// trailing newline, so a tile could gain or lose a blank row depending on
/// which path served it that tick. Both are the core's problem now, and it
/// closes both.
private func capture(ids: [String], client: MoomuxClient,
                     keeping previous: [String: [String]]) async -> ([String: [String]], String?) {
    guard !ids.isEmpty else { return (previous, nil) }
    return await Task.detached(priority: .utility) { () -> ([String: [String]], String?) in
        // Pruned to what is on screen, so a session that left the grid does
        // not keep its rows alive here.
        var out = ids.reduce(into: [String: [String]]()) { $0[$1] = previous[$1] ?? [] }
        // A failed call must not read as "every session is empty" — the same
        // instinct as `AppState.refresh` keeping its last good list. An absent
        // key means the core could not capture that one, so the tile keeps
        // what it last drew; `Capture` never sets `err`.
        let screens: [String: String]
        do { screens = try client.capture(ids: ids) } catch {
            return (out, "Couldn't capture the sessions: \(error.localizedDescription)")
        }
        for (id, text) in screens where out[id] != nil {
            out[id] = TmuxSnapshot.rows(of: text)
        }
        return (out, nil)
    }.value
}

/// A terminal used only as a renderer: bytes in, nothing out.
///
/// libghostty's host-managed backend, so there is no process and no pty behind
/// a tile — `InMemoryTerminalSession.receive` is the whole input path, and the
/// capture bytes go straight into the same VT engine the attached pane uses.
private struct SnapshotTerminal: NSViewRepresentable {
    let rows: [String]
    let controller: TerminalController

    /// A terminal that cannot be clicked, so the tile underneath can be.
    ///
    /// The snapshot covers ~85% of a tile, and a terminal view consumes a click
    /// rather than forwarding it. SwiftUI's `.allowsHitTesting(false)` does
    /// **not** reach it (measured against SwiftTerm, and the reason is the same
    /// here): the view is a real `NSView` in the AppKit hierarchy and the click
    /// is resolved by `NSView.hitTest` before SwiftUI is consulted. Refusing
    /// there is what makes "click a tile to open it" true, and it also keeps the
    /// terminal from stealing first responder from the sidebar list, which is
    /// what silently killed arrow-key navigation.
    private final class SnapshotTerminalView: AppTerminalView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> AppTerminalView {
        let view = SnapshotTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        view.delegate = context.coordinator
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(context.coordinator.session),
            // A tile is ~50 columns against an agent pane's 150-210, so the
            // font has to be small for a snapshot to say anything at all.
            fontSize: 9
        )
        return view
    }

    /// Guarded on the rows actually differing. `AppState` is `@Observable` and
    /// fires on any assignment, so a tile's body re-runs on every poll and every
    /// watcher tick — about once a second — while a capture only arrives every
    /// five. Unguarded, each tile re-feeds a whole screen into the parser five
    /// times per snapshot for nothing.
    func updateNSView(_ view: AppTerminalView, context: Context) {
        guard context.coordinator.rows != rows else { return }
        context.coordinator.rows = rows
        context.coordinator.repaint()
    }

    /// The same explicit teardown `AppState.detach` needs, and for the same
    /// measured reason: releasing the view does not free the surface, so a
    /// grid toggled open and shut repeatedly would otherwise leave a surface,
    /// a wakeup observer and a display link per tile behind every time.
    static func dismantleNSView(_ view: AppTerminalView, coordinator: Coordinator) {
        view.controller = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Truncation needs the tile's column count, and only the terminal knows
    /// it — and only once SwiftUI has given the view a real frame. So the rows
    /// live here and are painted from both sides: a fresh capture, and the
    /// resize that first reveals how wide a tile is. Without the second, the
    /// first paint lands on a zero-column grid and draws nothing.
    final class Coordinator: NSObject, TerminalSurfaceResizeDelegate,
                             TerminalSurfaceOpenURLDelegate {
        /// Nothing types into a tile — `hitTest` refuses the click that would
        /// give it focus — so the host side of the backend discards writes.
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        var rows: [String] = []
        private var columns = 0

        func terminalDidResize(columns: Int, rows _: Int) {
            self.columns = columns
            repaint()
        }

        func repaint() {
            guard columns > 0, !rows.isEmpty else { return }
            session.receive(TmuxSnapshot.screen(from: rows, columns: columns))
        }

        /// A tile cannot be ⌘-clicked — `hitTest` refuses — so in practice this
        /// never fires. It is here because the alternative is not "no links":
        /// a surface whose delegate does not conform has its `open_url`
        /// reported unhandled, and ghostty core then spawns `/usr/bin/open`
        /// itself, bypassing `TerminalLink`'s allowlist entirely. Relying on
        /// `hitTest` alone would make that fail-open-by-luck, one refactor away
        /// from opening whatever a pane printed.
        func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
            TerminalLink.open(url)
        }
    }
}

/// A one-shot `capture-pane` of a session, framed as bytes a terminal can draw.
///
/// Nothing here attaches a client, which is the entire reason the session grid
/// is snapshots: every tmux client on a session sets the shared window size, so
/// a grid of live clients would letterbox that many real sessions down to tile
/// size until it was closed.
enum TmuxSnapshot {

    /// A captured screen as rows, blank ones kept — the trailing-blank
    /// trimming belongs to `screen(from:columns:)`.
    static func rows(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Rows **truncated** to `columns`, framed with home+clear so a repaint
    /// replaces the screen rather than appending, CRLF-joined because a bare LF
    /// only moves down a row.
    ///
    /// Truncating rather than letting the terminal wrap is the whole legibility
    /// of a tile: a real agent pane is 150-210 columns and a tile is nearer 50,
    /// so wrapped rows would show the bottom quarter of the last few lines as
    /// mush. `capture-pane` without `-J` hands back one entry per screen row,
    /// so a row here really is a row there.
    static func screen(from lines: [String], columns: Int) -> String {
        let width = max(0, columns)
        var rows = lines.map { $0.count > width ? String($0.prefix(width)) : $0 }
        // capture-pane returns the pane's full height, blank rows below the
        // cursor included. Feeding those into a short tile scrolls the content
        // away and leaves the tile showing the blanks.
        while let last = rows.last, last.allSatisfy(\.isWhitespace) { rows.removeLast() }
        return "\u{1b}[H\u{1b}[2J" + rows.joined(separator: "\r\n")
    }

    static func demo() {
        // Splitting a batched capture used to live here and is the core's job
        // now (`Capture`, keyed by session id), which is also what fixed
        // mis-attributing a dead session's error to the previous tile.
        assert(rows(of: "a\nb\n") == ["a", "b", ""])

        let s = screen(from: ["abcdef", "gh"], columns: 4)
        assert(s.hasPrefix("\u{1b}[H\u{1b}[2J"), s.debugDescription)
        assert(s.hasSuffix("abcd\r\ngh"), "rows are cut, never wrapped: \(s.debugDescription)")
        assert(screen(from: [], columns: 4).hasSuffix("[2J"))
        assert(screen(from: ["a", "   ", ""], columns: 9).hasSuffix("[2Ja"),
               "the blank rows below a pane's cursor would scroll the tile empty")
        // A tile whose terminal has not been sized yet must not trap.
        assert(screen(from: ["ab"], columns: -1).hasSuffix("[2J"))
    }
}
