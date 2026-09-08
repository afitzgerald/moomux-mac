import AppKit
import Foundation

/// What a click on a link in a terminal pane is allowed to do.
///
/// libghostty finds the links: its implicit-URL matcher alongside OSC 8
/// payloads, underlined under the pointer while ⌘ is held, delivered on ⌘-click
/// through `TerminalSurfaceOpenURLDelegate`. What it does *not* do is decide
/// whether the link should be followed — it hands the host a string and the
/// host answers. A pane shows whatever an agent prints, which includes files it
/// did not write, so this is the allowlist that stands between
/// `cat hostile.txt` and the system opening it. With no delegate at all nothing
/// opens, so this is the only policy there is.
enum TerminalLink {

    /// Terminal output is attacker-influenceable, so nothing outside this set
    /// is handed to the system — not `mailto:`, `ssh:`, `tel:` or `x-anything:`,
    /// all of which an implicit-URL matcher will happily match.
    static let allowedSchemes: Set<String> = ["http", "https", "file"]

    /// The pure half, so it can be checked: what a clicked link resolves to, or
    /// nil to do nothing at all.
    ///
    /// `exists` is injected only so `demo()` does not depend on the filesystem.
    static func resolve(_ link: String,
                        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> URL?
    {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            guard allowedSchemes.contains(scheme) else { return nil }
            guard scheme == "file" else { return url }
            // /tmp is a symlink to /private/tmp, and a file:// URL naming the
            // symlink can fail to resolve depending on who opens it. Rebuild it
            // as a real file URL and follow the links.
            guard !url.path.isEmpty else { return nil }
            return fileURL(url.path)
        }

        // No scheme: the implicit detector also matches bare paths. Only ones
        // that are absolute (or ~-rooted) and actually exist are openable — a
        // relative path has no cwd to resolve against, since tmux does not emit
        // OSC 7 for us to have tracked one.
        let path = NSString(string: text).expandingTildeInPath
        guard path.hasPrefix("/"), exists(path) else { return nil }
        return fileURL(path)
    }

    /// `realpath(3)` and not `URL.resolvingSymlinksInPath`, which canonicalises
    /// the *opposite* way: it strips a leading `/private`, so `/tmp` stays
    /// `/tmp` — the one case worth resolving on macOS, since `/tmp` is a symlink
    /// to `/private/tmp`. Left unresolved on a path that does not exist.
    private static func fileURL(_ path: String) -> URL {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Hands the link to the system, or drops it. Opening a file with its
    /// default app is the point — the links agents print are screenshots and
    /// diffs meant to be looked at. Swap `open` for
    /// `activateFileViewerSelecting([url])` if revealing is ever wanted instead.
    static func open(_ link: String) {
        guard let url = resolve(link) else { return }
        NSWorkspace.shared.open(url)
    }

    static func demo() {
        let fake: (String) -> Bool = { $0 == "/private/tmp/x.png" || $0 == "/etc/hosts" }

        // Allowlist.
        assert(resolve("https://example.com/pr/1", exists: fake)?.absoluteString
               == "https://example.com/pr/1")
        assert(resolve("http://localhost:8080", exists: fake) != nil)
        assert(resolve("mailto:a@b.com", exists: fake) == nil, "no mail client from pane output")
        assert(resolve("ssh://host", exists: fake) == nil)
        assert(resolve("x-devonthink://open", exists: fake) == nil, "custom schemes are the risk")
        assert(resolve("javascript:alert(1)", exists: fake) == nil)
        assert(resolve("FILE:///private/tmp/x.png", exists: fake) != nil, "scheme is case-insensitive")
        assert(resolve("   ", exists: fake) == nil)

        // file:// and the /tmp symlink. resolvingSymlinksInPath only rewrites
        // paths that exist, so this asserts on the real /tmp -> /private/tmp.
        assert(resolve("file:///tmp/", exists: fake)?.path == "/private/tmp")
        assert(resolve("file:///etc/hosts", exists: fake)?.path == "/private/etc/hosts")

        // Bare paths: absolute and existing only.
        assert(resolve("/private/tmp/x.png", exists: fake)?.isFileURL == true)
        assert(resolve("/private/tmp/nope.png", exists: fake) == nil)
        assert(resolve("Sources/Moomux/UI/TerminalLinks.swift", exists: fake) == nil,
               "a relative path has no cwd to resolve against")
    }

    // The detector itself is no longer ours to check. SwiftTerm's `Terminal`
    // could be driven headlessly, so `demo()` used to feed real bytes in and
    // assert on what a click at a column found — bare URLs, a sentence's full
    // stop, markdown's closing paren, two links on one line, OSC 8 payload vs
    // label. libghostty's matcher only runs inside a live surface with a GPU
    // renderer attached, which is not something an assert can stand up. What
    // survives is the half that was always the security boundary: `resolve`,
    // which refuses whatever the matcher hands over.
}
