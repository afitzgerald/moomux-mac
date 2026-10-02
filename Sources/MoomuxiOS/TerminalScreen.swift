import GhosttyTerminal
import MoomuxKit
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

/// A live `tmux attach`, over the socket.
///
/// The phone has no `.exec` backend — iOS forbids spawning the `login`/`tmux`
/// the Mac pane runs — so the pty lives on the core's machine and this is the
/// host-managed `.inMemory` backend with a socket where its process would be:
/// `AttachChannel.read()` into `session.receive`, and the session's `write`
/// closure back out as keystrokes. Same VT engine as the Mac's attached pane.
///
/// Two consequences of the pty being remote, both good: there is no `TERM` to
/// get wrong here (the core fixes it at `xterm-256color`, because the terminfo
/// has to exist on *its* machine) and nothing is shell-quoted into a command
/// line, because this end spawns nothing at all.
struct TerminalScreen: View {
    let app: AppState
    let sessionID: Session.ID
    /// Pushes onto the list's stack. The ⋯ menu's Details needs it: a
    /// `NavigationLink` inside a `Menu` is not reliably a link.
    let push: (Route) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The pane's text size, and therefore the attached session's width — see
    /// the note on `fontSize` below. Set from the ⋯ menu's Text Size or by a
    /// pinch, and kept across sessions and launches either way: the size you
    /// last read at is the one the next pane opens at.
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.default
    @State private var pane = PaneHandle()
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var importingFiles = false
    @State private var attachments = AttachQueue()

    /// A tapped file, fetched from the core and shown in Quick Look — which
    /// already does images, PDFs, text and code, with zoom and a share sheet.
    @State private var preview: URL?
    /// The fetch in flight, so a second tap supersedes the first for what is
    /// shown. Only for what is shown: the detached read cannot be interrupted
    /// and runs to the end, and the next fetch clears what it wrote.
    @State private var fetch: Task<Void, Never>?
    /// A long-press's snapshot of the screen, open for selecting and copying.
    @State private var selecting: SelectableText?

    var body: some View {
        AttachedTerminal(controller: app.terminalController,
                         client: app.client,
                         sessionID: sessionID,
                         fontSize: fontSize,
                         pane: pane,
                         // The far end going away is the end of the screen's
                         // reason to exist: tmux exited, the session was
                         // killed, the core went down. Leaving a dead pane up
                         // makes the user dismiss a window to learn nothing.
                         onEnded: { dismiss() },
                         onURL: open(url:),
                         onFile: open(file:),
                         onPinch: { fontSize = $0 },
                         onSelect: { selecting = SelectableText(request: $0) })
            // The core's Ghostty config arriving after this pane was built:
            // a new surface is the only way to apply it (`paneConfigGeneration`).
            .id(app.paneConfigGeneration)
            // Applied to the live surface, not by rebuilding it: a pinch
            // lands here too (saved through `onPinch`), and a rebuild per
            // pinch would redraw the pane from nothing. The new width reaches
            // the pty through the ordinary resize path.
            .onChange(of: fontSize) { _, size in pane.view?.setFontSize(size) }
            .onAppear { app.paneOnScreen = sessionID }
            // **Not** `.ignoresSafeArea(.bottom)`. The surface sizes its grid
            // to the view, so extending under the home indicator buys two more
            // rows that are drawn behind it — and tmux puts the status line
            // and the cursor at the bottom, which is exactly what goes
            // missing. Reported as "the cursor is two lines below where it
            // should be", which is precisely the inset in rows.
            .quickLookPreview($preview)
            .sheet(item: $selecting) { SelectionSheet(selection: $0, fontSize: fontSize) }
            // Leaving the pane abandons its fetch, or a late refusal raises
            // "Couldn't do that" over whatever screen is next.
            .onDisappear {
                fetch?.cancel()
                if app.paneOnScreen == sessionID { app.paneOnScreen = nil }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The cow, saying the session's quip — the Mac's `CowQuip`,
                // and its reasoning: the name and state are what you picked
                // the session by and already know, while the quip is the
                // core's live answer to "what is it doing". It re-renders on
                // every snapshot.
                ToolbarItem(placement: .principal) {
                    if let session = app.session(id: sessionID) {
                        CowQuip(saying: app.quip(for: session) ?? app.label(for: session))
                    }
                }
                // The diff is one tap because "what has it changed?" is the
                // question you attach to ask. Details and Attach share a menu:
                // three icons beside the quip squeezed it to a word or two.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.changes(sessionID)) {
                        Image(systemName: "plus.forwardslash.minus")
                    }
                    .accessibilityLabel("View Changes")
                    .disabled(app.session(id: sessionID).map { !app.canDiff($0) } ?? true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // Attached is exactly when you want the branch, the PR
                        // state and the worktree — the row's swipe reaches
                        // detail too, but not once you are already in here.
                        Button { push(.detail(sessionID)) } label: {
                            Label("Details", systemImage: "info.circle")
                        }
                        // Here and not in the list's menu: it is this pane's
                        // size, and the one place to judge it is looking at it.
                        Picker(selection: $fontSize) {
                            ForEach(TerminalFontSize.choices(including: fontSize), id: \.self) { size in
                                Text("\(Int(size)) pt").tag(size)
                            }
                        } label: {
                            Label("Text Size", systemImage: "textformat.size")
                        }
                        .pickerStyle(.menu)
                        Section {
                            // A `Button` and not a `PhotosPicker`: inside a
                            // `Menu` the picker lays its label out itself, so
                            // its icon sat at a different gap from Files'.
                            Button { pickingPhotos = true } label: {
                                Label("Attach Photos", systemImage: "photo.on.rectangle")
                            }
                            Button { importingFiles = true } label: {
                                Label("Attach Files", systemImage: "folder")
                            }
                        }
                        .disabled(attachments.pending > 0)
                    } label: {
                        // A spinner while a batch uploads, but still a menu:
                        // Details must not wait on a photo.
                        if attachments.pending > 0 {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    .accessibilityLabel("More")
                }
            }
            // The New Session sheet's pickers, with the path pasted into the
            // pane rather than appended to a form: the agent is already
            // running, so this is a file dropped on its terminal.
            .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .images)
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photos = []
                attach(app.attachJobs(items))
            }
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { attach(app.attachJobs($0)) }
            // No form to put it under, and the pane is the program's screen.
            .alert("Couldn't attach",
                   isPresented: Binding(get: { attachments.error != nil },
                                        set: { if !$0 { attachments.clearError() } })) {
                Button("OK") {}
            } message: {
                Text(attachments.error ?? "")
            }
            // No `onDisappear` cancel, unlike the sheet: pushing the info
            // screen disappears this one too, and would drop a batch mid-way.
            // A batch outliving the pane pastes into a nil view — the files
            // still land on the core, and its temp sweep takes them.
    }

    /// A PR or Asana task link goes to MergeRight while that setting is on and
    /// the app is installed, the same rule as the Mac pane. Anything else goes
    /// to `UIApplication.open`, which hands an https link to the app that
    /// claims it (GitHub, Asana) before Safari.
    private func open(url: URL) {
        if let mr = app.mergeRightLink(url.absoluteString), UIApplication.shared.canOpenURL(mr) {
            UIApplication.shared.open(mr)
        } else {
            UIApplication.shared.open(url)
        }
    }

    /// Quick Look needs a local file, named so it knows what it is showing
    /// (`PreviewFile.name`). Each fetch writes its own directory off the main
    /// actor; only the one that is still current is shown, and it clears the
    /// rest — a preview is looked at and dismissed, never kept. A refusal
    /// goes to `actionError`, whose alert is on the stack above this screen.
    private func open(file path: String) {
        let client = app.client
        let id = sessionID
        fetch?.cancel()
        fetch = Task {
            do {
                let url = try await Task.detached {
                    let (resolved, data) = try client.readFile(id: id, path: path)
                    let dir = PreviewFile.root.appending(path: UUID().uuidString)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let url = dir.appending(path: PreviewFile.name(for: resolved, data: data))
                    try data.write(to: url)
                    return url
                }.value
                guard !Task.isCancelled else { return }
                PreviewFile.clear(keeping: url.deletingLastPathComponent())
                preview = url
            } catch {
                guard !Task.isCancelled else { return }
                app.actionError = error.localizedDescription
            }
        }
    }

    /// A paste, not keystrokes: `paste(text:)` frames it as bracketed paste
    /// when the program asked for that, which is how claude tells a dropped
    /// file from typing — an image path pasted becomes `[Image #1]`. It goes
    /// out through the surface's `write`, so it keeps its place among keys.
    /// The core names the file with nothing that needs shell quoting.
    private func attach(_ jobs: [AttachJob]) {
        attachments.run(jobs) { pane.view?.paste(text: $0 + " ") }
    }
}

/// The live surface, for the toolbar to paste into and resize the text of.
final class PaneHandle {
    weak var view: AttachedTerminal.LinkTapView?
}

struct AttachedTerminal: UIViewRepresentable {
    let controller: TerminalController
    let client: MoomuxClient
    let sessionID: Session.ID
    let fontSize: Double
    let pane: PaneHandle
    let onEnded: () -> Void
    let onURL: (URL) -> Void
    let onFile: (String) -> Void
    let onPinch: (Double) -> Void
    let onSelect: (TerminalTextSelectionRequest) -> Void

    func makeUIView(context: Context) -> UITerminalView {
        let view = LinkTapView(frame: .init(x: 0, y: 0, width: 390, height: 600))
        view.liveFontSize = fontSize
        view.onPinch = onPinch
        pane.view = view
        view.delegate = context.coordinator
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(context.coordinator.session),
            // The window reflows to this client (docs/macos-vs-ios.md D29), so the
            // font decides the attached session's *width*, not just how much
            // of a fixed grid is visible: 8pt is ~62 columns, 11pt ~43, and a
            // diff or an agent TUI hard-wraps mid-token below about 50. That
            // is why this is a control rather than a constant — there is no
            // value that is right for both reading prose and reading code on a
            // phone. Only the surface's *first* size comes from here; after
            // that `setFontSize` steps the live one, pinch included.
            fontSize: Float(fontSize),
            // Same reason the Mac pane sets it: ghostty coalesces resizes on a
            // 25ms trailing-only window, and an alt-screen agent TUI composites
            // a stale grid into the new bounds without this.
            resizeThrottleMilliseconds: 96
        )
        return view
    }

    func updateUIView(_: UITerminalView, context _: Context) {}

    /// Explicit teardown, exactly as `AppState.detach` needs on the Mac:
    /// dropping the view does not free the surface, and here it would also
    /// leave the attach socket open — so tmux would keep a client that nothing
    /// is reading, and the session would stay sized to a phone that left.
    static func dismantleUIView(_ view: UITerminalView, coordinator: Coordinator) {
        coordinator.teardown()
        view.controller = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, sessionID: sessionID, onEnded: onEnded, onURL: onURL,
                    onFile: onFile, onSelect: onSelect)
    }

    /// A tap on a link opens it.
    ///
    /// ghostty follows a link only on a ⌘-click — its URL matcher's hover mods
    /// are `ctrlOrSuper`, and the `link` config that would change that "can't
    /// currently be set" — and a finger tap carries no modifiers, so no link
    /// ever opened on the phone. So a clean tap (the one the package would
    /// spend toggling the keyboard) first asks ghostty what is under it as if
    /// ⌘ were held. `mouse_over_link` answers synchronously on the main thread.
    ///
    /// Shift as well while the program captures the mouse, which tmux with
    /// `mouse on` does: ghostty only refreshes links under capture when shift
    /// is held and not being reported, then strips it before matching. The
    /// off-screen positions either side reset its `link_point` cache — a probe
    /// at the cell it last checked would otherwise be skipped — and clear the
    /// underline afterwards. Ceiling: `link-previews = false` in the user's
    /// config suppresses `mouse_over_link` for plain URLs, so taps stop finding
    /// them; the upgrade is a ⌘-click through `open_url` instead.
    final class LinkTapView: UITerminalView {
        private var tap: CGPoint?

        /// The size the surface is drawing at now. The package tracks its own
        /// pinch counter privately (starting at 14, whatever the surface was
        /// built with) and publishes neither a getter nor a callback, so a
        /// pinch could never be saved. This view owns pinch instead: the
        /// package's recognizer is switched off, and this one steps the font
        /// with ghostty's own `increase_font_size`/`decrease_font_size` and
        /// reports the result when the fingers lift.
        var liveFontSize: Double = TerminalFontSize.default
        var onPinch: ((Double) -> Void)?
        private var pinchScale: CGFloat = 1

        override init(frame: CGRect) {
            super.init(frame: frame)
            for recognizer in gestureRecognizers ?? [] where recognizer is UIPinchGestureRecognizer {
                recognizer.isEnabled = false
            }
            addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        }

        required init?(coder: NSCoder) { fatalError("not from a nib") }

        /// Steps the live surface to `size`. Idempotent, so the save that a
        /// pinch triggers coming back through `onChange` does nothing.
        func setFontSize(_ size: Double) {
            let size = TerminalFontSize.clamped(size)
            let delta = Int((size - liveFontSize).rounded())
            guard delta != 0 else { return }
            let action = delta > 0 ? "increase_font_size:\(delta)" : "decrease_font_size:\(-delta)"
            if surface?.performBindingAction(action) == true { liveFontSize = size }
        }

        /// The package's own step: one point per 0.1 of scale.
        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                pinchScale = gesture.scale
            case .changed:
                let steps = Int((gesture.scale - pinchScale) / 0.1)
                guard steps != 0 else { return }
                pinchScale += CGFloat(steps) * 0.1
                setFontSize(liveFontSize + Double(steps))
            case .ended:
                onPinch?(liveFontSize)
            default:
                break
            }
        }

        /// ghostty reports a wheel to tmux at the last pointer position and
        /// drops it when there is none — and the package's finger-scroll pan
        /// sends no position (its trackpad one does), while the probe below
        /// parks the pointer off-screen after every tap. So a swipe never
        /// reached tmux at all. Aim the pointer at the finger as it lands,
        /// before the pan begins; momentum after lift keeps that position.
        /// The Mac pane's `scrollWheel` override is the same fix. Delete once
        /// `handleTouchScrollGesture` sends a position itself.
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first, touch.type == .direct {
                let point = touch.location(in: self)
                sendMousePos(x: point.x, y: point.y)
            }
            super.touchesBegan(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            tap = touches.first?.location(in: self)
            super.touchesEnded(touches, with: event)
            tap = nil
        }

        override func toggleSoftwareKeyboard() {
            guard let tap, let coordinator = delegate as? Coordinator else {
                return super.toggleSoftwareKeyboard()
            }
            sendMousePos(x: -1, y: -1)
            coordinator.hoverLink = nil
            sendMousePos(x: tap.x, y: tap.y, modifiers: isMouseCaptured ? [.super_, .shift] : .super_)
            let link = coordinator.hoverLink
            sendMousePos(x: -1, y: -1)
            guard let link, coordinator.follow(link) else { return super.toggleSoftwareKeyboard() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, TerminalSurfaceResizeDelegate,
                             TerminalSurfaceOpenURLDelegate,
                             TerminalSurfaceHoverLinkDelegate,
                             TerminalSurfaceClipboardConfirmationDelegate,
                             TerminalSurfaceTextSelectionRequestDelegate {
        private let onURL: (URL) -> Void
        private let onFile: (String) -> Void
        private let onSelect: (TerminalTextSelectionRequest) -> Void
        /// The attach itself — sizing, resize in place, reconnects — shared
        /// with the Mac's remote panes.
        private let remote: RemoteAttach

        var session: InMemoryTerminalSession { remote.session }

        init(client: MoomuxClient, sessionID: Session.ID, onEnded: @escaping () -> Void,
             onURL: @escaping (URL) -> Void, onFile: @escaping (String) -> Void,
             onSelect: @escaping (TerminalTextSelectionRequest) -> Void) {
            remote = RemoteAttach(client: client, sessionID: sessionID, onEnded: onEnded)
            self.onURL = onURL
            self.onFile = onFile
            self.onSelect = onSelect
        }

        /// A long-press. Conforming is the opt-in: without this delegate the
        /// package's long-press recognizer refuses to begin, so there was no
        /// way to select text on the phone at all. tmux owns the mouse, so a
        /// finger drag cannot select in the pane itself — the package hands
        /// over the visible screen as text instead, for a native text view.
        func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
            onSelect(request)
        }

        func terminalDidResize(columns: Int, rows: Int) {
            remote.terminalDidResize(columns: columns, rows: rows)
        }

        /// Permanent: the pane is going away.
        func teardown() { remote.teardown() }

        /// Read back by `LinkTapView`'s probe.
        var hoverLink: String?

        func terminalDidUpdateHoverLink(_ url: String?) { hoverLink = url }

        /// A ⌘-click from a hardware mouse or trackpad. The delegate must exist
        /// even so: without one ghostty core opens the link itself, straight
        /// past the allowlist in `follow`.
        func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
            follow(url)
        }

        /// Through `WebLink`, the allowlist; `onURL` decides where a web link
        /// opens. A path is on the core's disk, so it goes to `ReadFile`.
        @discardableResult
        func follow(_ link: String) -> Bool {
            if let url = WebLink.url(link) {
                onURL(url)
            } else if let path = WebLink.filePath(link) {
                onFile(path)
            } else {
                return false
            }
            return true
        }

        /// With no delegate the bridge answers `false` silently, which breaks
        /// the user's own paste with no dialog and nothing logged. Split on
        /// initiator, same as the Mac pane: a paste is the user, OSC 52 is the
        /// program in the pane asking.
        func terminalDidRequestClipboardConfirmation(
            _ request: TerminalClipboardConfirmationRequest
        ) {
            request.respond(allow: request.kind == .paste)
        }
    }
}
// MARK: - Selecting text

/// A long-press's snapshot, identifiable so `.sheet(item:)` can present it.
struct SelectableText: Identifiable {
    let id = UUID()
    let request: TerminalTextSelectionRequest
}

/// The screen as plain text in a read-only `UITextView`, with the word under
/// the finger pre-selected, so iOS's own handles, Copy and Share do the rest.
/// The package's example app does the same. Ceiling: the visible screen
/// only (`readViewportText`), not scrollback — scroll first, then hold.
struct SelectionSheet: View {
    let selection: SelectableText
    let fontSize: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: selection.request.text,
                               range: selection.request.anchorRange,
                               fontSize: fontSize)
                .ignoresSafeArea(edges: .bottom)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let text: String
    let range: NSRange?
    let fontSize: Double

    func makeUIView(context _: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.text = text
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.alwaysBounceVertical = true
        // The selection only shows once the view is in a window and first
        // responder — too early here, so on the next turn of the run loop.
        DispatchQueue.main.async {
            view.becomeFirstResponder()
            if let range, NSMaxRange(range) <= (view.text as NSString).length {
                view.selectedRange = range
                view.scrollRangeToVisible(range)
            } else {
                view.selectAll(nil)
            }
        }
        return view
    }

    func updateUIView(_: UITextView, context _: Context) {}
}

// MARK: - The cow

/// The cow mark plus its quip in a speech bubble, standing in for a title.
///
/// The bubble is the Kit's `SpeechBubble` so it matches the Mac exactly. The
/// mark cannot be: the Mac loads `moomux-terminal-nose.svg` straight from its
/// bundle and `UIImage` does not read SVG, so `make ios` rasterizes the same
/// file to a PNG (`Scripts/rasterize.swift`) rather than a second asset being
/// checked in to drift.
struct CowQuip: View {
    let saying: String

    var body: some View {
        HStack(spacing: 6) {
            if let cow = CowQuip.mark {
                Image(uiImage: cow).resizable().scaledToFit().frame(width: 22, height: 22)
            }
            Text(saying)
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.leading, 6 + 6)
                .padding(.trailing, 9)
                .padding(.vertical, 3)
                .background(SpeechBubble().fill(Color.secondary.opacity(0.15)))
        }
    }

    /// Decoded once: the image never changes and a toolbar redraws often.
    static let mark: UIImage? = Bundle.main
        .url(forResource: "moomux-terminal-nose", withExtension: "png")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap(UIImage.init(data:))
}
