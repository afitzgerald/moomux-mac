import AppKit
import SwiftUI

/// Loaded once and shared by every view that draws the cow mark — reading
/// and decoding the SVG from disk on every render (as each caller used to do
/// independently) is needless work for an image that never changes.
private let cowNoseImage: NSImage? = Bundle.main
    .url(forResource: "moomux-terminal-nose", withExtension: "svg")
    .flatMap(NSImage.init(contentsOf:))

/// `sharedBackgroundVisibility` is macOS 26 SDK API — referencing it at all,
/// even behind `#available`, fails to compile against an older SDK (that's
/// a *runtime* check; the symbol still has to exist at compile time). CI's
/// macos-15 runner has no such SDK. `#if compiler(>=6.2)` is a *compile*-time
/// gate instead: Xcode 26 is the first release whose Swift compiler reports
/// that version, and it always ships the macOS 26 SDK alongside it — so
/// whenever this branch is even parsed, the symbol is guaranteed present.
extension ToolbarContent {
    @ToolbarContentBuilder
    fileprivate func hidingSharedBackground() -> some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Semantic colors only — literal hex breaks dark mode.
enum Theme {
    static func color(_ state: AgentState) -> Color {
        switch state {
        case .needsInput: return .orange
        case .working: return .accentColor
        case .done: return .green
        case .parked: return .secondary
        case .unknown: return .secondary
        }
    }

    /// The sidebar's ± and ↑ badges. `internal/tui/list.go` draws both in
    /// `warnStyle`, which is built from the palette's *done* entry — so this is
    /// that same join, and re-theming `done` moves the badges with it.
    ///
    /// It does **not** currently render the TUI's color: `done` is amber there
    /// (`#e0af68` default, `#fabd2f` gruvbox, ANSI 11 terminal) and green here,
    /// so the badges come out green. Kept as the join rather than hardcoding
    /// amber on purpose — the mapping is the thing shared with the TUI, and
    /// fixing `color(.done)` fixes these too.
    static let gitWarn = color(.done)

    static let mono = Font.system(size: 12, design: .monospaced)
}

// MARK: - Root

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: Binding(
            get: { app.sidebarVisible ? .all : .detailOnly },
            set: { app.sidebarVisible = $0 != .detailOnly }
        )) {
            SessionList()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            // The grid replaces the detail column, not the window, so the
            // sidebar and the toolbar keep working while it is up.
            if app.showGrid {
                SessionGrid()
            } else if let session = app.session(id: app.selectedSessionID) {
                SessionDetail(session: session)
            } else {
                NoSessionSelectedView()
            }
        }
        // Blank rather than omitted: an unset title falls back to the
        // Window's own "moomux", which would duplicate RootTitle below.
        // `.toolbar(removing: .title)` looked like the fix for keeping
        // NSWindow.title accurate (Window menu, Mission Control) instead of
        // blank, but removing the default title item also frees the space
        // it reserved — every trailing toolbar button shifted left to fill
        // it. Not worth it for a menu few people open.
        .navigationTitle("")
        .toolbar {
            // The plain name/state/"moomux" title, replaced by the cow
            // "saying" the session's quip once one is selected and picked.
            // Declared once here — not per detail view — so every detail
            // state (grid, a session, none selected) builds the same toolbar
            // shape; splitting it across views was what caused the title to
            // flash into a mismatched, boxed-looking style switching between
            // them. `.navigation` puts it where the title used to read,
            // right after the sidebar toggle.
            //
            // macOS 26's Liquid Glass toolbar draws its own capsule around
            // every item's content by default — a ring around CowQuip's own
            // speech-bubble fill. `hidingSharedBackground` opts the item out
            // on that OS; older macOS never drew that ring to begin with.
            ToolbarItem(placement: .navigation) { RootTitle() }
                .hidingSharedBackground()
            ToolbarItem(placement: .status) { ConnectionBadge() }
            ToolbarItem {
                Button {
                    app.sheet = .create
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                // ⌘N lives on the File menu item, not here: two views claiming
                // the same shortcut is ambiguous and only one of them wins.
                .help("New session (⌘N)")
            }
            ToolbarItem {
                Toggle(isOn: $app.showGrid) { Label("Grid", systemImage: "square.grid.2x2") }
                    // ⌘G is Review Changes; the grid is the shifted one.
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help("Every live session at once, read-only. Click one to open it.")
            }
            ToolbarItem {
                Toggle("Archived", isOn: $app.showArchived)
                    .help("Show archived sessions")
            }
            ToolbarItem {
                Button {
                    Task {
                        await app.refresh()
                        // The expensive per-session state is only ever fetched
                        // on demand, so an explicit refresh is the one place it
                        // should be re-fetched rather than served from cache.
                        if let id = app.selectedSessionID {
                            await app.loadStatus(for: id, force: true)
                        }
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }
        }
        .task { app.start() }
        // A hint is what the *last action* had to say, and it is rendered in a
        // session's Info pane. Nothing else clears it, so without this an
        // "Opened a review window in moomux-a-1f2e." stays pinned under session
        // B indefinitely, describing something that happened to session A.
        .onChange(of: app.selectedSessionID) { _, _ in app.hint = nil }
        // Every modal hangs off the root, not off a row: the Session menu can
        // fire any of them with no row on screen at all.
        .sheet(item: $app.sheet) { sheet in
            switch sheet {
            case .create:
                NewSessionSheet()
            case let .edit(session):
                EditSessionSheet(session: session)
            case let .tags(session):
                TextFieldSheet(title: "Tags for “\(session.name)”",
                               labels: ["Ticket", "PR"],
                               values: [session.ticket ?? "", session.pr ?? ""]) {
                    app.setTags(session, ticket: $0[0], pr: $0[1])
                }
            case .settings:
                SettingsSheet()
            }
        }
        .alert(app.deleteStep == .warnUnsaved ? "This worktree may have work in it"
                                              : "Delete session?",
               isPresented: Binding(
            get: { app.pendingDelete != nil },
            set: { if !$0 { app.dismissDelete() } }
        ), presenting: app.pendingDelete) { session in
            switch app.deleteStep {
            case .warnUnsaved:
                // Not destructive, and not the default button: this step exists
                // to cost a deliberate second look, so the reflex key (Escape)
                // and the reflex button (Cancel) both keep the worktree.
                Button("Continue") { app.ackDelete() }
                Button("Cancel", role: .cancel) {}
            case .confirm:
                Button("Delete", role: .destructive) { app.delete(session) }
                Button("Cancel", role: .cancel) {}
            }
        } message: { session in
            Text(app.deleteStep == .warnUnsaved ? unsavedWarning(for: session)
                                                : deleteWarning(for: session))
        }
        // The whole visible surface of `actionError` for now: a refused action
        // has to say so somewhere, and an alert is the least that qualifies.
        .alert("Couldn't do that", isPresented: Binding(
            get: { app.actionError != nil },
            set: { if !$0 { app.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.actionError ?? "")
        }
    }

    /// The first step's message. Says what is actually at stake when the
    /// status is known, and says it is *unknown* when it is — "moomux hasn't
    /// looked" is information, and papering over it with the generic sentence
    /// would imply a check that never ran.
    private func unsavedWarning(for session: Session) -> String {
        let changes = app.statuses[session.id]?.changeSummary ?? ""
        guard !changes.isEmpty else {
            return "moomux hasn't checked \(session.worktreePath) for uncommitted or unpushed "
                + "work yet. Deleting removes the worktree either way."
        }
        return "\(session.name) has \(changes). Deleting removes the worktree, and that work "
            + "goes with it."
    }

    /// Reuses the status already fetched for the selected session rather than
    /// paying for a fresh `WorktreeStatus` round trip inside an alert — the same
    /// warning the TUI's confirm dialog shows, at no extra cost. A session that
    /// was never selected has no status, and then the alert is the base text.
    private func deleteWarning(for session: Session) -> String {
        let base = "Kills tmux, removes the worktree at \(session.worktreePath), "
            + "and deletes the branch if moomux made it."
        let changes = app.statuses[session.id]?.changeSummary ?? ""
        // First letter only. `.capitalized` title-cases every word, so the
        // server's "2 files changed, 2 commits unpushed" came out as "2 Files
        // Changed, 2 Commits Unpushed" — visibly not the same sentence the
        // detail pane shows.
        guard !changes.isEmpty else { return base }
        return "\(changes.prefix(1).uppercased())\(changes.dropFirst()). \(base)"
    }
}

/// The full new-session form — the same questions the TUI's dialog asks, now
/// that the core serves the agent/model/thinking table (`AgentOptions`) that
/// the pickers are built from. Nothing here hardcodes a list.
private struct NewSessionSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var form = NewSessionForm()

    private var projects: [String] { app.config?.orderedProjectNames ?? app.projects }
    private var project: Project? { app.config?.projects[form.project] }
    private var models: [String] { app.models(for: form.agent) }
    private var thinking: [String] { app.thinking(for: form.agent) }
    /// opencode has no fixed model list, so its control is a text field. Keyed
    /// off the list being empty rather than off the agent's name, so a future
    /// agent in the same position needs no change here.
    private var hasModelList: Bool { !models.isEmpty && form.agent != "opencode" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New session").font(.headline)
            Form {
                // ponytail: no `.focused()` here — a menu-style Picker
                // (NSPopUpButton) silently ignores FocusState on macOS.
                // Forcing it needs a custom NSViewRepresentable; not worth it
                // for focus-on-open alone.
                Picker("Project", selection: $form.project) {
                    Text("choose one").tag("")
                    ForEach(projects, id: \.self) { Text($0).tag($0) }
                }
                TextField("Name", text: $form.name)
                    .help("Names the branch, the worktree and the tmux session")
                // A short placeholder on purpose: a long one pushes the
                // field onto its own line in a grouped Form and the row
                // stops looking like the ones above it.
                TextField("Existing branch", text: $form.existingBranch,
                          prompt: Text("resume, don't cut"))
                TextField("Base branch", text: $form.baseBranch,
                          prompt: Text(project?.baseBranch ?? "the project's default"))
                    .disabled(project?.isPlain == true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("First prompt")
                    TextEditor(text: $form.prompt)
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 160)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                }
                TextField("Ticket", text: $form.ticket)
                TextField("PR", text: $form.pr)

                Picker("Agent", selection: $form.agent) {
                    // Only for a `prompt_agent` project, which starts with
                    // no agent chosen and must not silently pick one.
                    if form.agent.isEmpty { Text("choose one").tag("") }
                    ForEach(app.agentNames, id: \.self) { Text($0).tag($0) }
                }
                if hasModelList {
                    Picker("Model", selection: $form.model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField("Model", text: $form.modelText, prompt: Text("default"))
                        .help("\(form.agent) has no fixed model list — type one or leave it empty")
                }
                if !thinking.isEmpty {
                    Picker("Thinking", selection: $form.thinking) {
                        ForEach(thinking, id: \.self) { Text($0).tag($0) }
                    }
                    .help(form.agent == "codex"
                          ? "codex takes this as a real reasoning-effort flag"
                          : "Prepended to the first prompt — there is no CLI flag for it")
                }
                Toggle("Skip permission prompts", isOn: $form.dangerous)
                    .help(form.agent == "opencode"
                          ? "opencode has no permission-skipping flag — this does nothing for it"
                          : "claude: --dangerously-skip-permissions, codex: --yolo")
                Toggle("Send it (press Enter)", isOn: $form.autoSubmit)
                    .help("Off leaves the prompt typed but unsent, so you can look before it runs")
            }
            .formStyle(.grouped)
            // An empty `TextField` in a grouped Form draws no box at all, so a
            // blank field reads as a static label — the multi-line prompt field
            // as a large blank void. A border is the whole fix.
            .textFieldStyle(.roundedBorder)
            if !form.project.isEmpty && project?.promptAgent == true && form.agent.isEmpty {
                Text("This project asks for an agent every time — pick one above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Closes at once rather than waiting out the worktree and the
                // userscripts: `app.busy` reports progress in the toolbar, and
                // a refusal lands in the error alert either way.
                Button("Create") {
                    app.create(project: form.project, name: form.name,
                               existingBranch: form.existingBranch, baseBranch: form.baseBranch,
                               agent: form.agent, dangerous: form.dangerous,
                               model: form.modelToSend(hasModelList: hasModelList),
                               thinking: form.thinking, ticket: form.ticket, pr: form.pr,
                               prompt: form.prompt, autoSubmit: form.autoSubmit)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canCreate)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Seeded from the row being looked at — a second session in the same
        // project is the common case.
        .onAppear {
            form.project = app.session(id: app.selectedSessionID)?.project ?? ""
            form.autoSubmit = app.config?.autoSubmitDefault ?? false
            applyProject()
        }
        // The agent, and with it every list below it, belongs to the project.
        .onChange(of: form.project) { _, _ in applyProject() }
        .onChange(of: form.agent) { _, _ in form.clampChoices(models: models, thinking: thinking) }
        // The table arrives one round trip after the window, so a sheet opened
        // in that gap would seed its agent against an empty list.
        .onChange(of: app.agentNames) { _, _ in applyProject() }
    }

    private func applyProject() {
        form.applyProjectDefaults(project, agentNames: app.agentNames)
        form.clampChoices(models: models, thinking: thinking)
    }
}

/// Name, agent and the dangerous flag — the same three fields as the TUI's
/// edit-session form, saved the same way (rename, then agent).
private struct EditSessionSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @State private var name = ""
    @State private var agent = ""
    @State private var dangerous = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit “\(session.name)”").font(.headline)
            Form {
                TextField("Name", text: $name)
                Picker("Agent", selection: $agent) {
                    ForEach(app.agentNames, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Skip permission prompts", isOn: $dangerous)
                    .disabled(agent == "opencode")
                    .help(agent == "opencode"
                          ? "opencode has no permission-skipping flag"
                          : "claude: --dangerously-skip-permissions, codex: --yolo")
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            Text("Renaming also renames the tmux session. A new agent takes effect the next "
                 + "time this session is opened — the one already running keeps what it "
                 + "was launched with.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    app.edit(session, name: name, agent: agent, dangerous: dangerous)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            name = session.name
            // "" is not one of `agentNames`, and a session whose agent the core
            // no longer offers would leave the picker unselectable.
            agent = app.agentNames.contains(session.agentName)
                ? session.agentName : (app.agentNames.first ?? "claude")
            dangerous = session.dangerous
        }
    }
}

/// Rename is one text field and Tags is two, so they are one view.
private struct TextFieldSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let labels: [String]
    @State var values: [String]
    let onSave: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Form {
                ForEach(labels.indices, id: \.self) { i in
                    TextField(labels[i], text: $values[i])
                }
            }
            .formStyle(.grouped)
            // Without a border an empty field is invisible: the Tags sheet with
            // both fields blank looks like two static rows saying "Ticket" and "PR".
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(values); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// The empty-state artwork alone, with no caption — also stood in while a
/// selected session is deciding whether to auto-attach, where "No session
/// selected" would be wrong.
private struct PlateImage: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "PeekabooPlate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 220, height: 220)
        }
    }
}

/// The plain cow-terminal mark, spinning, for the moment between selecting a
/// session and knowing whether it auto-attaches.
private struct AttachingSpinner: View {
    @State private var rotating = false

    var body: some View {
        ZStack {
            if let image = cowNoseImage {
                Image(nsImage: image)
                    .resizable().scaledToFit().frame(width: 96, height: 96)
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false),
                               value: rotating)
                    .onAppear { rotating = true }
            } else {
                PlateImage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A rounded rect with a small triangular tail on its leading edge, pointing
/// at whatever is "speaking" — here, the cow icon beside it.
private struct SpeechBubble: Shape {
    var tailSize: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let bubble = CGRect(x: rect.minX + tailSize, y: rect.minY,
                             width: rect.width - tailSize, height: rect.height)
        var p = Path(roundedRect: bubble, cornerRadius: rect.height / 2)
        let midY = rect.midY
        p.move(to: CGPoint(x: bubble.minX + 1, y: midY - tailSize))
        p.addLine(to: CGPoint(x: rect.minX, y: midY))
        p.addLine(to: CGPoint(x: bubble.minX + 1, y: midY + tailSize))
        p.closeSubpath()
        return p
    }
}

/// The plain cow-terminal mark, unadorned — the constant part of the toolbar
/// title, whatever it's saying.
private struct CowIcon: View {
    var body: some View {
        if let image = cowNoseImage {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28)
        }
    }
}

/// The cow mark plus its picked quip in a speech bubble, standing in for the
/// plain session name/state title. Fill only, no stroke — a border here reads
/// as another toolbar button rather than a bubble.
private struct CowQuip: View {
    let quip: String

    var body: some View {
        HStack(spacing: 8) {
            CowIcon()
            Text(quip)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.leading, 6 + 8)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .background(SpeechBubble().fill(Color.secondary.opacity(0.15)))
        }
    }
}

/// The toolbar's one title slot: the selected session's cow-and-quip, its
/// plain name/state without a quip (an older core, or a state not yet
/// reported), or the app name with nothing selected. The cow mark is always
/// there — only what it's "saying" changes.
private struct RootTitle: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let session = app.session(id: app.selectedSessionID)
        if let session, let quip = app.quip(for: session), !quip.isEmpty {
            CowQuip(quip: quip)
        } else {
            HStack(spacing: 8) {
                CowIcon()
                if let session {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.name).font(.headline)
                        Text(app.state(for: session).label).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("moomux").font(.headline)
                }
            }
        }
    }
}

private struct NoSessionSelectedView: View {
    var body: some View {
        if Bundle.main.url(forResource: "PeekabooPlate", withExtension: "png") != nil {
            VStack(spacing: 20) {
                PlateImage()
                Text("No session selected").font(.title2).bold().foregroundStyle(.secondary)
                Spacer().frame(height: 40)
            }
        } else {
            ContentUnavailableView("No session selected", systemImage: "square.split.2x1")
        }
    }
}

// MARK: - Sidebar

private struct SessionList: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selectedSessionID) {
            ForEach(app.sessionsByProject, id: \.project) { group in
                Section(header: ProjectHeader(name: group.project)) {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session).tag(session.id)
                    }
                }
            }
        }
        .searchable(text: $app.searchQuery, placement: .sidebar, prompt: "Find a session")
        // `.searchFocused` is macOS 15; the bundle targets 14. The field is
        // there and clickable either way — only ⌘F is gated, and
        // `SessionCommands` hides the menu item on the same check so there is
        // no command that does nothing.
        .modifier(FocusSearchOnRequest(token: app.focusSearchToken))
        .overlay {
            if app.sessions.isEmpty {
                EmptyState()
            } else if app.listedSessions.isEmpty {
                // Only reachable while searching: with no query the list is
                // `visibleSessions`, and an empty one of those means every
                // session is archived, which the Archived toggle explains.
                ContentUnavailableView.search(text: app.searchQuery)
            }
        }
    }
}

/// Puts the caret in the sidebar's search field whenever `token` changes.
///
/// A `ViewModifier` only so the macOS 15 availability check has somewhere to
/// live that is not the middle of a modifier chain.
private struct FocusSearchOnRequest: ViewModifier {
    let token: Int
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .searchFocused($focused)
                .onChange(of: token) { _, _ in focused = true }
        } else {
            content
        }
    }
}

private struct ProjectHeader: View {
    @Environment(AppState.self) private var app
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            if let emoji = app.emoji(for: name) { Text(emoji) }
            Text(name)
        }
    }
}

private struct SessionRow: View {
    @Environment(AppState.self) private var app
    let session: Session

    var body: some View {
        let state = app.state(for: session)
        HStack(spacing: 8) {
            Image(systemName: state.symbol)
                .foregroundStyle(Theme.color(state))
                .help(state.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                Text(session.branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            // `internal/tui/list.go`'s two git icons, in its order: ± for a
            // dirty worktree, ↑ for commits that are not on the remote. Both
            // can show at once — they are different work in different places,
            // and collapsing them would hide one. SF Symbols rather than the
            // literal glyphs so they weigh and align like the row's other
            // icons; they draw the same ± and ↑. Counts stay in the detail
            // panel's Changes row.
            if let git = app.worktrees[session.id] {
                if git.dirty {
                    Image(systemName: "plusminus")
                        .foregroundStyle(Theme.gitWarn)
                        .help("uncommitted changes")
                }
                if git.unpushed {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(Theme.gitWarn)
                        .help("unpushed commits")
                }
            }
            // Archived rows are only on screen because the Archived toggle is
            // on, and without this they are indistinguishable from live ones —
            // the toggle changes the list and nothing says which rows it added.
            if session.archived {
                Image(systemName: "archivebox")
                    .foregroundStyle(.tertiary)
                    .help("archived")
            }
        }
        .padding(.vertical, 2)
        // Closes over `session`, never over the selection: right-clicking an
        // unselected row has to act on the row you clicked.
        .contextMenu {
            Button("Open in Terminal") { app.open(session) }
            Button("Review Changes") { app.review(session) }
                .disabled(!app.canReview(session))
            Button("Edit…") { app.sheet = .edit(session) }
            Button("Tags…") { app.sheet = .tags(session) }
            Divider()
            Button(session.archived ? "Unarchive" : "Archive") {
                app.setArchived(session, !session.archived)
            }
            Button("Move Up") { app.move(session, by: -1) }
                .disabled(!app.canReorder)
            Button("Move Down") { app.move(session, by: 1) }
                .disabled(!app.canReorder)
            Divider()
            // No confirmation: the worktree survives, the powersleep dot shows
            // the result immediately, and "Open in Terminal" brings it back.
            // Delete is the irreversible one, and the only thing that asks.
            Button("Kill tmux") { app.killTmux(session) }
                .disabled(!app.isAlive(session))
            Button("Delete…", role: .destructive) { app.askDelete(session) }
        }
    }
}

private struct EmptyState: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if case let .down(message) = app.connection {
            ContentUnavailableView {
                Label("Can't reach moomux", systemImage: "bolt.horizontal.circle")
            } description: {
                VStack(spacing: 6) {
                    Text(message)
                    Text("moomux serve").font(Theme.mono)
                    Text("Start the core, and this connects on its own.")
                        .foregroundStyle(.secondary)
                }
            }
        } else if app.projects.isEmpty {
            // The first thing a fresh install sees. Until the app could add a
            // project it had to say "go and use the TUI"; now it can offer the
            // one action that gets you out of here.
            ContentUnavailableView {
                Label("No projects yet", systemImage: "folder.badge.plus")
            } description: {
                Text("A project is a repo moomux cuts session worktrees from.")
            } actions: {
                Button("Add a project…") { app.sheet = .settings }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("No sessions", systemImage: "tray")
            } description: {
                Text("⌘N starts one.")
            }
        }
    }
}

// MARK: - Detail

private struct SessionDetail: View {
    @Environment(AppState.self) private var app
    let session: Session

    @State private var showInfo = false
    // Deciding whether to auto-attach takes a round trip (`loadStatus`), and
    // the landing page (`SessionInfo`) flashing up for that moment reads as
    // the old behavior coming back. Show just the empty-state artwork
    // instead — the same thing an unselected pane shows — until the decision
    // is made one way or the other.
    @State private var checkingAttach = true

    var body: some View {
        // Read off `attachedSessions`, not view-local `@State`, so switching
        // the sidebar selection away and back shows an already-attached
        // session immediately — see `AppState.attach(_:)`.
        let attached = app.attachedSessions.contains(session.id)
        Group {
            if attached {
                SessionTerminal(session: session, onDetach: { app.detach(session) })
            } else if checkingAttach && app.state(for: session) != .parked {
                // Only a live session has anything to wait for. A parked one
                // cannot attach whatever `loadStatus` comes back with, so
                // spinning at it just hides the landing page — and if that
                // round trip never returns, forever. Keyed off the same
                // derived state the row's icon draws, not off `alive` again.
                AttachingSpinner()
            } else {
                SessionInfo(session: session, onAttach: { app.attach(session) })
            }
        }
        .onChange(of: session.id) { _, _ in showInfo = false; checkingAttach = true }
        .inspector(isPresented: $showInfo) {
            SessionInfo(session: session, onAttach: nil)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .toolbar {
            if attached {
                ToolbarItem {
                    Button {
                        app.detach(session)
                    } label: {
                        Label("Detach", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .help("Leave the session running and give the size back")
                }
                ToolbarItem {
                    Button {
                        showInfo.toggle()
                    } label: {
                        Label("Info", systemImage: "sidebar.right")
                    }
                    .keyboardShortcut("i")
                    .help("Session details")
                }
            }
        }
        // Attach is the point of selecting a session — the landing page with a
        // manual Attach button only matters when there's nothing to attach to
        // (no live tmux, or no tmux binary), and `SessionInfo` still covers
        // that case. `attach` no-ops if already attached, so re-running this
        // on `session.id` changes (not on detach) is safe.
        .task(id: session.id) {
            await app.loadStatus(for: session.id)
            if app.isAlive(session) && ToolPath.find("tmux") != nil {
                app.attach(session)
            }
            checkingAttach = false
        }
    }
}

/// Everything about a session that isn't the terminal itself.
private struct SessionInfo: View {
    @Environment(AppState.self) private var app
    let session: Session
    /// nil when this is the inspector beside a terminal that is already attached.
    var onAttach: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let onAttach {
                    HStack {
                        Button(action: onAttach) {
                            Label("Attach", systemImage: "terminal")
                        }
                        .keyboardShortcut(.return)
                        .disabled(!app.isAlive(session) || ToolPath.find("tmux") == nil)
                        .help("Attach this tmux session inside the app")

                        Button {
                            app.open(session)
                        } label: {
                            Label("Open in terminal", systemImage: "arrow.up.forward.app")
                        }
                        // The core's own open path: a real terminal window, and
                        // what revives a session whose tmux is gone.
                        .help("Hand this session to your terminal app, as the TUI does")

                        // The Ticket/PR rows below already render the result;
                        // without this the detail pane is a dead end for the
                        // one edit you make while looking at a session.
                        Button {
                            app.sheet = .tags(session)
                        } label: {
                            Label("Tags", systemImage: "tag")
                        }
                        .help("Set this session's ticket and pull request")

                        Button {
                            app.sheet = .edit(session)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .help("This session's name and agent")

                        Button {
                            app.review(session)
                        } label: {
                            Label("Review", systemImage: "plus.forwardslash.minus")
                        }
                        .disabled(!app.canReview(session))
                        .help("Open this worktree's diff in a new tmux window (⌘G)")
                    }
                    if !app.isAlive(session) {
                        Text("No live tmux session — open it to start one.")
                            .foregroundStyle(.secondary)
                    } else if ToolPath.find("tmux") == nil {
                        Text("Can't find a tmux binary to attach with.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let hint = app.hint {
                    Text(hint).font(Theme.mono).textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    Field("Project", session.project)
                    Field("Agent", session.agentName + (session.dangerous ? "  ⚠︎ dangerous" : ""))
                    Field("Branch", session.branch)
                    Field("Worktree", session.worktreePath)
                    Field("tmux", session.tmuxSession
                        + (app.isAlive(session) ? "" : "  (not running)"))
                    if let status = app.statuses[session.id] {
                        if !status.changeSummary.isEmpty {
                            Field("Changes", status.changeSummary)
                        } else if status.known {
                            Field("Changes", "clean")
                        }
                        if let pr = status.pr, !pr.summary.isEmpty {
                            Field("PR status", pr.summary)
                        }
                    }
                    Field("Created", session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if session.hasBeenOpened {
                        Field("Last opened", session.lastOpened.formatted(.relative(presentation: .named)))
                    }
                    if let ticket = session.ticket, !ticket.isEmpty { Field("Ticket", ticket) }
                    if let pr = session.pr, !pr.isEmpty { Field("PR", pr) }
                }

                if let prompt = session.prompt, !prompt.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("First prompt").font(.headline)
                        Text(prompt).font(Theme.mono).textSelection(.enabled)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Field: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(Theme.mono).textSelection(.enabled)
        }
    }
}

// MARK: - Status

private struct ConnectionBadge: View {
    @Environment(AppState.self) private var app

    var body: some View {
        // A running write outranks the connection state: creating a session
        // cuts a worktree and runs the worktree-create userscripts, which is
        // tens of seconds of nothing visible happening otherwise. Here rather
        // than in the sheet so every action gets it for free.
        if let busy = app.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(busy)…").foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            switch app.connection {
            case .connecting:
                Text("connecting…").foregroundStyle(.secondary)
            case .connected:
                if let error = app.statusError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            case let .down(message):
                Label(message, systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("Is `moomux serve` running?")
            }
        }
    }
}

// MARK: - Menu bar

/// The one thing the TUI structurally cannot have: a live count of sessions
/// waiting on you, visible while you are in another app.
struct MenuBarContent: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(app.visibleSessions.filter { app.state(for: $0) != .parked }) { session in
                Button {
                    app.open(session)
                    app.selectedSessionID = session.id
                    NSApp.activate()
                    NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
                } label: {
                    let state = app.state(for: session)
                    HStack {
                        Image(systemName: state.symbol).foregroundStyle(Theme.color(state))
                        Text("\(session.project) · \(session.name)")
                        Spacer()
                        Text(state.label).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            if app.visibleSessions.isEmpty {
                Text(app.connection.isDown ? "moomux serve isn't running" : "No sessions")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            Divider().padding(.vertical, 4)
            Button("Quit Moomux") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(width: 320)
    }
}
