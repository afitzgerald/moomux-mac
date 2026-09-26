import AppKit
import MoomuxKit
import SwiftUI
import UniformTypeIdentifiers

/// The New Session sheet's first-prompt box: a plain `NSTextView` that turns
/// a dropped or pasted file into a path in the prompt, the way dropping a file
/// on a terminal does — which is how claude, codex and friends take images.
/// Every file goes through the core first (`AppState.attach`), as on the phone.
///
/// Not SwiftUI's `TextEditor`, because its `NSTextView` answers every drag
/// itself, before a SwiftUI `.dropDestination` is ever consulted.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    let attachments: AttachQueue
    let upload: @MainActor (String, UTType?, Data) async throws -> String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = PromptTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.font = .preferredFont(forTextStyle: .body)
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 5)
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.string = text
        view.attachments = attachments
        view.upload = upload

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // A re-keyed parent can hand over a new binding; typing into the old one is lost.
        context.coordinator.text = $text
        guard let view = scroll.documentView as? PromptTextView else { return }
        view.attachments = attachments
        view.upload = upload
        if view.string != text { view.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ note: Notification) {
            if let view = note.object as? NSTextView { text.wrappedValue = view.string }
        }
    }
}

private final class PromptTextView: NSTextView {
    var attachments: AttachQueue?
    var upload: (@MainActor (String, UTType?, Data) async throws -> String)?
    /// Where each pending drop's paths will go, kept in step with every edit
    /// made while its uploads run — typing before the drop point, or a second
    /// drop landing first, would otherwise put paths mid-word.
    private var anchors: [Anchor] = []
    private final class Anchor { var range: NSRange; init(_ range: NSRange) { self.range = range } }

    override func shouldChangeText(in affected: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affected, replacementString: replacementString) else { return false }
        let length = (replacementString as NSString?)?.length ?? 0
        for anchor in anchors {
            anchor.range = PromptDrop.shift(anchor.range, by: affected, replacementLength: length)
        }
        return true
    }

    // Return has to stay a newline — the core sends the prompt as one
    // paste-like `send-keys -l` chunk, so a multi-line prompt arrives intact —
    // so Tab is what gives, or this box is a keyboard trap.
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(nil) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(nil) }

    // A plain-text view reads neither images nor file URLs, so without these a
    // drop never reaches `readSelection` at all. *After* super's: the first
    // type the pasteboard has is the one super reads when `insertPaths` hands
    // back, and text that carries a picture of itself must be read as text —
    // read as TIFF it becomes a lone U+FFFC.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL, .png, .tiff]
    }

    // Paste and drop both land here; `readSelection(from:)` calls this one.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        insertPaths(from: pboard) || super.readSelection(from: pboard, type: type)
    }

    private func insertPaths(from pboard: NSPasteboard) -> Bool {
        // The drop point during a drag, the selection on a paste.
        let at = rangeForUserTextChange
        guard at.location != NSNotFound, let attachments, let upload else { return false }
        let drops = PromptDrop.items(from: pboard)
        guard !drops.isEmpty else { return false }
        // Read now: a screenshot dragged off its floating thumbnail is a file
        // macOS deletes moments later, too soon to wait its turn in the queue.
        let jobs = drops.map { $0.job(upload: upload, readNow: true) }
        // Paths land a moment later, in order, each one after the last — so
        // the first replaces what a paste had selected and the rest follow it.
        let anchor = Anchor(at)
        anchors.append(anchor)
        attachments.run(jobs, landed: { [weak self] path in
            self?.insert(path, at: anchor)
        }, finished: { [weak self] in
            self?.anchors.removeAll { $0 === anchor }
        })
        return true
    }

    /// Inserts `path` spaced off the word before it, and moves the anchor to
    /// just past it, where the next one goes. Clamped as a last resort.
    private func insert(_ path: String, at anchor: Anchor) {
        // Out of the list while its own insertion runs, or `shouldChangeText`
        // would shift it by the very text it is inserting.
        anchors.removeAll { $0 === anchor }
        defer { anchors.append(anchor) }
        anchor.range = insert(path, replacing: anchor.range)
    }

    private func insert(_ path: String, replacing range: NSRange) -> NSRange {
        let length = (string as NSString).length
        let location = min(range.location, length)
        let at = NSRange(location: location, length: min(range.length, length - location))
        let before = location > 0 ? (string as NSString).substring(with: NSRange(location: location - 1, length: 1)) : " "
        let lead = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
        let inserted = lead + path + " "
        insertText(inserted, replacementRange: at)
        return NSRange(location: location + (inserted as NSString).length, length: 0)
    }
}

/// What a drop, a paste or the Attach button hands the prompt, before anything
/// is uploaded. Pure over its inputs, so `demo()` can pin it.
enum PromptDrop: Equatable {
    /// A file, image or not; read when its job says.
    case file(URL, type: UTType?)
    /// Raw image data straight off the pasteboard — a clipboard screenshot.
    case data(name: String, type: UTType, Data)
    /// Not supported: an upload is one file's bytes.
    case folder

    /// The upload that turns this into a path for the prompt. `readNow`
    /// starts reading the file at once, off the main actor, rather than when
    /// the queue reaches it — at the cost of holding every file of the batch
    /// in memory until its turn, which is why only a drop asks for it.
    func job(upload: @escaping @MainActor (String, UTType?, Data) async throws -> String,
             readNow: Bool = false) -> AttachJob {
        switch self {
        case let .file(url, type):
            if readNow {
                let read = Task { try await Attachments.read(url) }
                return { try await upload(url.lastPathComponent, type, try await read.value) }
            }
            return { try await upload(url.lastPathComponent, type, try await Attachments.read(url)) }
        case let .data(name, type, data):
            return { try await upload(name, type, data) }
        case .folder:
            return { throw MoomuxClient.Failure.server("folders can't be attached") }
        }
    }

    /// Metadata only — the bytes are `job`'s to read.
    static func item(for url: URL) -> PromptDrop {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        return values?.isDirectory == true ? .folder : .file(url, type: values?.contentType)
    }

    /// Empty when there is nothing to attach, which hands the paste or drop
    /// back to the text view.
    static func items(from pboard: NSPasteboard) -> [PromptDrop] {
        let files = pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return files.map(item(for:)) }

        // Raw image data only when there is no text beside it: Office and
        // friends put a picture of the copied text on the pasteboard too, and a
        // text paste must stay a text paste.
        guard pboard.string(forType: .string) == nil else { return [] }
        if let png = pboard.data(forType: .png) { return [.data(name: "clipboard.png", type: .png, png)] }
        if let tiff = pboard.data(forType: .tiff) { return [.data(name: "clipboard.tiff", type: .tiff, tiff)] }
        return []
    }

    /// Where a pending insertion point ends up after an edit replaced
    /// `edit` with `replacementLength` characters: shifted by an edit before
    /// it, untouched by one after it, and collapsed to just past one that
    /// overlaps it — the text it was going to replace is gone anyway.
    static func shift(_ r: NSRange, by edit: NSRange, replacementLength: Int) -> NSRange {
        // Typing exactly at the insertion point counts as before it, so the
        // path lands after what was typed rather than splitting it.
        if edit.location + edit.length <= r.location {
            return NSRange(location: r.location + replacementLength - edit.length, length: r.length)
        }
        if edit.location >= r.location + r.length { return r }
        return NSRange(location: edit.location + replacementLength, length: 0)
    }

    static func demo() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("moomux-drop-demo-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let pb = NSPasteboard(name: .init("moomux-demo-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let tiff = rep.tiffRepresentation!

        // Plain text is not an attachment.
        pb.clearContents()
        pb.setString("hello", forType: .string)
        assert(items(from: pb).isEmpty)

        // Clipboard screenshot: raw data is uploaded as is; the core side
        // (`Attachments.prepare`) turns TIFF into PNG.
        pb.clearContents()
        pb.setData(png, forType: .png)
        assert(items(from: pb) == [.data(name: "clipboard.png", type: .png, png)])
        pb.clearContents()
        pb.setData(tiff, forType: .tiff)
        assert(items(from: pb) == [.data(name: "clipboard.tiff", type: .tiff, tiff)])

        // Text with a picture of itself beside it stays text.
        pb.clearContents()
        pb.setString("hello", forType: .string)
        pb.setData(tiff, forType: .tiff)
        assert(items(from: pb).isEmpty)

        // Files: every one is uploaded, image or not; a folder is refused;
        // nothing in a mixed drop goes missing.
        let shot = dir.appendingPathComponent("a shot.png")
        let notes = dir.appendingPathComponent("my notes.txt")
        let folder = dir.appendingPathComponent("a folder")
        try! png.write(to: shot)
        try! Data("x".utf8).write(to: notes)
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        pb.clearContents()
        pb.writeObjects([shot as NSURL, notes as NSURL, folder as NSURL])
        assert(items(from: pb) == [.file(shot, type: .png), .file(notes, type: .plainText), .folder])

        // An insertion point follows the edits made around it.
        let r = NSRange(location: 10, length: 4)
        assert(shift(r, by: NSRange(location: 2, length: 0), replacementLength: 3) == NSRange(location: 13, length: 4),
               "typing before it pushes it along")
        assert(shift(r, by: NSRange(location: 2, length: 5), replacementLength: 0) == NSRange(location: 5, length: 4),
               "deleting before it pulls it back")
        assert(shift(r, by: NSRange(location: 14, length: 0), replacementLength: 3) == r, "typing after it does nothing")
        assert(shift(r, by: NSRange(location: 12, length: 0), replacementLength: 1) == NSRange(location: 13, length: 0),
               "typing inside the selection it would replace collapses it past the typing")
        let caret = NSRange(location: 5, length: 0)
        assert(shift(caret, by: NSRange(location: 5, length: 0), replacementLength: 2) == NSRange(location: 7, length: 0),
               "typing at it puts the path after the typing")
        assert(shift(caret, by: NSRange(location: 5, length: 3), replacementLength: 0) == caret,
               "deleting forward from it leaves it")

        MainActor.assumeIsolated {
            let v = PromptTextView()
            v.isRichText = false
            v.attachments = AttachQueue()
            v.upload = { name, _, _ in "/t/\(name)" }

            // The regression: text + TIFF pasted through the view's own type
            // choice must come out as the text, not U+FFFC.
            pb.clearContents()
            pb.setString("hello", forType: .string)
            pb.setData(tiff, forType: .tiff)
            v.string = "x"
            v.setSelectedRange(NSRange(location: 1, length: 0))
            assert(v.readSelection(from: pb))
            assert(v.string == "xhello", "got \(v.string.debugDescription)")

            // Attachments land at the caret, in order, spaced off the word
            // before them, replacing what a paste had selected.
            pb.clearContents()
            pb.writeObjects([shot as NSURL, notes as NSURL])
            v.string = "look at THIS please"
            v.setSelectedRange(NSRange(location: 8, length: 4))
            assert(v.readSelection(from: pb))
            // Typed at the start before anything lands — the paths must still
            // go where the drop was, not four characters early.
            v.setSelectedRange(NSRange(location: 0, length: 0))
            v.insertText("so, ", replacementRange: NSRange(location: 0, length: 0))
            let deadline = Date().addingTimeInterval(2)
            while v.attachments?.pending != 0 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            let want = "so, look at /t/a shot.png /t/my notes.txt  please"
            assert(v.string == want, "got \(v.string.debugDescription)")
        }
    }
}
