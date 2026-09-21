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

        public var errorDescription: String? {
            switch self {
            case let .syscall(what, code):
                return "\(what): \(String(cString: strerror(code)))"
            case let .pathTooLong(path):
                return "socket path is too long for sockaddr_un: \(path)"
            case let .unresolved(host, why):
                return "cannot resolve \(host): \(why)"
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
        var candidate = Optional(first)
        while let info = candidate {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
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
        throw Failure.syscall("connect \(host):\(port)", lastErrno)
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
    public func readToEnd() throws -> Data {
        try handle.readToEnd() ?? Data()
    }

    /// Line-delimited reads, for the `Watch` stream. Go's `json.Encoder.Encode`
    /// terminates every object with a newline, which is what makes this work.
    public var lines: AsyncLineSequence<FileHandle.AsyncBytes> {
        handle.bytes.lines
    }

    public static func demo() {
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
