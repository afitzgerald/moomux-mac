import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The New Session sheet's first-prompt box: a plain `NSTextView` that turns
/// a dropped or pasted image into a path in the prompt, the way dropping a file
/// on a terminal does — which is how claude, codex and friends take images.
///
/// Not SwiftUI's `TextEditor`, because its `NSTextView` answers every drag
/// itself, before a SwiftUI `.dropDestination` is ever consulted.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String

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
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
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
        guard at.location != NSNotFound else { return false }
        let paths = PromptImages.paths(from: pboard)
        guard !paths.isEmpty else { return false }
        let before = at.location > 0 ? (string as NSString).substring(with: NSRange(location: at.location - 1, length: 1)) : " "
        let lead = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
        insertText(lead + paths.joined(separator: " ") + " ", replacementRange: at)
        return true
    }
}

/// Where a dropped image lives until the agent reads it.
public enum PromptImages {
    /// Every image is copied here, file drops included: a screenshot dragged
    /// straight off its floating thumbnail is a file macOS deletes moments
    /// later, and a copy also gives every path a name with nothing to quote.
    /// The ceiling is the system's temp sweep (~3 days unread) — long after the
    /// agent has looked.
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("moomux-images", isDirectory: true)

    /// What claude and codex will actually look at. Anything else ImageIO can
    /// decode (HEIC, TIFF, PSD, BMP…) is re-encoded as PNG on the way in.
    static let agentReadable: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// One prompt-ready path per file or image on `pboard`; empty when there
    /// are none, which hands the paste or drop back to the text view. A
    /// non-image file is its own path, quoted if it needs it, the way a
    /// terminal takes a dropped file.
    static func paths(from pboard: NSPasteboard, into dir: URL = directory) -> [String] {
        let files = pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            return files.map { src in
                let type = (try? src.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                if type?.conforms(to: .image) == true, let saved = save(file: src, into: dir) { return saved }
                return src.path.contains(where: { $0.isWhitespace || "'\"\\$`".contains($0) })
                    ? src.path.shellQuoted : src.path
            }
        }

        // Raw image data only when there is no text beside it: Office and
        // friends put a picture of the copied text on the pasteboard too, and a
        // text paste must stay a text paste.
        guard pboard.string(forType: .string) == nil else { return [] }
        if let png = pboard.data(forType: .png), let dst = destination("png", in: dir),
           (try? png.write(to: dst)) != nil {
            return [dst.path]
        }
        guard let tiff = pboard.data(forType: .tiff),
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let dst = destination("png", in: dir), writePNG(source, to: dst) else { return [] }
        return [dst.path]
    }

    private static func save(file src: URL, into dir: URL) -> String? {
        let ext = src.pathExtension.lowercased()
        if agentReadable.contains(ext) {
            guard let dst = destination(ext, in: dir), (try? FileManager.default.copyItem(at: src, to: dst)) != nil
            else { return nil }
            return dst.path
        }
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let dst = destination("png", in: dir), writePNG(source, to: dst) else { return nil }
        return dst.path
    }

    /// A fresh name in `dir`, which is created only once there is something to put in it.
    private static func destination(_ ext: String, in dir: URL) -> URL? {
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    /// The first frame, full size, turned upright — a phone's HEIC is stored
    /// sideways with an EXIF flag, and PNG has nowhere to carry that flag.
    private static func writePNG(_ source: CGImageSource, to dst: URL) -> Bool {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let out = CGImageDestinationCreateWithURL(dst as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(out, image, nil)
        return CGImageDestinationFinalize(out)
    }

    static func demo() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("moomux-images-demo-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let pb = NSPasteboard(name: .init("moomux-demo-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let tiff = rep.tiffRepresentation!
        func isPNG(_ path: String) -> Bool {
            path.hasSuffix(".png") && fm.contents(atPath: path)?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
        }

        // Nothing to save creates nothing.
        pb.clearContents()
        pb.setString("hello", forType: .string)
        assert(paths(from: pb, into: dir).isEmpty && !fm.fileExists(atPath: dir.path))

        // Clipboard screenshot: raw data becomes a file, TIFF converted.
        pb.clearContents()
        pb.setData(png, forType: .png)
        let raw = paths(from: pb, into: dir)
        assert(raw.count == 1 && fm.contents(atPath: raw[0]) == png)
        pb.clearContents()
        pb.setData(tiff, forType: .tiff)
        let rawTiff = paths(from: pb, into: dir)
        assert(rawTiff.count == 1 && isPNG(rawTiff[0]))

        // Text with a picture of itself beside it stays text.
        pb.clearContents()
        pb.setString("hello", forType: .string)
        pb.setData(tiff, forType: .tiff)
        assert(paths(from: pb, into: dir).isEmpty)

        // Files: a readable image is copied as is, anything else ImageIO reads
        // becomes PNG, a non-image is its own path — quoted — and nothing in a
        // mixed drop goes missing.
        let shot = dir.appendingPathComponent("a shot.png")
        let scan = dir.appendingPathComponent("scan.tiff")
        let notes = dir.appendingPathComponent("my notes.txt")
        try! png.write(to: shot)
        try! tiff.write(to: scan)
        try! Data("x".utf8).write(to: notes)
        pb.clearContents()
        pb.writeObjects([shot as NSURL, scan as NSURL, notes as NSURL])
        let mixed = paths(from: pb, into: dir)
        assert(mixed.count == 3)
        assert(mixed[0] != shot.path && !mixed[0].contains(" ") && fm.contents(atPath: mixed[0]) == png)
        assert(isPNG(mixed[1]))
        assert(mixed[2] == notes.path.shellQuoted)

        MainActor.assumeIsolated {
            let v = PromptTextView()
            v.isRichText = false

            // The regression: text + TIFF pasted through the view's own type
            // choice must come out as the text, not U+FFFC.
            pb.clearContents()
            pb.setString("hello", forType: .string)
            pb.setData(tiff, forType: .tiff)
            v.string = "x"
            v.setSelectedRange(NSRange(location: 1, length: 0))
            assert(v.readSelection(from: pb))
            assert(v.string == "xhello", "got \(v.string.debugDescription)")

            // An image lands at the caret, spaced off the word before it.
            pb.clearContents()
            pb.setData(png, forType: .png)
            v.string = "look at"
            v.setSelectedRange(NSRange(location: 7, length: 0))
            assert(v.readSelection(from: pb))
            assert(v.string.hasPrefix("look at /") && v.string.hasSuffix(".png "))
            try? fm.removeItem(atPath: String(v.string.dropFirst(8).dropLast()))
        }
        _ = raw.map { try? fm.removeItem(atPath: $0) }
        _ = rawTiff.map { try? fm.removeItem(atPath: $0) }
    }
}
