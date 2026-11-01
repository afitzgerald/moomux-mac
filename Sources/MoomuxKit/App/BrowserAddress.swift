import Foundation

/// What the phone's Browser address field turns typing into.
public enum BrowserAddress {
    /// `ipc.TailnetProxyPort`: the core's CONNECT proxy, beside
    /// `MoomuxClient.tailnetPort`.
    public static let proxyPort: UInt16 = 45877

    /// A bare `host:port/path` gets `http://`, since a dev server is never
    /// https. A leading scheme other than http(s) is refused rather than
    /// prefixed; a `://` later on, in a query, is not a scheme.
    public static func url(_ typed: String) -> URL? {
        let t = typed.trimmed
        guard !t.isEmpty else { return nil }
        let schemed = t.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
        guard let url = URL(string: schemed ? t : "http://" + t), url.host() != nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    public static func demo() {
        assert(url("localhost:3000/app")?.absoluteString == "http://localhost:3000/app")
        assert(url(" https://app.example.test ")?.absoluteString == "https://app.example.test")
        assert(url("localhost:9000/login?next=http://localhost:9000/x")?.host() == "localhost")
        assert(url("ftp://x") == nil && url("") == nil && url("javascript://x") == nil)
    }
}
