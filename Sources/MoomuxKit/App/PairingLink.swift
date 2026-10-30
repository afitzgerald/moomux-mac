import Foundation

/// A `moomux://connect?host=…&name=…` link, as the Mac's pairing QR encodes it.
public struct PairingLink: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let name: String
}

// MARK: - Parsing

extension PairingLink {
    public static let defaultPort: UInt16 = 45876

    public struct Refused: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        static let outsideTailnet = Refused(message: "This link points outside your tailnet. Use Connect manually if you meant it.")
        static let notALink = Refused(message: "This isn't a moomux pairing link.")
    }

    /// Only tailnet and loopback hosts are accepted: a link is attacker-controlled
    /// input, and anything else would let one repoint the phone at their host.
    public init(url: URL) throws {
        guard url.scheme?.lowercased() == "moomux", url.host?.lowercased() == "connect",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty
        else { throw Refused.notALink }
        var port = Self.defaultPort
        if let raw = items.first(where: { $0.name == "port" })?.value {
            guard let p = UInt16(raw), p != 0 else { throw Refused.notALink }
            port = p
        }
        guard Self.isTailnet(host) else { throw Refused.outsideTailnet }
        let name = items.first(where: { $0.name == "name" })?.value ?? ""
        self.init(host: host, port: port, name: name.isEmpty ? host : name)
    }

    /// `100.64.0.0/10`, `fd7a:115c:a1e0::/48`, `*.ts.net`, or loopback.
    public static func isTailnet(_ host: String) -> Bool {
        // URLComponents decodes %00 into a real NUL, which getaddrinfo treats as
        // the end of the name: "evil.com\0.ts.net" would resolve evil.com.
        guard !host.isEmpty, host.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x7a) || $0 == 0x2e || $0 == 0x3a || $0 == 0x2d }) else { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let a = UInt32(bigEndian: v4.s_addr)
            return a >> 24 == 127 || a & 0xFFC0_0000 == 0x6440_0000
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b == [UInt8](repeating: 0, count: 15) + [1] { return true }
            return Array(b[0..<6]) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        }
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return h == "localhost" || h.hasSuffix(".ts.net")
    }
}

// MARK: - Failure

/// Why a connect attempt failed, as far as the pairing screen tells apart.
// ponytail: reads Connection.down's string; carry the error kind on Connection if a third case is ever needed
public enum ConnectFailure: Equatable {
    /// Someone answered and hung up: the listener drops a wrong-account peer
    /// unread, which arrives as EOF or, if the kernel sends RST, a reset.
    case refused
    /// Nothing answered: no route, timeout, or the name did not resolve.
    case unreachable

    public init?(_ why: String) {
        if why.hasPrefix("connect ") || why.hasPrefix("cannot resolve ") {
            self = .unreachable
        } else if why == StreamSocket.Failure.syscall("read", ETIMEDOUT).localizedDescription {
            // A keepalive timeout: the computer is asleep or gone, not a wrong account.
            self = .unreachable
        } else if why == MoomuxClient.Failure.emptyResponse.localizedDescription
                    || why == StreamSocket.Failure.syscall("read", ECONNRESET).localizedDescription {
            self = .refused
        } else {
            return nil
        }
    }
}

// MARK: - Demo

extension PairingLink {
    public static func demo() {
        let ok = try! PairingLink(url: URL(string: "moomux://connect?host=100.71.5.0&name=Jos%C3%A9%27s%20Mac")!)
        assert(ok == PairingLink(host: "100.71.5.0", port: 45876, name: "José's Mac"))
        assert((try? PairingLink(url: URL(string: "moomux://connect?host=100.100.1.2&port=8765")!))?.port == 8765)
        assert((try? PairingLink(url: URL(string: "moomux://connect?host=100.100.1.2")!))?.name == "100.100.1.2")
        for bad in ["moomux://connect?host=8.8.8.8", "moomux://connect?host=evil.example.com",
                    "moomux://connect?host=100.100.1.2&port=70000", "moomux://connect", "moomux://other?host=100.100.1.2"] {
            assert((try? PairingLink(url: URL(string: bad)!)) == nil, bad)
        }
        for good in ["100.64.0.1", "100.127.255.255", "fd7a:115c:a1e0::1", "mac.tail1234.ts.net", "MAC.TAIL1234.TS.NET.", "127.0.0.1", "localhost"] {
            assert(isTailnet(good), good)
        }
        assert(!isTailnet("evil.example.com\u{0}.ts.net"))
        assert((try? PairingLink(url: URL(string: "moomux://connect?host=evil.example.com%00.ts.net")!)) == nil)
        for bad in ["100.63.255.255", "100.128.0.0", "10.0.0.1", "fd7a:115c:a1e1::1", "ts.net.evil.com"] {
            assert(!isTailnet(bad), bad)
        }
        // Pinned against the real error types, so a reworded error fails here.
        assert(ConnectFailure(MoomuxClient.Failure.emptyResponse.localizedDescription) == .refused)
        assert(ConnectFailure(StreamSocket.Failure.syscall("read", ECONNRESET).localizedDescription) == .refused)
        assert(ConnectFailure(StreamSocket.Failure.syscall("connect 100.1.2.3:45876", ETIMEDOUT).localizedDescription) == .unreachable)
        assert(ConnectFailure(StreamSocket.Failure.unresolved("mac.ts.net", "nodename nor servname").localizedDescription) == .unreachable)
        assert(ConnectFailure(StreamSocket.Failure.syscall("read", ETIMEDOUT).localizedDescription) == .unreachable)
        assert(ConnectFailure("unknown method \"Pair\"") == nil)
    }
}
