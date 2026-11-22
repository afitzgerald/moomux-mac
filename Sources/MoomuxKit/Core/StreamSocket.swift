import Foundation

/// A blocking stream socket, over AF_UNIX locally or TCP to a core reached
/// across a tailnet.
///
/// Network.framework can reach both too, but its async connection state
/// machine is a lot of ceremony for "connect, write one line, read the
/// answer" — which is the entire protocol `moomux serve` speaks, since it
/// closes the connection after every call. The one long-lived connection
/// (`Watch`) reads line-delimited JSON, which `FileHandle.bytes.lines` already
/// does. Everything below the connect is identical for both families, and
/// BSD sockets are as available on iOS as they are here.
public final class StreamSocket {

    public enum Failure: Error, LocalizedError {
        case syscall(String, Int32)
        case pathTooLong(String)
        case unresolved(String, String)
        /// The core sent more than `limit` bytes without ending the reply or line.
        case tooLong(limit: Int)
        /// No `utun` interface holds a tailnet address, so a non-loopback dial
        /// would leave over whatever network is up instead.
        case noTailnet(String)

        public var errorDescription: String? {
            switch self {
            case let .syscall(what, code):
                return "\(what): \(String(cString: strerror(code)))"
            case let .pathTooLong(path):
                return "socket path is too long for sockaddr_un: \(path)"
            case let .unresolved(host, why):
                return "cannot resolve \(host): \(why)"
            case let .noTailnet(host):
                return "Tailscale is not connected, so \(host) was not dialled"
            case let .tooLong(limit):
                return "the core's reply is longer than \(limit >> 10) KB"
            }
        }
    }

    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    /// A write to a socket whose peer has gone raises SIGPIPE, whose default
    /// disposition kills the process — and a signal is not an error, so the
    /// `try?` around every `AttachChannel.send` does not catch it. One
    /// keystroke after the core restarts or the tailnet route drops would take
    /// the app down instead of showing the read loop's "connection lost".
    /// With this the same write throws EPIPE.
    private static func silenceSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Bounds a *read* the way `connectWithin` bounds the connect.
    ///
    /// No `SO_RCVTIMEO`: `Watch` and `Attach` are idle for minutes at a time
    /// by design, so a receive deadline would tear down healthy streams. The
    /// failure to catch is the half-open one — the Mac sleeps or the tailnet
    /// route goes without a RST — where the peer is gone and no byte or EOF
    /// ever arrives, leaving `readToEnd`/`bytes.lines` parked forever with
    /// `connection` still reading `.connected` and `Task.cancel()` unable to
    /// interrupt a blocking `read(2)`. Keepalive probes turn that into
    /// ETIMEDOUT in ~30s. Unix sockets always EOF when the peer dies, which is
    /// why this is only on the TCP path.
    private static func enableKeepalive(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
        var idle: Int32 = 15, interval: Int32 = 5, count: Int32 = 3
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, socklen_t(MemoryLayout<Int32>.size))
    }

    /// `connect(2)` on a blocking socket cannot be interrupted — the fd is
    /// local to the initializer, so neither `close()` nor `AppState.stop()`
    /// can reach it — and a tailnet peer that resolves but is unreachable (Mac
    /// asleep, route dropped) parks it for the kernel's ~75s. That turns the
    /// 2s config poll into a 75s one and makes the watch loop's 5s backoff
    /// meaningless. Non-blocking connect plus a `poll` deadline bounds it.
    /// Returns 0, or the errno to report.
    private static func connectWithin(_ fd: Int32, _ sa: UnsafePointer<sockaddr>, _ len: socklen_t,
                                      seconds: Int32 = 5) -> Int32 {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }

        if connect(fd, sa, len) == 0 { return 0 }
        guard errno == EINPROGRESS else { return errno }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, seconds * 1000)
        if ready == 0 { return ETIMEDOUT }
        if ready < 0 { return errno }

        var err: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &size) == 0 else { return errno }
        return err
    }

    public init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.syscall("socket", errno) }
        Self.silenceSigPipe(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // sun_path is a fixed 104-byte tuple. A longer path would silently
        // truncate into a connect to some *other* socket, so refuse it.
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw Failure.pathTooLong(path)
        }
        // sockaddr_un() zero-fills, so copying count bytes leaves the NUL.
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }

        var rc: Int32 = -1
        withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                rc = connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Failure.syscall("connect \(path)", code)
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// `getaddrinfo` rather than `inet_pton`: a tailnet is reached by MagicDNS
    /// name at least as often as by its 100.x address, and the same call
    /// covers IPv6 — which is the only address a tailnet node is guaranteed.
    public init(host: String, port: UInt16) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let first = list else {
            throw Failure.unresolved(host, String(cString: gai_strerror(rc)))
        }
        defer { freeaddrinfo(list) }

        // Try every answer: a node with both A and AAAA records hands back two,
        // and connecting to the first is how a v6-only path looks like a dead
        // server.
        var lastErrno: Int32 = EHOSTUNREACH
        var noTailnet = false
        var candidate = Optional(first)
        while let info = candidate {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                // Loopback (scratch-core bridge, simulator) dials as-is. Anything
                // else must leave through the tailnet's utun, or with Tailscale
                // off a `*.ts.net` name or CGNAT address reaches whatever the
                // local network answers with.
                if !Self.isLoopback(info.pointee.ai_addr), !Self.bindToTailnet(fd, family: info.pointee.ai_family) {
                    Darwin.close(fd)
                    lastErrno = ENETDOWN
                    noTailnet = true
                    candidate = info.pointee.ai_next
                    continue
                }
                Self.silenceSigPipe(fd)
                Self.enableKeepalive(fd)
                let err = Self.connectWithin(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if err == 0 {
                    handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    return
                }
                lastErrno = err
                Darwin.close(fd)
            } else {
                lastErrno = errno
            }
            candidate = info.pointee.ai_next
        }
        if noTailnet, lastErrno == ENETDOWN { throw Failure.noTailnet(host) }
        throw Failure.syscall("connect \(host):\(port)", lastErrno)
    }

    // MARK: Tailnet pinning

    /// Whether `a` is a tailnet address: `100.64.0.0/10` or `fd7a:115c:a1e0::/48`.
    static func isTailnet(v4 b: [UInt8]) -> Bool { b.count == 4 && b[0] == 100 && b[1] & 0xC0 == 0x40 }
    static func isTailnet(v6 b: [UInt8]) -> Bool {
        b.count == 16 && b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
    }

    private static func isLoopback(_ sa: UnsafePointer<sockaddr>?) -> Bool {
        guard let sa else { return false }
        if Int32(sa.pointee.sa_family) == AF_INET {
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) >> 24 == 127 }
        }
        if Int32(sa.pointee.sa_family) == AF_INET6 {
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var a = $0.pointee.sin6_addr
                return withUnsafeBytes(of: &a) { Array($0) } == [UInt8](repeating: 0, count: 15) + [1]
            }
        }
        return false
    }

    /// Index of a `utun` interface holding a tailnet address of `family`, if any.
    private static func tailnetInterface(family: Int32) -> UInt32? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cur = list
        while let i = cur?.pointee {
            cur = i.ifa_next
            guard String(cString: i.ifa_name).hasPrefix("utun"), let sa = i.ifa_addr,
                  Int32(sa.pointee.sa_family) == family else { continue }
            let hit: Bool
            if family == AF_INET {
                hit = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var a = $0.pointee.sin_addr
                    return isTailnet(v4: withUnsafeBytes(of: &a) { Array($0) })
                }
            } else {
                hit = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    var a = $0.pointee.sin6_addr
                    return isTailnet(v6: withUnsafeBytes(of: &a) { Array($0) })
                }
            }
            if hit { return if_nametoindex(i.ifa_name) }
        }
        return nil
    }

    /// Pins `fd` to the tailnet interface; false when there is none.
    private static func bindToTailnet(_ fd: Int32, family: Int32) -> Bool {
        guard family == AF_INET || family == AF_INET6, var idx = tailnetInterface(family: family), idx != 0 else { return false }
        let (level, opt) = family == AF_INET ? (IPPROTO_IP, IP_BOUND_IF) : (IPPROTO_IPV6, IPV6_BOUND_IF)
        return setsockopt(fd, level, opt, &idx, socklen_t(MemoryLayout<UInt32>.size)) == 0
    }

    public func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    /// One blocking read of whatever has arrived. Empty means "no more" —
    /// the peer hung up, or `close()` was called to cancel this read.
    ///
    /// `read(2)` and **not** `FileHandle.availableData`, which raises an
    /// `NSFileHandleOperationException` when the descriptor goes away under a
    /// parked read. That is an Objective-C exception, so Swift cannot catch it
    /// and the process aborts — and since `close()` *is* how a read in
    /// progress gets cancelled here, every detach took the app down with it.
    /// Shipped once, found in a crash report rather than by reading:
    /// `availableData` -> `_NSFileHandleRaiseOperationExceptionWhileReading`
    /// -> `objc_exception_throw` -> `abort`.
    ///
    /// `readToEnd` is wrong for a pty for a different reason — it would wait
    /// for the far end to hang up before showing a single frame.
    public func readChunk() throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            // The descriptor stays ours until dealloc — `close()` shuts the
            // socket down rather than freeing the number, so this can never
            // read from a connection somebody else has since opened.
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(handle.fileDescriptor, raw.baseAddress, raw.count)
            }
            if n > 0 { return Data(buffer[0..<n]) }
            if n == 0 { return Data() }          // the peer closed
            if errno == EINTR { continue }       // a signal, not an end
            let code = errno
            // EBADF is `close()` cancelling this read — the detach, not a
            // failure. Everything else (ECONNRESET on a dropped tailnet,
            // ETIMEDOUT) has to be distinguishable: after `{"ok":true}` an
            // empty read *is* "tmux exited", so reporting a dead link that way
            // makes the pane vanish with nothing said.
            if code == EBADF || lock.withLock({ closed }) { return Data() }
            throw Failure.syscall("read", code)
        }
    }

    /// Wraps an already-connected descriptor. Only `demo()` uses it — a
    /// `socketpair` is the cheapest way to have a real fd to close.
    init(adopting fd: Int32) {
        Self.silenceSigPipe(fd)
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Half-close: "the request is finished, I am still reading".
    ///
    /// A one-shot call has to send this or a server that reads its request to
    /// EOF waits forever — the connection stays open because the client is
    /// waiting for the answer on it. `nc` does this when its stdin ends,
    /// which is why a request pasted through `nc` answers while the same
    /// bytes from this client hang. **Not** for `Attach` or `Watch`: both keep
    /// writing on the connection after the request.
    public func closeWrite() {
        shutdown(handle.fileDescriptor, SHUT_WR)
    }

    /// Reads until the peer closes. The server closes after one response, so
    /// this is the whole answer to a one-shot call.
    ///
    /// A loop over `readChunk` and **not** `FileHandle.readToEnd`, which
    /// folds a TCP reset into `NSCocoaErrorDomain 256` ("The file couldn't be
    /// opened.") — the one failure a wrong-account phone gets, since the core
    /// drops it unread. `readChunk` keeps the errno, so `ConnectFailure` can
    /// tell a reset from a dead route.
    ///
    /// Capped at `limit` (64 MB, well past any real reply): a peer that never
    /// stops sending must fail the call, not fill memory.
    public func readToEnd(limit: Int = StreamSocket.maxReply) throws -> Data {
        var all = Data()
        while true {
            let chunk = try readChunk()
            if chunk.isEmpty { return all }
            all.append(chunk)
            if all.count > limit { throw Failure.tooLong(limit: limit) }
        }
    }

    public static let maxReply = 64 << 20

    /// Bytes read past the last line returned by `readLine`. Touched only by
    /// the one task reading a `Watch` stream.
    private var lineBuffer = Data()

    /// One newline-terminated line, for the `Watch` stream (Go's
    /// `json.Encoder.Encode` ends every object with one). Blocking, like
    /// `readChunk`; `nil` means the peer closed. A line longer than `limit`
    /// throws instead of growing without bound.
    public func readLine(limit: Int = StreamSocket.maxReply) throws -> Data? {
        while true {
            if let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = lineBuffer[lineBuffer.startIndex..<newline]
                lineBuffer = Data(lineBuffer[lineBuffer.index(after: newline)...])
                return Data(line)
            }
            if lineBuffer.count > limit { throw Failure.tooLong(limit: limit) }
            let chunk = try readChunk()
            if chunk.isEmpty { return nil }
            lineBuffer.append(chunk)
        }
    }

    /// Writes `bytes` in 4 KB pieces, retrying short writes, then closes `fd`.
    /// One 200 KB `write` into a socketpair is not guaranteed to be accepted
    /// whole on every kernel; a failed one left the reader with an empty
    /// stream, which `readToEnd` reports as a clean EOF rather than "too long".
    private static func floodWrite(_ fd: Int32, _ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, min(4096, bytes.count - sent)) }
            if n > 0 { sent += n } else if n < 0, errno == EINTR || errno == EAGAIN || errno == ENOBUFS { usleep(1000) } else { break }
        }
        Darwin.close(fd)
    }

    public static func demo() {
        assert(isTailnet(v4: [100, 64, 0, 1]) && isTailnet(v4: [100, 127, 255, 255]))
        assert(!isTailnet(v4: [100, 63, 255, 255]) && !isTailnet(v4: [100, 128, 0, 0]))
        assert(!isTailnet(v4: [10, 64, 0, 1]) && !isTailnet(v4: [127, 0, 0, 1]) && !isTailnet(v4: [100, 64]))
        let ts: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] + [UInt8](repeating: 7, count: 10)
        assert(isTailnet(v6: ts))
        assert(!isTailnet(v6: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe1] + [UInt8](repeating: 7, count: 10)))
        assert(!isTailnet(v6: [UInt8](repeating: 0, count: 15) + [1]))
        // Closing a socket under a parked read must *end* that read. This is
        // the crash `readChunk` exists in its current form to avoid — it took
        // the app down on every detach. The regression is a read that never
        // returns, so the read runs on its own thread against a deadline: a
        // self-check that hangs reports nothing at all, in CI least of all.
        final class Outcome: @unchecked Sendable { var ended = false }
        var pair: [Int32] = [0, 0]
        if socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 {
            let socket = StreamSocket(adopting: pair[0])
            let outcome = Outcome()
            let finished = DispatchSemaphore(value: 0)
            Thread {
                outcome.ended = (try? socket.readChunk())?.isEmpty == true
                finished.signal()
            }.start()
            Thread { Thread.sleep(forTimeInterval: 0.05); socket.close() }.start()
            assert(finished.wait(timeout: .now() + 1) == .success,
                   "a read cancelled by close() must end, not park forever")
            assert(outcome.ended, "a read cancelled by close() must end, not raise")
            Darwin.close(pair[1])
        }

        // Read caps: a line splits at the newline and keeps the tail, and a
        // peer that overruns the limit gets an error, not unbounded memory.
        if socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 {
            let socket = StreamSocket(adopting: pair[0])
            _ = Darwin.write(pair[1], "ab\ncd\n", 6)
            let first = try? socket.readLine(limit: 8)
            let second = try? socket.readLine(limit: 8)
            assert(first == .some(Data("ab".utf8)), "readLine must split at the newline")
            assert(second == .some(Data("cd".utf8)), "readLine must keep the tail")
            let flood = [UInt8](repeating: 65, count: 200_000)
            Self.silenceSigPipe(pair[1])  // the reader closes first; the flood must not SIGPIPE
            Thread { Self.floodWrite(pair[1], flood) }.start()
            var capped = false
            do { _ = try socket.readLine(limit: 100) } catch { capped = true }
            assert(capped, "an over-long line must throw")
            socket.close()
        }
        if socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 {
            let socket = StreamSocket(adopting: pair[0])
            let flood = [UInt8](repeating: 65, count: 200_000)
            Self.silenceSigPipe(pair[1])  // the reader closes first; the flood must not SIGPIPE
            Thread { Self.floodWrite(pair[1], flood) }.start()
            var capped = false
            do { _ = try socket.readToEnd(limit: 100) } catch { capped = true }
            assert(capped, "an over-long reply must throw")
            socket.close()
        }

        // A refused TCP connect must *throw*, not hang and not succeed: the
        // phone's whole failure path — "core not reachable" rather than "no
        // sessions" — hangs off this being an error.
        var refused = false
        do { _ = try StreamSocket(host: "127.0.0.1", port: 1) } catch { refused = true }
        assert(refused, "connecting to a closed port must fail")

        // A write to a socket whose peer has gone must *throw*. Without
        // SO_NOSIGPIPE this line does not fail the assert — it kills the
        // process with SIGPIPE, which is the bug.
        if socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 {
            let socket = StreamSocket(adopting: pair[0])
            Darwin.close(pair[1])
            var broke = false
            do { try socket.write(Data("x".utf8)) } catch { broke = true }
            assert(broke, "a write to a departed peer must throw, not signal")
            socket.close()
        }

        // A one-shot call's answer must surface a reset as a reset. The core
        // drops a wrong-account phone unread, so the kernel sends RST, and
        // `FileHandle.readToEnd` turned that into "The file couldn't be
        // opened." — which `ConnectFailure` can never classify. A loopback
        // listener stands in for the core; the client runs on its own thread
        // against a deadline so a hang fails instead of parking.
        func oneShot(reset: Bool, reply: String) -> (data: Data?, why: String?, finished: Bool) {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            guard listener >= 0 else { return (nil, "socket", true) }
            defer { Darwin.close(listener) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(listener, 1) == 0 else { return (nil, "listen", true) }
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) }
            }
            let port = UInt16(bigEndian: addr.sin_port)

            Thread {
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { return }
                if reset {
                    // The request must have arrived (and stay unread) before the
                    // linger-0 close, as in production; otherwise the RST can land
                    // before connect's SO_ERROR read or the write.
                    var b: UInt8 = 0
                    _ = recv(peer, &b, 1, MSG_PEEK)
                    var linger = linger(l_onoff: 1, l_linger: 0)
                    setsockopt(peer, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
                } else {
                    var buf = [UInt8](repeating: 0, count: 64)
                    _ = Darwin.read(peer, &buf, buf.count)
                    _ = reply.withCString { Darwin.write(peer, $0, strlen($0)) }
                }
                Darwin.close(peer)
            }.start()

            final class Box: @unchecked Sendable { var data: Data?; var why: String? }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            Thread {
                do {
                    let client = try StreamSocket(host: "127.0.0.1", port: port)
                    try client.write(Data("{\"method\":\"Config\"}\n".utf8))
                    client.closeWrite()
                    box.data = try client.readToEnd()
                } catch {
                    box.why = error.localizedDescription
                }
                done.signal()
            }.start()
            let finished = done.wait(timeout: .now() + 3) == .success
            return (box.data, box.why, finished)
        }

        let reset = oneShot(reset: true, reply: "")
        assert(reset.finished, "a reset one-shot call must end, not park forever")
        assert(reset.why == Failure.syscall("read", ECONNRESET).localizedDescription,
               "a reset one-shot call must report the reset, not a Cocoa error: \(reset.why ?? "nil")")
        assert(reset.why.flatMap(ConnectFailure.init) == .refused, "a reset must classify as refused")

        let answered = oneShot(reset: false, reply: "{\"ok\":true}\n")
        assert(answered.finished, "an answered one-shot call must end")
        assert(answered.data == Data("{\"ok\":true}\n".utf8), "a normal close must deliver exactly the reply")

        // No unresolvable-host check on purpose: it would call `getaddrinfo`,
        // which has no deadline of its own (`connectWithin`'s 5s starts after
        // resolution), so a resolver that blackholes rather than answering —
        // a captive portal, CI with DNS blocked — parks the selfcheck for its
        // whole retry budget. The refused-connect assert above already pins
        // what the phone's "core not reachable" path needs: failure throws
        // rather than hangs.
    }

    /// Closing is how a read in progress is cancelled — `bytes.lines` is parked
    /// inside `read(2)` and will not notice task cancellation on its own. Safe
    /// to call from another thread and more than once.
    public func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            // `shutdown` and not `handle.close()`: closing frees the fd
            // *number* while a reader is between loading it and calling
            // `read(2)`, and this app opens a fresh socket every 2s for the
            // config poll — so that number is very likely already reissued and
            // the parked read consumes another connection's bytes. Every
            // socket here is a stream socket, so SHUT_RDWR ends the read with
            // 0 just as well, and the descriptor stays ours until `handle`
            // deallocs (`closeOnDealloc`).
            shutdown(handle.fileDescriptor, SHUT_RDWR)
        }
    }
}
