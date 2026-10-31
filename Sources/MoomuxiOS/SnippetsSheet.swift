import SwiftUI

/// One entry in the key bar's Snippets menu. Pasted into the pane, then Return
/// unless `submit` is false — a command that takes an argument is left open,
/// with a trailing space, for the user to finish.
struct Snippet: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var submit: Bool

    static let key = "snippets"

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
    func text(for agent: String) -> String {
        let name = text.trimmingCharacters(in: .whitespaces).dropFirst()
        guard agent == "codex", text.hasPrefix("/"), Self.skills.contains(String(name)) else { return text }
        return "$\(name) "
    }

    /// The user's list, or the defaults until they first save one. An empty
    /// saved list stays empty: deleting every snippet is a choice. A list
    /// this build cannot read is copied aside before the defaults stand in,
    /// so the next save does not destroy the only copy.
    static var saved: [Snippet] {
        get {
            let store = UserDefaults.standard
            guard let data = store.data(forKey: key) else { return defaults }
            if let list = try? JSONDecoder().decode([Snippet].self, from: data) { return list }
            store.set(data, forKey: key + ".unreadable")
            return defaults
        }
        // Blank rows are dropped here, not filtered at every reader.
        set {
            let kept = newValue.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: key)
        }
    }
}

/// Add, remove, reorder and edit the key bar's snippets. Saved when the sheet
/// closes, by Done or a swipe alike, so there is no Save button to miss.
struct SnippetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snippets = Snippet.saved
    @State private var confirmingRestore = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($snippets) { $snippet in
                        HStack {
                            TextField("Text", text: $snippet.text)
                                .font(.body.monospaced())
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            // An icon rather than a switch: it says what it
                            // does, and it is what the menu row sends.
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
                    }
                    .onDelete { snippets.remove(atOffsets: $0) }
                    .onMove { snippets.move(fromOffsets: $0, toOffset: $1) }
                    Button {
                        snippets.append(Snippet(text: "", submit: true))
                    } label: {
                        Label("Add Snippet", systemImage: "plus")
                    }
                } footer: {
                    Text("\(Image(systemName: "return")) sends Return after pasting. Turn it off for a command you want to finish yourself; a trailing space is kept.")
                }
                Section {
                    Button("Restore Defaults", role: .destructive) { confirmingRestore = true }
                }
            }
            .confirmationDialog("Replace your snippets with the defaults?",
                                isPresented: $confirmingRestore, titleVisibility: .visible) {
                Button("Restore Defaults", role: .destructive) { snippets = Snippet.defaults }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onDisappear { Snippet.saved = snippets }
        }
    }
}
