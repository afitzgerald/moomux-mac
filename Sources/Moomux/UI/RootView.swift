import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MoomuxKit

/// Loaded once and shared by every view that draws the cow mark — reading
/// and decoding the SVG from disk on every render (as each caller used to do
/// independently) is needless work for an image that never changes.
private let cowNoseImage: NSImage? = Bundle.main
    .url(forResource: "moomux-terminal-nose", withExtension: "svg")
    .flatMap(NSImage.init(contentsOf:))

/// `sharedBackgroundVisibility` is macOS 26 SDK API — referencing it at all,
/// even behind `#available`, fails to compile against an older SDK (that's
/// a *runtime* check; the symbol still has to exist at compile time). CI is
/// on macos-26 now and has it; a macos-15 runner or an older toolchain does
/// not, and that is what shipped a release with no glass toolbar at all.
/// `#if compiler(>=6.2)` is a *compile*-time
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

/// The colors this app draws sessions with. Every one of them comes from the
/// core's `Themes` table now — no hardcoded palette here, and no literal hex
/// outside `resolve`, which honours both halves of a served light/dark pair.
enum Theme {
    // The colors moved to `SessionTheme` in the Kit so the phone draws from
    // the same served palette; these forward so nothing in this file changed.
    static func color(_ state: AgentState, _ palette: ThemePalette?) -> Color {
        SessionTheme.color(state, palette)
    }

    static func gitWarn(_ palette: ThemePalette?) -> Color { SessionTheme.gitWarn(palette) }

    static func pr(_ badge: PRInfo.Badge, _ palette: ThemePalette?) -> Color {
        SessionTheme.pr(badge, palette)
    }

    static let mono = Font.system(size: 12, design: .monospaced)

    /// The sidebar's font. An empty or uninstalled family falls back to the
    /// system font rather than to something arbitrary.
    static func list(_ family: String, _ size: Double) -> Font {
        guard !family.isEmpty, let font = NSFont(name: family, size: size) else {
            return .system(size: size)
        }
        return Font(font)
    }

    /// A regression here is silent by construction — a hex the parser rejects
    /// falls through to the SwiftUI semantic color and still renders something
    /// plausible — so the parser gets asserts rather than a screenshot.
    static func demo() {
        assert(list("", 13) == .system(size: 13), "no family means the system font")
        assert(list("No Such Family", 13) == .system(size: 13), "an uninstalled family falls back")
        assert(list("Menlo", 13) != .system(size: 13), "an installed family is actually used")

    }
}

// MARK: - Root

struct RootView: View {
    @Environment(AppState.self) private var app

    private func showCoreWhatsNew() {
        guard app.sheet == nil, let core = app.coreWhatsNew else { return }
        let unseen = WhatsNew.takeUnseen(in: core.releases, current: core.version, key: WhatsNew.coreSeenKey)
        if unseen.show {
            app.sheet = .coreWhatsNew(WhatsNew.releases(after: unseen.seen, in: core.releases, current: core.version))
        }
    }

    // The grid replaces the detail column, not the window, so the sidebar and
    // the toolbar keep working while it is up.
    // The update badge rides the detail, not the window, so a right-hand list
    // does not end up underneath it.
    private var detail: some View {
        Group {
            if app.showGrid {
                SessionGrid()
            } else if let session = app.session(id: app.selectedSessionID) {
                SessionDetail(session: session)
            } else {
                NoSessionSelectedView()
            }
        }
        .overlay(alignment: .bottomTrailing) { UpdateBadge() }
    }

    var body: some View {
        @Bindable var app = app
        Group {
            if app.sidebarOnRight {
                // NavigationSplitView has no trailing sidebar, so the right-hand
                // list is an inspector column. Flipping the split view to
                // right-to-left looked like less code, but NSToolbar still
                // splits at the sidebar's width from the left, so every detail
                // item overflowed into the sidebar's half — measured.
                NavigationStack { detail }
                    .inspector(isPresented: $app.sidebarShown) {
                        // A split view's sidebar column gets this style for
                        // free; the row bands and accent bars are tuned to it.
                        SessionList()
                            .listStyle(.sidebar)
                            .inspectorColumnWidth(min: 240, ideal: 300, max: 520)
                    }
            } else {
                NavigationSplitView {
                    SessionList()
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
                } detail: {
                    detail
                }
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
            // No glass capsule: it is a reading, not a control, and the
            // capsule made it look like a button with its text jammed in.
            ToolbarItem(placement: .status) { UsageBadge() }
                .hidingSharedBackground()
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
                // Bound to what the sidebar is actually drawing, not to the
                // stored preference: with `folderFirst` remembered true, a core
                // that sends no folder layout would otherwise draw this checked
                // *and* disabled over a project-first list, with no way to
                // clear it. Writing still sets the preference.
                Toggle(isOn: Binding(get: { app.folderView },
                                     set: { app.folderFirst = $0 })) {
                    Label("Folders", systemImage: "folder")
                }
                    // ⇧⌘F lives on the View menu item, not here.
                    .help("Group the sidebar by folder instead of by project (⇧⌘F)")
                    // A core too old to send a folder-first layout has none to
                    // draw; a toggle that could only empty the sidebar is worse
                    // than one that is off.
                    .disabled(app.folderRows.isEmpty)
            }
            ToolbarItem {
                Toggle(isOn: $app.showArchived) { Label("Archived", systemImage: "archivebox") }
                    .help("Show only archived sessions")
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
            if app.sidebarOnRight {
                // The split view's own sidebar button goes with the split view.
                ToolbarItem {
                    Button {
                        app.toggleSidebar()
                    } label: {
                        // Not `sidebar.right`: Info already wears it.
                        Label("Toggle Sidebar", systemImage: "list.bullet")
                    }
                    .help("Show or hide the session list (⌃⌘S)")
                }
            }
        }
        .task {
            app.start()
            let unseen = WhatsNew.takeUnseen()
            if unseen.show { app.sheet = .whatsNew(after: unseen.seen) }
        }
        // The core's notes arrive on a snapshot, after the app's own sheet may
        // already be up; a sheet in the way just means asking again once it closes.
        .onChange(of: app.coreWhatsNew) { _, _ in showCoreWhatsNew() }
        // Not at once: an item swapped in mid-dismissal repaints the sheet that
        // is leaving with the new content, then presents again.
        .onChange(of: app.sheet) { _, sheet in
            guard sheet == nil else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                showCoreWhatsNew()
            }
        }
        // `hint` is what the last *session-less* action had to say, rendered
        // in whichever Info pane is showing, so it must not outlive the
        // selection. Per-session ones live in `sessionHints` and stay put.
        .onChange(of: app.selectedSessionID) { _, _ in app.hint = nil }
        // A refused create reopens its sheet with the form as it was sent —
        // unless another sheet is up, which one `.sheet(item:)` cannot stack
        // on; then the alert says where the form went.
        .onChange(of: app.failedCreate) { _, failed in
            guard let failed else { return }
            if app.sheet == nil {
                app.sheet = .create
            } else {
                app.actionError = "Creating session failed: \(failed.error)\n\n"
                    + "Your form is kept: New Session (⌘N) reopens it."
            }
        }
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
            case let .newFolder(assign):
                TextFieldSheet(title: "New folder",
                               labels: ["Name"], values: [""]) { values in
                    let name = values[0].trimmed
                    // Filing a session into it *is* the create: SetSessionFolder
                    // makes a folder on first use, so this stays one call.
                    if let session = assign {
                        app.setFolder(session, to: name)
                    } else {
                        app.createFolder(name: name)
                    }
                }
            case let .renameFolder(name):
                TextFieldSheet(title: "Rename “\(name)”",
                               labels: ["Name"], values: [name]) { values in
                    app.renameFolder(from: name, to: values[0].trimmed)
                }
            case let .web(link):
                if let url = TerminalLink.resolve(link) {
                    WebSheet(link: link, url: url)
                }
            case .settings:
                SettingsSheet()
            case let .whatsNew(after):
                WhatsNewSheet(releases: WhatsNew.releases(after: after))
            case let .coreWhatsNew(releases):
                WhatsNewSheet(releases: releases, subject: "the core")
            case .acknowledgements:
                AcknowledgementsSheet()
            }
        }
        .alert(Text(app.pendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete session?"),
               isPresented: Binding(
            get: { app.pendingDelete != nil },
            set: { if !$0 { app.dismissDelete() } }
        ), presenting: app.pendingDelete) { session in
            Button("Delete", role: .destructive) { app.delete(session) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text(app.deleteWarning(for: session))
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

}

/// The full new-session form — the same questions the TUI's dialog asks, now
/// that the core serves the agent/model/thinking table (`AgentOptions`) that
/// the pickers are built from. Nothing here hardcodes a list.
private struct NewSessionSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var form = NewSessionForm()
    /// The core's refusal of the last Create, verbatim, when the sheet was
    /// reopened over it.
    @State private var error: String?
    @FocusState private var baseBranchFocused: Bool
    @State private var showMore = false
    @State private var attachments = AttachQueue()
    @State private var importingFiles = false

    private func upload(name: String, type: UTType?, data: Data) async throws -> String {
        try await app.attach(name: name, type: type, data: data)
    }

    private var projects: [String] { app.config?.orderedProjectNames ?? [] }
    private var project: Project? { app.config?.projects[form.project] }
    private var models: [String] { app.models(for: form.agent) }
    private var thinking: [String] { app.thinking(for: form.agent) }
    private var hasModelList: Bool { app.hasModelList(for: form.agent) }

    private var agentPicker: some View {
        Picker("Agent", selection: $form.agent) {
            // Only for a `prompt_agent` project, which starts with no agent
            // chosen and must not silently pick one.
            if form.agent.isEmpty { Text("choose one").tag("") }
            ForEach(app.agentNames, id: \.self) { Text($0).tag($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // What gets typed on every session first; what almost never
            // changes (model, base branch) folded away under More options.
            Form {
                Section {
                    // No `.focused()` here — a menu-style Picker
                    // (NSPopUpButton) silently ignores FocusState on macOS.
                    // Forcing it needs a custom NSViewRepresentable; not worth
                    // it for focus-on-open alone.
                    Picker("Project", selection: $form.project) {
                        Text("choose one").tag("")
                        ForEach(projects, id: \.self) { Text($0).tag($0) }
                    }
                    // Up here only when the project asks every time — and then
                    // it asks about permissions too, as the TUI does; otherwise
                    // the project's own agent and flag are right, and
                    // overriding the agent lives under More options.
                    if project?.promptAgent == true {
                        agentPicker
                        Toggle("Skip permission prompts", isOn: $form.dangerous)
                            .help(form.agent == "opencode"
                                  ? "opencode has no permission-skipping flag — this does nothing for it"
                                  : "claude: --dangerously-skip-permissions, codex: --yolo")
                    }
                }
                Section {
                    PromptEditor(text: $form.prompt, attachments: attachments, upload: upload)
                        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 160)
                        // `.roundedBorder` reaches TextFields, not this
                        // NSTextView, and without an edge typed text floats
                        // in the row.
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        // An NSTextView has no placeholder of its own.
                        .overlay(alignment: .topLeading) {
                            if form.prompt.isEmpty {
                                Text("What should the agent do?")
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 7).padding(.top, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .help("Drop or paste a file to add its path. Leave it empty to start the agent idle.")
                    HStack {
                        Button("Attach Files…", systemImage: "paperclip") { importingFiles = true }
                        if attachments.pending > 0 { ProgressView().controlSize(.small) }
                    }
                    // Here and not in an alert: the sheet is still open, and
                    // the paths that did land are right above it.
                    if let error = attachments.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !thinking.isEmpty {
                        Picker("Thinking", selection: $form.thinking) {
                            ForEach(thinking, id: \.self) { Text($0).tag($0) }
                        }
                        // The core decides which; opencode is the one agent
                        // with no launch flag for it (`reasoningEffortFlag`).
                        .help(form.agent == "opencode"
                              ? "Prepended to the first prompt — opencode has no flag for it"
                              : "Passed to \(form.agent) as its reasoning-effort flag")
                    }
                }
                Section {
                    // The placeholder is the name the prompt will give it, so
                    // typing one is only for overriding that.
                    TextField("Name", text: $form.name, prompt: Text(form.namePlaceholder))
                        .help("Names the branch, the worktree and the tmux session")
                    TextField("Existing branch", text: $form.existingBranch,
                              prompt: Text("resume, don't cut"))
                    // Only a new branch is cut from it, so it steps aside
                    // while one is being resumed.
                    TextField("Base branch", text: $form.baseBranch, prompt: Text("the repo's default"))
                        .disabled(project?.isPlain == true || !form.existingBranch.isEmpty)
                        .focused($baseBranchFocused)
                        .overlay {
                            if error.map(NewSessionForm.blamesBaseBranchField) == true {
                                RoundedRectangle(cornerRadius: 5).stroke(.red)
                            }
                        }
                }
                Section {
                    TextField("Ticket", text: $form.ticket)
                    TextField("PR", text: $form.pr)
                }
                Section {
                    DisclosureGroup(isExpanded: $showMore) {
                        if project?.promptAgent != true { agentPicker }
                        if hasModelList {
                            Picker("Model", selection: $form.model) {
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                        } else {
                            TextField("Model", text: $form.modelText, prompt: Text("default"))
                                .padding(.vertical, 2)  // see ProjectSheet's More options
                                .help("\(form.agent) has no fixed model list — type one or leave it empty")
                        }
                        Toggle("Send the prompt (press Enter)", isOn: $form.autoSubmit)
                            .help("Starts at Settings → Sessions' default; this session only")
                    } label: {
                        MoreOptionsLabel(isExpanded: $showMore)
                    }
                }
            }
            .formStyle(.grouped)
            // Its ideal height is its content's, so the sheet grows when More
            // options opens instead of scrolling the new rows out of sight — a
            // sheet otherwise keeps the size it opened at. Capped so a short
            // window scrolls rather than pushing Create off the bottom.
            .frame(maxHeight: 660)
            .fixedSize(horizontal: false, vertical: true)
            // An empty `TextField` in a grouped Form draws no box at all, so a
            // blank field reads as a static label. A border is the whole fix.
            .textFieldStyle(.roundedBorder)
            // Its own line: beside the buttons at this width it truncated,
            // and it is the only explanation for a disabled Create.
            if !form.project.isEmpty && project?.promptAgent == true && form.agent.isEmpty {
                Text("This project asks for an agent every time — pick one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Closes at once rather than waiting out the worktree and the
                // userscripts: `app.busy` reports progress in the toolbar, and
                // a refusal reopens this sheet with the form as it was sent.
                Button("Create") {
                    app.create(form)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                // Until every attachment's path is in the prompt.
                .disabled(!form.canCreate || attachments.pending > 0)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Seeded from the row being looked at — a second session in the same
        // project is the common case — else the first project, as on the
        // phone: "choose one" left every project-derived field blank.
        // A refused create's form comes back whole, with the core's reason.
        .onAppear {
            (form, error) = app.openNewSessionForm(project: app.session(id: app.selectedSessionID)?.project
                                                   ?? projects.first ?? "")
            if error.map(NewSessionForm.blamesBaseBranchField) == true {
                // A field cannot take focus before the sheet is on screen.
                DispatchQueue.main.async { baseBranchFocused = true }
            }
        }
        .onChange(of: form.prompt) { _, prompt in app.promptDraft = prompt }
        // The agent, and with it every list below it, belongs to the project.
        .onChange(of: form.project) { _, _ in app.applyProject(to: &form) }
        .onChange(of: form.agent) { _, _ in app.clampChoices(of: &form) }
        .onChange(of: app.agentNames) { _, _ in app.agentNamesChanged(in: &form) }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                attachments.run(urls.map { PromptDrop.item(for: $0).job(upload: upload) }) { form.appendPath($0) }
            case .failure(let error):
                // Shown where an upload's failure would be.
                attachments.run([{ throw error }]) { _ in }
            }
        }
        .onDisappear { attachments.cancelAll() }
    }
}

/// The label of a "More options" disclosure in a grouped Form, where a
/// DisclosureGroup answers only its chevron: a plain button over the whole row.
struct MoreOptionsLabel: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button { withAnimation { isExpanded.toggle() } } label: {
            Text("More options")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            // A Grid, not a grouped Form: the Form sizes each field to its text,
            // so an empty one shrank beside its label and a long URL dropped
            // onto a row of its own.
            Grid(alignment: .leading, verticalSpacing: 10) {
                ForEach(labels.indices, id: \.self) { i in
                    GridRow {
                        Text(labels[i]).gridColumnAlignment(.trailing)
                        TextField(labels[i], text: $values[i]).labelsHidden()
                    }
                }
            }
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

/// The plain cow-terminal mark, unadorned — the constant part of the toolbar
/// title, whatever it's saying.
private struct CowIcon: View {
    var body: some View {
        if let image = cowNoseImage {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28)
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
            CowQuip(saying: quip, mark: cowNoseImage.map(Image.init(nsImage:)))
        } else {
            HStack(spacing: 8) {
                CowIcon()
                if let session {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.name).font(.headline)
                        Text(app.label(for: session)).font(.caption).foregroundStyle(.secondary)
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
            // Two lenses on the same rows, both laid out by the core. Which one
            // is on screen is a `UserDefaults` preference (`folderFirst`), and
            // a core too old to send a folder-first layout keeps this one.
            if app.folderView { folderFirst } else { projectFirst }
        }
        .background(NoSelectionHighlight())
        .searchable(text: $app.searchQuery, placement: .sidebar, prompt: "Find a session")
        // `.searchFocused` is macOS 15; the bundle targets 14. The field is
        // there and clickable either way — only ⌘F is gated, and
        // `SessionCommands` hides the menu item on the same check so there is
        // no command that does nothing.
        .modifier(FocusSearchOnRequest())
        .overlay {
            if app.sessions.isEmpty {
                EmptyState()
            } else if app.listedSessions.isEmpty {
                if app.searching {
                    ContentUnavailableView.search(text: app.searchQuery)
                } else if app.showArchived {
                    ContentUnavailableView("No Archived Sessions", systemImage: "archivebox")
                }
                // Otherwise every session is archived, which the Archived
                // toggle explains.
            }
        }
    }

    @ViewBuilder private var projectFirst: some View {
        ForEach(app.sessionsByProject, id: \.project) { group in
            // Not `Section`: a sidebar section keeps its *own* hidden
            // disclosure state, a click on the header drives that as well
            // as ours, and the two fall out of phase the moment a project
            // is collapsed at launch — SwiftUI starts expanded, so the
            // first click on a folded project expanded ours and collapsed
            // its, and the rows stayed away. Plain rows have no such
            // state. Both measured.
            ProjectHeader(
                name: group.project,
                hidden: group.sessions.count - app.shownSessions(
                    of: group.project, in: group.sessions
                ).count
            )
            // Untagged, but the List will still "select" it: a click in
            // the row's leading inset misses the header's own
            // `contentShape`, falls through, highlights the row and nils
            // the session selection. Two outcomes for one row, and one of
            // them threw away state.
            .selectionDisabled()
            // The core lays the rows out (`sessionview.Rows`); this walks
            // them. A folder header is a plain row for the same reason a
            // project header is — a selectable row would take the List's
            // selection, and there is no session behind it.
            ForEach(app.sidebarRows(of: group.project, in: group.sessions)) { row in
                switch row {
                case let .folder(name, collapsed, count):
                    FolderHeader(project: group.project, name: name,
                                 collapsed: collapsed, count: count)
                        .selectionDisabled()
                case let .session(session, folder):
                    // One level in from its header, whichever it is: the
                    // project header, or a folder header one level in itself.
                    SessionRow(session: session, level: folder.isEmpty ? 1 : 2).tag(session.id)
                }
            }
        }
    }

    /// `sessionview.FolderRows`: every folder at the top level with a project
    /// subheader under it, then everything filed nowhere, by project, last.
    /// One flat list rather than a `ForEach` per project — the folders are one
    /// global namespace and their members span projects.
    @ViewBuilder private var folderFirst: some View {
        ForEach(app.folderSidebarRows) { row in
            switch row {
            case let .folder(name, collapsed, count):
                // No project: this header is the whole folder, whatever
                // projects its members come from, so a drop or an Archive All
                // on it means all of them.
                FolderHeader(project: "", name: name, collapsed: collapsed, count: count,
                             level: 0)
                    .selectionDisabled()
            case let .project(folder, name, collapsed, hidden):
                // The loose block's header is the project header proper —
                // collapse through the core, drop-to-unfile and all. Inside a
                // folder it is a group of its own, folding only itself.
                if folder.isEmpty {
                    ProjectHeader(name: name, hidden: hidden).selectionDisabled()
                } else {
                    FolderProjectHeader(folder: folder, name: name, collapsed: collapsed,
                                        hidden: hidden)
                        .selectionDisabled()
                }
            case let .session(session, indent):
                SessionRow(session: session, level: indent).tag(session.id)
            }
        }
    }
}

/// A project subheader inside a folder, folding only itself — the same plain
/// row as the other two headers, one level in. Its collapse is this window's
/// (`AppState.setFolderProject`), not `SetProjectCollapsed`: the same project
/// has a subheader under every folder it has members in, and folding all of
/// them plus the loose block at once is not what a disclosure triangle means.
///
/// No drop destination: a drop here would mean "file into this folder", which
/// is exactly what the `FolderHeader` above it already takes.
private struct FolderProjectHeader: View {
    @Environment(AppState.self) private var app
    let folder: String
    let name: String
    let collapsed: Bool
    let hidden: Int

    var body: some View {
        HStack(spacing: 4) {
            // No font of its own: the row's is the list font, so the chevron
            // draws at the size every other icon in the sidebar does. The
            // colour is stated rather than inherited for the same reason — a
            // subheader's row is secondary, and a disclosure triangle that
            // changes shade with its row reads as a different control.
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .frame(width: SidebarGrid.disclosure(app.listFontSize))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
            if let emoji = app.listEmoji(for: name) {
                Text(emoji).frame(width: SidebarGrid.icon(app.listFontSize))
            }
            Text(name)
        }
        .font(Theme.list(app.listFontFamily, app.listFontSize))
        .foregroundStyle(.secondary)
        .padding(.leading, SidebarGrid.indent(1, app.listFontSize))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { app.setFolderProject(folder: folder, project: name, expanded: collapsed) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(collapsed && hidden > 0 ? "\(name), collapsed, \(hidden) sessions" : name)
        .accessibilityAction {
            app.setFolderProject(folder: folder, project: name, expanded: collapsed)
        }
    }
}

/// Stops the sidebar's table drawing its selection pill, which is grey — the
/// same tone as a header band. Selection itself is untouched (clicks, arrow
/// keys, `List(selection:)`); the selected row draws its own accent edge.
///
/// SwiftUI has no switch for this, so it reaches the `NSTableView` behind the
/// `List`: it walks up from a background view until an ancestor holds one.
/// Ceiling: a SwiftUI that stops backing `List` with an `NSTableView` makes
/// this a no-op and the pill comes back, which is harmless.
private struct NoSelectionHighlight: NSViewRepresentable {
    final class Coordinator { weak var table: NSTableView? }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // This runs on every body pass (each 2s poll), so a table found once is
        // remembered; only a missing or replaced one is searched for again.
        if let table = context.coordinator.table, table.window != nil {
            if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
            return
        }
        // The table is not built yet on the first pass, so look a beat later.
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let a = ancestor {
                if let table = Self.table(in: a) {
                    table.selectionHighlightStyle = .none
                    coordinator.table = table
                    return
                }
                ancestor = a.superview
            }
        }
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for sub in view.subviews { if let t = table(in: sub) { return t } }
        return nil
    }
}

/// Puts the caret in the sidebar's search field whenever
/// `searchFocusPending` is set, including when it was set by the update that
/// mounted the list.
///
/// A `ViewModifier` only so the macOS 15 availability check has somewhere to
/// live that is not the middle of a modifier chain.
private struct FocusSearchOnRequest: ViewModifier {
    @Environment(AppState.self) private var app
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .searchFocused($focused)
                .onChange(of: app.searchFocusPending, initial: true) { _, pending in
                    guard pending else { return }
                    focused = true
                    app.searchFocusPending = false
                }
        } else {
            content
        }
    }
}

private struct ProjectHeader: View {
    @Environment(AppState.self) private var app
    let name: String
    let hidden: Int
    @State private var targeted = false

    var body: some View {
        // The header is not a selectable row, so a tap gesture here does not
        // steal the List's selection the way one on a row would.
        let expanded = app.projectExpanded(name)
        // The selected session's row is hidden by this collapse, and its
        // terminal is still on screen — the header says so with the same edges.
        let holdsSelection = !expanded && app.session(id: app.selectedSessionID).map {
            $0.project == name && (!app.folderView || $0.folder.isEmpty)
        } == true
        HStack(spacing: 4) {
            // No font of its own: the row's is the list font, so the chevron
            // draws at the size every other icon in the sidebar does. The
            // colour is stated rather than inherited for the same reason — a
            // subheader's row is secondary, and a disclosure triangle that
            // changes shade with its row reads as a different control.
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .frame(width: SidebarGrid.disclosure(app.listFontSize))
                .rotationEffect(.degrees(expanded ? 90 : 0))
            if let emoji = app.listEmoji(for: name) {
                Text(emoji).frame(width: SidebarGrid.icon(app.listFontSize))
            }
            Text(name)
        }
        // Small caps on a band: the tint is what says "group" now that
        // sessions no longer repeat the header's weight and size.
        .font(Theme.list(app.listFontFamily, max(9, app.listFontSize - 2)).weight(.semibold))
        .textCase(.uppercase)
        .padding(.vertical, 3)
        // Level 0 in both lenses: a project header is either the top of the
        // list or the top of the trailing loose block.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { app.setProject(name, expanded: !expanded) }
        .dropDestination(for: String.self) { ids, _ in
            app.drop(ids, into: "", project: name)
        } isTargeted: { targeted = $0 }
        .listRowBackground(targeted ? AnyView(SessionTheme.dropTarget) : AnyView(band(expanded: expanded, holdsSelection: holdsSelection)))
        .contextMenu {
            Button("New Folder…") { app.sheet = .newFolder(assign: nil) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(expanded || hidden == 0 ? name
            : "\(name), collapsed, \(hidden) sessions"
                + (holdsSelection ? ", contains the selected session" : ""))
        .accessibilityAction { app.setProject(name, expanded: !expanded) }
    }

    /// A tab on its group: rounded top, square bottom while the sessions sit
    /// under it. Collapsed there is nothing under it, so it closes all four
    /// corners and steps in so neighbouring projects do not fuse. Same shape
    /// as the phone's header band.
    private func band(expanded: Bool, holdsSelection: Bool) -> some View {
        let r: CGFloat = expanded ? 0 : 12
        return ZStack {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: r,
                                   bottomTrailingRadius: r, topTrailingRadius: 12)
                .fill(Color.primary.opacity(0.1))
                .padding(.vertical, expanded ? 0 : 1)
            if holdsSelection { SelectionEdges(height: app.listFontSize * 1.5) }
        }
    }
}

/// A folder header — the same plain-row shape as `ProjectHeader`, one level in.
private struct FolderHeader: View {
    @Environment(AppState.self) private var app
    let project: String
    let name: String
    let collapsed: Bool
    let count: Int
    /// How many levels in: one under a project header, none in the
    /// folder-first sidebar, where a folder *is* the top level.
    var level = 1
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 4) {
            // No font of its own: the row's is the list font, so the chevron
            // draws at the size every other icon in the sidebar does. The
            // colour is stated rather than inherited for the same reason — a
            // subheader's row is secondary, and a disclosure triangle that
            // changes shade with its row reads as a different control.
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .frame(width: SidebarGrid.disclosure(app.listFontSize))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
            Image(systemName: collapsed ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: SidebarGrid.icon(app.listFontSize))
            Text(name)
        }
        .font(Theme.list(app.listFontFamily, app.listFontSize))
        .padding(.leading, SidebarGrid.indent(level, app.listFontSize))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { app.setFolder(name: name, collapsed: !collapsed) }
        .dropDestination(for: String.self) { ids, _ in
            app.drop(ids, into: name, project: project)
        } isTargeted: { targeted = $0 }
        .listRowBackground(targeted ? SessionTheme.dropTarget : nil)
        .contextMenu {
            Button("Rename…") { app.sheet = .renameFolder(name: name) }
            Button("Archive All") { app.setArchived(project: project, folder: name, true) }
            Button("Unarchive All") { app.setArchived(project: project, folder: name, false) }
            Divider()
            // No confirmation: deleting a folder files its members back at the
            // top level and removes nothing.
            Button("Delete") { app.deleteFolder(name: name) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(collapsed && count > 0 ? "\(name), collapsed, \(count) sessions" : name)
        .accessibilityAction { app.setFolder(name: name, collapsed: !collapsed) }
    }
}

private struct SessionRow: View {
    @Environment(AppState.self) private var app
    let session: Session
    /// How many levels in the row sits — straight off its layout row, so
    /// nothing here has to join back to a folder to know. 1 under a project
    /// header, 2 under a folder-then-project pair.
    var level = 0

    @Environment(\.controlActiveState) private var activeState

    /// An accent bar on each outer edge of the selected row — the one thing in
    /// the list that is not grey. Its height follows the list font, and it
    /// dims with the window: the system's own pill did both.
    private var selectionEdge: some View {
        SelectionEdges(height: app.listFontSize * 1.5, dimmed: activeState != .key)
    }

    var body: some View {
        let state = app.state(for: session)
        // One line, like the phone: state icon, name, badges right-aligned. A
        // long name truncates before the badges do. The row's height is the
        // name's alone — the badges are set smaller — so a badge appearing on
        // a snapshot cannot change it (a row whose height changed in the same
        // List update that moved rows crashed AppKit: NSTableRowData
        // rowIndexForView, null deref, macOS 27.0).
        HStack(spacing: SidebarGrid.gap) {
            Image(systemName: state.symbol)
                .foregroundStyle(Theme.color(state, app.palette))
                .frame(width: SidebarGrid.icon(app.listFontSize))
                .help(app.label(for: session))
            Text(session.name)
                .foregroundStyle(state == .parked ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Order, colours and rules are the Kit's; the tags are links here.
            // Badges track the name 3pt down — what .caption (10pt) was under
            // .body (13pt) before any of this was adjustable.
            SessionBadges(app: app, session: session, spacing: 10) { symbol, link, help in
                TagIcon(symbol: symbol, link: link, help: help)
            }
            .font(Theme.list(app.listFontFamily, max(9, app.listFontSize - 3)))
        }
        .font(Theme.list(app.listFontFamily, app.listFontSize))
        .padding(.vertical, 2)
        // The system's selection pill is switched off (`NoSelectionHighlight`):
        // it was grey, the same tone as a header band.
        .listRowBackground(app.selectedSessionID == session.id ? AnyView(selectionEdge) : nil)
        // `level - 1`: the dot sits straight under its header's icon, not a
        // step in from it — the band is what says which header it belongs to.
        .padding(.leading, SidebarGrid.rowIndent(max(0, level - 1), app.listFontSize))
        // The payload is the session id as a plain string — no custom UTType,
        // which would need an Info.plist declaration to be worth anything.
        // The cost is that dragging a row into a text field types its id;
        // `AppState.drop` ignores any string that is not a session of the
        // project it landed on.
        .draggable(session.id)
        // `DoubleClickCatcher`, not `TapGesture(count: 2)`: SwiftUI's own
        // double-tap gesture uses a fixed internal timeout rather than the
        // system's actual double-click speed (System Settings ›
        // Trackpad/Mouse), which read as "finicky" — needing an
        // unreasonably fast double-click to register. `NSEvent.clickCount`
        // is AppKit's own reading of that same system setting.
        .background(DoubleClickCatcher {
            app.selectedSessionID = session.id
            app.attach(session)
        })
        // Closes over `session`, never over the selection: right-clicking an
        // unselected row has to act on the row you clicked.
        //
        // The iPhone's session menu order (`SessionActions`): links, then
        // filing and naming, then what ends the session. The Mac-only tools
        // sit between the last two.
        .contextMenu {
            // Only a value the inspector would make a link (`Field`) appears.
            let ticket = session.ticket.flatMap { TerminalLink.resolve($0) != nil ? $0 : nil }
            let pr = session.pr.flatMap { TerminalLink.resolve($0) != nil ? $0 : nil }
            let mergeRight = app.installedMergeRightLink(for: session)
            if let ticket { Button("Ticket") { app.openTag(ticket) } }
            if let pr { Button("Pull Request") { app.openTag(pr) } }
            if let mergeRight {
                Button("Open in MergeRight") { NSWorkspace.shared.open(mergeRight) }
            }
            if ticket != nil || pr != nil || mergeRight != nil { Divider() }
            Menu("Folder") {
                Button("None") { app.setFolder(session, to: "") }
                    .disabled(session.folder.isEmpty)
                let folders = app.folderNames
                if !folders.isEmpty { Divider() }
                ForEach(folders, id: \.self) { name in
                    Button(name) { app.setFolder(session, to: name) }
                        .disabled(name == session.folder)
                }
                Divider()
                Button("New Folder…") {
                    app.sheet = .newFolder(assign: session)
                }
            }
            Button(session.pinned ? "Unpin" : "Pin to Top") {
                app.setPinned(session, !session.pinned)
            }
            Button(session.archived ? "Unarchive" : "Archive") {
                app.setArchived(session, !session.archived)
            }
            Button("Edit…") { app.sheet = .edit(session) }
            Button("Tags…") { app.sheet = .tags(session) }
            Divider()
            Button("Open in Diff Tool") { app.openDiffTool(session) }
                .disabled(!app.canOpenDiffTool(session))
            Button("Review Changes") { app.review(session) }
                .disabled(!app.canReview(session))
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.worktreePath, forType: .string)
            }
            .disabled(session.worktreePath.isEmpty)
            Button("Move Up") { app.move(session, by: -1) }
                .disabled(!app.canReorder)
            Button("Move Down") { app.move(session, by: 1) }
                .disabled(!app.canReorder)
            Divider()
            // No confirmation: the worktree survives, the powersleep dot shows
            // the result immediately, and Attach brings it back.
            // Delete is the irreversible one, and the only thing that asks.
            Button("Kill tmux") { app.killTmux(session) }
                .disabled(!app.isAlive(session))
            Button("Delete…", role: .destructive) { app.askDelete(session) }
        }
    }
}

/// A double-click sink that sits behind a row's content and forwards every
/// event straight on to `super`, so it never disturbs the List's own
/// single-click selection above it — only rides along for the second click of
/// a pair. `NSEvent.clickCount` is AppKit counting clicks against the system's
/// own double-click-speed preference, which is what makes this reliable where
/// `TapGesture(count: 2)` was not.
private struct DoubleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    final class ClickView: NSView {
        var action: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { action?() }
            super.mouseDown(with: event)
        }
    }

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.action = action
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
        } else if app.config?.projects.isEmpty != false {
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
            } else if checkingAttach && app.isAlive(session) {
                // Only a live session has anything to wait for. A parked one
                // cannot attach whatever `loadStatus` comes back with, so
                // spinning at it just hides the landing page — and if that
                // round trip never returns, forever. `isAlive` and not
                // `state != .parked`: before the first snapshot there is no
                // view at all, and "unknown" is not something to spin at.
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
        //
        // The `isAlive` guard is load-bearing now that `attach` revives a
        // parked session: browsing the sidebar must not relaunch agents.
        // Starting one back up stays a button press.
        .task(id: session.id) {
            await app.loadStatus(for: session.id)
            if app.isAlive(session) && app.canAttach {
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
                        .disabled(!app.canAttach)
                        .help("Attach this tmux session inside the app, starting it if it isn't running")


                        // The Ticket/PR rows below already render the result;
                        // without this the detail pane is a dead end for the
                        // one edit you make while looking at a session.
                        Button {
                            app.sheet = .tags(session)
                        } label: {
                            Label("Tags", systemImage: "tag")
                        }
                        .help("Set this session's ticket and pull request")

                        if let link = app.installedMergeRightLink(for: session) {
                            Button {
                                NSWorkspace.shared.open(link)
                            } label: {
                                Label("MergeRight", systemImage: "arrow.triangle.pull")
                            }
                            .help("Open this session's pull request in MergeRight")
                        }

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

                        Button {
                            app.openDiffTool(session)
                        } label: {
                            Label("Diff Tool", systemImage: "square.split.2x1")
                        }
                        .disabled(!app.canOpenDiffTool(session))
                        .help("Open this worktree in the diff tool from Settings (⌘D)")
                    }
                    if !app.canAttach {
                        Text("Can't find a tmux binary to attach with.")
                            .foregroundStyle(.secondary)
                    } else if !app.isAlive(session) {
                        Text("No live tmux session — Attach starts one.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let hint = app.sessionHints[session.id] ?? app.hint {
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
                    }
                    // Off the snapshot, not a call of its own: the core caches
                    // and jitters the `gh pr view` behind it for every session.
                    if let pr = app.views[session.id]?.pr, !pr.summary.isEmpty {
                        Field("PR status", pr.summary)
                    }
                    Field("Created", session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if session.hasBeenOpened {
                        Field("Last opened", session.lastOpened.formatted(.relative(presentation: .named)))
                    }
                    if let ticket = session.ticket, !ticket.isEmpty { Field("Ticket", ticket, link: true) }
                    if let pr = session.pr, !pr.isEmpty { Field("PR", pr, link: true) }
                }

                // The core recovers this from the agent's own logs for a
                // session moomux didn't start, so it is not always the stored one.
                let prompt = app.prompt(for: session)
                if !prompt.isEmpty {
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

/// A tag icon that opens its target when the tag is a link, and stays
/// decorative when it isn't — a ticket is as often "T-1" as a URL, and a button
/// that does nothing when clicked is worse than no button. `TerminalLink` is
/// the same allowlist a ⌘-clicked pane link goes through, so nothing here can
/// hand the system a scheme that one refuses.
///
/// A `Button` and not a tap gesture: a gesture on a row's content outranks the
/// `List`'s own selection and would stop the row selecting at all.
private struct TagIcon: View {
    @Environment(AppState.self) private var app
    let symbol: String
    let link: String
    let help: String

    var body: some View {
        if TerminalLink.resolve(link) != nil {
            Button { app.openTag(link) } label: { Image(systemName: symbol) }
                .buttonStyle(.plain)
                .help("\(help) — click to open")
        } else {
            Image(systemName: symbol).help(help)
        }
    }
}

private struct Field: View {
    @Environment(AppState.self) private var app
    let label: String
    let value: String
    let link: Bool

    init(_ label: String, _ value: String, link: Bool = false) {
        self.label = label
        self.value = value
        self.link = link
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            // A ticket is as often "T-1" as a URL, so only a value the same
            // allowlist a ⌘-clicked pane link goes through accepts becomes a
            // link; everything else stays selectable text.
            if link, TerminalLink.resolve(value) != nil {
                // A Button and not a tap gesture on selectable text: the
                // selection swallows the click (same reason TagIcon is one).
                Button { app.openTag(value) } label: {
                    Text(value).font(Theme.mono).underline()
                }
                .buttonStyle(.link)
                .onHover { NSCursor.pointingHand.set(); if !$0 { NSCursor.arrow.set() } }
                // The click opens it, so copying needs another way in.
                .contextMenu {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                }
            } else {
                Text(value).font(Theme.mono).textSelection(.enabled)
            }
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
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(busy).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
            .fixedSize()
        } else {
            switch app.connection {
            case .connecting:
                Text("Connecting").font(.subheadline).foregroundStyle(.secondary)
            case .connected:
                if let error = app.statusError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            case let .down(message):
                Label(message, systemImage: "bolt.horizontal.circle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("Is `moomux serve` running?")
            }
        }
    }
}

/// Bottom-right, only while the app or the core is out of date. Hover for which and how
/// to update; the cask follows every tag, so `brew upgrade` is the whole fix.
private struct UpdateBadge: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let lines = [
            app.appUpdate.map { "Moomux \(WhatsNew.version) → \($0)" },
            app.coreUpdate.map { "Core \($0.current) → \($0.latest)" },
        ].compactMap { $0 }
        if !lines.isEmpty {
            Label("Update available", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                .help(lines.joined(separator: "\n"))
        }
    }
}

/// Claude's 5h and weekly quota, when the core serves one. Absent draws
/// nothing — almost nobody running this app runs agent-usage. Click for every
/// window and when it resets: the phone's menu, as a popover. A tooltip alone
/// was too well hidden — nothing about a line of text says "hover me".
private struct UsageBadge: View {
    @Environment(AppState.self) private var app
    @State private var showingDetail = false

    var body: some View {
        if let usage = app.usage {
            // The countdowns, and whether a window has reset, move every
            // minute; the snapshot only when agent-usage rewrites its file,
            // and not at all once the stream has dropped.
            TimelineView(.everyMinute) { context in
                Button { showingDetail.toggle() } label: {
                    UsageLine(usage, palette: app.palette, now: context.date, saysUsed: true)
                        .font(.subheadline)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Claude usage — click for reset times")
                .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(usage.detail(now: context.date).enumerated()), id: \.offset) { _, line in
                            Text(line)
                        }
                    }
                    .monospacedDigit()
                    .fixedSize()
                    .padding(12)
                }
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
            ForEach(app.menuBarSessions) { session in
                Button {
                    app.selectedSessionID = session.id
                    NSApp.activate()
                    NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
                } label: {
                    let state = app.state(for: session)
                    HStack {
                        Image(systemName: state.symbol).foregroundStyle(Theme.color(state, app.palette))
                        // The project name only when there is no emoji to stand in for it (a core too old
                        // to send one, or the menu bar's emoji switched off).
                        Text(app.menuBarEmoji(for: session.project).map { "\($0) \(session.name)" } ?? "\(session.project) · \(session.name)")
                        Spacer()
                        Text(app.label(for: session)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            if app.menuBarSessions.isEmpty {
                Text(app.connection.isDown ? "moomux serve isn't running" : "Nothing needs you")
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

/// An accent bar on each outer edge of a row: the selected session's, and the
/// header that is holding it while collapsed.
private struct SelectionEdges: View {
    let height: CGFloat
    var dimmed = false

    var body: some View {
        ZStack {
            Color.accentColor.opacity(dimmed ? 0.05 : 0.1)
            bar.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 3)
            bar.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 3)
        }
    }

    private var bar: some View {
        Capsule().fill(Color.accentColor.opacity(dimmed ? 0.45 : 1)).frame(width: 3, height: height)
    }
}
