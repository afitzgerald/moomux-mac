import Foundation

/// The phone's link allowlist: http(s) and nothing else. One rule for the
/// session detail's ticket/PR tags and for a tapped link in a pane, where it is
/// a security boundary — pane output is attacker-influenceable (the Mac's
/// `TerminalLink` has the reasoning), and a `file:` or bare path would name the
/// core's disk, not the phone's. Here rather than in the iOS target so
/// `--selftest` can assert it.
public enum WebLink {
    public static func url(_ value: String?) -> URL? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), url.host?.isEmpty == false,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
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
    }
}
