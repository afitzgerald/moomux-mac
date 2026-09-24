import MoomuxKit
import SwiftUI

/// The Mac's New Session sheet on a phone: the same `NewSessionForm`, the same
/// pickers off the core's `AgentOptions`, the same one `CreateSession` call.
/// Only the layout differs — sections instead of a fixed-width panel.
struct NewSessionSheet: View {
    let app: AppState
    /// Asked when the create finishes: whether to go to the new session.
    let focus: @MainActor () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var form = NewSessionForm()

    private var projects: [String] { app.config?.orderedProjectNames ?? [] }
    private var project: Project? { app.config?.projects[form.project] }
    private var models: [String] { app.models(for: form.agent) }
    private var thinking: [String] { app.thinking(for: form.agent) }
    private var hasModelList: Bool { app.hasModelList(for: form.agent) }
    /// Anything typed. Pickers are cheap to redo; a half-written prompt is not.
    private var edited: Bool {
        ![form.name, form.prompt, form.existingBranch, form.baseBranch, form.ticket, form.pr]
            .allSatisfy(\.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Project", selection: $form.project) {
                        Text("choose one").tag("")
                        ForEach(projects, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Name", text: $form.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("First prompt") {
                    TextField("What should the agent do?", text: $form.prompt, axis: .vertical)
                        .lineLimit(3...8)
                    Toggle("Send it (press Enter)", isOn: $form.autoSubmit)
                }
                Section {
                    Picker("Agent", selection: $form.agent) {
                        // Only for a `prompt_agent` project, which must not
                        // silently pick one.
                        if form.agent.isEmpty { Text("choose one").tag("") }
                        ForEach(app.agentNames, id: \.self) { Text($0).tag($0) }
                    }
                    if hasModelList {
                        Picker("Model", selection: $form.model) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        TextField("Model", text: $form.modelText, prompt: Text("Model (default)"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if !thinking.isEmpty {
                        Picker("Thinking", selection: $form.thinking) {
                            ForEach(thinking, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Toggle("Skip permission prompts", isOn: $form.dangerous)
                } header: {
                    Text("Agent")
                } footer: {
                    if !form.project.isEmpty && project?.promptAgent == true && form.agent.isEmpty {
                        Text("This project asks for an agent every time — pick one.")
                    }
                }
                Section("Branch") {
                    // On iOS the prompt *is* the label, so it has to name the field.
                    TextField("Existing branch (resume, don't cut)", text: $form.existingBranch)
                    TextField("Base branch", text: $form.baseBranch,
                              prompt: Text("Base branch (\(project?.baseBranch.flatMap { $0.isEmpty ? nil : $0 } ?? "project default"))"))
                        .disabled(project?.isPlain == true)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Section("Tags") {
                    TextField("Ticket", text: $form.ticket)
                    TextField("PR", text: $form.pr)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
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
                    .disabled(!form.canCreate)
                }
            }
        }
        // A swipe down is too easy to make by accident while scrolling a form;
        // once something is typed, Cancel is the only way out.
        .interactiveDismissDisabled(edited)
        // No selection to seed from on a phone, so the first project — the
        // picker is the top row, so a wrong guess is one tap away.
        .onAppear { form = app.newSessionForm(project: projects.first ?? "") }
        // Opened before the config landed (the `-newSession` seam): seed once
        // it does, unless the user has already started.
        .onChange(of: projects) { _, projects in
            if form.project.isEmpty && !edited { form = app.newSessionForm(project: projects.first ?? "") }
        }
        .onChange(of: form.project) { _, _ in app.applyProject(to: &form) }
        .onChange(of: form.agent) { _, _ in app.clampChoices(of: &form) }
        .onChange(of: app.agentNames) { _, _ in app.agentNamesChanged(in: &form) }
    }
}
