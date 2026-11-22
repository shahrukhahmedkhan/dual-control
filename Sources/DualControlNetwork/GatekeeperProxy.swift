#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// Why the proxy could not reach a server.
    public struct ConnectFailure: Error, Equatable, Sendable {
        /// Why, in plain words.
        public let reason: String
        /// True if the server did not answer in time.
        public let timedOut: Bool

        /// A failure.
        public init(reason: String, timedOut: Bool) {
            self.reason = reason
            self.timedOut = timedOut
        }
    }

    /// Opens the proxy's connection to a server: a connected TCP socket, or why not.
    public typealias ProxyConnector = @Sendable (_ host: String, _ port: Int) -> Result<Int32, ConnectFailure>

    /// The gatekeeper (D7a): an HTTP proxy on 127.0.0.1 that agent processes must use for every connection, since
    /// their sandbox reaches nothing else. It tunnels `CONNECT host:443` and forwards plain `http://` requests (port
    /// 80) to hosts `NetworkPolicy` allows, never looks inside TLS, and reports every attempt and how each allowed
    /// connection ended. Requests without the session token get 407 and are not reported.
    ///
    /// One thread per connection. `stop()` closes the listener and every open connection; a stopped proxy cannot be
    /// started again (make a new one, with a new port and token).
    public final class GatekeeperProxy: @unchecked Sendable {
        /// Connections served at once; more are closed at once.
        public static let maxConnections = 128
        /// Seconds a client has to send its request head.
        static let headTimeout: Int32 = 15
        /// Seconds without a byte either way before a connection is closed.
        static let idleTimeout: Int32 = 300

        private let connect: ProxyConnector
        private let onAttempt: @Sendable (NetworkAttempt) -> Void
        private let onClosed: @Sendable (NetworkTransfer) -> Void
        private let lock = NSLock()
        private var policy: NetworkPolicy
        private var listener: Int32 = -1
        private var wake: [Int32] = [-1, -1]
        private var live: Set<Int32> = []
        private var stopped = false
        private var nextConnection = 1
        private var current: ProxyEndpoint?

        /// A proxy deciding with `policy`. `connect` reaches servers (tests pass their own); the callbacks run on the
        /// proxy's threads.
        public init(
            policy: NetworkPolicy,
            connect: @escaping ProxyConnector = PublicConnector.connect,
            onAttempt: @escaping @Sendable (NetworkAttempt) -> Void,
            onClosed: @escaping @Sendable (NetworkTransfer) -> Void
        ) {
            self.policy = policy
            self.connect = connect
            self.onAttempt = onAttempt
            self.onClosed = onClosed
        }

        /// Where agent processes reach it, once started.
        public var endpoint: ProxyEndpoint? { lock.withLock { current } }

        /// Binds 127.0.0.1 on a port the system picks, with a fresh token, and starts accepting.
        public func start() throws -> ProxyEndpoint {
            try lock.withLock {
                guard !stopped, listener < 0 else { throw ConnectFailure(reason: "already started", timedOut: false) }
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { throw ConnectFailure(reason: "socket: errno \(errno)", timedOut: false) }
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                address.sin_port = 0
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let bound = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
                    }
                }
                guard bound, listen(fd, 128) == 0, pipe(&wake) == 0,
                    let endpoint = ProxyEndpoint(
                        port: UInt16(bigEndian: address.sin_port),
                        token: ProxyEndpoint.newToken()
                    )
                else {
                    close(fd)
                    throw ConnectFailure(reason: "could not listen on 127.0.0.1: errno \(errno)", timedOut: false)
                }
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                listener = fd
                current = endpoint
                let thread = Thread { [self] in acceptLoop(fd, endpoint: endpoint) }
                thread.name = "DualControl.proxy"
                thread.start()
                return endpoint
            }
        }

        /// Decides new connections with `policy` from now on.
        public func update(_ policy: NetworkPolicy) {
            lock.withLock { self.policy = policy }
        }

        /// Closes the listener and every open connection now. Safe to call more than once.
        public func stop() {
            lock.withLock {
                guard !stopped else { return }
                stopped = true
                current = nil
                if wake[1] >= 0 { _ = write(wake[1], "x", 1) }
                for fd in live { shutdown(fd, SHUT_RDWR) }
            }
        }

        private func acceptLoop(_ fd: Int32, endpoint: ProxyEndpoint) {
            defer {
                lock.withLock {
                    close(fd)
                    close(wake[0])
                    close(wake[1])
                    listener = -1
                }
            }
            while true {
                var fds = [
                    pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0),
                ]
                let ready = poll(&fds, 2, -1)
                if ready < 0 && errno == EINTR { continue }
                if ready < 0 || fds[1].revents != 0 || lock.withLock({ stopped }) { return }
                guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                prepare(client)
                let admitted: Int? = lock.withLock {
                    guard !stopped, live.count < Self.maxConnections else { return nil }
                    live.insert(client)
                    defer { nextConnection += 1 }
                    return nextConnection
                }
                guard let number = admitted else {
                    close(client)
                    continue
                }
                let thread = Thread { [self] in
                    serve(client, number: number, endpoint: endpoint)
                    forget(client)
                }
                thread.name = "DualControl.proxy-connection"
                thread.start()
            }
        }

        // MARK: - One connection

        private func serve(_ client: Int32, number: Int, endpoint: ProxyEndpoint) {
            var buffer: [UInt8] = []
            let request: ProxyRequest
            let headLength: Int
            while true {
                do {
                    if case .complete(let parsed, let length) = try ProxyRequest.parse(buffer) {
                        request = parsed
                        headLength = length
                        break
                    }
                } catch {
                    _ = writeAll(client, ProxyResponse.refusal(400, error.description))
                    return
                }
                guard let chunk = readSome(client, timeout: Self.headTimeout) else { return }
                buffer += chunk
            }
            guard request.isAuthorized(by: endpoint) else {
                _ = writeAll(client, ProxyResponse.refusal(407, "proxy authentication required"))
                return
            }
            let started = Date()
            var decision = lock.withLock { policy }.decide(request.kind, host: request.host, port: request.port)
            var framing = BodyFraming.none
            if decision.isAllowed, case .forward = request.kind {
                do { framing = try request.bodyFraming() } catch { decision = .badRequest(error.description) }
            }
            onAttempt(
                NetworkAttempt(
                    connection: number,
                    method: request.method,
                    host: request.host,
                    port: request.port,
                    decision: decision
                )
            )
            guard decision.isAllowed else {
                let status = decision.ruleID == "network.bad-request" ? 400 : 403
                _ = writeAll(client, ProxyResponse.refusal(status, "\(decision.reason) [\(decision.ruleID)]"))
                return
            }
            var counts = (up: 0, down: 0)
            var failure: String?
            defer {
                onClosed(
                    NetworkTransfer(
                        connection: number,
                        host: request.host,
                        port: request.port,
                        bytesUp: counts.up,
                        bytesDown: counts.down,
                        duration: Date().timeIntervalSince(started),
                        failure: failure
                    )
                )
            }
            let upstream: Int32
            switch connect(request.host, request.port) {
            case .failure(let problem):
                failure = problem.reason
                _ = writeAll(client, ProxyResponse.refusal(problem.timedOut ? 504 : 502, problem.reason))
                return
            case .success(let fd):
                upstream = fd
            }
            prepare(upstream)
            guard track(upstream) else {
                close(upstream)
                failure = "the proxy stopped"
                return
            }
            defer { forget(upstream) }
            let rest = Array(buffer[headLength...])
            if case .forward = request.kind {
                counts = forward(request, framing: framing, early: rest, client: client, upstream: upstream)
            } else {
                guard writeAll(client, ProxyResponse.established) else { return }
                counts = tunnel(early: rest, client: client, upstream: upstream)
            }
        }

        /// Raw bytes both ways until both sides are done, either fails or nothing moves for `idleTimeout`.
        private func tunnel(early: [UInt8], client: Int32, upstream: Int32) -> (up: Int, down: Int) {
            var up = 0
            var down = 0
            if !early.isEmpty {
                guard writeAll(upstream, early) else { return (0, 0) }
                up += early.count
            }
            var clientOpen = true
            var upstreamOpen = true
            while clientOpen || upstreamOpen {
                // A side that has ended is left out (fd -1): poll would keep reporting its hang-up.
                var fds = [
                    pollfd(fd: clientOpen ? client : -1, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: upstreamOpen ? upstream : -1, events: Int16(POLLIN), revents: 0),
                ]
                let ready = poll(&fds, 2, Self.idleTimeout * 1000)
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { break }
                if clientOpen, fds[0].revents != 0 {
                    guard let chunk = readNow(client) else { break }
                    if chunk.isEmpty {
                        clientOpen = false
                        shutdown(upstream, SHUT_WR)
                    } else {
                        guard writeAll(upstream, chunk) else { break }
                        up += chunk.count
                    }
                }
                if upstreamOpen, fds[1].revents != 0 {
                    guard let chunk = readNow(upstream) else { break }
                    if chunk.isEmpty {
                        upstreamOpen = false
                        shutdown(client, SHUT_WR)
                    } else {
                        guard writeAll(client, chunk) else { break }
                        down += chunk.count
                    }
                }
            }
            return (up, down)
        }

        /// One plain-HTTP request: the rewritten head, exactly the framed body (anything after it, such as a second
        /// request, is dropped), then the response with its head rewritten to close, until the server closes.
        private func forward(
            _ request: ProxyRequest,
            framing: BodyFraming,
            early: [UInt8],
            client: Int32,
            upstream: Int32
        ) -> (up: Int, down: Int) {
            var up = 0
            var down = 0
            var remaining = 0
            var scanner = ChunkedBodyScanner()
            var bodyDone: Bool
            switch framing {
            case .none: bodyDone = true
            case .length(let length):
                remaining = length
                bodyDone = length == 0
            case .chunked: bodyDone = false
            }
            /// The leading part of `bytes` that belongs to the body; marks the body done at its end.
            func bodyPart(_ bytes: [UInt8]) -> [UInt8]? {
                guard !bodyDone else { return [] }
                switch framing {
                case .none: return []
                case .length:
                    let take = min(remaining, bytes.count)
                    remaining -= take
                    bodyDone = remaining == 0
                    return Array(bytes.prefix(take))
                case .chunked:
                    guard let used = try? scanner.consume(bytes[...]) else { return nil }
                    bodyDone = scanner.isDone
                    return Array(bytes.prefix(used))
                }
            }
            let head = request.forwardedHead()
            guard writeAll(upstream, head), let first = bodyPart(early), writeAll(upstream, first) else {
                return (0, 0)
            }
            up += head.count + first.count
            var rewriter = ResponseHeadRewriter()
            while true {
                // Once the body is complete the client is no longer read: nothing more of it goes upstream.
                var fds = [
                    pollfd(fd: upstream, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: bodyDone ? -1 : client, events: Int16(POLLIN), revents: 0),
                ]
                let ready = poll(&fds, 2, Self.idleTimeout * 1000)
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { break }
                if !bodyDone, fds[1].revents != 0 {
                    guard let chunk = readNow(client), !chunk.isEmpty, let part = bodyPart(chunk),
                        writeAll(upstream, part)
                    else { break }
                    up += part.count
                }
                if fds[0].revents != 0 {
                    guard let chunk = readNow(upstream), !chunk.isEmpty else { break }
                    guard let out = try? rewriter.feed(chunk[...]) else {
                        if down == 0 {
                            _ = writeAll(client, ProxyResponse.refusal(502, "the server's reply is not HTTP"))
                        }
                        break
                    }
                    guard writeAll(client, out) else { break }
                    down += out.count
                }
            }
            return (up, down)
        }

        // MARK: - Socket helpers

        private func track(_ fd: Int32) -> Bool {
            lock.withLock {
                guard !stopped else { return false }
                live.insert(fd)
                return true
            }
        }

        /// Stops tracking `fd` and closes it; `stop()` only ever shuts down tracked descriptors, so a closed number
        /// that is reused elsewhere is never touched.
        private func forget(_ fd: Int32) {
            lock.withLock {
                live.remove(fd)
                close(fd)
            }
        }
    }

    /// No SIGPIPE, close-on-exec, and a send timeout, so a peer that stops reading cannot hold a thread forever.
    func prepare(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// Waits up to `timeout` seconds for bytes; `nil` on timeout, error or end of stream.
    func readSome(_ fd: Int32, timeout: Int32) -> [UInt8]? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&pfd, 1, timeout * 1000)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, let chunk = readNow(fd), !chunk.isEmpty else { return nil }
            return chunk
        }
    }

    /// One read of what is there: empty at end of stream, `nil` on error.
    func readNow(_ fd: Int32) -> [UInt8]? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return nil }
            return Array(chunk[..<count])
        }
    }

    /// Writes all of `bytes`; false on error.
    func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
#endif
