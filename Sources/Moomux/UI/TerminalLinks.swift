import AppKit
import Foundation
import MoomuxKit

/// What a click on a link in a terminal pane is allowed to do.
///
/// libghostty finds the links: its implicit-URL matcher alongside OSC 8
/// payloads, underlined under the pointer while ⌘ is held, delivered on ⌘-click
/// through `TerminalSurfaceOpenURLDelegate`. What it does *not* do is decide
/// whether the link should be followed — it hands the host a string and the
/// host answers. A pane shows whatever an agent prints, which includes files it
/// did not write, so this is the allowlist that stands between
/// `cat hostile.txt` and the system opening it.
///
/// **Every surface must install that delegate.** Not doing so does not mean
/// "nothing opens" — the package reports the action unhandled and ghostty core
/// then spawns `/usr/bin/open` itself (`TerminalController+Callbacks.swift`
/// says so in as many words), which walks straight past this allowlist. Fail
/// open, not closed.
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
        // that are absolute (or ~-rooted) and actually exist are openable here
        // — a relative path has no cwd to resolve against on this side, since
        // tmux does not emit OSC 7. `AppState.openPaneLink` hands those to the
        // core, which can ask tmux for the pane's directory.
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
        NSWorkspace.shared.open(desktopApp(url) ?? url)
    }

    /// Asana's and Linear's desktop apps register a custom scheme but claim no
    /// universal link for their https host, so an https task or issue URL
    /// handed to `NSWorkspace` always lands in a browser. Rewriting it ourselves
    /// is the only way to skip that. The shapes are the apps' own handlers':
    /// `asanadesktop:///app` + the https path, and `linear://` + the path
    /// without its leading slash (Linear's `resolveDeeplink` resolves that
    /// against linear.app). Query and fragment are kept for both.
    ///
    /// nil whenever it would not work, so the caller falls back to the browser:
    /// a link that is neither, or one on a machine without that app, where the
    /// custom scheme would open nothing at all.
    ///
    /// Deliberately *not* done by adding either scheme to `allowedSchemes`:
    /// this only ever fires on a URL that already passed the allowlist, so a
    /// pane cannot print a custom-scheme link of its own choosing.
    static func desktopApp(_ url: URL, installed: (String) -> Bool = schemeHasHandler) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch url.host?.lowercased() {
        case "app.asana.com":
            guard installed("asanadesktop") else { return nil }
            parts.scheme = "asanadesktop"
            parts.host = ""
            parts.path = "/app" + url.path
        case "linear.app":
            guard installed("linear") else { return nil }
            let path = url.path.drop { $0 == "/" }
            guard let workspace = path.split(separator: "/").first else { return nil }
            parts.scheme = "linear"
            parts.host = String(workspace)
            parts.path = String(path.dropFirst(workspace.count))
        default:
            return nil
        }
        return parts.url
    }

    static func schemeHasHandler(_ scheme: String) -> Bool {
        guard let probe = URL(string: "\(scheme):///") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    /// Whether an event gets a Shift added so a ⌘-click reaches ghostty's
    /// link check past mouse capture — see `AttachedTerminalView.mouseDown`.
    /// Only while captured: uncaptured, ghostty keeps the Shift, so ⌘ plus a
    /// Shift no longer matches its ⌘-only link hover and nothing opens. Only
    /// real mouse events: `scrollWheel` forwards a scroll event to
    /// `mouseMoved`, and rebuilding that as a mouse event throws. And only
    /// ⌘'s own key: added to a Shift key's release, it would read as a press.
    static func addsShift(type: NSEvent.EventType, keyCode: UInt16,
                          flags: NSEvent.ModifierFlags, captured: Bool) -> Bool {
        guard captured, flags.contains(.command), !flags.contains(.shift) else { return false }
        switch type {
        case .leftMouseDown, .leftMouseUp, .mouseMoved: return true
        case .flagsChanged: return keyCode == 0x37 || keyCode == 0x36
        default: return false
        }
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

        // Asana's desktop app. The shape is taken from the app's own log line
        // ("Custom protocol handler invoked with URL: asanadesktop:///app/1/…"),
        // not from guessing: three slashes, then "app", then the https path.
        let yes: (String) -> Bool = { _ in true }
        let no: (String) -> Bool = { _ in false }
        let task = URL(string: "https://app.asana.com/1/1206/project/1216/task/1218")!
        assert(desktopApp(task, installed: yes)?.absoluteString
               == "asanadesktop:///app/1/1206/project/1216/task/1218")
        assert(desktopApp(task, installed: no) == nil, "no app means the browser")
        assert(desktopApp(URL(string: "https://app.asana.com/0/1/2?focus=true#f")!,
                            installed: yes)?.absoluteString
               == "asanadesktop:///app/0/1/2?focus=true#f", "query and fragment survive")
        assert(desktopApp(URL(string: "https://github.com/a/b/pull/1")!, installed: yes) == nil)
        assert(desktopApp(URL(string: "https://asana.com/pricing")!, installed: yes) == nil,
               "only the app host, not the marketing site")

        // Linear's desktop app: `linear://` + the path, per its resolveDeeplink.
        let issue = URL(string: "https://linear.app/acme/issue/ENG-12/fix-it?x=1#c")!
        assert(desktopApp(issue, installed: yes)?.absoluteString
               == "linear://acme/issue/ENG-12/fix-it?x=1#c")
        assert(desktopApp(issue, installed: no) == nil, "no app means the browser")
        assert(desktopApp(URL(string: "https://linear.app/acme")!, installed: yes)?.absoluteString
               == "linear://acme")
        assert(desktopApp(URL(string: "https://linear.app/")!, installed: yes) == nil,
               "the homepage is not a workspace")
        assert(desktopApp(URL(string: "https://linear.app.example.com/a")!, installed: yes) == nil)

        // ⌘-click past mouse capture.
        let cmd: NSEvent.ModifierFlags = .command
        assert(addsShift(type: .leftMouseDown, keyCode: 0, flags: cmd, captured: true))
        assert(addsShift(type: .mouseMoved, keyCode: 0, flags: cmd, captured: true))
        assert(addsShift(type: .flagsChanged, keyCode: 0x37, flags: cmd, captured: true))
        assert(!addsShift(type: .leftMouseDown, keyCode: 0, flags: cmd, captured: false),
               "uncaptured, the Shift would break ghostty's own ⌘-click")
        assert(!addsShift(type: .scrollWheel, keyCode: 0, flags: cmd, captured: true),
               "a scroll event rebuilt as a mouse event throws")
        assert(!addsShift(type: .flagsChanged, keyCode: 0x38, flags: cmd, captured: true),
               "a Shift key's release must not become a press")
        assert(!addsShift(type: .leftMouseDown, keyCode: 0, flags: [], captured: true))
        assert(!addsShift(type: .leftMouseDown, keyCode: 0, flags: [.command, .shift], captured: true))
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

extension AppState {
    /// Where a clicked ticket or PR tag goes. Web links open in the overlay —
    /// a browser tab per glance is what this exists to stop — and anything with
    /// a native app of its own (a `file:` tag, an Asana task or Linear issue on
    /// a machine with that app) goes there instead: the real app beats a logged-out
    /// WKWebView of the same page.
    ///
    /// Here rather than on `AppState` itself: the store is in `MoomuxKit`,
    /// which both apps link, and `TerminalLink` is AppKit — `NSWorkspace` and
    /// a Mac's installed apps. The `Sheet.web` case stays on the store, since
    /// what a front end does about a link is the part that differs.
    /// `mergeRightLink(for:)`, or nil on a Mac without MergeRight, where the
    /// custom scheme would open nothing — so the action is hidden, not dead.
    func installedMergeRightLink(for session: Session) -> URL? {
        guard let link = mergeRightLink(for: session),
              TerminalLink.schemeHasHandler("mergeright") else { return nil }
        return link
    }

    /// A ⌘-clicked link in a session's pane. A URL or an absolute path that
    /// exists opens exactly as `TerminalLink.open` always did. A path it cannot
    /// resolve alone — relative, or ending in `:line:col` — goes to the core's
    /// `ResolveFile`, which knows the pane's directory and applies the same
    /// rules as the phone's viewer; the answer is opened here, locally.
    /// Only the file opens, not the line: `NSWorkspace` has no way to say one.
    public func openPaneLink(_ link: String, in id: Session.ID) {
        // A remote pane's paths name the core's disk: fetch the file and open
        // the local copy, as the phone does with Quick Look.
        if remoteAttaches[id] != nil, WebLink.url(link) == nil, let path = WebLink.filePath(link) {
            return openRemoteFile(path, in: id)
        }
        if TerminalLink.resolve(link) != nil {
            if !openInMergeRight(link) { TerminalLink.open(link) }
            return
        }
        guard let path = WebLink.filePath(link) else { return }
        let client = client
        Task {
            do {
                let resolved = try await Task.detached {
                    try WebLink.firstSuccess(of: path) { try client.resolveFile(id: id, path: $0) }
                }.value
                TerminalLink.open(resolved)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// `ReadFile`, written under the temp directory with a name the system can
    /// open (`PreviewFile`), then handed to the default app. Left there rather
    /// than cleaned up: the app that opened it may still be reading it, and
    /// the system clears the temp directory itself.
    private func openRemoteFile(_ path: String, in id: Session.ID) {
        let client = client
        Task {
            do {
                let url = try await Task.detached {
                    let (resolved, data) = try WebLink.firstSuccess(of: path) { try client.readFile(id: id, path: $0) }
                    let dir = PreviewFile.root.appending(path: UUID().uuidString)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let url = dir.appending(path: PreviewFile.name(for: resolved, data: data))
                    try data.write(to: url)
                    return url
                }.value
                NSWorkspace.shared.open(url)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// A PR or Asana link, tag or pane alike, goes to MergeRight while the
    /// setting is on and the app is installed — ahead of the Asana app, since
    /// MergeRight opens the PR that links the ticket. false when it did not.
    private func openInMergeRight(_ link: String) -> Bool {
        guard let mr = mergeRightLink(link),
              TerminalLink.schemeHasHandler("mergeright") else { return false }
        NSWorkspace.shared.open(mr)
        return true
    }

    public func openTag(_ link: String) {
        guard let url = TerminalLink.resolve(link), !openInMergeRight(link) else { return }
        if url.isFileURL || TerminalLink.desktopApp(url) != nil {
            TerminalLink.open(link)
        } else {
            sheet = .web(link)
        }
    }
}
