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

    // MARK: - Folder-first

    /// One line of the folder-first sidebar.
    public enum FolderSidebarRow: Identifiable, Hashable, Sendable {
        case folder(name: String, collapsed: Bool, count: Int)
        /// A project header: a subheader inside a folder, or — with `folder`
        /// empty — the trailing block of sessions filed nowhere. `hidden` is
        /// what its own collapse is keeping off screen, 0 when it is open.
        case project(folder: String, name: String, collapsed: Bool, hidden: Int)
        case session(Session, indent: Int)

        public var id: String {
            switch self {
            case let .folder(name, _, _): return "folder:\(name)"
            case let .project(folder, name, _, _): return "sub:\(folder)/\(name)"
            case let .session(session, _): return session.id
            }
        }

        public var session: Session? {
            if case let .session(s, _) = self { return s }
            return nil
        }
    }

    /// One (folder, project) group's key in `collapsedGroups` — the loose
    /// block is the group whose folder is "".
    public static func groupKey(folder: String, project: String) -> String {
        "\(folder)\u{0}\(project)"
    }

    /// The folder-first layout (`Snapshot.folderRows`) filtered to what this
    /// window is showing, on the same rules as `rows(_:shown:searching:)`: a
    /// header with nothing in `shown` is not drawn, a collapsed one draws with
    /// the count of what it hides, and a search reaches inside both.
    ///
    /// `collapsedGroups` holds `groupKey`s, so one rule covers both project
    /// header kinds — the loose block's (the core's own `collapsed` flag) and a
    /// subheader's (this window's, since one project appears under every folder
    /// it has members in and folding them all at once is not what a disclosure
    /// triangle means). `pinned` is the selected and attached session, which no
    /// collapse may take off screen.
    public static func folderRows(_ layout: [FolderRow], shown: [Session], searching: Bool,
                                  collapsedGroups: Set<String> = [],
                                  pinned: String? = nil) -> [FolderSidebarRow] {
        let sessions = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // What each header has in *this* view — the core's own counts are of
        // every member, which overstates a filtered or searched list.
        var members: [String: Int] = [:]
        var folders: [String: Int] = [:]
        var pinnedGroup: String?
        for row in layout where row.kind == .session && sessions[row.id] != nil {
            members[groupKey(folder: row.folder, project: row.project), default: 0] += 1
            folders[row.folder, default: 0] += 1
            if row.id == pinned { pinnedGroup = groupKey(folder: row.folder, project: row.project) }
        }

        var out: [FolderSidebarRow] = []
        for row in layout {
            let group = groupKey(folder: row.folder, project: row.project)
            switch row.kind {
            case .folder:
                guard let count = folders[row.folder] else { continue }
                out.append(.folder(name: row.folder, collapsed: row.collapsed && !searching,
                                   count: count))
            case .project:
                guard !(row.hidden && !searching), let count = members[group] else { continue }
                let collapsed = collapsedGroups.contains(group)
                out.append(.project(folder: row.folder, name: row.project, collapsed: collapsed,
                                    hidden: collapsed ? count - (group == pinnedGroup ? 1 : 0) : 0))
            case .session:
                guard let session = sessions[row.id], !(row.hidden && !searching) else { continue }
                guard !collapsedGroups.contains(group) || row.id == pinned else { continue }
                // Always one level in from whatever header it sits under: a
                // project subheader inside a folder (two levels), or the loose
                // block's own project header (one).
                out.append(.session(session, indent: row.folder.isEmpty ? 1 : 2))
            }
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

        folderDemo()
    }

    /// The folder-first layout, on the shape `BuildFolderRows` produces:
    /// [work: one/a, two/b], then the loose block one/c, two/d.
    private static func folderDemo() {
        func sess(_ id: String, _ project: String, _ folder: String) -> Session {
            try! Wire.decoder.decode(Session.self, from: Data(
                #"{"id":"\#(id)","name":"\#(id)","project":"\#(project)","folder":"\#(folder)"}"#
                    .utf8))
        }
        func layout(collapsed: Bool) -> [FolderRow] {
            [FolderRow(kind: .folder, folder: "work", collapsed: collapsed, count: 2),
             FolderRow(kind: .project, folder: "work", project: "one", hidden: collapsed, count: 1),
             FolderRow(kind: .session, folder: "work", project: "one", id: "a", hidden: collapsed),
             FolderRow(kind: .project, folder: "work", project: "two", hidden: collapsed, count: 1),
             FolderRow(kind: .session, folder: "work", project: "two", id: "b", hidden: collapsed),
             FolderRow(kind: .project, project: "one", count: 1),
             FolderRow(kind: .session, project: "one", id: "c"),
             FolderRow(kind: .project, project: "two", count: 1),
             FolderRow(kind: .session, project: "two", id: "d")]
        }
        let all = [sess("a", "one", "work"), sess("b", "two", "work"),
                   sess("c", "one", ""), sess("d", "two", "")]

        let open = folderRows(layout(collapsed: false), shown: all, searching: false)
        assert(open.map(\.id) == ["folder:work", "sub:work/one", "a", "sub:work/two", "b",
                                  "sub:/one", "c", "sub:/two", "d"], "\(open.map(\.id))")
        // Every session one level in from its own header: folder › project ›
        // session is two, the loose block's project › session is one.
        assert(open.compactMap { if case let .session(s, indent) = $0 { return (s.id, indent) }
                                 else { return nil } }
            .allSatisfy { $0.0 == "a" || $0.0 == "b" ? $0.1 == 2 : $0.1 == 1 })

        let shut = folderRows(layout(collapsed: true), shown: all, searching: false)
        assert(shut.map(\.id) == ["folder:work", "sub:/one", "c", "sub:/two", "d"],
               "a collapsed folder hides its whole subtree")
        if case let .folder(_, collapsed, count) = shut[0] { assert(collapsed && count == 2) } else {
            assert(false, "row 0 must be the folder header")
        }

        // Search reaches inside a collapsed folder, and a header with no match
        // is not drawn at all — neither the folder's nor its subheader's.
        let found = folderRows(layout(collapsed: true), shown: [sess("b", "two", "work")],
                               searching: true)
        assert(found.map(\.id) == ["folder:work", "sub:work/two", "b"], "\(found.map(\.id))")
        let none = folderRows(layout(collapsed: false), shown: [sess("c", "one", "")],
                              searching: false)
        assert(none.map(\.id) == ["sub:/one", "c"], "\(none.map(\.id))")

        // One rule for both project header kinds: a collapsed group keeps its
        // header, counts what it hides, and drops its rows. Here one group in
        // a folder and one in the loose block, at once.
        let folded = folderRows(layout(collapsed: false), shown: all, searching: false,
                                collapsedGroups: [groupKey(folder: "work", project: "one"),
                                                  groupKey(folder: "", project: "one")])
        assert(folded.map(\.id) == ["folder:work", "sub:work/one", "sub:work/two", "b",
                                    "sub:/one", "sub:/two", "d"], "\(folded.map(\.id))")
        for row in folded {
            if case let .project(_, name, collapsed, hidden) = row {
                assert(collapsed == (name == "one"), "\(name)")
                assert(hidden == (name == "one" ? 1 : 0), "\(name) \(hidden)")
            }
        }
        // The attached session survives its group folding, and is not counted
        // as hidden.
        let pinned = folderRows(layout(collapsed: false), shown: all, searching: false,
                                collapsedGroups: [groupKey(folder: "work", project: "one")],
                                pinned: "a")
        assert(pinned.map(\.id).contains("a"))
        if case let .project(_, _, _, hidden) = pinned[1] { assert(hidden == 0, "\(hidden)") } else {
            assert(false, "row 1 must be the subheader")
        }
    }
}
