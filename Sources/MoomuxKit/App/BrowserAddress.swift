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

    /// A link the pane hands to the Browser rather than Safari: one only the
    /// computer can reach, judged by its name alone — loopback, or a name
    /// reserved for local use. A public site goes to Safari whatever its
    /// scheme or port. Ceiling: an `/etc/hosts` name under a real domain is
    /// not recognised; typing it into the Browser still works.
    public static func isDevServer(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(),
              ["http", "https"].contains(scheme) else { return false }
        if ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) { return true }
        return [".localhost", ".test", ".local", ".internal"].contains { host.hasSuffix($0) }
    }

    public static func demo() {
        assert(isDevServer(URL(string: "http://localhost:3000/app")!))
        assert(isDevServer(URL(string: "https://app.example.test/login")!))
        assert(isDevServer(URL(string: "http://shop.app.localhost:9130/landing")!))
        assert(isDevServer(URL(string: "http://127.0.0.1:8080")!))
        assert(!isDevServer(URL(string: "http://example.org/docs")!), "a public site, plain http or not")
        assert(!isDevServer(URL(string: "https://example.com:8443/")!))
        assert(!isDevServer(URL(string: "https://github.com/a/b/pull/1")!))
        assert(!isDevServer(URL(string: "mailto:a@b.c")!))
        assert(url("localhost:3000/app")?.absoluteString == "http://localhost:3000/app")
        assert(url(" https://app.example.test ")?.absoluteString == "https://app.example.test")
        assert(url("localhost:9000/login?next=http://localhost:9000/x")?.host() == "localhost")
        assert(url("ftp://x") == nil && url("") == nil && url("javascript://x") == nil)
    }
}

/// Which `WKWebsiteDataStore` holds each session's cookies and logins. A
/// store is keyed by a UUID while a session is keyed by a computer and a
/// string, so the pairing is recorded here for a sweep to find it again.
public enum BrowserStores {
    static let key = "browserStores"

    /// The session's store, made up and recorded on first use.
    public static func id(computer: UUID, session: Session.ID, defaults: UserDefaults = .standard) -> UUID {
        let owner = "\(computer.uuidString)/\(session)"
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if let found = all.first(where: { $0.value == owner }), let id = UUID(uuidString: found.key) { return id }
        let id = UUID()
        all[id.uuidString] = owner
        defaults.set(all, forKey: key)
        return id
    }

    /// The computer's stores whose session is not in `live`; all of them for
    /// nil. Still recorded until `drop`, so one that fails to go is retried.
    public static func stale(computer: UUID, live: Set<Session.ID>?, defaults: UserDefaults = .standard) -> [UUID] {
        let prefix = computer.uuidString + "/"
        let all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return all.compactMap { id, owner in
            guard owner.hasPrefix(prefix), live.map({ !$0.contains(String(owner.dropFirst(prefix.count))) }) ?? true
            else { return nil }
            return UUID(uuidString: id)
        }
    }

    /// Where the session's Browser keeps its last URL, so it goes with the store.
    public static func urlKey(_ id: UUID) -> String { "browserURL.\(id.uuidString)" }

    public static func drop(_ id: UUID, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[id.uuidString] = nil
        defaults.set(all, forKey: key)
        defaults.removeObject(forKey: urlKey(id))
    }

    public static func demo() {
        let d = UserDefaults(suiteName: "BrowserStores.demo")!
        d.removePersistentDomain(forName: "BrowserStores.demo")
        let mac = UUID(), mini = UUID()
        let a = id(computer: mac, session: "p:a", defaults: d)
        assert(id(computer: mac, session: "p:a", defaults: d) == a, "the same session keeps its store")
        let b = id(computer: mac, session: "p:b", defaults: d)
        let other = id(computer: mini, session: "p:a", defaults: d)
        assert(a != b && a != other, "no two sessions share cookies, across computers either")
        assert(stale(computer: mac, live: ["p:a"], defaults: d) == [b])
        assert(Set(stale(computer: mac, live: nil, defaults: d)) == [a, b], "forgetting takes every one")
        d.set("http://localhost:3000", forKey: urlKey(b))
        drop(b, defaults: d)
        assert(d.string(forKey: urlKey(b)) == nil, "the last URL goes with the store")
        assert(stale(computer: mac, live: ["p:a"], defaults: d).isEmpty)
        assert(stale(computer: mini, live: nil, defaults: d) == [other])
        d.removePersistentDomain(forName: "BrowserStores.demo")
    }
}
