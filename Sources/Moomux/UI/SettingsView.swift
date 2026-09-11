import AppKit
import SwiftUI

/// Settings and project management: the two write surfaces that are about the
/// configuration rather than about one session.
///
/// A sheet and not a `Settings` scene, so it is reachable the same way every
/// other form here is (`app.sheet`), and so the Session menu and the toolbar
/// can open it with a row selected or not. ⌘, still opens it — the shortcut is
/// what people reach for, the scene is not.
struct SettingsSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pane: Pane? = .projects
    /// The project form, presented *from here* rather than through
    /// `app.sheet`: this view is already what that modifier is showing, and one
    /// `.sheet(item:)` presents one thing. Its own state, because it is the
    /// only surface that opens it.
    @State private var editingProject: ProjectTarget?

    /// One category per sidebar row. Four is already more than a segmented
    /// picker wants to carry, and the alternative was a single "Preferences"
    /// pane holding everything that wasn't a project.
    enum Pane: String, CaseIterable, Identifiable {
        case projects, general, appearance, terminal
        var id: String { rawValue }

        var title: String {
            switch self {
            case .projects: "Projects"
            case .general: "General"
            case .appearance: "Appearance"
            case .terminal: "Terminal"
            }
        }

        var symbol: String {
            switch self {
            case .projects: "folder"
            case .general: "gearshape"
            case .appearance: "paintbrush"
            case .terminal: "apple.terminal"
            }
        }

    }

    /// nil `name` is "add"; a name is "edit that one". A wrapper because
    /// `.sheet(item:)` wants something `Identifiable` and `String?` isn't.
    struct ProjectTarget: Identifiable, Hashable {
        let name: String?
        var id: String { name ?? "" }
    }

    var body: some View {
        VStack(spacing: 0) {
            // An `HStack` and not a `NavigationSplitView`: nested inside this
            // sheet — which is itself presented from `RootView`'s split view —
            // both columns' `List`s render completely empty, the projects list
            // included. Measured, twice. Two columns by hand cost nothing here;
            // there is no navigation stack to push onto and nothing to collapse.
            HStack(spacing: 0) {
                List(Pane.allCases, selection: $pane) { p in
                    Label(p.title, systemImage: p.symbol).tag(p)
                }
                .listStyle(.sidebar)
                .frame(width: 160)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Inline, not an alert. `RootView`'s "Couldn't do that" alert is
            // bound on a view this sheet covers, so SwiftUI defers it until the
            // sheet closes — which is how "Remove" on a project that still has
            // sessions came to look like a button that does nothing. Measured.
            // A second `.alert` on the same state would race the first for the
            // presentation; a row cannot.
            if let error = app.actionError {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        app.actionError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 660, height: 480)
        // The row above already showed it. Left set, `RootView`'s deferred
        // alert fires the moment this sheet closes and says the same thing a
        // second time — measured, and it reads as the action having failed
        // twice.
        .onDisappear { app.actionError = nil }
        .sheet(item: $editingProject) { target in
            ProjectSheet(editing: target.name)
        }
        // Hosted here and nowhere else, for the same reason the form is: the
        // add that raises them can only have come from this sheet, and an alert
        // bound on a view that a sheet is covering never appears.
        .alert("Path is not a git repository", isPresented: Binding(
            get: { app.pendingProjectInit != nil },
            set: { if !$0 { app.pendingProjectInit = nil } }
        ), presenting: app.pendingProjectInit) { pending in
            Button("Init a git repo") { app.initProject(name: pending.name, pending.project) }
            Button("Add as plain folder") {
                app.addPlainProject(name: pending.name, pending.project)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("\(pending.project.repo)\n\nmoomux can run `git init` there (plus an empty "
                 + "first commit), or manage it as a plain folder — no worktrees, no branches, "
                 + "every session in the folder itself.")
        }
        .alert("Remove project?", isPresented: Binding(
            get: { app.pendingProjectDelete != nil },
            set: { if !$0 { app.pendingProjectDelete = nil } }
        ), presenting: app.pendingProjectDelete) { name in
            Button("Remove", role: .destructive) { app.removeProject(name: name) }
            Button("Cancel", role: .cancel) {}
        } message: { name in
            Text("Drops “\(name)” from moomux's config. The repository and everything in it "
                 + "stays on disk. Sessions have to be deleted first.")
        }
    }
}

extension SettingsSheet {
    @ViewBuilder
    private var detail: some View {
        // Only Projects is useless without a core. General and Appearance each
        // own client-local controls (the diff tool, the session list's font)
        // beside their core-backed ones, so they gate the *section* rather than
        // taking the whole pane over — see `NotConnectedSection`.
        switch pane ?? .projects {
        case .projects:
            if app.config == nil {
                ContentUnavailableView {
                    Label("Not connected", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text("Projects come from the core — start `moomux serve`.")
                }
            } else {
                ProjectsPane(editing: $editingProject).padding(16)
            }
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .terminal: TerminalPreferencesPane()
        }
    }
}

// MARK: - Projects

/// Every project moomux knows about, in the user's own order, with the four
/// writes the core offers. No drag-to-reorder: `MoveProject` takes a ±1 delta
/// and `onMove` wants index sets over a bound array, so two buttons are the
/// whole feature for a day less work — same trade the session list makes.
private struct ProjectsPane: View {
    @Environment(AppState.self) private var app
    @Binding var editing: SettingsSheet.ProjectTarget?
    @State private var selection: String?

    private var names: [String] { app.config?.orderedProjectNames ?? [] }

    var body: some View {
        VStack(spacing: 8) {
            List(selection: $selection) {
                ForEach(names, id: \.self) { name in
                    // No double-click-to-edit: a tap gesture on the row
                    // content competes with the `List`'s own selection, and a
                    // row that will not select leaves Edit and Remove
                    // permanently disabled. The buttons are the whole feature.
                    ProjectRow(name: name, project: app.config?.projects[name])
                        .tag(name)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay {
                // A fresh install lands here with nothing in the list, and an
                // empty `List` is a blank box that says nothing about what to do.
                if names.isEmpty {
                    ContentUnavailableView {
                        Label("No projects", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Add the repo you want moomux to cut session worktrees from.")
                    }
                }
            }
            HStack {
                // Never disabled: with nothing configured and nothing selected,
                // this is the only way out of the empty state.
                Button {
                    editing = .init(name: nil)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button("Edit") { if let selection { editing = .init(name: selection) } }
                    .disabled(selection == nil)
                Button("Remove") { app.pendingProjectDelete = selection }
                    .disabled(selection == nil)
                Spacer()
                Button {
                    if let selection { app.moveProject(name: selection, by: -1) }
                } label: {
                    Label("Move up", systemImage: "arrow.up")
                }
                .labelStyle(.iconOnly)
                .disabled(selection == nil)
                Button {
                    if let selection { app.moveProject(name: selection, by: 1) }
                } label: {
                    Label("Move down", systemImage: "arrow.down")
                }
                .labelStyle(.iconOnly)
                .disabled(selection == nil)
            }
            Text("Removing a project only drops it from moomux's config — nothing on disk is "
                 + "touched, and its sessions have to be deleted first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProjectRow: View {
    let name: String
    let project: Project?

    var body: some View {
        HStack(spacing: 8) {
            Text(project?.emoji ?? "").frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name)
                    if project?.isPlain == true {
                        Text("plain").font(.caption).foregroundStyle(.secondary)
                    } else if project?.noWorktree == true {
                        Text("no worktree").font(.caption).foregroundStyle(.secondary)
                    }
                    if project?.dangerous == true {
                        Text("⚠︎ dangerous").font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(project?.repo ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Not just the agent name: a `prompt_agent` project has one stored
            // and deliberately ignores it, so showing it would be a lie.
            Text(project?.promptAgent == true ? "asks each time" : (project?.agentName ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Add or edit one project. The kind (git vs plain) is not a field: adding
/// decides it — a real repo path goes in as git, and a path that isn't one
/// raises the init-or-plain choice in `RootView` — and editing cannot change
/// it at all, because existing sessions were made under the old one.
struct ProjectSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// nil to add, a name to edit.
    let editing: String?
    @State private var form = ProjectForm()

    private var isPlain: Bool { app.config?.projects[editing ?? ""]?.isPlain == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "Add project" : "Edit “\(editing!)”").font(.headline)
            Form {
                TextField("Name", text: $form.name)
                    // The core keys projects by name and has no rename, so
                    // editing one is a remove plus an add — not this form.
                    .disabled(editing != nil)
                TextField("Repo path", text: $form.repo, prompt: Text("~/src/thing"))
                Picker("Agent", selection: $form.agent) {
                    ForEach(app.agentNames, id: \.self) { Text($0).tag($0) }
                }
                .disabled(form.askAgent)
                Toggle("Ask which agent every time", isOn: $form.askAgent)
                    .help("New sessions in this project start with no agent chosen")
                Toggle("Skip permission prompts", isOn: $form.dangerous)
                    .disabled(form.askAgent)
                    .help("The default for new sessions in this project")
                if !isPlain {
                    TextField("Base branch", text: $form.baseBranch, prompt: Text("main"))
                    TextField("Branch prefix", text: $form.branchPrefix,
                              prompt: Text("optional, e.g. alan/"))
                    Toggle("One folder, no worktrees", isOn: $form.noWorktree)
                        .help("Sessions run in the repo itself, sharing its checkout. "
                              + "Can't be changed while the project has sessions.")
                }
                TextField("Emoji", text: $form.emoji, prompt: Text("none"))
                    // No palette picker: `config.ProjectEmojiPalette` is a Go
                    // table nothing serves over IPC, and this app must not keep
                    // a copy to drift. ⌃⌘Space is macOS's own picker.
                    .help("Shown in place of the name in the TUI's compact views. "
                          + "Left empty, the TUI picks one and this app shows none.")
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            if let problem = form.problem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            } else if isPlain {
                Text("A plain project has no branches or worktrees, so it has no base branch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save") {
                    if let editing {
                        app.updateProject(name: editing, form.project)
                    } else {
                        app.addProject(name: form.name.trimmed, form.project)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(form.problem != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let editing, let p = app.config?.projects[editing] {
                form = ProjectForm(editing: editing, p)
            }
            // The picker needs a valid selection even for a project whose
            // agent is unset — "" is not one of `agentNames`.
            if form.agent.isEmpty { form.agent = app.agentNames.first ?? "claude" }
        }
    }
}

// MARK: - General

/// Stands in for a pane's core-backed sections when there is no core, so the
/// client-local controls beside them stay usable — a whole-pane
/// `ContentUnavailableView` would take the session list's font down with the
/// theme. Backticks are literal in a `Text`, so the command is written plain.
private struct NotConnectedSection: View {
    var body: some View {
        Section {
            Label("Not connected", systemImage: "bolt.horizontal.circle")
                .foregroundStyle(.secondary)
        } footer: {
            Text("These settings come from the core — start moomux serve.")
                .font(.caption)
        }
    }
}

/// The core config flags that change behaviour rather than looks, plus the one
/// local setting that does the same. Three of these are shared with the TUI —
/// it is one config file, and a front end that could edit projects but not
/// these would stop somewhere odd. Each control is one socket write, and the
/// poll loop is what puts the new value back on screen.
private struct GeneralPane: View {
    @Environment(AppState.self) private var app

    private var cfg: Config? { app.config }

    var body: some View {
        Form {
            // One notice for the pane, and the core-backed rows simply absent
            // beneath it — repeating it in every section it applies to is
            // noisier than saying it once.
            if cfg == nil { NotConnectedSection() }

            Section("Sessions") {
                if cfg != nil {
                    Toggle("Sort sessions by last opened", isOn: Binding(
                        get: { cfg?.sortRecentFirst ?? false },
                        set: { app.setSortRecentFirst($0) }))
                        .help("Turns manual reordering off — the next open would undo it")
                    Toggle("Send the first prompt by default", isOn: Binding(
                        get: { cfg?.autoSubmitDefault ?? false },
                        set: { app.setAutoSubmitDefault($0) }))
                        .help("The starting state of the new-session form's send toggle, here and in the TUI")
                }
                // This app's own (`UserDefaults`), so it stays usable with no
                // core — which is why the gate above is per row and not over
                // the whole section.
                Toggle("Select a new session as soon as it's created", isOn: Binding(
                    get: { app.autoFocusNewSession }, set: { app.autoFocusNewSession = $0 }))
                    .help("Off leaves the sidebar selection where it was")
            }

            if cfg != nil {
                Section {
                    Toggle("Relaunch the TUI inside tmux", isOn: Binding(
                        get: { cfg?.autoTmux ?? false },
                        set: { app.setAutoTmux($0) }))
                } header: {
                    Text("Terminal UI")
                } footer: {
                    Text("moomux run in a terminal puts itself in a dedicated tmux session on "
                         + "startup. Nothing to do with this app's panes — see the Terminal "
                         + "pane for those.")
                    .font(.caption)
                }
            }

            // Not ours to fix: macOS leaves pop-up buttons and switches out of
            // the Tab chain unless Full Keyboard Access is on, so Tab in the New
            // Session sheet skips Agent, Model and Thinking entirely and looks
            // like a bug in the form.
            Section {
                Button("Open Keyboard settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Tab skips the pop-up menus and switches until macOS's Full Keyboard Access "
                     + "is on (Keyboard → Keyboard navigation). With it on, Tab reaches them and "
                     + "Space opens a menu or flips a switch.")
                .font(.caption)
            }

            // This app's own, not the shared config: the core serves no such
            // field, and a launcher for a Mac app is nothing the TUI could use.
            Section {
                // The worktree path is appended, so type the command as you
                // would in a shell minus the directory.
                TextField("Diff tool", text: Binding(
                    get: { app.diffTool }, set: { app.diffTool = $0 }),
                    prompt: Text("diffier"))
            } header: {
                Text("Tools")
            } footer: {
                Text("⌘D runs this against the selected session's worktree — code --diff, "
                     + "diffier. Left empty, ⌘D opens the diff in a tmux window instead.")
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

/// How the two front ends look. The theme is the core's and shared with the
/// TUI; the session list's font is this app's alone — which is why only the
/// second half sits behind the core gate.
private struct AppearancePane: View {
    @Environment(AppState.self) private var app

    private var cfg: Config? { app.config }

    var body: some View {
        Form {
            if cfg == nil { NotConnectedSection() }

            Section {
                Picker("Font", selection: Binding(
                    get: { app.listFontFamily }, set: { app.listFontFamily = $0 })) {
                    Text("System").tag("")
                    ForEach(app.fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: Binding(get: { app.listFontSize }, set: { app.listFontSize = $0 }),
                        in: 9...24, step: 1) {
                    Text("Text size: \(Int(app.listFontSize)) pt")
                }
            } header: {
                Text("Session list")
            } footer: {
                Text("Project and folder headers draw 2pt larger. This app only — the TUI "
                     + "renders in whatever font your terminal is set to.")
                .font(.caption)
            }

            if cfg != nil {
                Section {
                    // `app.themeNames` is the served list, so this app and the
                    // TUI offer the same palettes and render the same colors
                    // from them. It also keeps an unrecognized stored theme as a
                    // choice: a Picker whose selection matches no tag renders
                    // blank *and* writes nothing, so it would look like a bug and
                    // then be silently replaced by the first click on any other
                    // row here.
                    Picker("Theme", selection: Binding(
                        get: { cfg?.theme?.nilIfEmpty ?? "default" },
                        set: { app.setTheme($0, appearance: cfg?.appearance ?? "") })) {
                        ForEach(app.themeNames, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("TUI appearance", selection: Binding(
                        get: { cfg?.appearance?.nilIfEmpty ?? "auto" },
                        set: { app.setTheme(cfg?.theme ?? "", appearance: $0 == "auto" ? "" : $0) })) {
                        Text("auto").tag("auto")
                        Text("light").tag("light")
                        Text("dark").tag("dark")
                    }
                } header: {
                    Text("Theme")
                } footer: {
                    Text("Theme is shared: the core serves the palette both front ends draw "
                         + "from, so a session's state color is the same here and in the "
                         + "terminal UI. Appearance is the terminal UI's alone — this app "
                         + "follows the system.")
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Terminal

/// Where the terminal panes get their font, colours and cursor: the user's own
/// Ghostty config, read from the same four paths ghostty itself looks at.
///
/// There is deliberately no font picker and no theme picker here. libghostty is
/// configured by ghostty config text, and a second place to set the same values
/// would have to either lose to the file or silently override it — a Ghostty
/// user editing their config and seeing nothing change is worse than no control
/// at all. What this pane does is say which files were used, and get out of the
/// way.
private struct TerminalPreferencesPane: View {
    @Environment(AppState.self) private var app

    /// All of them, in load order, because ghostty loads all of them and lets
    /// the later ones override — showing only the first would misreport which
    /// settings actually won.
    private var configPaths: [String] { AppState.ghosttyConfigPaths() }

    private func short(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Config") {
                    if configPaths.isEmpty {
                        Text("No Ghostty config found \u{2014} using built-in defaults")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(configPaths, id: \.self) { path in
                                Text(short(path))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let last = configPaths.last {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: last)])
                    }
                }
                // The lines ghostty refused. libghostty rejects a config on
                // **any** diagnostic — it does not load it minus the bad line — so
                // `AppState` retries without them rather than letting one typo cost
                // the whole config, and this is the only report that it happened.
                let dropped = app.paneConfigDropped
                if !dropped.isEmpty {
                    LabeledContent("Ignored") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(dropped, id: \.self) { line in
                                Text(line)
                                    .textSelection(.enabled)
                                    .foregroundStyle(.orange)
                            }
                            Text("Ghostty rejected these; the rest of the config loaded.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // Whatever ghostty said when even the narrowed config would not
                // load — a broken managed-config write, say. Verbatim, because
                // there is nothing this app can do with it but show it.
                if let issue = app.terminalController.lastConfigurationIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("Panes render with Ghostty's engine and read Ghostty's own config, so they "
                     + "look like your terminal does. Changes apply to panes opened after a "
                     + "restart. Only Nerd Fonts carry the icons prompts and statuslines use.")
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

