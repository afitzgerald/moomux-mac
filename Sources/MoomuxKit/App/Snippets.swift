import SwiftUI

/// An entry in a Snippets menu. The key bar pastes it into the pane, then
/// sends Return if `submit` is true.
public struct Snippet: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var text: String
    public var submit: Bool
    // Older saved lists have no flag; keep treating moomux's own skills as skills.
    private var skill: Bool?

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

    public init(text: String, submit: Bool) {
        self.text = text
        self.submit = submit
    }

    private static let moomuxSkills: Set = ["/kill", "/tag", "/reseed", "/spawn"]

    var usesAgentPrefix: Bool {
        get { skill ?? Self.moomuxSkills.contains(String(text.prefix { !$0.isWhitespace })) }
        set { skill = newValue }
    }

    public func text(for agent: String, inTerminal: Bool = false) -> String {
        guard usesAgentPrefix, let first = text.first, "/$@".contains(first),
              let next = text.dropFirst().first, !next.isWhitespace else { return text }
        let prefix: Character
        switch agent {
        case "claude", "antigravity": prefix = "/"
        case "codex": prefix = "$"
        case "opencode": prefix = "@"
        default: return text
        }
        let invocation = String(prefix) + text.dropFirst()
        // On Codex, a space closes the skill completion popup so one Return
        // submits. The prompt editor already adds its own separating space.
        if inTerminal, agent == "codex", !invocation.contains(where: \.isWhitespace) {
            return invocation + " "
        }
        return invocation
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

    public static func demo() {
        let tag = try! JSONDecoder().decode(Snippet.self, from: Data(
            #"{"id":"38E776CB-0C6A-408B-968D-958401D5A904","text":"/tag","submit":true}"#.utf8))
        assert(tag.text(for: "claude") == "/tag")
        assert(tag.text(for: "codex") == "$tag")
        assert(tag.text(for: "codex", inTerminal: true) == "$tag ", "close Codex's completion popup")
        assert(tag.text(for: "opencode") == "@tag")
        assert(Snippet(text: "/clear", submit: true).text(for: "opencode") == "/clear")
        assert(Snippet(text: "/tmp/file", submit: true).text(for: "codex") == "/tmp/file")
        assert(Snippet(text: "y", submit: true).text(for: "codex") == "y")
        var custom = Snippet(text: "$review  this ", submit: false)
        custom.usesAgentPrefix = true
        assert(custom.text(for: "antigravity") == "/review  this ")
        assert(custom.text(for: "opencode") == "@review  this ")
        assert(custom.text(for: "codex", inTerminal: true) == "$review  this ")
        assert(custom.text(for: "unknown") == custom.text)
        var literal = tag
        literal.usesAgentPrefix = false
        assert(literal.text(for: "opencode") == "/tag")
        // A scratch key, so the user's own list is untouched.
        let key = "snippets.selftest"
        let store = UserDefaults.standard
        defer { store.removeObject(forKey: key); store.removeObject(forKey: key + ".unreadable") }
        store.removeObject(forKey: key)
        assert(saved(key).isEmpty, "a prompt-style key starts empty")
        save([Snippet(text: "a", submit: true), Snippet(text: "  ", submit: true)], key)
        assert(saved(key).map(\.text) == ["a"], "blank rows are dropped on save")
        save([custom, literal], key)
        assert(saved(key).map { $0.text(for: "opencode") } == ["@review  this ", "/tag"])
        save([], key)
        assert(saved(key).isEmpty, "an emptied list stays empty")
        store.set(Data("nope".utf8), forKey: key)
        assert(saved(key).isEmpty && store.data(forKey: key + ".unreadable") != nil,
               "an unreadable list is kept aside")
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
                Button { snippet.usesAgentPrefix.toggle() } label: {
                    Image(systemName: "at")
                        .foregroundStyle(snippet.usesAgentPrefix ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.borderless)
                .help("Use the agent’s skill prefix")
                .accessibilityLabel("Use agent’s skill prefix")
                .accessibilityValue(snippet.usesAgentPrefix ? "On" : "Off")
                .accessibilityAddTraits(snippet.usesAgentPrefix ? .isSelected : [])
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Image(systemName: "at")) adjusts a skill’s leading /, $ or @ to match the agent.")
            if sendsReturn {
                Text("\(Image(systemName: "return")) sends Return after pasting. Turn it off for a command you want to finish yourself; a trailing space is kept.")
            } else {
                Text("Added to the end of the prompt.")
            }
        }
    }
}
