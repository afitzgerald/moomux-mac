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
                    if !thinking.isEmpty {
                        Picker("Thinking", selection: $form.thinking) {
                            ForEach(thinking, id: \.self) { Text($0).tag($0) }
                        }
                    }
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
