import Foundation

/// Links over to MergeRight, the native PR app: `mergeright://open?url=<link>`.
/// It takes a session's GitHub PR page, or its Asana task and finds the PR
/// whose body links that — so both tags land on the same pull request, and the
/// PR tag goes first because it names it directly.
///
/// Both apps build the link here; only opening it is per platform. A value
/// MergeRight cannot place (not in its inbox) is its problem, not ours: the Mac
/// app falls back to the browser and the phone says so.
public enum MergeRight {
    public static func link(for session: Session) -> URL? {
        link(session.pr) ?? link(session.ticket)
    }

    /// nil for anything but a GitHub PR page or an Asana task. The plain https
    /// Asana URL, never `TerminalLink.asanaDesktop`'s rewrite — MergeRight
    /// matches on the task id inside it.
    ///
    /// Strict about the shape because pane text reaches this too, not just a
    /// session's own tags: `git push` prints `…/pull/new/<branch>` for a PR
    /// that does not exist yet, and an Asana board or inbox has no task for
    /// MergeRight to find a PR by. Both keep opening where they did.
    public static func link(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased()
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let number = { (i: Int) in i < parts.count && !parts[i].isEmpty && parts[i].allSatisfy { $0.isASCII && $0.isNumber } }
        switch host {
        case "github.com":
            // owner/repo/pull/<n>, and anything under it (/files, /commits).
            guard parts.count >= 4, parts[2] == "pull", number(3) else { return nil }
        case "app.asana.com":
            // …/task/<id> (the current shape), or the older /0/<project>/<task>.
            let task = parts.firstIndex(of: "task").map { number($0 + 1) } ?? false
            guard task || (parts.first == "0" && number(1) && number(2)) else { return nil }
        default:
            return nil
        }
        var link = URLComponents()
        link.scheme = "mergeright"
        link.host = "open"
        link.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return link.url
    }

    public static func demo() {
        func inner(_ link: URL?) -> String? {
            link.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "url" }?.value
        }
        let pr = "https://github.com/acme/widgets/pull/12/files#diff-1"
        assert(link(pr)?.absoluteString.hasPrefix("mergeright://open?url=https") == true)
        assert(inner(link(pr)) == pr, "survives as one query value")
        let odd = "https://app.asana.com/0/1/2?focus=true&x=a+b"
        assert(inner(link(odd)) == odd, "& and + in the inner URL do not split or decode it")
        assert(link(odd)?.query?.contains("&x=") == false)
        assert(link(" \(pr) ") != nil)
        assert(link("https://github.com/acme/widgets/issues/3") == nil, "a PR page only")
        assert(link("http://github.com/acme/widgets/pull/3") == nil)
        assert(link("T-123") == nil && link("") == nil && link(nil) == nil)
        assert(link("https://asana.com/pricing") == nil)
        assert(link("https://github.com/acme/widgets/pull/new/my-branch") == nil,
               "git push's create-a-PR link has no PR to open yet")
        assert(link("https://github.com/acme/pull/issues/3") == nil, "a repo named pull")
        assert(link("https://github.com/acme/widgets/blob/main/pull/1.md") == nil)
        assert(link("https://github.com/acme/widgets/pull/12") != nil)
        assert(link("\(pr)\n") != nil, "a trailing newline from pane text")
        assert(link("https://app.asana.com/1/1206/project/1216/task/1218") != nil)
        assert(link("https://app.asana.com/1/1206/task/1218?focus=true") != nil)
        assert(link("https://app.asana.com/0/portfolio/123/list") == nil, "no task to match on")
        assert(link("https://app.asana.com/1/1206/project/1216/board") == nil)
        assert(link("https://app.asana.com/0/inbox/123") == nil)
    }
}

extension AppState {
    /// `MergeRight.link(for:)`, or nil while the setting is off. This and
    /// `mergeRightLink(_:)` are the only gates onto MergeRight, on both
    /// platforms; whether it is installed is each platform's own check.
    public func mergeRightLink(for session: Session) -> URL? {
        mergeRightLinks ? MergeRight.link(for: session) : nil
    }

    /// The same for a single clicked link — a tag, or one in a pane.
    public func mergeRightLink(_ link: String) -> URL? {
        mergeRightLinks ? MergeRight.link(link) : nil
    }
}
