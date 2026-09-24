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

    /// nil for anything but a GitHub PR page or an Asana link. The plain https
    /// Asana URL, never `TerminalLink.asanaDesktop`'s rewrite — MergeRight
    /// matches on the task id inside it.
    public static func link(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host == "app.asana.com" || (host == "github.com" && url.path.contains("/pull/"))
        else { return nil }
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
    }
}

extension AppState {
    /// `MergeRight.link(for:)`, or nil while the setting is off — the one gate
    /// every "Open in MergeRight" goes through, on both platforms.
    public func mergeRightLink(for session: Session) -> URL? {
        mergeRightLinks ? MergeRight.link(for: session) : nil
    }
}
