import DiffKit
import MoomuxKit
import SwiftUI

/// A session's changes against its merge base — what Review shows in tmux,
/// drawn natively. The phone gets this and the Mac does not: on a desk the
/// tmux window and the GUI diff tool (⌘D) are better than any viewer here,
/// while on a 6-inch screen a pager at 50 columns is the worse half.
///
/// Flat, not a tree, for MergeRight's reason: indentation costs width the
/// names want.
struct ChangesScreen: View {
    let app: AppState
    let sessionID: Session.ID

    var body: some View {
        content
            .navigationTitle(app.session(id: sessionID)?.name ?? "Changes")
            .navigationBarTitleDisplayMode(.inline)
            .task { await app.loadDiff(sessionID) }
            .refreshable { await app.loadDiff(sessionID) }
    }

    @ViewBuilder
    private var content: some View {
        switch app.diffs[sessionID] {
        case .none:
            ProgressView().controlSize(.small)
        case .some(.none):
            ContentUnavailableView("Not a git repository", systemImage: "folder.badge.questionmark")
        // Not when truncated: a first file over the cap alone sends no patch.
        case let .some(.some(diff)) where diff.files.isEmpty && !diff.truncated:
            ContentUnavailableView("No changes", systemImage: "checkmark.circle",
                                   description: Text("Nothing differs from the base branch."))
        case let .some(.some(diff)):
            List {
                Section {
                    ForEach(diff.files) { file in
                        NavigationLink(value: Route.fileDiff(sessionID, file.path)) { row(file) }
                    }
                } header: {
                    // "HEAD" is the core saying no base branch shares history
                    // with this one — "vs HEAD" would read as a real comparison.
                    Text(diff.base == "HEAD" || diff.base.isEmpty
                         ? "Uncommitted changes only" : "Against \(diff.base)")
                } footer: {
                    if diff.truncated {
                        Text(diff.files.isEmpty
                             ? "Too large to send — the first file alone is over the limit."
                             : "Too large to send whole — the files after these were left out.")
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ file: FileChange) -> some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.monospaced()).lineLimit(1)
                if let old = file.previousPath {
                    // A plain `mv` is +0 −0 — without this the row says nothing happened.
                    Text("renamed from \(old)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                } else if !dir.isEmpty {
                    // Truncated from the head: the end of a path is the part
                    // that tells two files apart.
                    Text(dir).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            if file.isBinary {
                Text("binary").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("+\(file.additions)").foregroundStyle(DiffTheme.added)
                Text("−\(file.deletions)").foregroundStyle(DiffTheme.removed)
            }
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .combine)
    }
}

/// One file. Looked up by path in its own `body`, like every other route here,
/// so a refresh on the list underneath redraws this too. The route's path is only
/// the seed: the stepper swaps the file in place rather than pushing another screen.
struct FileDiffScreen: View {
    let app: AppState
    let sessionID: Session.ID
    @State private var selection: FileChange.ID?
    /// Pressed on the last file: leaves the Changes list behind as well.
    let finished: () -> Void

    init(app: AppState, sessionID: Session.ID, path: String, finished: @escaping () -> Void) {
        self.app = app
        self.sessionID = sessionID
        self.finished = finished
        _selection = State(initialValue: path)
    }

    var body: some View {
        let path = selection ?? ""
        Group {
            if app.diffs[sessionID] == nil {
                // Pushed without the list having loaded — a deep link. Measured:
                // without this it read as "No longer changed" for a file that was.
                ProgressView().controlSize(.small)
                    .task { await app.loadDiff(sessionID) }
            } else if let diff = app.diffs[sessionID] ?? nil,
                      let file = diff.files.first(where: { $0.id == path }) {
                PatchView(file: file)
                    .overlay(alignment: .bottomLeading) {
                        PatchFileStepper(files: diff.files, selection: $selection).padding(12)
                    }
                    .onPatchFilesEnd(perform: finished)
            } else {
                // The file went away on a refresh: committed and merged, or reverted.
                ContentUnavailableView("No longer changed", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}
