import SwiftUI

/// One entry in the key bar's Snippets menu. Pasted into the pane, then Return
/// unless `submit` is false — a command that takes an argument is left open,
/// with a trailing space, for the user to finish.
public struct Snippet: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var text: String
    public var submit: Bool

    public static let key = "snippets"

    static let defaults: [Snippet] = [
        .init(text: "/clear", submit: true), .init(text: "/compact", submit: true),
        .init(text: "/model", submit: true),
        // Parks the session, so a menu tap alone must not do it.
        .init(text: "/kill", submit: false),
        .init(text: "/tag", submit: true), .init(text: "/reseed", submit: true),
        .init(text: "/spawn ", submit: false),
        .init(text: "y", submit: true), .init(text: "continue", submit: true),
    ]

    /// moomux's own skills, which every agent but codex spells `/tag`.
    static let skills: Set = ["kill", "tag", "reseed", "spawn"]

    /// What is pasted. Codex names a skill `$tag`, not `/tag`, and Return on a
    /// pasted `$tag` only accepts its completion popup; the trailing space
    /// closes the popup so the one Return submits. Measured on codex-cli
    /// 0.166. Applied here rather than stored, so one list serves both agents.
    public func text(for agent: String) -> String {
        let name = text.trimmingCharacters(in: .whitespaces).dropFirst()
        guard agent == "codex", text.hasPrefix("/"), Self.skills.contains(String(name)) else { return text }
        return "$\(name) "
    }

    /// The New Session sheet's list, inserted into the first prompt. Its own
    /// list, starting empty: a key-bar command is not a prompt.
    public static let promptKey = "promptSnippets"

    /// The defaults a list starts with and Restore Defaults puts back.
    public static func defaults(_ key: String) -> [Snippet] { key == Self.key ? defaults : [] }

    /// The user's list, or the defaults until they first save one. An empty
    /// saved list stays empty: deleting every snippet is a choice. A list
    /// this build cannot read is copied aside before the defaults stand in,
    /// so the next save does not destroy the only copy.
    public static func saved(_ key: String = key) -> [Snippet] {
        let store = UserDefaults.standard
        guard let data = store.data(forKey: key) else { return defaults(key) }
        if let list = try? JSONDecoder().decode([Snippet].self, from: data) { return list }
        store.set(data, forKey: key + ".unreadable")
        return defaults(key)
    }

    /// Blank rows are dropped here, not filtered at every reader.
    public static func save(_ list: [Snippet], _ key: String = key) {
        let kept = list.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: key)
    }
}

/// Add, remove, reorder and edit the key bar's snippets, or the first
/// prompt's (`Snippet.promptKey`). Saved as they are edited, so there is no
/// Save button to miss.
public struct SnippetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let key: String
    @State private var snippets: [Snippet]
    @State private var confirmingRestore = false

    public init(key: String = Snippet.key) {
        self.key = key
        _snippets = State(initialValue: Snippet.saved(key))
    }

    /// Only the key bar sends Return; a prompt snippet is just text.
    private var sendsReturn: Bool { key == Snippet.key }

    public var body: some View {
        content
            .confirmationDialog("Replace your snippets with the defaults?",
                                isPresented: $confirmingRestore, titleVisibility: .visible) {
                Button("Restore Defaults", role: .destructive) { snippets = Snippet.defaults(key) }
            }
            // Every edit, not on the way out: a closing sheet disappears
            // only after its animation, which the menus were reading first.
            .onChange(of: snippets) { _, list in Snippet.save(list, key) }
    }

    #if os(iOS)
    private var content: some View {
        NavigationStack {
            List {
                Section {
                    rows
                    addButton
                } footer: {
                    footer
                }
                if sendsReturn {
                    Section {
                        Button("Restore Defaults", role: .destructive) { confirmingRestore = true }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
    #else
    /// New Session's own shape: a grouped form, the buttons under it.
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section {
                    if snippets.isEmpty {
                        Text("No snippets yet.").foregroundStyle(.secondary)
                    }
                    rows
                    addButton.buttonStyle(.borderless)
                } header: {
                    Text("Snippets")
                } footer: {
                    footer.font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            // Grows with the list, and scrolls past that.
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if sendsReturn {
                    Button("Restore Defaults…") { confirmingRestore = true }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
    #endif

    private var rows: some View {
        ForEach($snippets) { $snippet in
            HStack {
                TextField("Snippet", text: $snippet.text, prompt: Text("Text"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                // An icon rather than a switch: it says what it does, and it
                // is what the menu row sends.
                if sendsReturn {
                    Button { snippet.submit.toggle() } label: {
                        Image(systemName: "return")
                            .foregroundStyle(snippet.submit ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }
                    // Borderless, or the whole row becomes the button.
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Send Return")
                    .accessibilityValue(snippet.submit ? "On" : "Off")
                    .accessibilityAddTraits(snippet.submit ? .isSelected : [])
                }
                #if os(macOS)
                // A Mac list has no swipe or edit mode to delete with.
                Button("Remove", systemImage: "minus.circle.fill") {
                    snippets.removeAll { $0.id == snippet.id }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                #endif
            }
        }
        .onDelete { snippets.remove(atOffsets: $0) }
        .onMove { snippets.move(fromOffsets: $0, toOffset: $1) }
    }

    private var addButton: some View {
        Button {
            snippets.append(Snippet(text: "", submit: true))
        } label: {
            Label("Add Snippet", systemImage: "plus")
        }
    }

    @ViewBuilder private var footer: some View {
        if sendsReturn {
            Text("\(Image(systemName: "return")) sends Return after pasting. Turn it off for a command you want to finish yourself; a trailing space is kept.")
        } else {
            Text("Added to the end of the prompt.")
        }
    }
}
