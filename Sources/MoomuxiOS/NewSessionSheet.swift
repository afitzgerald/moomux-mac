import MoomuxKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The Mac's New Session sheet on a phone: the same `NewSessionForm`, the same
/// pickers off the core's `AgentOptions`, the same one `CreateSession` call.
/// Only the layout differs — sections instead of a fixed-width panel.
struct NewSessionSheet: View {
    let app: AppState
    /// Asked when the create finishes: whether to go to the new session.
    let focus: @MainActor () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var form = NewSessionForm()
    /// The core's refusal of the last Create, verbatim, when the sheet was
    /// reopened over it.
    @State private var error: String?
    @FocusState private var baseBranchFocused: Bool
    @State private var photos: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var attachments = AttachQueue()

    private var projects: [String] { app.config?.orderedProjectNames ?? [] }
    private var project: Project? { app.config?.projects[form.project] }
    private var models: [String] { app.models(for: form.agent) }
    private var thinking: [String] { app.thinking(for: form.agent) }
    private var hasModelList: Bool { app.hasModelList(for: form.agent) }
    /// Anything typed. Pickers are cheap to redo; a half-written prompt is not.
    /// The base branch counts once it differs from the project's, which it
    /// arrives filled in with.
    private var edited: Bool { Self.edited(form) }
    private static func edited(_ form: NewSessionForm) -> Bool {
        form.baseBranchEdited
            || ![form.name, form.prompt, form.existingBranch, form.ticket, form.pr].allSatisfy(\.isEmpty)
    }
    private var blamesBaseBranch: Bool { error.map(NewSessionForm.blamesBaseBranchField) == true }

    private var agentPicker: some View {
        Picker("Agent", selection: $form.agent) {
            // Only for a `prompt_agent` project, which must not silently pick one.
            if form.agent.isEmpty { Text("choose one").tag("") }
            ForEach(app.agentNames, id: \.self) { Text($0).tag($0) }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, prompt: String) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    var body: some View {
        NavigationStack {
            // The Mac's layout: what changes per session on the face, the
            // agent override and model folded under More options.
            Form {
                Section {
                    Picker("Project", selection: $form.project) {
                        Text("choose one").tag("")
                        ForEach(projects, id: \.self) { Text($0).tag($0) }
                    }
                    // Up here only when the project asks every time — and then
                    // it asks about permissions too, as the TUI does.
                    if project?.promptAgent == true {
                        agentPicker
                        Toggle("Skip permission prompts", isOn: $form.dangerous)
                    }
                } footer: {
                    if form.project.isEmpty {
                        Text("Choose the project to start the session in.")
                    } else if project?.promptAgent == true && form.agent.isEmpty {
                        Text("This project asks for an agent every time — pick one.")
                    }
                }
                Section {
                    // A fixed-height editor, not `TextField(axis: .vertical)`:
                    // that one sizes itself by laying out the whole text on
                    // every pass, and a long restored draft held the main
                    // thread past the watchdog — killed on every open, since
                    // the draft survives the crash. This one scrolls and lays
                    // out only what is visible.
                    TextEditor(text: $form.prompt)
                        .frame(height: 150)
                        .overlay(alignment: .topLeading) {
                            if form.prompt.isEmpty {
                                Text("What should the agent do?")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("Prompt")
                    // Borderless, or two buttons sharing a Form row both fire
                    // on any tap in it. The pill and Thinking share the row:
                    // both are settings of the prompt above.
                    HStack(spacing: 8) {
                        HStack(spacing: 0) {
                            PhotosPicker(selection: $photos, matching: .images) {
                                Image(systemName: "photo.on.rectangle").attachBarIcon()
                            }
                            .accessibilityLabel("Photos")
                            Button { importingFiles = true } label: {
                                Image(systemName: "paperclip").attachBarIcon()
                            }
                            .accessibilityLabel("Files")
                        }
                        .buttonStyle(.borderless)
                        .tint(.white)
                        .attachBarPill()
                        if attachments.pending > 0 { ProgressView().accessibilityLabel("Uploading") }
                        Spacer(minLength: 8)
                        if !thinking.isEmpty {
                            Picker("Thinking", selection: $form.thinking) {
                                ForEach(thinking, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .tint(.secondary)
                            .fixedSize()
                        }
                    }
                } footer: {
                    if let error = form.promptProblem ?? attachments.error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    // Labelled rows rather than bare fields: the base branch
                    // arrives filled in, so a placeholder could not name it.
                    field("Name", $form.name, prompt: form.namePlaceholder)
                    field("Existing branch", $form.existingBranch, prompt: "resume, don't cut")
                    field("Base branch", $form.baseBranch, prompt: "the repo's default")
                        .disabled(project?.isPlain == true || !form.existingBranch.isEmpty)
                        .focused($baseBranchFocused)
                        .foregroundStyle(blamesBaseBranch ? .red : .primary)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    field("Ticket", $form.ticket, prompt: "")
                    field("PR", $form.pr, prompt: "")
                }
                Section {
                    DisclosureGroup("More options") {
                        if project?.promptAgent != true { agentPicker }
                        if hasModelList {
                            Picker("Model", selection: $form.model) {
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                        } else {
                            field("Model", $form.modelText, prompt: "default")
                        }
                        // Starts at the config's default; this session only.
                        Toggle("Send the prompt", isOn: $form.autoSubmit)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Closes at once, as on the Mac: `busy` reports progress in
                    // the status badge and a refusal reopens this sheet.
                    Button("Create") {
                        app.create(form, focus: focus)
                        dismiss()
                    }
                    .disabled(!form.canCreate || attachments.pending > 0)
                }
            }
        }
        // A swipe down is too easy to make by accident while scrolling a form;
        // once something is typed, Cancel is the only way out.
        .interactiveDismissDisabled(edited || attachments.pending > 0)
        .onDisappear { attachments.cancelAll() }
        // No project until one is chosen, and Create waits for it
        // (`canCreate`). The Mac can seed from the selected row; a phone has
        // no selection, and defaulting to the first project put every session
        // there unless you remembered to change it.
        // A refused create's form comes back whole, with the core's reason.
        .onAppear {
            (form, error) = app.openNewSessionForm(project: "")
            if blamesBaseBranch { DispatchQueue.main.async { baseBranchFocused = true } }
        }
        .onChange(of: form.prompt) { _, prompt in app.promptDraft = prompt }
        // Opened before the config landed (the `-newSession` seam): take its
        // defaults once it does, unless the user has already started. The
        // prompt is the saved draft, so it is carried over rather than counted.
        .onChange(of: projects) { _, _ in
            var fresh = form
            fresh.prompt = ""
            if form.project.isEmpty && error == nil && !Self.edited(fresh) {
                let prompt = form.prompt
                form = app.newSessionForm(project: "")
                form.prompt = prompt
            }
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            attach(app.attachJobs(items))
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { attach(app.attachJobs($0)) }
        .onChange(of: form.project) { _, _ in app.applyProject(to: &form) }
        .onChange(of: form.agent) { _, _ in app.clampChoices(of: &form) }
        .onChange(of: app.agentNames) { _, _ in app.agentNamesChanged(in: &form) }
    }

    // MARK: - Attachments

    /// A file on the phone has no path an agent on the Mac could open, so
    /// every one is uploaded and its path appended to the prompt.
    private func attach(_ jobs: [AttachJob]) {
        attachments.run(jobs) { form.appendPath($0) }
    }
}

/// One upload job per picked photo or file, shared by the New Session sheet and
/// the terminal screen — they differ only in where the returned path lands.
extension AppState {
    func attachJobs(_ items: [PhotosPickerItem]) -> [AttachJob] {
        items.map { item in {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CocoaError(.fileReadUnknown)
            }
            let type = item.supportedContentTypes.first
            return try await self.attach(name: "photo.\(type?.preferredFilenameExtension ?? "jpg")",
                                         type: type, data: data)
        } }
    }

    /// A picker that failed becomes a job that fails, so its reason is shown
    /// where an upload's failure would be.
    func attachJobs(_ picked: Result<[URL], Error>) -> [AttachJob] {
        switch picked {
        case .failure(let error):
            return [{ throw error }]
        case .success(let urls):
            return urls.map { url in {
                try await self.attach(name: url.lastPathComponent,
                                      type: UTType(filenameExtension: url.pathExtension),
                                      data: try await Attachments.read(url))
            } }
        }
    }
}

/// The key bar's look (`PaneKeyBar`): icon-only buttons, 14pt glyphs, 51pt
/// tall, in one dark glass pill.
private extension View {
    func attachBarIcon() -> some View {
        font(.system(size: 14)).frame(minWidth: 48, minHeight: 51).contentShape(Rectangle())
    }

    func attachBarPill() -> some View {
        glassEffect(.regular.tint(.black.opacity(0.7)).interactive(), in: Capsule())
    }
}
