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
            // "HEAD" is the core saying no base branch shares history with
            // this one — "vs HEAD" would read as a real comparison.
            let headOnly = diff.base == "HEAD" || diff.base.isEmpty
            List {
                // The viewed marks are kept against every file, so marking one
                // section's file does not forget the other's.
                let viewed = app.viewed(sessionID, in: diff.files)
                Section {
                    if diff.uncommitted.isEmpty {
                        Text("No uncommitted changes").foregroundStyle(.secondary)
                    }
                    rows(diff.uncommitted, viewed: viewed)
                } header: {
                    header(headOnly ? "Uncommitted changes only" : "Uncommitted", diff.uncommitted, viewed: viewed)
                } footer: {
                    if diff.committed.isEmpty { truncation(diff) }
                }
                if !diff.committed.isEmpty {
                    Section {
                        rows(diff.committed, viewed: viewed)
                    } header: {
                        header("Committed on this branch · against \(diff.base)", diff.committed, viewed: viewed)
                    } footer: {
                        truncation(diff)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func rows(_ files: [FileChange], viewed: Binding<Set<FileChange.ID>>) -> some View {
        ForEach(files) { file in
            let seen = viewed.wrappedValue.contains(file.id)
            NavigationLink(value: Route.fileDiff(sessionID, file.path)) { row(file, viewed: seen) }
                .swipeActions(edge: .leading) {
                    Button(seen ? "Unviewed" : "Viewed",
                           systemImage: seen ? "eye.slash" : "checkmark") {
                        if seen { viewed.wrappedValue.remove(file.id) }
                        else { viewed.wrappedValue.insert(file.id) }
                    }
                    .tint(.accentColor)
                }
        }
    }

    private func header(_ title: String, _ files: [FileChange], viewed: Binding<Set<FileChange.ID>>) -> some View {
        let seen = files.filter { viewed.wrappedValue.contains($0.id) }.count
        return Text(seen == 0 ? title : "\(title) · \(seen) of \(files.count) viewed")
    }

    @ViewBuilder
    private func truncation(_ diff: SessionDiff) -> some View {
        if diff.truncated {
            Text(diff.files.isEmpty
                 ? "Too large to send — the first file alone is over the limit."
                 : "Too large to send whole — the files after these were left out.")
        }
    }

    private func row(_ file: FileChange, viewed: Bool) -> some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if viewed {
                        Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Viewed")
                    }
                    Text(name).font(.body.monospaced()).lineLimit(1)
                        .foregroundStyle(viewed ? .secondary : .primary)
                }
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

/// Every file's diff on one page, opened at the file the route names. Scrolling
/// runs from one file straight into the next, each under its own header; the
/// file at the top is the current one, which the title, find, the stepper and
/// the menu act on. MergeRight's page, without its review threads.
///
/// Looked up in its own `body`, like every other route here, so a refresh on
/// the list underneath redraws this too.
struct FileDiffScreen: View {
    let app: AppState
    let sessionID: Session.ID
    /// The file at the top of the page. The route's path is only the seed.
    @State private var selection: FileChange.ID?
    /// Pressed on the last file: leaves the Changes list behind as well.
    let finished: () -> Void

    /// A re-indent is noise on a phone more often than on a desk: every
    /// whitespace-only line costs a full row of a narrow screen.
    @AppStorage("hidesWhitespaceChanges") private var hidesWhitespace = false
    /// Markdown files rendered before and after, instead of their patch.
    @State private var rendered: Set<String> = []
    /// The patch's code size, written by a pinch. DiffKit's own default is 12.
    @AppStorage("diffCodeSize") private var codeSize = 12.0

    /// The item at the top of the page. Not read in `body`: it is written for
    /// every row scrolled past, and a body that read it would redraw each time.
    @State private var position = PatchPagePosition()
    /// The file the reader's own scroll made current, so the change it causes
    /// is not mistaken for a jump.
    @State private var scrolledTo: String?
    @State private var pool = PatchFilePool()
    /// Which files the page lists and how tall the rest is. Not read in `body`.
    @State private var pageWindow = PatchPageWindow()
    @State private var scrollRequest: ScrollRequest?

    // Find, across the whole change. The query outlives a change of file —
    // that is what lets stepping past the last match carry on into the next.
    @State private var query = ""
    @State private var searching = false
    /// The current file's matches.
    @State private var matches: [DiffFind.Match] = []
    @State private var current = 0
    /// "12 of 40" across files; nil while counting.
    @State private var counts: (before: Int, total: Int)?
    /// Set by a step into another file: 1 lands on its first match, -1 on its last.
    @State private var landing: Int?
    /// The query `matches` were found for. A new query scrolls to its first
    /// match; a file merely scrolled into does not, or reading would fight find.
    @State private var searched = ""

    init(app: AppState, sessionID: Session.ID, path: String, finished: @escaping () -> Void) {
        self.app = app
        self.sessionID = sessionID
        self.finished = finished
        _selection = State(initialValue: path)
    }

    var body: some View {
        let path = selection ?? ""
        Group {
            switch app.diffs[sessionID] {
            case .none:
                // Pushed without the list having loaded — a deep link. Measured:
                // without this it read as "No longer changed" for a file that was.
                ProgressView().controlSize(.small)
                    .task { await app.loadDiff(sessionID) }
            case let .some(.some(diff)) where !diff.files.isEmpty:
                page(diff)
                    // A path the change no longer has — committed and merged, or
                    // reverted — opens the page at its first file.
                    .onChange(of: diff.files.map(\.id), initial: true) { _, ids in
                        if !ids.contains(path) { selection = ids.first }
                    }
                    .task(id: FindKey(path: path, patch: currentFile(in: diff)?.patch?.hashValue ?? 0,
                                      query: query, hidesWhitespace: hidesWhitespace)) {
                        await find(in: currentFile(in: diff), files: diff.files)
                    }
            default:
                ContentUnavailableView("No longer changed", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        // Not over the rendered preview: it finds in the patch, which is not on screen.
        .findField(!showsRendered(path), text: $query, isPresented: $searching)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if isMarkdown(path) {
                        Button { rendered.formSymmetricDifference([path]) } label: {
                            Label(showsRendered(path) ? "Show the Diff" : "Show Rendered, Before and After",
                                  systemImage: showsRendered(path) ? "doc.plaintext" : "doc.richtext")
                        }
                    }
                    // Both act on the patch, which the rendered view does not show.
                    Group {
                        Button { searching = true } label: {
                            Label("Find", systemImage: "magnifyingglass")
                        }
                        Toggle(isOn: $hidesWhitespace) {
                            Label("Hide Whitespace Changes", systemImage: "text.alignleft")
                        }
                    }
                    .disabled(showsRendered(path))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
    }

    private func currentFile(in diff: SessionDiff) -> FileChange? {
        diff.files.first { $0.id == selection }
    }

    private func isMarkdown(_ path: String) -> Bool { CodeLanguage.detect(path: path) == .markdown }

    private func showsRendered(_ path: String) -> Bool { rendered.contains(path) && isMarkdown(path) }

    private func patch(_ file: FileChange) -> PatchFile { pool.file(for: file, hidesWhitespace: hidesWhitespace) }

    // MARK: Page

    private func page(_ diff: SessionDiff) -> some View {
        let files = diff.files
        return GeometryReader { area in
            ScrollViewReader { proxy in
                // Both axes: long lines scroll the whole page sideways, as one.
                ScrollView([.vertical, .horizontal]) {
                    let plan = plan(files, viewport: area.size)
                    // One lazy stack of rows, not of files, so only the rows on
                    // screen are built. The files outside the window are a spacer
                    // each, in a plain stack: a lazy one would size a spacer as one row.
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: plan.above)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(plan.items) { item in
                                pageItem(item, files: files, base: diff.base, width: area.size.width)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                        pageWindow.record(item.file.path, item.part, height: height)
                                    }
                                    .id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                        Color.clear.frame(height: plan.below)
                        // Room below the last file, so a short one can still reach
                        // the top and become the current file.
                        Color.clear.frame(width: 1, height: area.size.height)
                    }
                    .frame(width: pool.pageWidth(files, codeSize: codeSize, atLeast: area.size.width),
                           alignment: .leading)
                }
                // Dragged or flung over files that are only a spacer: the file
                // there becomes current, which moves the window to it.
                .patchFollowsScrollbar { offset, height in
                    guard let index = pageWindow.fileToFollow(offset: offset, contentHeight: height,
                                                              endRoom: area.size.height),
                          files.indices.contains(index), files[index].id != selection else { return }
                    selection = files[index].id
                }
                .overlay(alignment: .top) {
                    if let file = currentFile(in: diff) {
                        header(file, files: files).frame(width: area.size.width)
                    }
                }
                .patchPinchZoom($codeSize)
                .patchPagePosition(position) { path in
                    guard path != selection else { return }
                    scrolledTo = path
                    selection = path
                }
                .onChange(of: selection) { _, path in
                    guard let path, path != scrolledTo else { return }
                    scrolledTo = nil
                    jump(to: path, in: files)
                }
                // A find match asked for.
                .onChange(of: scrollRequest) { _, request in
                    guard let request else { return }
                    // Let go of a file jump's hold first, or the page snaps back to that header.
                    position.top = nil
                    withAnimation { proxy.scrollTo(request.id, anchor: UnitPoint(x: 0, y: 0.5)) }
                }
                // Opened at a file other than the first: jump once the files above
                // it are built, then a beat for the page to take them.
                .task {
                    pageWindow.pauseFollowing(for: 30)
                    defer { pageWindow.pauseFollowing() }
                    guard let index = files.firstIndex(where: { $0.id == selection }), index > 0 else { return }
                    for file in files[..<index] { await patch(file).built() }
                    try? await Task.sleep(for: .milliseconds(150))
                    position.top = PatchRows.itemID(files[index].path, "header")
                }
            }
            .patchViewportWidth(area.size.width)
        }
        .overlay(alignment: .bottomLeading) {
            // "Next" marks the current file viewed and goes to the next one
            // that is not — the list shows the same marks.
            PatchFileStepper(files: files, selection: $selection, viewed: app.viewed(sessionID, in: files))
                .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            if !query.isEmpty { findBar(files: files).padding(12) }
        }
        .onPatchFilesEnd(perform: finished)
        // Out without stepping to the end: back past the list to where it was opened from.
        .onPatchFilesDone(perform: finished)
        // The unchanged lines between hunks, revealed on demand. DiffKit checks
        // the text against the patch and offers nothing if the agent has edited
        // the file since.
        .patchFileText { file in
            // Not for a file only flicked past: its rows leaving the screen cancel the wait.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return nil }
            return try? await app.worktreeFile(file.path, in: sessionID)
        }
    }

    /// One item of the page: a file's header, what stands in for its rows
    /// (nothing, or the rendered markdown), or one of its rows.
    private struct PageItem: Identifiable {
        let file: FileChange
        /// "header", "chrome", or the row's own id — what its height is recorded under.
        let part: String
        var row: PatchRows.Item?
        var id: String { PatchRows.itemID(file.path, part) }
    }

    private struct PagePlan {
        var items: [PageItem] = []
        var above: CGFloat = 0
        var below: CGFloat = 0
    }

    /// The items of the files near the current one, as one flat list, and the
    /// measured height of the files left out either side. A lazy stack's cost is
    /// per item, not per item on screen, so listing every row of a big change
    /// drops most frames.
    private func plan(_ files: [FileChange], viewport: CGSize) -> PagePlan {
        pageWindow.measuring(under: "\(codeSize)|\(hidesWhitespace)")
        let heights = files.map { file in
            pageWindow.parkedHeight(of: file.path, rows: showsRendered(file.path) ? nil : rows(of: file).count,
                                    collapsed: false, note: false)
        }
        let top = files.firstIndex { $0.id == selection } ?? 0
        guard let window = pageWindow.plan(heights: heights, top: top, budget: max(3_000, viewport.height * 3))
        else { return PagePlan() }
        var plan = PagePlan(above: window.above, below: window.below)
        for file in files[window.files] {
            plan.items.append(PageItem(file: file, part: "header"))
            // Always one: `parkedHeight` counts a chrome whether or not the file has any.
            plan.items.append(PageItem(file: file, part: "chrome"))
            guard !showsRendered(file.path) else { continue }
            for row in rows(of: file) { plan.items.append(PageItem(file: file, part: row.id, row: row)) }
        }
        return plan
    }

    private func rows(of file: FileChange) -> [PatchRows.Item] {
        patch(file).items(layout: .unified, reservesGaps: true)
    }

    @ViewBuilder
    private func pageItem(_ item: PageItem, files: [FileChange], base: String, width: CGFloat) -> some View {
        if let row = item.row {
            PatchRow(row, of: patch(item.file), codeSize: codeSize)
                // Line ids repeat from file to file, so the current match is the current file's only.
                .patchFind(query, current: item.file.id == selection && matches.indices.contains(current)
                           ? matches[current] : nil)
        } else if item.part == "header" {
            header(item.file, files: files).frame(width: width)
        } else if showsRendered(item.file.path) {
            // A fixed height: the preview fills what it is offered, and a page offers no limit.
            RenderedMarkdown(app: app, sessionID: sessionID, file: item.file, base: base)
                .frame(width: width, height: 480)
        } else {
            Color.clear.frame(width: width, height: 0)
        }
    }

    /// Path, counts and the viewed tick. Pinned over the page for the current file.
    private func header(_ file: FileChange, files: [FileChange]) -> some View {
        let viewed = app.viewed(sessionID, in: files)
        let seen = viewed.wrappedValue.contains(file.id)
        return HStack(spacing: 8) {
            // Truncated from the head: the end of a path tells two files apart.
            Text(file.path).font(.footnote.monospaced()).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if !file.isBinary {
                Text("+\(file.additions)").foregroundStyle(DiffTheme.added)
                Text("−\(file.deletions)").foregroundStyle(DiffTheme.removed)
            }
            Button {
                if seen { viewed.wrappedValue.remove(file.id) } else { viewed.wrappedValue.insert(file.id) }
            } label: {
                Image(systemName: seen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(seen ? Color.accentColor : .secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(seen ? "Viewed" : "Mark Viewed")
        }
        .font(.caption.monospacedDigit())
        .buttonStyle(.plain)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Takes the page to a file's header. A header outside the window is not on
    /// the page until the window has moved, and an id the page lacks is dropped.
    private func jump(to path: String, in files: [FileChange]) {
        pageWindow.pauseFollowing()
        let header = PatchRows.itemID(path, "header")
        guard let index = files.firstIndex(where: { $0.id == path }), !pageWindow.lists(index) else {
            position.top = header
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            // Another jump came meanwhile: its header is the one to hold.
            guard selection == path else { return }
            position.top = header
        }
    }

    /// Scrolls to a line once its file is built: a step into a file not on
    /// screen yet asks for a row the page does not have.
    private func requestScroll(toLine lineID: Int, in file: FileChange) {
        let patch = patch(file)
        Task { @MainActor in
            await patch.built()
            guard let id = patch.itemID(forLine: lineID, layout: .unified) else { return }
            scrollRequest = ScrollRequest(id: id)
        }
    }

    // MARK: Find

    private struct FindKey: Hashable {
        let path: String
        let patch: Int
        let query: String
        let hidesWhitespace: Bool
    }

    /// Re-run on every keystroke, change of file, refresh and whitespace toggle;
    /// `.task(id:)` cancels the one it replaces, which is the debounce.
    private func find(in file: FileChange?, files: [FileChange]) async {
        let query = query, hides = hidesWhitespace
        guard !query.isEmpty, let file else {
            (matches, current, counts, searched) = ([], 0, nil, "")
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        // Parsing a large patch is not main-actor work.
        let found = await Task.detached {
            DiffFind.matches(in: file, query: query, hidesWhitespaceChanges: hides)
        }.value
        guard !Task.isCancelled else { return }
        let typed = query != searched
        matches = found
        searched = query
        current = landing.map { $0 < 0 ? max(found.count - 1, 0) : 0 } ?? 0
        if typed || landing != nil, found.indices.contains(current) {
            requestScroll(toLine: found[current].lineID, in: file)
        }
        landing = nil
        counts = nil
        counts = await DiffFind.totals(in: files, query: query, current: file.path, localCount: found.count)
    }

    /// Past either end of this file's matches, on to the nearest file that has
    /// some, wrapping; with no other file to go to, round this one.
    private func step(_ delta: Int, files: [FileChange]) {
        guard let file = files.first(where: { $0.id == selection }) else { return }
        let next = current + delta
        if matches.indices.contains(next) {
            current = next
            requestScroll(toLine: matches[next].lineID, in: file)
        } else if let other = DiffFind.nextFile(in: files, from: file.path, delta: delta, query: query) {
            landing = delta
            selection = other.id
        } else if !matches.isEmpty {
            current = delta > 0 ? 0 : matches.count - 1
            requestScroll(toLine: matches[current].lineID, in: file)
        }
    }

    private func findBar(files: [FileChange]) -> some View {
        let label: String = switch counts {
        case .none: "…"
        case let .some(c) where c.total == 0: "No matches"
        // The other files' counts are raw patch text, so a file with matches
        // only in hidden whitespace can push this past the total; clamp it.
        case let .some(c): "\(min(c.before + current + 1, c.total)) of \(c.total)"
        }
        return HStack(spacing: 14) {
            Text(label).font(.caption.monospacedDigit())
            Group {
                Button { step(-1, files: files) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Previous Match")
                Button { step(1, files: files) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Next Match")
            }
            .disabled(counts.map { $0.total == 0 } ?? true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
    }
}

/// A row the page is asked to bring into view. Each one new, so the same row
/// asked for twice scrolls twice.
private struct ScrollRequest: Equatable {
    let id: String
    let token = UUID()
}

/// The page's `PatchFile`s, made on first use and kept while the page shows the
/// file: its rows come and go with the lazy stack, what was built and revealed
/// does not. A class, so making one inside a body is not a state change.
private final class PatchFilePool {
    private var files: [String: PatchFile] = [:]
    private var width: (key: [String], width: CGFloat)?

    /// The file's `PatchFile`, made afresh when its patch or the whitespace setting changed.
    func file(for file: FileChange, hidesWhitespace: Bool) -> PatchFile {
        if let made = files[file.path], made.file == file, made.hidesWhitespaceChanges == hidesWhitespace {
            return made
        }
        let made = PatchFile(file: file, hidesWhitespaceChanges: hidesWhitespace)
        files[file.path] = made
        return made
    }

    /// As wide as the widest file needs unwrapped, so every long line can be
    /// scrolled to. It scans every patch, so it is kept per paths, patch lengths
    /// and size: a refresh that edits a patch to the same length keeps a stale
    /// width, until the code size or a length changes.
    func pageWidth(_ files: [FileChange], codeSize: Double, atLeast visible: CGFloat) -> CGFloat {
        let key = ["\(codeSize)"] + files.map { "\($0.path)#\($0.patch?.utf8.count ?? -1)" }
        if width?.key != key {
            let widest = files.map { PatchRows.width(of: $0, codeSize: codeSize, lineNumbers: .one, layout: .unified) }
                .max() ?? 0
            width = (key, widest)
        }
        return max(visible, width?.width ?? 0)
    }
}

/// Both sides of a markdown file read whole and drawn by DiffKit's
/// `MarkdownView`, Mermaid included. The phone only: the Mac reviews in tmux.
private struct RenderedMarkdown: View {
    let app: AppState
    let sessionID: Session.ID
    let file: FileChange
    let base: String
    @State private var revisions: Result<(before: String?, after: String?), Error>?

    var body: some View {
        Group {
            switch revisions {
            case .none:
                ProgressView().controlSize(.small)
            case let .failure(error):
                ContentUnavailableView("Couldn't load the file", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            case let .success(revisions):
                // "working tree": the after side is the file on disk,
                // uncommitted edits included, not the branch's last commit.
                PatchMarkdownPreview(file: file, before: revisions.before, after: revisions.after,
                                     baseRef: base.isEmpty ? "HEAD" : base, headRef: "working tree")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Re-read when a refresh brings a different patch for the same path.
        .task(id: file) {
            revisions = nil
            do { revisions = .success(try await app.revisions(of: file, in: sessionID)) }
            catch { revisions = .failure(error) }
        }
    }
}

private extension View {
    @ViewBuilder
    func findField(_ shown: Bool, text: Binding<String>, isPresented: Binding<Bool>) -> some View {
        if shown { searchable(text: text, isPresented: isPresented, prompt: "Find in changes") } else { self }
    }
}

private extension AppState {
    /// A session's viewed files as the ids DiffKit's stepper takes, read and
    /// written against the patches on screen now.
    func viewed(_ id: Session.ID, in files: [FileChange]) -> Binding<Set<FileChange.ID>> {
        Binding(get: { self.viewedFiles[id, default: ViewedFiles()].ids(in: files) },
                set: { self.viewedFiles[id, default: ViewedFiles()].set($0, in: files) })
    }
}
