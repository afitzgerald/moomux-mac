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
    private var edited: Bool {
        form.baseBranchEdited
            || ![form.name, form.prompt, form.existingBranch, form.ticket, form.pr].allSatisfy(\.isEmpty)
    }

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
                    if project?.promptAgent == true && form.agent.isEmpty {
                        Text("This project asks for an agent every time — pick one.")
                    }
                }
                Section {
                    TextField("What should the agent do?", text: $form.prompt, axis: .vertical)
                        .lineLimit(3...8)
                    // Borderless, or two buttons sharing a Form row both fire
                    // on any tap in it.
                    HStack {
                        PhotosPicker(selection: $photos, matching: .images) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }
                        Spacer()
                        Button { importingFiles = true } label: {
                            Label("Files", systemImage: "paperclip")
                        }
                    }
                    .buttonStyle(.borderless)
                    if attachments.pending > 0 {
                        LabeledContent("Uploading…") { ProgressView() }
                    }
                    if !thinking.isEmpty {
                        Picker("Thinking", selection: $form.thinking) {
                            ForEach(thinking, id: \.self) { Text($0).tag($0) }
                        }
                    }
                } footer: {
                    if let error = attachments.error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    // Labelled rows rather than bare fields: the base branch
                    // arrives filled in, so a placeholder could not name it.
                    field("Name", $form.name, prompt: form.namePlaceholder)
                    field("Existing branch", $form.existingBranch, prompt: "resume, don't cut")
                    field("Base branch", $form.baseBranch, prompt: "the repo's default")
                        .disabled(project?.isPlain == true || !form.existingBranch.isEmpty)
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
                    // the status badge and a refusal lands in the list's alert.
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
        // No selection to seed from on a phone, so the first project — the
        // picker is the top row, so a wrong guess is one tap away.
        .onAppear { form = app.newSessionForm(project: projects.first ?? "") }
        // Opened before the config landed (the `-newSession` seam): seed once
        // it does, unless the user has already started.
        .onChange(of: projects) { _, projects in
            if form.project.isEmpty && !edited { form = app.newSessionForm(project: projects.first ?? "") }
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
