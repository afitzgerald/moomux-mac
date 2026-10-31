import MoomuxKit
import SwiftUI

/// The saved computers. Tap one to switch to it; hold (or swipe) for Rename…
/// and Forget. One at a time: switching disconnects from the computer on
/// screen and connects to the other.
struct ComputersSheet: View {
    let computers: ComputerStore
    let select: (UUID) -> Void
    let add: () -> Void
    let forget: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The computer a Rename… or a Forget is open for.
    @State private var renaming: Computers.Computer?
    @State private var renameTo = ""
    @State private var forgetting: Computers.Computer?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(computers.saved.list) { computer in
                        row(computer)
                    }
                }
                Section {
                    Button {
                        dismiss()
                        add()
                    } label: {
                        Label("Add computer", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Computers")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { computer in
                // The placeholder is what an empty name falls back to.
                TextField(computer.codeName.isEmpty ? computer.host : computer.codeName, text: $renameTo)
                Button("Save") { computers.saved.rename(computer.id, to: renameTo) }
                Button("Cancel", role: .cancel) {}
            }
            .alert(forgetting.map { "Forget \($0.displayName)?" } ?? "",
                   isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                   presenting: forgetting) { computer in
                Button("Forget", role: .destructive) { forget(computer.id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Scan its code again to add it back.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ computer: Computers.Computer) -> some View {
        Button {
            dismiss()
            if computer.id != computers.saved.currentID { select(computer.id) }
        } label: {
            HStack {
                Text(computer.displayName).foregroundStyle(.primary)
                Spacer()
                if computer.id == computers.saved.currentID {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .contextMenu {
            Button("Rename…", systemImage: "pencil") { rename(computer) }
            Button("Forget", systemImage: "trash", role: .destructive) { forgetting = computer }
        }
        // Not `role: .destructive`: that animates the row away at once, and
        // Forget still has to be confirmed.
        .swipeActions {
            Button("Forget", systemImage: "trash") { forgetting = computer }.tint(.red)
            Button("Rename", systemImage: "pencil") { rename(computer) }
        }
    }

    private func rename(_ computer: Computers.Computer) {
        renameTo = computer.customName
        renaming = computer
    }
}
