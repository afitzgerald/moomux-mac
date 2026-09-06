import AppKit
import Foundation
import SwiftTerm

/// What a click on a link in a terminal pane is allowed to do.
///
/// SwiftTerm already finds the links: 1.20 ships ghostty's implicit-URL regex
/// (`linkReporting = .implicit`) alongside OSC 8 payloads, underlines the match
/// under the pointer while ⌘ is held, and calls `requestOpenLink` on ⌘-click.
/// What it does *not* do is care what the link says — its default handler hands
/// any scheme at all to `NSWorkspace.open`. A pane shows whatever an agent
/// prints, which includes files it did not write, so this is the allowlist that
/// stands between `cat hostile.txt` and the system opening it.
enum TerminalLink {

    /// Terminal output is attacker-influenceable, so nothing outside this set
    /// is handed to the system — not `mailto:`, `ssh:`, `tel:` or `x-anything:`,
    /// all of which SwiftTerm's detector will happily match.
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

        detectionDemo()
    }

    // MARK: - Detection

    /// The detection itself is SwiftTerm's, but a version bump can change it
    /// under us and the failure mode is silent (nothing is clickable, or too
    /// much is). This drives the real code path — a headless `Terminal` fed the
    /// same bytes a pane gets — and asserts on what a click at a column finds.
    private static func detectionDemo() {
        func link(in line: String, atColumnOf needle: String) -> String? {
            let term = Terminal(delegate: SilentTerminalDelegate())
            term.feed(text: line)
            let col = line.distance(from: line.startIndex, to: line.range(of: needle)!.lowerBound)
            return term.link(at: .screen(Position(col: col, row: 0)), mode: .explicitAndImplicit)
        }

        assert(link(in: "see https://example.com/x for more", atColumnOf: "example")
               == "https://example.com/x", "bare URL in plain output")
        assert(link(in: "opened https://example.com/pr/1.", atColumnOf: "pr")
               == "https://example.com/pr/1", "a sentence's full stop is not part of the URL")
        assert(link(in: "wrote [shot](file:///private/tmp/x.png) ok", atColumnOf: "x.png")
               == "file:///private/tmp/x.png", "markdown's closing paren is not part of the URL")
        assert(link(in: "no link at all here", atColumnOf: "link") == nil)

        // Two on one line: hit-testing has to return the one under the pointer.
        let two = "https://a.example/1 and https://b.example/2"
        assert(link(in: two, atColumnOf: "a.example") == "https://a.example/1")
        assert(link(in: two, atColumnOf: "b.example") == "https://b.example/2")
        assert(link(in: two, atColumnOf: "and") == nil, "the gap between them is not a link")

        // OSC 8, the explicit form: the payload is the link, not the label.
        let osc8 = "\u{1b}]8;;https://example.com/ci\u{1b}\\CI run\u{1b}]8;;\u{1b}\\ done"
        let term = Terminal(delegate: SilentTerminalDelegate())
        term.feed(text: osc8)
        assert(term.link(at: .screen(Position(col: 1, row: 0)), mode: .explicitAndImplicit)
               == "https://example.com/ci", "OSC 8 label must resolve to its payload")
        assert(term.link(at: .screen(Position(col: 9, row: 0)), mode: .explicitAndImplicit) == nil,
               "text after the OSC 8 terminator is not part of the link")

        // And the policy layer refuses what the detector happily matches.
        assert(resolve(link(in: "mail me at mailto:a@b.com now", atColumnOf: "a@b") ?? "") == nil)
    }
}

/// A `Terminal` needs a delegate; `demo()`'s does not need to do anything.
private final class SilentTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
}
