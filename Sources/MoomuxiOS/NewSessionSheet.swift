import MoomuxKit
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
    @State private var attachments = AttachQueue()

    private var projects: [String] { app.config?.orderedProjectNames ?? [] }
    private var project: Project? { app.config?.projects[form.project] }
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
            // The Mac's layout, in sections.
            Form {
                Section {
                    Picker("Project", selection: $form.project) {
                        Text("choose one").tag("")
                        ForEach(projects, id: \.self) { Text($0).tag($0) }
                    }
                } footer: {
                    if form.project.isEmpty {
                        Text("Choose the project to start the session in.")
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
                    PromptBar(app: app, form: $form, uploading: attachments.pending > 0,
                              attach: attach, fileJobs: app.attachJobs)
                    // Under the agent it belongs to, only for one with no
                    // model list (opencode); the rest pick theirs in the menu.
                    if !hasModelList && !form.agent.isEmpty {
                        field("Model", $form.modelText, prompt: "default")
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
        .onChange(of: form.project) { _, _ in app.applyProject(to: &form) }
        .onChange(of: form.agent) { _, _ in app.clampChoices(of: &form) }
        .onChange(of: form.model) { _, _ in app.clampChoices(of: &form) }
        .onChange(of: app.agentNames) { _, _ in app.presetAgent(in: &form) }
        .onChange(of: app.config?.lastAgent) { _, _ in app.presetAgent(in: &form) }
        .onChange(of: app.agentOptions) { _, _ in app.keepChoices(of: &form) }
        .onChange(of: app.config?.excludedModels) { _, _ in app.keepChoices(of: &form) }
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

