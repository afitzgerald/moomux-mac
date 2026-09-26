import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Files attached to a first prompt, on the Mac and the phone alike: each one
/// is uploaded to the core (`SaveFile`) and the path that comes back goes into
/// the prompt, the way a file dropped on a terminal lands. The core writes it
/// where the agent can read it, so neither front end keeps a temp directory.
public enum Attachments {
    /// What claude and codex will actually look at. Anything else ImageIO can
    /// decode is re-encoded on the way in.
    public static let agentReadable: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// An image the agent could not read, re-encoded so it can: HEIC/HEIF —
    /// most of a camera roll — as JPEG, because a 12MP photo as PNG is over the
    /// upload cap; anything else (TIFF, PSD, BMP, a clipboard screenshot) as
    /// PNG, lossless for the text in it. Non-images, and images already
    /// readable, go as they are, and so does anything ImageIO cannot decode.
    public static func prepare(name: String, type: UTType?, data: Data) -> (name: String, data: Data) {
        let ext = (name as NSString).pathExtension.lowercased()
        guard type?.conforms(to: .image) == true, !agentReadable.contains(ext),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return (name, data) }
        let photo = type?.conforms(to: .heic) == true || type?.conforms(to: .heif) == true
        let out: UTType = photo ? .jpeg : .png
        guard let encoded = encode(source, as: out) else { return (name, data) }
        return ((name as NSString).deletingPathExtension + "." + (photo ? "jpg" : "png"), encoded)
    }

    /// A picked or dropped file's bytes, read off the main actor: a large
    /// file, or one iCloud has not downloaded yet, would otherwise freeze the
    /// sheet. Too big is refused from the size the file system reports,
    /// before reading any of it; an unreadable file throws its own reason.
    /// The security scope is the phone's file picker; on the Mac, which is not
    /// sandboxed, it is a no-op.
    public static func read(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > MoomuxClient.maxSaveFile {
                throw MoomuxClient.Failure.tooLarge
            }
            return try Data(contentsOf: url)
        }.value
    }

    /// The first frame, full size, turned upright — a phone's HEIC is stored
    /// sideways with an EXIF flag, and PNG has nowhere to carry that flag.
    static func encode(_ source: CGImageSource, as type: UTType) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        let data = NSMutableData()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let out = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }

    public static func demo() {
        let tiny = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        func file(_ type: UTType) -> Data {
            let data = NSMutableData()
            let out = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(out, tiny, nil)
            assert(CGImageDestinationFinalize(out))
            return data as Data
        }
        func isPNG(_ d: Data) -> Bool { d.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) }

        // Readable images and non-images pass through untouched.
        let png = file(.png)
        assert(prepare(name: "a.png", type: .png, data: png) == ("a.png", png))
        let text = Data("x".utf8)
        assert(prepare(name: "notes.txt", type: .plainText, data: text) == ("notes.txt", text))
        // A type that claims image but will not decode is sent as is.
        assert(prepare(name: "bad.tiff", type: .tiff, data: text) == ("bad.tiff", text))

        // TIFF becomes PNG, and says so in its name.
        let tiff = prepare(name: "scan.tiff", type: .tiff, data: file(.tiff))
        assert(tiff.name == "scan.png" && isPNG(tiff.data), tiff.name)

        // HEIC becomes JPEG — only where this machine can write one to test with.
        let heic = NSMutableData()
        if let out = CGImageDestinationCreateWithData(heic, UTType.heic.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(out, tiny, nil)
            if CGImageDestinationFinalize(out) {
                let photo = prepare(name: "IMG_1.HEIC", type: .heic, data: heic as Data)
                assert(photo.name == "IMG_1.jpg" && photo.data.prefix(2) == Data([0xFF, 0xD8]), photo.name)
            }
        }
    }
}

/// One upload job: produces the path that goes into the prompt. Usually
/// `AppState.attach`; on the Mac a non-image file is its own path and skips
/// the upload.
public typealias AttachJob = @MainActor () async throws -> String

/// Runs a sheet's attachments: in order, so paths land the way they were
/// picked; counted, so Create can wait for them rather than send a prompt
/// missing its paths; cancelled with the sheet. One per sheet.
@MainActor @Observable
public final class AttachQueue {
    public private(set) var pending = 0
    /// Cleared by the next batch, not by the next success, so one failure in
    /// a batch stays on screen beside the paths that did land.
    public private(set) var error: String?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init() {}

    /// `finished` runs once the batch is over, however it ended.
    public func run(_ jobs: [AttachJob], landed: @escaping @MainActor (String) -> Void,
                    finished: @escaping @MainActor () -> Void = {}) {
        guard !jobs.isEmpty else { return finished() }
        error = nil
        pending += jobs.count
        tasks.append(Task {
            // What a cancelled run still owes the counter.
            var left = jobs.count
            defer { pending -= left; finished() }
            var failed: [String] = []
            for job in jobs {
                defer { pending -= 1; left -= 1 }
                if Task.isCancelled { return }
                do {
                    let path = try await job()
                    // The one in flight when the sheet closed still lands on
                    // the core; the system's temp sweep takes it from there.
                    if Task.isCancelled { return }
                    landed(path)
                } catch {
                    failed.append(error.localizedDescription)
                }
            }
            if !failed.isEmpty {
                error = "Couldn't attach \(failed.count == 1 ? "one file" : "\(failed.count) files"): "
                    + Set(failed).sorted().joined(separator: "; ")
            }
        })
    }

    /// For an alert that shows `error` and is dismissed before the next batch.
    public func clearError() { error = nil }

    public func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}
