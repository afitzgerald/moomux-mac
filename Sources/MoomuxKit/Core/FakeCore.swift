import Foundation

/// `moomux serve` reduced to a script, for the `demo()`s that drive the real
/// client, store and attach end to end rather than a hand-built request.
///
/// Every connection gets its own thread and has its request line recorded.
/// A method with a handler gets the socket and keeps it as long as it likes —
/// how `Watch` streams and `Attach` turns raw; anything else is answered with
/// `answer` and hung up, and an empty answer hangs up without one. Selftest
/// only: the accept thread parks for the life of the process, which under
/// `--selftest` is under a second.
final class FakeCore: @unchecked Sendable {
    /// Short and unique: `sun_path` is 104 bytes, and several cores can be up
    /// in one run.
    let path = "/tmp/mmx-\(getpid())-\(UUID().uuidString.prefix(6)).sock"
    private let lock = NSLock()
    private var answer = #"{"result":{}}"#
    private var handlers: [String: @Sendable (StreamSocket) -> Void] = [:]
    private var seen: [String] = []

    init() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(fd >= 0 && bound == 0 && listen(fd, 16) == 0, "selftest: cannot listen on \(path)")
        Thread { [self] in
            while case let conn = accept(fd, nil, nil), conn >= 0 {
                Thread { self.serve(StreamSocket(adopting: conn)) }.start()
            }
        }.start()
    }

    deinit { unlink(path) }

    /// Every request ends at its newline — `call` half-closes after it too,
    /// but `Watch` and `Attach` keep writing on the same connection.
    private func serve(_ socket: StreamSocket) {
        defer { socket.close() }
        var buffer = Data()
        while !buffer.contains(UInt8(ascii: "\n")) {
            guard let chunk = try? socket.readChunk(), !chunk.isEmpty else { break }
            buffer.append(chunk)
        }
        let line = String(decoding: buffer.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
        let request = Self.canonical(line)
        let method = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["method"] as? String
        let (handler, reply) = lock.withLock { () -> ((@Sendable (StreamSocket) -> Void)?, String) in
            seen.append(request)
            return (method.flatMap { handlers[$0] }, answer)
        }
        if let handler { return handler(socket) }
        if !reply.isEmpty { try? socket.write(Data(reply.utf8)) }
    }

    /// The requests `body` sent, one per line, keys sorted so a literal can
    /// pin them. For synchronous calls; nothing else may be talking.
    func requests(answering reply: String, _ body: () -> Void) -> String {
        lock.withLock { answer = reply; seen = [] }
        body()
        return lock.withLock { seen.joined(separator: "\n") }
    }

    /// Hands `method`'s connections to `handler` from now on.
    func on(_ method: String, _ handler: @escaping @Sendable (StreamSocket) -> Void) {
        lock.withLock { handlers[method] = handler }
    }

    /// How many `method` requests have arrived, from any thread.
    func count(_ method: String) -> Int {
        lock.withLock { seen.filter { $0.contains(#""method":"\#(method)""#) }.count }
    }

    /// Every request so far, canonicalised.
    var log: [String] { lock.withLock { seen } }

    /// Runs the main run loop until `done` or the deadline — how a synchronous
    /// `demo()` lets main-actor tasks (`AppState`, `RemoteAttach`) make
    /// progress. False on timeout, so the caller's assert names what stalled.
    @MainActor
    static func spin(_ seconds: Double = 3, until done: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !done() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return true
    }

    private static func canonical(_ line: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "unparseable: \(line)" }
        return String(decoding: data, as: UTF8.self)
    }
}
