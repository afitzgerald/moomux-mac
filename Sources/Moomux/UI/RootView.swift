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
    /// The agent-state colors, from the palette the core serves for the
    /// config's current theme. Nil before `Themes` has answered, which falls
    /// back to SwiftUI's own semantic colors — literally what the "default"
    /// palette encodes, so the zero state is the right one.
    static func color(_ state: AgentState, _ palette: ThemePalette?) -> Color {
        resolve(palette?.color(for: state)) ?? {
            switch state {
            case .needsInput: return .orange
            case .working: return .accentColor
            case .done: return .green
            case .parked, .unknown: return .secondary
            }
        }()
    }

    /// The sidebar's ± and ↑ badges. `internal/tui/list.go` draws both in
    /// `warnStyle`, built from the palette's *warn* entry — so this is that
    /// same join, and the two front ends now agree. (It used to bind to
    /// `done`, which came out green here and amber there; the core split
    /// `warn` out of `done` to end exactly that.)
    static func gitWarn(_ palette: ThemePalette?) -> Color {
        resolve(palette?.warn) ?? .orange
    }

    /// The sidebar's PR icon. Merged is the palette's `done`, conflicts and
    /// failing CI its `warn` — the same two entries the git badges and state
    /// dots already use, so nothing new is hardcoded here.
    static func pr(_ badge: PRInfo.Badge, _ palette: ThemePalette?) -> Color {
        switch badge {
        case .merged: return resolve(palette?.done) ?? .green
        case .conflicts, .failing, .comments: return gitWarn(palette)
        // Pending is not a problem, so it stays secondary: warn here would
        // put an amber icon on every PR for the minutes its checks run.
        case .open, .closed, .pending: return .secondary
        }
    }

    /// A served color as SwiftUI sees it. `system` wins when the core names
    /// one — that is how the state dots keep following the user's live
    /// accent instead of a frozen #007aff. Otherwise the light/dark pair, as
    /// a dynamic NSColor so AppKit resolves the half at draw time and no
    /// view has to observe the color scheme.
    private static func resolve(_ c: ThemeColor?) -> Color? {
        guard let c else { return nil }
        switch c.system {
        case "accent": return .accentColor
        case "green": return .green
        case "orange": return .orange
        case "secondary": return .secondary
        default: break
        }
        guard nsColor(c.light) != nil, nsColor(c.dark) != nil else { return nil }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(dark ? c.dark : c.light) ?? .labelColor
        })
    }

    /// "#rrggbb" only — the one format the core sends for a non-ANSI theme.
    private static func nsColor(_ hex: String) -> NSColor? {
        var h = Substring(hex)
        guard h.first == "#" else { return nil }
        h = h.dropFirst()
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255,
                       alpha: 1)
    }

    static let mono = Font.system(size: 12, design: .monospaced)

    /// A regression here is silent by construction — a hex the parser rejects
    /// falls through to the SwiftUI semantic color and still renders something
    /// plausible — so the parser gets asserts rather than a screenshot.
    static func demo() {
        assert(nsColor("#076678") != nil)
        assert(nsColor("12") == nil, "an ANSI index is not hex")
        assert(nsColor("#12345") == nil && nsColor("#1234567") == nil, "six digits or nothing")
        assert(nsColor("076678") == nil, "the # is required")
        assert(nsColor("#gggggg") == nil)
        assert(nsColor("#ffffff")?.usingColorSpace(.sRGB)?.blueComponent == 1)
        assert(nsColor("#ff0000")?.usingColorSpace(.sRGB)?.blueComponent == 0, "channels in RGB order")

        // system beats hex, and only for the names the core actually sends.
        assert(resolve(ThemeColor(light: "#ff0000", dark: "#ff0000", system: "accent")) == .accentColor)
        assert(resolve(ThemeColor(light: "#ff0000", dark: "#ff0000", system: "chartreuse")) != nil,
               "an unfamiliar system name falls back to the pair, not to nil")
        assert(resolve(nil) == nil)
        // The ANSI theme never reaches here (`ThemePalette.resolved` swaps it
        // for default), but a half it could not parse must read as "no color"
        // so the caller's semantic fallback wins.
        assert(resolve(ThemeColor(light: "11", dark: "11")) == nil)
        assert(resolve(ThemeColor(light: "#83a598", dark: "")) == nil, "both halves or neither")
    }
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
                Toggle(isOn: $app.showArchived) { Label("Archived", systemImage: "archivebox") }
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
            case let .newFolder(project, assign):
                TextFieldSheet(title: "New folder in “\(project)”",
                               labels: ["Name"], values: [""]) { values in
                    let name = values[0].trimmed
                    // Filing a session into it *is* the create: SetSessionFolder
                    // makes a folder on first use, so this stays one call.
                    if let session = assign {
                        app.setFolder(session, to: name)
                    } else {
                        app.createFolder(project: project, name: name)
                    }
                }
            case let .renameFolder(project, name):
                TextFieldSheet(title: "Rename “\(name)”",
                               labels: ["Name"], values: [name]) { values in
                    app.renameFolder(project: project, from: name, to: values[0].trimmed)
                }
            case .settings:
                SettingsSheet()
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

    private var projects: [String] { app.config?.orderedProjectNames ?? [] }
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
                        // An NSTextView takes Tab as a literal character, which
                        // made this box a keyboard trap. Return has to stay a
                        // newline — the core sends the prompt as one paste-like
                        // `send-keys -l` chunk, so a multi-line prompt arrives
                        // intact — so Tab is what gives, moving focus the way it
                        // does in every other field.
                        // Back-tab is its own key equivalent (U+0019), not
                        // `.tab` with a shift modifier — matching only `.tab`
                        // gets you a box you can leave forwards and not back.
                        .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
                            let w = NSApp.keyWindow
                            if press.modifiers.contains(.shift) {
                                w?.selectPreviousKeyView(nil)
                            } else {
                                w?.selectNextKeyView(nil)
                            }
                            return .handled
                        }
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
            ForEach(app.sessionsByProject, id: \.project) { group in
                // Not `Section`: a sidebar section keeps its *own* hidden
                // disclosure state, a click on the header drives that as well
                // as ours, and the two fall out of phase the moment a project
                // is collapsed at launch — SwiftUI starts expanded, so the
                // first click on a folded project expanded ours and collapsed
                // its, and the rows stayed away. Plain rows have no such
                // state, and they are what lets a collapsed project keep the
                // attached session's row on screen. Both measured.
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
                        SessionRow(session: session, indented: !folder.isEmpty).tag(session.id)
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
    let hidden: Int
    @State private var targeted = false

    var body: some View {
        // The header is not a selectable row, so a tap gesture here does not
        // steal the List's selection the way one on a row would.
        let expanded = app.projectExpanded(name)
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
            if let emoji = app.emoji(for: name) { Text(emoji) }
            Text(name)
            if !expanded, hidden > 0 {
                Text("\(hidden)")
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { app.setProject(name, expanded: !expanded) }
        .dropDestination(for: String.self) { ids, _ in
            app.drop(ids, into: "", project: name)
        } isTargeted: { targeted = $0 }
        .listRowBackground(targeted ? Color.accentColor.opacity(0.25) : nil)
        .contextMenu {
            Button("New Folder…") { app.sheet = .newFolder(project: name, assign: nil) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(expanded ? name : "\(name), collapsed, \(hidden) sessions")
        .accessibilityAction { app.setProject(name, expanded: !expanded) }
    }
}

/// A folder header — the same plain-row shape as `ProjectHeader`, one level in.
private struct FolderHeader: View {
    @Environment(AppState.self) private var app
    let project: String
    let name: String
    let collapsed: Bool
    let count: Int
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
            Image(systemName: collapsed ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
            Text(name)
            if collapsed, count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { app.setFolder(project: project, name: name, collapsed: !collapsed) }
        .dropDestination(for: String.self) { ids, _ in
            app.drop(ids, into: name, project: project)
        } isTargeted: { targeted = $0 }
        .listRowBackground(targeted ? Color.accentColor.opacity(0.25) : nil)
        .contextMenu {
            Button("Rename…") { app.sheet = .renameFolder(project: project, name: name) }
            // No confirmation: deleting a folder files its members back at the
            // top level and removes nothing.
            Button("Delete") { app.deleteFolder(project: project, name: name) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(collapsed ? "\(name), collapsed, \(count) sessions" : name)
        .accessibilityAction { app.setFolder(project: project, name: name, collapsed: !collapsed) }
    }
}

private struct SessionRow: View {
    @Environment(AppState.self) private var app
    let session: Session
    /// Set for a session inside a folder — straight off its row, so nothing
    /// here has to join back to the folder to know.
    var indented = false

    var body: some View {
        let state = app.state(for: session)
        // Baseline rather than .top: a two-line row is taller than the icon, and
        // .top would leave it floating a couple of points above the name.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: state.symbol)
                .foregroundStyle(Theme.color(state, app.palette))
                .help(app.label(for: session))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Second row, right aligned. Empty for a session with no tags
                // and a clean worktree, and an empty HStack takes no height, so
                // those rows stay single-line.
                HStack(spacing: 10) {
                    // `internal/tui/list.go` draws the tag icons before the git
                    // ones, in this order. The PR icon carries its merge/CI
                    // state the way `prGlyph` does — a merged or blocked PR is
                    // exactly what you want to spot without opening the session.
                    if let ticket = session.ticket, !ticket.isEmpty {
                        TagIcon(symbol: "ticket", link: ticket, help: ticket)
                            .foregroundStyle(.secondary)
                    }
                    if let pr = session.pr, !pr.isEmpty {
                        let info = app.views[session.id]?.pr
                        let badge = PRInfo.badge(info)
                        TagIcon(symbol: badge.symbol, link: pr,
                                help: info?.summary.isEmpty == false ? "\(badge.help) — \(info!.summary)"
                                                                    : badge.help)
                            .foregroundStyle(Theme.pr(badge, app.palette))
                    }
                    // `internal/tui/list.go`'s two git icons, in its order: ±
                    // for a dirty worktree, ↑ for commits that are not on the
                    // remote. Both can show at once — they are different work
                    // in different places, and collapsing them would hide one.
                    // SF Symbols rather than the literal glyphs so they weigh
                    // and align like the row's other icons; they draw the same
                    // ± and ↑. Counts stay in the detail panel's Changes row.
                    if let git = app.gitBadges(for: session) {
                        if git.dirty {
                            Image(systemName: "plusminus")
                                .foregroundStyle(Theme.gitWarn(app.palette))
                                .help("Uncommitted changes")
                        }
                        if git.unpushed {
                            Image(systemName: "arrow.up")
                                .foregroundStyle(Theme.gitWarn(app.palette))
                                .help("Unpushed commits")
                        }
                    }
                    // Archived rows are only on screen because the Archived
                    // toggle is on, and without this they are indistinguishable
                    // from live ones — the toggle changes the list and nothing
                    // says which rows it added.
                    if session.archived {
                        Image(systemName: "archivebox")
                            .foregroundStyle(.tertiary)
                            .help("Archived")
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, indented ? 12 : 0)
        // The payload is the session id as a plain string — no custom UTType,
        // which would need an Info.plist declaration to be worth anything.
        // The cost is that dragging a row into a text field types its id;
        // `AppState.drop` ignores any string that is not a session of the
        // project it landed on.
        .draggable(session.id)
        // Closes over `session`, never over the selection: right-clicking an
        // unselected row has to act on the row you clicked.
        .contextMenu {
            Button("Review Changes") { app.review(session) }
                .disabled(!app.canReview(session))
            Button("Open in Diff Tool") { app.openDiffTool(session) }
                .disabled(!app.canOpenDiffTool(session))
            Button("Edit…") { app.sheet = .edit(session) }
            Button("Tags…") { app.sheet = .tags(session) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.worktreePath, forType: .string)
            }
            .disabled(session.worktreePath.isEmpty)
            Divider()
            Button(session.archived ? "Unarchive" : "Archive") {
                app.setArchived(session, !session.archived)
            }
            Menu("Folder") {
                Button("None") { app.setFolder(session, to: "") }
                    .disabled(session.folder.isEmpty)
                let folders = app.folders(of: session.project)
                if !folders.isEmpty { Divider() }
                ForEach(folders, id: \.self) { name in
                    Button(name) { app.setFolder(session, to: name) }
                        .disabled(name == session.folder)
                }
                Divider()
                Button("New Folder…") {
                    app.sheet = .newFolder(project: session.project, assign: session)
                }
            }
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
                        .disabled(ToolPath.find("tmux") == nil)
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
                    if ToolPath.find("tmux") == nil {
                        Text("Can't find a tmux binary to attach with.")
                            .foregroundStyle(.secondary)
                    } else if !app.isAlive(session) {
                        Text("No live tmux session — Attach starts one.")
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
                    if let ticket = session.ticket, !ticket.isEmpty { Field("Ticket", ticket) }
                    if let pr = session.pr, !pr.isEmpty { Field("PR", pr) }
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
    let symbol: String
    let link: String
    let help: String

    var body: some View {
        if TerminalLink.resolve(link) != nil {
            Button { TerminalLink.open(link) } label: { Image(systemName: symbol) }
                .buttonStyle(.plain)
                .help("\(help) — click to open")
        } else {
            Image(systemName: symbol).help(help)
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

// MARK: - Menu bar

/// The one thing the TUI structurally cannot have: a live count of sessions
/// waiting on you, visible while you are in another app.
struct MenuBarContent: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(app.visibleSessions.filter { app.isAlive($0) }) { session in
                Button {
                    app.selectedSessionID = session.id
                    NSApp.activate()
                    NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
                } label: {
                    let state = app.state(for: session)
                    HStack {
                        Image(systemName: state.symbol).foregroundStyle(Theme.color(state, app.palette))
                        Text("\(session.project) · \(session.name)")
                        Spacer()
                        Text(app.label(for: session)).foregroundStyle(.secondary)
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
