import Foundation
import SwiftTerm
import SwiftUI

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

    private var tiles: [Session] { app.visibleSessions.filter { app.isAlive($0) } }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                ForEach(tiles) { session in
                    SessionTile(session: session)
                        .onTapGesture {
                            app.selectedSessionID = session.id
                            app.showGrid = false
                        }
                }
            }
            .padding(12)
        }
        .overlay {
            if tiles.isEmpty {
                ContentUnavailableView("No live sessions", systemImage: "square.grid.2x2",
                                       description: Text("A session has to have a tmux session "
                                                         + "running before there is anything to show."))
            }
        }
    }
}

private struct SessionTile: View {
    @Environment(AppState.self) private var app
    let session: Session

    @State private var rows: [String] = []

    var body: some View {
        let state = app.state(for: session)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: state.symbol).foregroundStyle(Theme.color(state))
                Text(session.name).lineLimit(1)
                Spacer()
                Text(session.project).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption)
            SnapshotTerminal(rows: rows)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(session.id == app.selectedSessionID
                                      ? Color.accentColor : Color.secondary.opacity(0.3))
                }
        }
        .contentShape(Rectangle())
        .task(id: session.tmuxSession) {
            // What this costs, plainly: one short-lived `tmux capture-pane`
            // process per visible tile every tick. Five seconds rather than the
            // store's two because a snapshot is a glance, not a live terminal,
            // and the process churn is the whole expense. The task belongs to
            // the tile, so closing the grid stops all of it.
            //
            // If a wall of tiles ever makes this bite, the upgrade is one tmux
            // invocation with `;`-joined capture-pane commands — not a client
            // per tile, which is the thing this design exists to avoid.
            while !Task.isCancelled {
                rows = await capture(session: session.tmuxSession)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// `Process` blocks, same rule as every `MoomuxClient` call. A GUI app has
/// launchd's `PATH`, so tmux comes from `ToolPath` and never from a bare name.
///
/// No `-e`, unlike the control-mode repaint: `TmuxSnapshot.screen` cuts rows by
/// character count, and SGR escapes are characters that occupy no columns, so
/// keeping colour would cut every coloured row short.
private func capture(session: String) async -> [String] {
    guard !session.isEmpty, let tmux = ToolPath.find("tmux") else { return [] }
    return await Task.detached(priority: .utility) { () -> [String] in
        // A session can die between the poll and the capture. Nothing captured
        // leaves the tile showing its last snapshot, which is the same instinct
        // as `AppState.refresh` keeping the last good list: a failed call must
        // not read as "empty".
        guard let out = try? ToolPath.run(tmux, ["capture-pane", "-p", "-t", session])
        else { return [] }
        return out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }.value
}

/// A terminal used only as a renderer: bytes in, nothing out.
///
/// `NoScrollerTerminalView` and not `TerminalView`: SwiftTerm reserves ~17pt
/// for a scroller it never hides, which is a whole column at this size.
private struct SnapshotTerminal: NSViewRepresentable {
    let rows: [String]

    /// A terminal that cannot be clicked, so the tile underneath can be.
    ///
    /// The snapshot covers ~85% of a tile, and `MacTerminalView.mouseDown`
    /// swallows a click without forwarding it — the same thing `PaneTerminalView`
    /// exists to override. SwiftUI's `.allowsHitTesting(false)` does **not**
    /// reach it (measured: the tap still never fired): the view is a real
    /// `NSView` in the AppKit hierarchy and the click is resolved by
    /// `NSView.hitTest` before SwiftUI is consulted. Refusing there is what
    /// makes "click a tile to open it" true, and it also keeps the terminal
    /// from stealing first responder from the sidebar list, which is what
    /// silently killed arrow-key navigation.
    private final class SnapshotTerminalView: NoScrollerTerminalView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = SnapshotTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        view.terminalDelegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        context.coordinator.view = view
        return view
    }

    /// Guarded on the rows actually differing. `AppState` is `@Observable` and
    /// fires on any assignment, so a tile's body re-runs on every poll and every
    /// watcher tick — about once a second — while a capture only arrives every
    /// five. Unguarded, each tile re-feeds a whole screen into SwiftTerm five
    /// times per snapshot for nothing.
    func updateNSView(_ view: TerminalView, context: Context) {
        guard context.coordinator.rows != rows else { return }
        context.coordinator.rows = rows
        context.coordinator.repaint()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Truncation needs the tile's column count, and only the terminal knows
    /// it — and only once SwiftUI has given the view a real frame. So the rows
    /// live here and are painted from both sides: a fresh capture, and the
    /// `sizeChanged` that first reveals how wide a tile is. Without the second,
    /// the first paint lands on a zero-frame view and SwiftTerm's soft-reset
    /// wipes it, which is the black-idle-pane bug in miniature.
    final class Coordinator: TerminalDelegateBase {
        weak var view: TerminalView?
        var rows: [String] = []

        override func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            repaint()
        }

        func repaint() {
            guard let view, !rows.isEmpty else { return }
            let screen = TmuxSnapshot.screen(from: rows, columns: view.getTerminal().cols)
            view.feed(byteArray: Array(screen.utf8)[...])
        }
    }
}

/// Hides SwiftTerm's scroller, which is not cosmetic.
///
/// In SwiftTerm 1.20.0 `reservedScrollerWidth` is `scroller?.isHidden == true ? 0
/// : scrollerWidth` — it ignores `scrollerStyle` entirely, and nothing in the
/// library ever hides the scroller. So **every** view silently reserves ~17pt,
/// which is a whole column at tile size.
///
/// Note the version: an earlier reading of this same property came from
/// SwiftTerm's `main`, where it also checks `scrollerStyle == .legacy` and
/// setting `.overlay` would have been enough. Read `.build/checkouts`, not a
/// fresh clone.
class NoScrollerTerminalView: TerminalView {
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview is NSScroller { subview.isHidden = true }
    }
}

/// `TerminalViewDelegate` has a dozen members. SwiftTerm supplies defaults for
/// most of them, but not all — `rangeChanged` in particular — so this collects
/// the no-ops in one place and each coordinator overrides only what it needs.
class TerminalDelegateBase: NSObject, TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A one-shot `capture-pane` of a session, framed as bytes a terminal can draw.
///
/// Nothing here attaches a client, which is the entire reason the session grid
/// is snapshots: every tmux client on a session sets the shared window size, so
/// a grid of live clients would letterbox that many real sessions down to tile
/// size until it was closed.
enum TmuxSnapshot {

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
