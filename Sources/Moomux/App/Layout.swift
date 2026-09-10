import Foundation

/// The sidebar's list, and the reorder that acts on it.
///
/// Both are ports of `internal/sessionview`: `rows(...)` filters the layout the
/// core already derived (`Snapshot.rows`) down to what this window is showing,
/// and `reorder(...)` is `sessionview.Reorder` — the one piece a client cannot
/// be handed, because `ReorderSessions` takes the order the *client* is
/// displaying. Nothing here groups or sorts; the core does that.
public enum Layout {

    /// One line of the sidebar under a project header.
    public enum SidebarRow: Identifiable, Hashable, Sendable {
        case folder(name: String, collapsed: Bool, count: Int)
        /// `folder` is the group this session is filed under, "" when loose —
        /// straight off the row, so nothing has to join back to the session.
        case session(Session, folder: String)

        public var id: String {
            switch self {
            case let .folder(name, _, _): return "folder:\(name)"
            case let .session(session, _): return session.id
            }
        }

        public var session: Session? {
            if case let .session(s, _) = self { return s }
            return nil
        }
    }

    /// The rows to draw for one project: the core's layout, minus the sessions
    /// this window is filtering out.
    ///
    /// `shown` is the already-filtered session list (archived toggle, search).
    /// A folder with nothing in that list draws no header at all — an empty
    /// row saying "0" is noise in a sidebar, and a folder whose members are
    /// all archived or all filtered out is not part of what the user asked to
    /// see. A *collapsed* folder still draws, with the count of what it is
    /// hiding, since its members are in `shown` and only its own state keeps
    /// them off screen. While `searching` a collapsed folder shows its matches
    /// rather than a count — a search answered by a row nobody can see is the
    /// same bug as a search answered by a collapsed project.
    public static func rows(_ layout: [Row], shown: [Session], searching: Bool) -> [SidebarRow] {
        let sessions = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // What each folder has in this view, which is both whether its header
        // is drawn at all and the number on it: the core's own counts are of
        // every member, which would overstate a filtered or searched list.
        var members: [String: Int] = [:]
        for row in layout where !row.isFolder && !row.folder.isEmpty && sessions[row.id] != nil {
            members[row.folder, default: 0] += 1
        }

        var out: [SidebarRow] = []
        for row in layout {
            guard !row.isFolder else {
                if let count = members[row.folder] {
                    out.append(.folder(name: row.folder, collapsed: row.collapsed && !searching,
                                       count: count))
                }
                continue
            }
            guard let session = sessions[row.id], !(row.hidden && !searching) else { continue }
            out.append(.session(session, folder: row.folder))
        }
        return out
    }

    /// A project's whole session order after moving `id` one step, or nil when
    /// the move has nowhere to go. `sessionview.Reorder`, rule for rule.
    ///
    /// A session inside a folder moves among its siblings and never silently
    /// escapes — leaving a folder is what assigning one is for. Anything else
    /// moves as a whole block, hopping an entire folder rather than landing in
    /// its middle, where the core's own layout would only pull it back out
    /// again (which is how "Move Up does nothing" used to happen).
    ///
    /// `skip` names rows this window is not showing: they keep their slots but
    /// are never chosen as the thing to swap with, so a move is never spent on
    /// a row the user cannot see.
    public static func reorder(_ layout: [Row], id: String, delta: Int,
                               skip: (String) -> Bool = { _ in false }) -> [String]? {
        guard delta != 0 else { return nil }
        var blocks = self.blocks(layout)
        var bi = -1, si = -1
        for (i, block) in blocks.enumerated() {
            if let j = block.ids.firstIndex(of: id) { bi = i; si = j }
        }
        guard bi >= 0 else { return nil }

        if !blocks[bi].folder.isEmpty {
            var ids = blocks[bi].ids
            var j = si + delta
            while j >= 0 && j < ids.count {
                if !skip(ids[j]) {
                    ids.swapAt(si, j)
                    blocks[bi].ids = ids
                    return blocks.flatMap(\.ids)
                }
                j += delta
            }
            return nil
        }

        var j = bi + delta
        while j >= 0 && j < blocks.count {
            // A folder always has something on screen — its header renders even
            // with every member filtered out.
            if !blocks[j].folder.isEmpty || blocks[j].ids.contains(where: { !skip($0) }) {
                blocks.swapAt(bi, j)
                return blocks.flatMap(\.ids)
            }
            j += delta
        }
        return nil
    }

    /// One movable unit: a loose session, or a folder with every member it owns.
    struct Block {
        var folder = ""
        var ids: [String] = []
    }

    static func blocks(_ layout: [Row]) -> [Block] {
        var blocks: [Block] = []
        for row in layout {
            if row.isFolder {
                blocks.append(Block(folder: row.folder))
            } else if !row.folder.isEmpty, blocks.last?.folder == row.folder {
                blocks[blocks.count - 1].ids.append(row.id)
            } else {
                blocks.append(Block(ids: [row.id]))
            }
        }
        return blocks
    }

    // MARK: - Checks

    static func demo() {
        func sess(_ id: String) -> Session {
            try! Wire.decoder.decode(Session.self, from: Data(
                #"{"id":"\#(id)","name":"\#(id)"}"#.utf8))
        }
        // a, [work: b, c], d — the shape BuildRows produces.
        func layout(collapsed: Bool) -> [Row] {
            [Row(id: "a"),
             Row(folder: "work", collapsed: collapsed, count: 2),
             Row(id: "b", folder: "work", hidden: collapsed),
             Row(id: "c", folder: "work", hidden: collapsed),
             Row(id: "d")]
        }
        let all = ["a", "b", "c", "d"].map { sess($0) }

        let open = rows(layout(collapsed: false), shown: all, searching: false)
        assert(open.map(\.id) == ["a", "folder:work", "b", "c", "d"], "\(open.map(\.id))")

        let shut = rows(layout(collapsed: true), shown: all, searching: false)
        assert(shut.map(\.id) == ["a", "folder:work", "d"], "a collapsed folder hides its members")
        if case let .folder(_, collapsed, count) = shut[1] { assert(collapsed && count == 2) } else {
            assert(false, "row 1 must be the header")
        }

        // A search reaches inside a collapsed folder, and draws no header for
        // one that matched nothing.
        let found = rows(layout(collapsed: true), shown: [sess("c")], searching: true)
        assert(found.map(\.id) == ["folder:work", "c"], "\(found.map(\.id))")
        let none = rows(layout(collapsed: true), shown: [sess("a")], searching: true)
        assert(none.map(\.id) == ["a"], "a folder with no match draws no header")

        // A folder with nothing in the current view draws nothing: a folder
        // with no members at all, and one whose only member is filtered out.
        let empty = rows([Row(folder: "later")], shown: [], searching: false)
        assert(empty.isEmpty, "an empty folder has no header")
        let filtered = rows(layout(collapsed: false), shown: [sess("a"), sess("d")],
                            searching: false)
        assert(filtered.map(\.id) == ["a", "d"], "\(filtered.map(\.id))")
        // ...but a collapsed one whose members are only hidden by its own state
        // still draws, counting what it is hiding rather than every member.
        let half = rows(layout(collapsed: true), shown: [sess("a"), sess("c"), sess("d")],
                        searching: false)
        assert(half.map(\.id) == ["a", "folder:work", "d"], "\(half.map(\.id))")
        if case let .folder(_, _, count) = half[1] { assert(count == 1, "\(count)") } else {
            assert(false, "row 1 must be the header")
        }

        // Reorder moves whole blocks, so `a` hops the folder rather than
        // landing between b and c.
        assert(reorder(layout(collapsed: false), id: "a", delta: 1) == ["b", "c", "a", "d"])
        assert(reorder(layout(collapsed: true), id: "d", delta: -1) == ["a", "d", "b", "c"],
               "a collapsed folder carries its hidden members with it")
        // Inside a folder, a member moves among its siblings and stays put.
        assert(reorder(layout(collapsed: false), id: "c", delta: -1) == ["a", "c", "b", "d"])
        assert(reorder(layout(collapsed: false), id: "b", delta: -1) == nil,
               "the first member cannot leave its folder by moving up")
        assert(reorder(layout(collapsed: false), id: "a", delta: -1) == nil, "off the top")
        assert(reorder(layout(collapsed: false), id: "nosuch", delta: 1) == nil)
        // Every id comes back, hidden ones included: Store.Reorder numbers what
        // it is handed 1..N, so a session left out keeps a stale Order that
        // then interleaves with the renumbered ones.
        assert(reorder(layout(collapsed: true), id: "a", delta: 1)?.count == 4)
        // A row the window is filtering out is never the one swapped with.
        assert(reorder([Row(id: "a"), Row(id: "b"), Row(id: "c")], id: "a", delta: 1,
                       skip: { $0 == "b" }) == ["c", "b", "a"])
    }
}
