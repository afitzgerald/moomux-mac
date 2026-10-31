import Foundation

/// The computers the phone has paired with, and the one it is on.
///
/// One at a time: switching disconnects from one core and connects to the
/// other, so nothing past the connect screen knows there is more than one.
/// Pure and `Codable`; the phone keeps it in `UserDefaults`.
public struct Computers: Codable, Equatable, Sendable {
    public struct Computer: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public var host: String
        public var port: Int
        /// The pairing code's name for it; empty for a typed address.
        public var codeName = ""
        /// The user's own name for it. Wins over `codeName` and survives a
        /// rescan, which only ever refreshes `codeName`.
        public var customName = ""

        public var displayName: String {
            !customName.isEmpty ? customName : !codeName.isEmpty ? codeName : host
        }

        public var endpoint: MoomuxClient.Endpoint { .tcp(host: host, port: UInt16(clamping: port)) }
    }

    public private(set) var list: [Computer] = []
    public private(set) var currentID: UUID?

    public init() {}

    public var current: Computer? { list.first { $0.id == currentID } }

    /// The port too, not just the host: `UInt16(clamping:)` turns a mistyped
    /// 458760 into 65535 and connects *there*. Refusing it keeps Connect
    /// disabled instead.
    public static func valid(host: String, port: Int) -> Bool {
        !host.trimmed.isEmpty && (1...65535).contains(port)
    }

    /// Adds the computer at this address, or finds the saved one, and makes
    /// it current. Matched on the address and not the name: two Macs can
    /// share a hostname, and a match on it would silently repoint one at the
    /// other. ponytail: a computer whose tailnet address changed comes back as
    /// a second entry; Forget the dead one.
    public mutating func add(host: String, port: Int, name: String) {
        let host = host.trimmed
        if let i = list.firstIndex(where: { $0.host == host && $0.port == port }) {
            if !name.isEmpty { list[i].codeName = name }
            currentID = list[i].id
        } else {
            let computer = Computer(id: UUID(), host: host, port: port, codeName: name)
            list.append(computer)
            currentID = computer.id
        }
    }

    public mutating func select(_ id: UUID) {
        if list.contains(where: { $0.id == id }) { currentID = id }
    }

    /// An empty name hands the computer back to its code's name.
    public mutating func rename(_ id: UUID, to name: String) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].customName = name.trimmed
    }

    /// Forgetting the current one moves to the first left, if any.
    public mutating func forget(_ id: UUID) {
        list.removeAll { $0.id == id }
        if currentID == id { currentID = list.first?.id }
    }

    public static func demo() {
        var c = Computers()
        assert(c.current == nil)
        c.add(host: " 100.64.0.1 ", port: 45876, name: "MacBook-Pro")
        let pro = c.currentID!
        c.add(host: "100.64.0.2", port: 45876, name: "Mac-mini")
        let mini = c.currentID!
        assert(c.list.count == 2 && c.current?.displayName == "Mac-mini")

        // A rescan switches to the saved one rather than adding a twin, and
        // never clears a rename.
        c.rename(pro, to: "  Work  ")
        c.add(host: "100.64.0.1", port: 45876, name: "MacBook-Pro-2")
        assert(c.list.count == 2 && c.currentID == pro, "same address, same computer")
        assert(c.current?.displayName == "Work" && c.current?.codeName == "MacBook-Pro-2")
        c.rename(pro, to: " ")
        assert(c.current?.displayName == "MacBook-Pro-2", "an empty rename gives the code's name back")

        // A typed address is named by itself, keeps a code's name it already
        // had, and a different port is a different core.
        c.add(host: "100.64.0.1", port: 45876, name: "")
        assert(c.current?.displayName == "MacBook-Pro-2")
        c.add(host: "100.64.0.1", port: 8765, name: "")
        assert(c.list.count == 3 && c.current?.displayName == "100.64.0.1")

        c.select(mini)
        assert(c.currentID == mini)
        c.select(UUID())
        assert(c.currentID == mini, "an unknown id changes nothing")

        // Forgetting another leaves the current alone; forgetting the current
        // moves to the first left; forgetting the last leaves none.
        let roundTrip = try! JSONDecoder().decode(Computers.self, from: JSONEncoder().encode(c))
        assert(roundTrip == c)
        c.forget(pro)
        assert(c.currentID == mini && c.list.count == 2)
        c.forget(mini)
        assert(c.current?.port == 8765)
        c.forget(c.currentID!)
        assert(c.list.isEmpty && c.current == nil)

        assert(valid(host: "a", port: 1) && !valid(host: " ", port: 1) && !valid(host: "a", port: 458760))
    }
}
