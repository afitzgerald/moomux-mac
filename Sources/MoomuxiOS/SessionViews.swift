import MoomuxKit
import SwiftUI

/// Both screens on one path type. Mixing `navigationDestination(for:)` with
/// `navigationDestination(isPresented:)` pushed an *empty* destination when the
/// deep link opened the terminal at launch — a back chevron and nothing else —
/// so there is one route enum and one destination.
/// The size an attached pane opens at. Shared between the list's menu, which
/// sets it, and `TerminalScreen`, which reads it when building a surface.
enum TerminalFontSize {
    static let key = "terminalFontSize"
    static let `default` = 11.0
    /// The range that is useful on a phone: the window reflows to this client,
    /// so 8pt is ~62 columns and 16pt is ~30. Below ~50 a diff hard-wraps
    /// mid-token; above it prose gets hard to read at arm's length.
    static let choices: [Double] = [8, 9, 10, 11, 12, 14, 16]
}

enum Route: Hashable {
    case detail(Session.ID)
    case terminal(Session.ID)
}

// MARK: - List

/// Project-first, the same order the core served — `AppState.sessionsByProject`
/// is the Mac sidebar's source too, so the two front ends cannot disagree
/// about what is in the list or what order it is in.
struct SessionListView: View {
    @Bindable var app: AppState
    let endpoint: EndpointStore
    let disconnect: () -> Void
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.default
    /// The folder a Rename… is open for, and the text being typed. An alert
    /// rather than the Mac's sheet: one field, one question.
    @State private var renaming: String?
    @State private var renameTo = ""
    /// `-newSession YES` opens the sheet at launch — the screenshot seam, same
    /// idea as `-openSession` below.
    @State private var creating = UserDefaults.standard.bool(forKey: "newSession")
    /// Screenshot seam. There is no way to tap a row from `simctl`, so
    /// `-openSession <id>` opens one straight away and `make ios-shot
    /// SESSION=<id>` can photograph the detail screen. A `UserDefaults` key,
    /// so it costs nothing when unset.
    @State private var path: [Route] = {
        guard let id = UserDefaults.standard.string(forKey: "openSession") else { return [] }
        return UserDefaults.standard.bool(forKey: "attach")
            ? [.detail(id), .terminal(id)] : [.detail(id)]
    }()

    /// The default lens: a section per project, with the core's folder
    /// headers spliced in under each.
    @ViewBuilder
    private var projectFirstSections: some View {
        ForEach(app.sessionsByProject, id: \.project) { group in
            Section(header: ProjectHeader(app: app, name: group.project,
                                          count: group.sessions.count)) {
                // `sidebarRows` is the core's own layout for this project —
                // `sessionview.Rows`, with folder headers spliced in —
                // filtered to what this window shows. Iterating
                // `group.sessions` instead was what dropped folders on the
                // floor: it is the flat membership list, and the grouping
                // lives in the layout.
                ForEach(app.sidebarRows(of: group.project, in: group.sessions)) { row in
                    switch row {
                    case let .folder(name, collapsed, count):
                        FolderHeader(app: app, name: name, collapsed: collapsed,
                                     count: count, project: group.project,
                                     renaming: $renaming)
                    case let .session(session, folder):
                        // A session sits one level in from the header it is
                        // grouped under: 1 under a project, 2 under a folder.
                        sessionRow(session, indent: folder.isEmpty ? 1 : 2)
                    }
                }
            }
        }
    }

    /// Show a session's pane, reusing the one already in the stack rather
    /// than pushing a second.
    ///
    /// Pushing blindly is wasteful in a way that shows: each `TerminalScreen`
    /// is its own `Attach`, so pane → ⓘ → Review would leave two tmux clients
    /// on one session, the buried one still holding a size the visible one
    /// then fights over. Truncating to the existing terminal also puts Back
    /// where it belongs — at the list, not at a stale copy of the same pane.
    ///
    /// A terminal for a *different* session is dropped rather than buried, for
    /// the same reason: a tapped banner (`onChange(of: selectedSessionID)`)
    /// would otherwise push B's pane over A's, and the buried one keeps its
    /// `AttachChannel` open — two tmux clients, with A sized to this phone
    /// until the user pops back through it.
    private func showTerminal(_ id: Session.ID) {
        if let at = path.firstIndex(of: .terminal(id)) {
            path.removeSubrange((at + 1)...)
            return
        }
        if let at = path.firstIndex(where: { if case .terminal = $0 { true } else { false } }) {
            path.removeSubrange(at...)
        }
        path.append(.terminal(id))
    }

    /// One session. Shared by both lenses, and the only place the tap rule
    /// lives.
    ///
    /// Tapping a live row attaches — that is the primary action and it should
    /// not be buried. A *parked* row opens detail instead, because `Attach`
    /// calls `EnsureTmux` and would revive the session: measured, a tap on a
    /// parked row stood a tmux session and its agent back up within a second.
    /// The Mac sidebar gates auto-attach on `isAlive` for exactly this reason,
    /// and a phone needs it more, not less — a tap is the only gesture there
    /// is, so a mis-tap while scrolling would start an agent.
    @ViewBuilder
    private func sessionRow(_ session: Session, indent: Int) -> some View {
        // `onTapGesture`, not a `Button`: a Button's own gesture recogniser
        // wins the long press, so `.contextMenu` on it never fires —
        // measured first on the folder header, which is built this way for
        // the same reason, as is the Mac's.
        SessionRow(app: app, session: session)
            .contentShape(Rectangle())
            .onTapGesture {
                if app.isAlive(session) { showTerminal(session.id) }
                else { path.append(.detail(session.id)) }
            }
            // One item, deliberately. Archive and Details are already a swipe
            // away, forms belong on a screen rather than in a menu, and Delete
            // wants the warning that names dirty files and unpushed commits —
            // all of which live in detail. Review is here because it is the
            // one action worth taking *without* leaving the list: it opens the
            // diff in the session's own tmux, ready for when you attach.
            .contextMenu {
                Button("Review Changes") {
                    app.review(session)
                    showTerminal(session.id)
                }
                .disabled(!app.canReview(session))
            }
        .swipeActions(edge: .trailing) {
            Button(session.archived ? "Unarchive" : "Archive") {
                app.setArchived(session, !session.archived)
            }
            .tint(.indigo)
            Button("Details") { path.append(.detail(session.id)) }
                .tint(.gray)
        }
        // `rowIndent`, not `indent`: a session pays for the disclosure column
        // it has no chevron for, which is what puts its state icon one clean
        // step right of the icon of the header above it.
        .padding(.leading, SidebarGrid.rowIndent(indent - 1, SidebarGrid.phoneFont))
    }


    /// The folder-first lens — `Snapshot.FolderRows`: every folder at the top
    /// level with a project subheader under it, then the sessions filed
    /// nowhere, by project, last. One flat list rather than sections, because
    /// the top level is folders and a section header cannot nest.
    ///
    /// A project *subheader* inside a folder folds locally
    /// (`AppState.setFolderProject`), not through `SetProjectCollapsed`: the
    /// same project has a subheader under every folder it has members in, and
    /// folding all of them plus the loose block at once is not what a
    /// disclosure triangle means.
    @ViewBuilder
    private var folderFirstRows: some View {
        ForEach(app.folderSidebarRows) { row in
            switch row {
            case let .folder(name, collapsed, count):
                FolderHeader(app: app, name: name, collapsed: collapsed,
                             count: count, project: "", level: 0,
                             renaming: $renaming)
            case let .project(folder, name, collapsed, hidden):
                // The loose block — the sessions filed nowhere — is a *real*
                // project header, folded by the core's `SetProjectCollapsed`.
                // Only a genuine subheader inside a folder folds locally.
                //
                // Rendering both the same way is a one-way door: `AppState.
                // collapsedGroups` derives the loose block's key from the
                // core's flag, so a local toggle writes a set that is never
                // consulted for it and the block can never be expanded again.
                if folder.isEmpty {
                    ProjectHeader(app: app, name: name, count: hidden)
                } else {
                Button {
                    app.setFolderProject(folder: folder, project: name, expanded: collapsed)
                } label: {
                    HStack(spacing: SidebarGrid.gap) {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .frame(width: SidebarGrid.disclosure(SidebarGrid.phoneFont))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text([app.emoji(for: name), name]
                            .compactMap { $0 }.joined(separator: " "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                    }
                    .contentShape(Rectangle())
                    .padding(.leading, SidebarGrid.indent(1, SidebarGrid.phoneFont))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(collapsed && hidden > 0 ? "\(name), collapsed, \(hidden) sessions" : name)
                }
            case let .session(session, indent):
                sessionRow(session, indent: indent)
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if app.connection.isDown { ConnectionRow(app: app) }
                if app.folderView { folderFirstRows } else { projectFirstSections }
            }
            .listStyle(.insetGrouped)
            // No title: "Sessions" named the only screen there is, and on a
            // phone a large title costs a row of sessions to say nothing.
            .navigationBarTitleDisplayMode(.inline)
            // The destination is unconditional and each screen looks its own
            // session up in its own `body`. Resolving it *here* looked
            // identical and was wrong: this closure is not a view body, so the
            // read of `app.sessions` registers no dependency — a deep link that
            // ran before the first snapshot rendered an empty destination (a
            // back chevron and nothing else) and never re-evaluated when the
            // sessions arrived.
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .detail(id):
                    SessionDetailView(app: app, sessionID: id, showTerminal: showTerminal)
                case let .terminal(id): TerminalScreen(app: app, sessionID: id)
                }
            }
            .searchable(text: $app.searchQuery, prompt: "Search names")
            .refreshable { await app.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        // Disabled, and *checked* off `folderView` rather than
                        // the stored preference: a remembered `folderFirst`
                        // against a core too old to send the layout would
                        // otherwise draw ticked over a project-first list with
                        // no way to clear it. Same rule as the Mac's toolbar.
                        Toggle("Group by Folder", isOn: Binding(
                            get: { app.folderView },
                            set: { app.folderFirst = $0 }
                        ))
                        .disabled(app.folderRows.isEmpty)
                        Toggle("Archived Only", isOn: $app.showArchived)
                        Toggle("Open in MergeRight", isOn: $app.mergeRightLinks)
                        Picker("Terminal size", selection: $fontSize) {
                            ForEach(TerminalFontSize.choices, id: \.self) { size in
                                Text("\(Int(size)) pt").tag(size)
                            }
                        }
                        Button("Disconnect", role: .destructive) {
                            app.stop()
                            disconnect()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { StatusBadge(app: app) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New Session")
                        .disabled(app.connection.isDown || app.config == nil)
                }
            }
            .alert("Rename folder", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameTo)
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    if let from = renaming, !renameTo.trimmed.isEmpty, renameTo.trimmed != from {
                        app.renameFolder(from: from, to: renameTo.trimmed)
                    }
                    renaming = nil
                }
            } message: {
                // Worth saying: the namespace is global, so this is not a
                // per-project rename even though the header sits under one.
                Text("Folders are global — this renames it everywhere.")
            }
            .onChange(of: renaming) { _, folder in renameTo = folder ?? "" }
            // Go to the new session only if the user is still on the list: a create
            // takes tens of seconds, and by then they may be typing in another
            // session's terminal, which a jump would detach.
            .sheet(isPresented: $creating) { NewSessionSheet(app: app, focus: { path.isEmpty }) }
            // A tapped banner is a request to go to that session, and
            // `Notifier` has no way to reach the stack — it sets the
            // selection, which on the Mac *is* the navigation. Cleared after,
            // so tapping a banner for the same session twice works.
            .onChange(of: app.selectedSessionID) { _, id in
                guard let id else { return }
                // Same gate as the row tap: attaching revives a parked
                // session and relaunches its agent, and a banner can outlive
                // the tmux it was raised for.
                if let session = app.session(id: id), app.isAlive(session) { showTerminal(id) }
                else { path.append(.detail(id)) }
                app.selectedSessionID = nil
            }
            .overlay {
                // `.connected`, not merely "not down": `connection` stays
                // `.connecting` until the first call returns, and a remembered
                // host that is asleep or off-tailnet takes the socket's whole
                // 5s deadline to say so — which would read as a confident "no
                // sessions" until it did. Same rule as `refresh` keeping the
                // last-good list: a failed call must not look empty.
                if app.sessions.isEmpty, app.connection == .connected {
                    ContentUnavailableView("No sessions", systemImage: "rectangle.on.rectangle")
                }
            }
        }
        // On the stack rather than on the `List`, so it still appears over a
        // pushed pane: every refusal funnels into `actionError`, and the one
        // that needs it most — a review the core refused — is raised from a
        // screen that has just navigated to the terminal as though it worked.
        .alert("Couldn't do that", isPresented: Binding(
            get: { app.actionError != nil },
            set: { if !$0 { app.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.actionError ?? "")
        }
    }
}

/// A folder inside a project. Collapsing is one global bit on the core, so it
/// folds that folder in every project at once — `SetFolderCollapsed`'s own
/// behaviour, not something this app decides.
private struct FolderHeader: View {
    let app: AppState
    let name: String
    let collapsed: Bool
    let count: Int
    /// Which project's members this header is showing. Empty means every
    /// project, which is what a folder header in the folder-first lens spans
    /// — and what `AppState.setArchived` reads it as. A header drawn *inside*
    /// a project's section must pass that project, or Archive All reaches
    /// sessions it is not showing.
    let project: String
    /// How many levels in: one under a project header, none in the
    /// folder-first lens where a folder *is* the top level.
    var level = 1
    @Binding var renaming: String?

    var body: some View {
        // Row content plus `onTapGesture`, **not** a `Button`. A Button's own
        // gesture swallows the long press, so `.contextMenu` on it never
        // fires — measured: a slow hold on a folder produced nothing at all.
        // Same family as `CLAUDE.md`'s "a tap gesture on a List row's content
        // beats the List's own selection", and the Mac's `FolderHeader` is
        // built this way for the same reason.
        Group {
            HStack(spacing: SidebarGrid.gap) {
                // One chevron, *rotated* rather than swapped for a different
                // glyph — the Mac's `FolderHeader` does the same, and it is
                // why the Mac never had the name-shifts-sideways problem:
                // `chevron.right` and `chevron.down` are not the same width.
                // The fixed frames are this list's version of `SidebarGrid`'s
                // columns, since `folder.fill` is wider than `folder` too.
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarGrid.disclosure(SidebarGrid.phoneFont))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Image(systemName: collapsed ? "folder.fill" : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarGrid.icon(SidebarGrid.phoneFont))
                Text(name).font(.subheadline.weight(.medium))
                Spacer(minLength: 6)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
            .padding(.leading, SidebarGrid.indent(level, SidebarGrid.phoneFont))
        }
        .contentShape(Rectangle())
        .onTapGesture { app.setFolder(name: name, collapsed: !collapsed) }
        // The Mac's folder context menu, minus Rename's sheet — a phone gets
        // an alert with a field, which is the same question with less
        // machinery. Delete is not confirmed for the same reason it is not
        // there: it files members back at the top level and removes nothing.
        .contextMenu {
            Button("Rename…") { renaming = name }
            Button("Archive All") { app.setArchived(project: project, folder: name, true) }
            Button("Unarchive All") { app.setArchived(project: project, folder: name, false) }
            Divider()
            Button("Delete", role: .destructive) { app.deleteFolder(name: name) }
        }
        // Spoken, not drawn. `CLAUDE.md`: "the *number* is spoken, not drawn:
        // no header renders a count badge any more" — `count` exists to decide
        // what is drawn at all and to fill this label.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(collapsed && count > 0 ? "\(name), collapsed, \(count) sessions" : name)
    }
}

/// A project header, and the control that expands it.
///
/// Tappable because the list now draws the core's layout, which honours
/// `SetProjectCollapsed` — so a collapsed project renders as a header with
/// nothing under it, and without this there is no way to open it again. The
/// flag is the core's and survives a restart, so it reads the same in both
/// front ends.
private struct ProjectHeader: View {
    let app: AppState
    let name: String
    /// What a collapsed header is hiding. Spoken in the accessibility label,
    /// never drawn — same rule as `FolderHeader`.
    let count: Int

    var body: some View {
        let expanded = app.projectExpanded(name)
        Button {
            app.setProject(name, expanded: !expanded)
        } label: {
            HStack(spacing: SidebarGrid.gap) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .frame(width: SidebarGrid.disclosure(SidebarGrid.phoneFont))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                // An empty emoji draws nothing rather than a computed glyph,
                // same as the Mac app — `emoji(for:)` returns only what the
                // core serves as `project_emoji`.
                Text([app.emoji(for: name), name].compactMap { $0 }.joined(separator: " "))
                Spacer(minLength: 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(expanded || count == 0 ? name : "\(name), collapsed, \(count) sessions")
    }
}

private struct SessionRow: View {
    let app: AppState
    let session: Session

    var body: some View {
        // One line: state icon, name, badges right-aligned. The Mac puts the
        // badges on a second line, which it can afford in a wide sidebar — on
        // a phone that cost about half a row of height per session and pushed
        // three sessions off the screen. A long name truncates instead, which
        // is the cheaper loss: the badges are fixed-width and the tail of a
        // name is usually the least distinguishing part of it.
        //
        // The quip is not here either — it is on the pane's title, where it is
        // about the session you are in rather than one of thirty you are
        // scrolling past.
        HStack(spacing: SidebarGrid.gap) {
            // `AgentState.symbol` and `PRInfo.Badge.symbol` live in the Kit
            // and the colors come from `SessionTheme`, which reads the palette
            // the core serves — so this row and the Mac sidebar agree by
            // construction rather than by two tables kept in step.
            Image(systemName: app.state(for: session).symbol)
                .foregroundStyle(SessionTheme.color(app.state(for: session), app.palette))
                .frame(width: SidebarGrid.icon(SidebarGrid.phoneFont))
                .accessibilityLabel(app.state(for: session).label)
            Text(session.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Badges(app: app, session: session)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct SessionDetailView: View {
    let app: AppState
    let sessionID: Session.ID
    /// Review opens a window *inside the session's tmux*, so it is only worth
    /// anything if the app then shows that tmux. On the Mac the pane is
    /// already on screen and the window switch just happens; here the screen
    /// has to follow, or the action looks like it did nothing. A closure
    /// rather than the path itself: the list owns how the stack is shaped,
    /// including reusing a pane already on it.
    let showTerminal: (Session.ID) -> Void
    /// Deleting a session removes the screen's subject, so it leaves too.
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var tagging = false
    @State private var ticket = ""
    @State private var pr = ""

    var body: some View {
        if let session = app.session(id: sessionID) {
            detail(session)
        } else {
            // Before the first snapshot, and after a delete.
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func detail(_ session: Session) -> some View {
        List {
            Section {
                // Not gated, unlike the row tap: reviving a parked session
                // is fine as a deliberate button press — it is a mis-tap
                // while scrolling the list that must not start an agent.
                //
                // Through `showTerminal`, not a `NavigationLink`: reached
                // from a pane (row → ⓘ) the stack already holds this
                // session's terminal, and pushing a second one leaves two
                // `Attach`es on one tmux session fighting over its size.
                Button {
                    showTerminal(session.id)
                } label: {
                    Label("Attach", systemImage: "terminal")
                }
            }
            // What the last action on this session had to say — a create's
            // userscript warnings or a first prompt that did not land.
            if let hint = app.sessionHints[session.id] {
                Section("Last action") {
                    Text(hint).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Image(systemName: app.state(for: session).symbol)
                            .foregroundStyle(SessionTheme.color(app.state(for: session), app.palette))
                        Text(app.label(for: session))
                    }
                }
                if let quip = app.quip(for: session) {
                    LabeledContent("Doing", value: quip)
                }
                LabeledContent("Project", value: session.project)
                LabeledContent("Branch", value: session.branch)
                LabeledContent("Agent", value: session.agentName)
                if session.dangerous {
                    Label("Permissions skipped", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            // Tappable here rather than in the list: the row's own tap
            // attaches, and a 12pt glyph beside it is a mis-tap waiting to
            // start a tmux client you did not want. In detail they are full
            // rows with room to aim at.
            Section {
                Button {
                    app.review(session)
                    showTerminal(sessionID)
                } label: {
                    Label("Review Changes", systemImage: "plus.forwardslash.minus")
                }
                .disabled(!app.canReview(session))
                Button {
                    newName = session.name
                    renaming = true
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button {
                    ticket = session.ticket ?? ""
                    pr = session.pr ?? ""
                    tagging = true
                } label: {
                    Label("Tags…", systemImage: "ticket")
                }
            } footer: {
                // Why it is greyed, rather than leaving the user to guess. The
                // core refuses a parked session by name rather than reviving
                // it, because asking for a diff must not relaunch an agent.
                if !app.canReview(session) {
                    Text("Review needs a live session.")
                }
            }

            if WebLink.url(session.ticket) != nil || WebLink.url(session.pr) != nil {
                Section {
                    if let url = WebLink.url(session.ticket) {
                        Link(destination: url) { Label("Ticket", systemImage: "ticket") }
                    }
                    if let url = WebLink.url(session.pr) {
                        Link(destination: url) {
                            Label("Pull request", systemImage: "arrow.triangle.pull")
                        }
                    }
                    // Hidden without MergeRight installed, where the scheme
                    // opens nothing (`canOpenURL` needs the scheme listed in
                    // LSApplicationQueriesSchemes).
                    if let link = app.mergeRightLink(for: session),
                       UIApplication.shared.canOpenURL(link) {
                        Link(destination: link) {
                            Label("Open in MergeRight", systemImage: "arrow.up.forward.app")
                        }
                    }
                }
            }

            if let pr = app.views[session.id]?.pr {
                Section("Pull request") {
                    LabeledContent("State", value: pr.state)
                    LabeledContent("Checks", value: pr.ci)
                    LabeledContent("Mergeable", value: pr.mergeable)
                    if pr.unresolved > 0 {
                        LabeledContent("Unresolved", value: "\(pr.unresolved)")
                    }
                }
            }

            let prompt = app.prompt(for: session)
            if !prompt.isEmpty {
                Section("First prompt") { Text(prompt).font(.callout) }
            }

            Section {
                Button(role: .destructive) {
                    app.askDelete(session)
                } label: {
                    Label("Delete Session", systemImage: "trash")
                }
            }
        }
        .labelStyle(RowLabel())
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        // One alert, and the information *is* the safeguard — the Mac asks
        // once too, because a second "are you sure" is a reflex while the
        // dirty/unpushed lines are not. `askDelete` re-fetches the worktree
        // status behind this, and until it lands the message says it is
        // checking rather than implying a check that never ran.
        .alert("Delete \(session.name)?", isPresented: Binding(
            get: { app.pendingDelete?.id == session.id },
            set: { if !$0 { app.dismissDelete() } }
        )) {
            Button("Cancel", role: .cancel) { app.dismissDelete() }
            Button("Delete", role: .destructive) {
                app.delete(session)
                dismiss()
            }
        } message: {
            Text(app.deleteWarning(for: session))
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = newName.trimmed
                guard !name.isEmpty, name != session.name else { return }
                // The whole edit in one call, as the Mac does it: the rename
                // no-ops when unchanged, and the agent is passed back verbatim
                // rather than defaulted, since nothing here is changing it.
                app.edit(session, name: name,
                         agent: session.agentName, dangerous: session.dangerous)
            }
        }
        .alert("Tags", isPresented: $tagging) {
            TextField("Ticket URL", text: $ticket).textInputAutocapitalization(.never)
            TextField("PR URL", text: $pr).textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Save") { app.setTags(session, ticket: ticket.trimmed, pr: pr.trimmed) }
        }
        .task { await app.loadStatus(for: session.id) }
    }
}

// MARK: - Bits

/// The Mac sidebar's badge row, in its order: ticket, PR (carrying its own
/// merge/CI state), then `internal/tui/list.go`'s two git icons — ± for a
/// dirty worktree, ↑ for commits not on the remote. Both git icons can show at
/// once; they are different work in different places and collapsing them would
/// hide one. Archived last, and only in a search — the one list that mixes
/// archived rows in with live ones.
private struct Badges: View {
    let app: AppState
    let session: Session

    var body: some View {
        HStack(spacing: 5) {
            if let ticket = session.ticket, !ticket.isEmpty {
                Image(systemName: "ticket").foregroundStyle(.secondary)
            }
            if let pr = session.pr, !pr.isEmpty {
                let badge = PRInfo.badge(app.views[session.id]?.pr)
                Image(systemName: badge.symbol)
                    .foregroundStyle(SessionTheme.pr(badge, app.palette))
                    .accessibilityLabel(badge.help)
            }
            if let git = app.gitBadges(for: session) {
                if git.dirty {
                    Image(systemName: "plusminus")
                        .foregroundStyle(SessionTheme.gitWarn(app.palette))
                        .accessibilityLabel("Uncommitted changes")
                }
                if git.unpushed {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(SessionTheme.gitWarn(app.palette))
                        .accessibilityLabel("Unpushed commits")
                }
            }
            if session.archived && app.searching {
                Image(systemName: "archivebox")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Archived")
            }
        }
        .font(.caption2)
    }
}

private struct StatusBadge: View {
    let app: AppState

    var body: some View {
        // A write in flight outranks the connection state: `mutate` sets
        // `busy` for every action, and a worktree create takes tens of
        // seconds with nothing else on screen to say so.
        if app.busy != nil {
            ProgressView().controlSize(.small)
        } else {
            connectionState
        }
    }

    @ViewBuilder
    private var connectionState: some View {
        switch app.connection {
        case .connecting: ProgressView().controlSize(.small)
        case .connected: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .down: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Icon-and-text rows in a `List` or `Form`. A list gives a `Label` a wide
/// icon column and centres each glyph in it, so the text lines up but the gap
/// does not: the pencil sits far from "Rename…", the ticket close to "Tags…",
/// and Photos further from its text than Files. Glyphs pinned
/// to the trailing edge of a column as wide as the widest one make every gap
/// the same 8pt; the price is a slightly ragged left edge of icons.
struct RowLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    /// A view of its own so the column can grow with Dynamic Type — a fixed
    /// 30pt is overrun by a large glyph at accessibility sizes.
    private struct Row: View {
        let configuration: Configuration
        @ScaledMetric private var width = 30.0

        var body: some View {
            HStack(spacing: 8) {
                configuration.icon.imageScale(.large).frame(width: width, alignment: .trailing)
                configuration.title
            }
        }
    }
}

/// A failed call must not read as "no sessions" — `AppState.refresh` keeps the
/// last good list and reports through `connection`, so this row is the only
/// thing that changes when the core goes away.
private struct ConnectionRow: View {
    let app: AppState

    var body: some View {
        if case let .down(why) = app.connection {
            Label(why, systemImage: "bolt.horizontal.circle")
                .labelStyle(RowLabel())
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
