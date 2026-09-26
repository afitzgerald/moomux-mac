import Foundation
import UniformTypeIdentifiers

/// The phone's link allowlist: http(s) and nothing else. One rule for the
/// session detail's ticket/PR tags and for a tapped link in a pane, where it is
/// a security boundary — pane output is attacker-influenceable (the Mac's
/// `TerminalLink` has the reasoning), and a `file:` or bare path names the
/// core's disk, not the phone's — so `filePath` sends those to the core's
/// `ReadFile`, which decides what may be read. Here rather than in the iOS
/// target so `--selftest` can assert it.
public enum WebLink {
    /// A schemeless `www.` link is read as https: it is plainly a web
    /// address, and sent on as a path it would only earn a "does not exist".
    public static func url(_ value: String?) -> URL? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if text.lowercased().hasPrefix("www.") { text = "https://" + text }
        guard let url = URL(string: text), url.host?.isEmpty == false,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// A tapped link that names a file on the core's machine, as the string to
    /// hand `ReadFile` — or nil for anything else, which is dropped. The core
    /// resolves it and decides what may be read; this only keeps URLs of other
    /// schemes off that call. A `file:` URL gives its path. Otherwise the one
    /// colon a path may carry is a trailing `:line` or `:line:col` — with the
    /// final `:` compilers and `rg` print, too — so `mailto:x` and
    /// `x-callback://y` stay out while `Foo.swift:42:7:` gets in.
    public static func filePath(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              url(text) == nil else { return nil }
        if text.lowercased().hasPrefix("file://") {
            guard let path = URL(string: text)?.path, !path.isEmpty else { return nil }
            return path
        }
        let bare = text.replacingOccurrences(of: #"(:\d+){1,2}:?$"#, with: "", options: .regularExpression)
        return bare.isEmpty || bare.contains(":") ? nil : text
    }

    public static func demo() {
        assert(url("https://github.com/a/b/pull/1")?.host == "github.com")
        assert(url("HTTP://example.com") != nil, "scheme is case-insensitive")
        assert(url("  https://example.com/x\n") != nil, "matcher whitespace is trimmed")
        assert(url(nil) == nil && url("") == nil)
        assert(url("javascript:alert(1)") == nil)
        assert(url("file:///etc/hosts") == nil, "the core's disk, not the phone's")
        assert(url("/etc/hosts") == nil)
        assert(url("mailto:a@b.com") == nil)
        assert(url("x-callback://open") == nil, "custom schemes are the risk")
        assert(url("https:") == nil, "no host, nothing to open")
        assert(url("www.example.com/x")?.absoluteString == "https://www.example.com/x")
        assert(filePath("www.example.com/x") == nil, "a web link, not a missing file")

        assert(filePath("/tmp/shot.png") == "/tmp/shot.png")
        assert(filePath("Sources/Foo.swift:42:7") == "Sources/Foo.swift:42:7", "the core strips the location")
        assert(filePath("Makefile:12") == "Makefile:12")
        assert(filePath("internal/ipc/server.go:285:3:") != nil, "as a compiler prints it")
        assert(filePath("Foo.swift:42:") != nil, "as rg prints it")
        assert(filePath("file:///private/tmp/a%20b.png") == "/private/tmp/a b.png")
        assert(filePath("https://github.com/a") == nil, "a web link, not a file")
        assert(filePath("mailto:a@b.com") == nil)
        assert(filePath("x-callback://open") == nil)
        assert(filePath("javascript:alert(1)") == nil)
        assert(filePath("file://") == nil && filePath(":42") == nil && filePath("  ") == nil)
    }
}

/// Where the phone puts a file fetched from the core for Quick Look, and what
/// it calls it. Quick Look goes by the extension alone, so `Makefile`, `.env`
/// and every source type iOS has no UTType for (`.go`, `.toml`, `.rs`) would
/// get its "no preview" page; text under a name iOS cannot read as text gets
/// `.txt` appended so it shows as text.
public enum PreviewFile {
    public static let root = FileManager.default.temporaryDirectory.appending(path: "moomux-preview")

    public static func name(for resolved: String, data: Data) -> String {
        let base = (resolved as NSString).lastPathComponent
        let name = base.isEmpty ? "file" : base
        let ext = (name as NSString).pathExtension
        // Any type iOS recognises keeps its name, text or not — a `.png` is
        // shown as a picture. Only a missing or unknown (dynamic) extension
        // is worth sniffing.
        let known = !ext.isEmpty && UTType(filenameExtension: ext)?.isDynamic == false
        return known || !looksLikeText(data) ? name : name + ".txt"
    }

    /// git's own test: a NUL in the first 8000 bytes is binary. No decoding,
    /// so a 30 MB file costs nothing extra to classify.
    static func looksLikeText(_ data: Data) -> Bool {
        !data.prefix(8000).contains(0)
    }

    /// Every earlier fetch's directory but `keep`.
    public static func clear(keeping keep: URL) {
        let others = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in others where dir.lastPathComponent != keep.lastPathComponent {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    public static func demo() {
        let text = Data("all: build\n".utf8)
        assert(name(for: "/wt/shot.png", data: Data([0x89, 0x50])) == "shot.png")
        assert(name(for: "/wt/Sources/Foo.swift", data: text) == "Foo.swift")
        assert(name(for: "/wt/NOTES.md", data: text) == "NOTES.md", "markdown is text to iOS")
        assert(name(for: "/wt/shot.png", data: Data("no NUL here".utf8)) == "shot.png", "a known type is never renamed")
        assert(name(for: "/wt/internal/server.go", data: text) == "server.go.txt", "no UTType for Go")
        assert(name(for: "/wt/doc.pdf", data: Data("%PDF-1.4\n".utf8)) == "doc.pdf", "a type iOS knows keeps its name")
        assert(name(for: "/wt/zeros", data: Data(count: 16)) == "zeros", "NULs are binary")
        assert(name(for: "/wt/Makefile", data: text) == "Makefile.txt", "text with no extension reads as text")
        assert(name(for: "/wt/.env", data: text) == ".env.txt")
        assert(name(for: "/wt/empty", data: Data()) == "empty.txt", "an empty file is still a file")
        assert(name(for: "/wt/a.out", data: Data([0xff, 0xfe, 0x00, 0xc3])) == "a.out")
    }
}
