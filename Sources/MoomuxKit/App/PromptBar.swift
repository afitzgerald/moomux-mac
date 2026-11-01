import PhotosUI
import SwiftUI

/// The row under the New Session sheet's first prompt, on the Mac and the
/// iPhone alike: one pill of Attach and Snippets (menus, as on the phone's key
/// bar), then agent and model as one choice, then Thinking — all three change
/// together (`clampChoices`), and all are settings of the prompt above.
public struct PromptBar: View {
    let app: AppState
    @Binding var form: NewSessionForm
    let uploading: Bool
    let attach: ([AttachJob]) -> Void
    /// What a picked file becomes. The Mac's goes through its drop path.
    let fileJobs: (Result<[URL], Error>) -> [AttachJob]
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var importingFiles = false
    @State private var editingSnippets = false
    @State private var snippets = Snippet.saved(Snippet.promptKey)

    public init(app: AppState, form: Binding<NewSessionForm>, uploading: Bool,
                attach: @escaping ([AttachJob]) -> Void,
                fileJobs: @escaping (Result<[URL], Error>) -> [AttachJob]) {
        self.app = app
        _form = form
        self.uploading = uploading
        self.attach = attach
        self.fileJobs = fileJobs
    }

    private var thinking: [String] { app.thinking(for: form.agent, model: form.model) }
    private var hasModelList: Bool { app.hasModelList(for: form.agent) }

    public var body: some View {
        // Borderless, or two buttons sharing a Form row both fire on any tap in it.
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Menu {
                    Button("Photos", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                    Button("Files", systemImage: "folder") { importingFiles = true }
                } label: {
                    Image(systemName: "paperclip").attachBarIcon()
                }
                .attachBarItem()
                .accessibilityLabel("Attach")
                Menu {
                    ForEach(snippets) { snippet in
                        Button(snippet.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            form.appendPath(snippet.text)
                        }
                    }
                    Section {
                        Button("Edit Snippets…", systemImage: "pencil") { editingSnippets = true }
                    }
                } label: {
                    Image(systemName: "bolt").attachBarIcon()
                }
                .attachBarItem()
                .accessibilityLabel("Snippets")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .tint(.primary)
            .attachBarPill()
            if uploading { ProgressView().controlSize(.small).accessibilityLabel("Uploading") }
            Spacer(minLength: 8)
            agentPicker
            if !thinking.isEmpty {
                Picker("Thinking", selection: $form.thinking) {
                    ForEach(thinking, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                // The value alone: beside the agent, what it sets is plain.
                .labelsHidden()
                .tint(.secondary)
                .fixedSize()
                // The core decides which; opencode is the one agent with no
                // launch flag for it (`reasoningEffortFlag`).
                .help(form.agent == "opencode"
                      ? "Thinking — prepended to the first prompt, as opencode has no flag for it"
                      : "Thinking — passed to \(form.agent) as its reasoning-effort flag")
            }
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            attach(app.attachJobs(items))
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .images)
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { attach(fileJobs($0)) }
        .sheet(isPresented: $editingSnippets, onDismiss: { snippets = Snippet.saved(Snippet.promptKey) }) {
            SnippetsSheet(key: Snippet.promptKey)
        }
    }

    /// One list, each agent's models under its name, so a choice sets both,
    /// and the button shows only the agent's logo. An agent with no model
    /// list (opencode) is one row, its model free text under this row.
    /// The agent is empty only until the core's table arrives.
    private var agentPicker: some View {
        Menu {
            Picker("Agent and model", selection: agentChoice) {
                ForEach(app.agentNames, id: \.self) { name in
                    let icon = AgentMark.image(name) ?? Image(systemName: "terminal")
                    if app.hasModelList(for: name) {
                        // No heading: the logo on every row names the agent.
                        Section {
                            // The current agent's list keeps a chosen model that was since hidden.
                            let shown = app.models(for: name)
                            ForEach(name == form.agent ? form.modelChoices(shown) : shown, id: \.self) { model in
                                Label { Text(app.modelLabel(model, agent: name)) } icon: { icon }
                                    .tag(AgentChoice(agent: name, model: model))
                            }
                        }
                    } else {
                        Label { Text(name) } icon: { icon }
                            .tag(AgentChoice(agent: name, model: ""))
                    }
                }
            }
            // Inline, or the Mac nests the whole list under one submenu.
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                if form.agent.isEmpty {
                    Image(systemName: "questionmark.circle").font(.system(size: Self.markSize - 5))
                } else if AgentMark.image(form.agent) != nil {
                    AgentMark(form.agent, size: Self.markSize)
                } else {
                    Text(form.agent)
                }
                #if os(iOS)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                #endif
            }
        }
        #if os(macOS)
        // The Mac draws its own chevron.
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        #endif
        .tint(.secondary)
        .accessibilityLabel("Agent and model")
        .accessibilityValue(form.agent.isEmpty ? "choose one" : "\(form.agent), \(app.modelLabel(form.model, agent: form.agent))")
    }

    #if os(iOS)
    private static let markSize: CGFloat = 22
    #else
    private static let markSize: CGFloat = 16
    #endif

    private struct AgentChoice: Hashable {
        var agent: String
        /// Empty for an agent with no model list.
        var model: String
    }

    private var agentChoice: Binding<AgentChoice> {
        Binding {
            AgentChoice(agent: form.agent, model: hasModelList ? form.model : "")
        } set: {
            form.agent = $0.agent
            if !$0.model.isEmpty { form.model = $0.model }
        }
    }
}

extension AppState {
    /// One upload job per picked photo; its path lands wherever the caller puts it.
    public func attachJobs(_ items: [PhotosPickerItem]) -> [AttachJob] {
        items.map { item in {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CocoaError(.fileReadUnknown)
            }
            let type = item.supportedContentTypes.first
            return try await self.attach(name: "photo.\(type?.preferredFilenameExtension ?? "jpg")",
                                         type: type, data: data)
        } }
    }
}

/// The phone's key bar's shape (`PaneKeyBar`'s attach button): 36pt wide,
/// 51pt tall, in one glass capsule. 12.5pt glyphs draw the same size as its
/// 10pt ones, which `UIButton` scales up — measured off screenshots of both.
/// The Mac has no key bar, so its pill is the height of the pop-up beside
/// it, and its frame goes on the menu: a Mac menu's label is drawn at its
/// glyph's size whatever frame it is given. Untinted,
/// unlike the key bar's: that one sits over a dark pane, this one on a form.
private extension View {
    func attachBarIcon() -> some View {
        #if os(iOS)
        font(.system(size: 12.5)).frame(minWidth: 36, minHeight: 51).contentShape(Rectangle())
        #else
        font(.system(size: 13))
        #endif
    }

    func attachBarItem() -> some View {
        #if os(iOS)
        self
        #else
        frame(width: 32, height: 24).contentShape(Rectangle())
        #endif
    }

    @ViewBuilder func attachBarPill() -> some View {
        if #available(macOS 26, iOS 26, *) {
            #if os(iOS)
            glassEffect(.regular.interactive(), in: Capsule())
            #else
            // Interactive glass flexes under a press, which on a Mac shifted
            // the icons each time a menu opened and closed.
            glassEffect(.regular, in: Capsule())
            #endif
        } else {
            background(.quaternary, in: Capsule())
        }
    }
}
