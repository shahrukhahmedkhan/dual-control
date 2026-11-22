#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// Opens the forwarder's socket to its device, connected (TCP or UDP), or says why not.
    public typealias LANConnector = @Sendable (_ endpoint: LANEndpoint) -> Result<Int32, ConnectFailure>

    /// One approved LAN endpoint (D7b): listens on 127.0.0.1, on a port the system picks, and passes everything to
    /// and from that one device. Agent processes reach the device only through it: their sandbox allows this port
    /// and no remote address. It reports every connection like the gatekeeper does (`NetworkAttempt`, method `TCP`
    /// or `UDP`, rule `lan.endpoint`, then `NetworkTransfer`). Other local users' processes could use it too, but
    /// they can reach the device directly anyway; the forwarder only gives the sandboxed agent what the owner
    /// approved.
    ///
    /// TCP: one thread per connection, at most `maxConnections`. UDP: one socket connected to the device; replies go
    /// to whoever sent the last datagram, and the transfer is reported when the forwarder stops. Never broadcasts:
    /// the endpoint is a unicast address and `SO_BROADCAST` is never set. `stop()` closes everything; a stopped
    /// forwarder cannot be started again.
    public final class LANForwarder: @unchecked Sendable {
        /// TCP connections served at once; more are closed at once.
        public static let maxConnections = 32
        /// Seconds without a byte either way before a TCP connection is closed.
        static let idleTimeout: Int32 = 300

        /// The device.
        public let endpoint: LANEndpoint
        private let connect: LANConnector
        private let onAttempt: @Sendable (NetworkAttempt) -> Void
        private let onClosed: @Sendable (NetworkTransfer) -> Void
        private let lock = NSLock()
        private var listener: Int32 = -1
        private var device: Int32 = -1
        private var live: Set<Int32> = []
        private var stopped = false
        private var port: UInt16 = 0
        private var udp: (connection: Int, up: Int, down: Int, started: Date)?

        /// A forwarder to `endpoint`. `connect` reaches the device (tests pass their own); the callbacks run on the
        /// forwarder's threads.
        public init(
            endpoint: LANEndpoint,
            connect: @escaping LANConnector = LANForwarder.connectToDevice,
            onAttempt: @escaping @Sendable (NetworkAttempt) -> Void,
            onClosed: @escaping @Sendable (NetworkTransfer) -> Void
        ) {
            self.endpoint = endpoint
            self.connect = connect
            self.onAttempt = onAttempt
            self.onClosed = onClosed
        }

        /// The port on 127.0.0.1, once started.
        public var localPort: UInt16 { lock.withLock { port } }

        /// Binds 127.0.0.1 and starts forwarding; returns the port.
        public func start() throws -> UInt16 {
            let tcp = endpoint.transport == .tcp
            let fd = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, tcp ? IPPROTO_TCP : IPPROTO_UDP)
            guard fd >= 0 else { throw ConnectFailure(reason: "socket: errno \(errno)", timedOut: false) }
            var address = Self.loopback(port: 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
                }
            }
            guard bound, !tcp || listen(fd, 16) == 0 else {
                close(fd)
                throw ConnectFailure(reason: "bind: errno \(errno)", timedOut: false)
            }
            var deviceSocket: Int32 = -1
            if !tcp {
                switch connect(endpoint) {
                case .success(let socket): deviceSocket = socket
                case .failure(let failure):
                    close(fd)
                    throw failure
                }
            }
            let chosen = UInt16(bigEndian: address.sin_port)
            try lock.withLock {
                guard !stopped, listener < 0 else {
                    close(fd)
                    if deviceSocket >= 0 { close(deviceSocket) }
                    throw ConnectFailure(reason: "already started", timedOut: false)
                }
                listener = fd
                device = deviceSocket
                port = chosen
            }
            let thread = Thread { [self] in tcp ? acceptLoop(fd) : datagramLoop(fd, deviceSocket) }
            thread.stackSize = 1 << 18
            thread.start()
            return chosen
        }

        /// Closes the listener, the device socket and every open connection.
        public func stop() {
            let (fds, finished): ([Int32], (connection: Int, up: Int, down: Int, started: Date)?) = lock.withLock {
                stopped = true
                let fds = [listener, device].filter { $0 >= 0 } + Array(live)
                listener = -1
                device = -1
                live = []
                defer { udp = nil }
                return (fds, udp)
            }
            for fd in fds {
                shutdown(fd, SHUT_RDWR)
                close(fd)
            }
            if let finished {
                onClosed(transfer(finished.connection, up: finished.up, down: finished.down, since: finished.started))
            }
        }

        // MARK: - TCP

        private func acceptLoop(_ fd: Int32) {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                let admitted = lock.withLock {
                    guard !stopped, live.count < Self.maxConnections else { return false }
                    live.insert(client)
                    return true
                }
                guard admitted else {
                    close(client)
                    continue
                }
                let thread = Thread { [self] in serve(client) }
                thread.stackSize = 1 << 18
                thread.start()
            }
        }

        private func serve(_ client: Int32) {
            let number = LANConnectionNumbers.shared.next()
            let started = Date()
            onAttempt(attempt(number, method: "TCP"))
            var up = 0
            var down = 0
            var failure: String?
            switch connect(endpoint) {
            case .failure(let why):
                failure = why.reason
            case .success(let server):
                if lock.withLock({ stopped ? false : live.insert(server).inserted }) {
                    relay(client, server, up: &up, down: &down)
                }
                lock.withLock { _ = live.remove(server) }
                close(server)
            }
            lock.withLock { _ = live.remove(client) }
            close(client)
            onClosed(transfer(number, up: up, down: down, since: started, failure: failure))
        }

        /// Copies both ways until both sides have ended, either errs, or nothing moves for `idleTimeout`. An end
        /// from one side is passed on as a half-close (a request sent, then the reply read).
        private func relay(_ client: Int32, _ server: Int32, up: inout Int, down: inout Int) {
            var fds = [
                pollfd(fd: client, events: Int16(POLLIN), revents: 0),
                pollfd(fd: server, events: Int16(POLLIN), revents: 0),
            ]
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while fds[0].fd >= 0 || fds[1].fd >= 0 {
                let ready = poll(&fds, 2, Self.idleTimeout * 1000)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { return }
                for index in 0..<2 where fds[index].fd >= 0 && fds[index].revents != 0 {
                    let from = fds[index].fd
                    let to = index == 0 ? server : client
                    let count = read(from, &buffer, buffer.count)
                    if count == 0 {
                        shutdown(to, SHUT_WR)
                        fds[index].fd = -1
                        continue
                    }
                    guard count > 0, Self.writeAll(to, buffer, count) else { return }
                    if index == 0 { up += count } else { down += count }
                }
            }
        }

        // MARK: - UDP

        private func datagramLoop(_ local: Int32, _ server: Int32) {
            var fds = [
                pollfd(fd: local, events: Int16(POLLIN), revents: 0),
                pollfd(fd: server, events: Int16(POLLIN), revents: 0),
            ]
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            var client = sockaddr_in()
            var hasClient = false
            while true {
                let ready = poll(&fds, 2, -1)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0, !lock.withLock({ stopped }) else { return }
                if fds[0].revents != 0 {
                    var from = sockaddr_in()
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let count = withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(local, &buffer, buffer.count, 0, $0, &length)
                        }
                    }
                    guard count >= 0 else { return }
                    client = from
                    hasClient = true
                    let first = lock.withLock { () -> Int? in
                        if udp == nil {
                            let number = LANConnectionNumbers.shared.next()
                            udp = (number, 0, 0, Date())
                            return number
                        }
                        return nil
                    }
                    if let first { onAttempt(attempt(first, method: "UDP")) }
                    if send(server, buffer, count, 0) == count { lock.withLock { udp?.up += count } }
                }
                if fds[1].revents != 0 {
                    let count = recv(server, &buffer, buffer.count, 0)
                    guard count >= 0 else { return }
                    guard hasClient else { continue }
                    let sent = withUnsafePointer(to: &client) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(local, buffer, count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    if sent == count { lock.withLock { udp?.down += count } }
                }
            }
        }

        // MARK: - Reports

        private func attempt(_ number: Int, method: String) -> NetworkAttempt {
            NetworkAttempt(
                connection: number,
                method: method,
                host: endpoint.host,
                port: Int(endpoint.port),
                decision: .lanEndpoint
            )
        }

        private func transfer(_ number: Int, up: Int, down: Int, since: Date, failure: String? = nil)
            -> NetworkTransfer
        {
            NetworkTransfer(
                connection: number,
                host: endpoint.host,
                port: Int(endpoint.port),
                bytesUp: up,
                bytesDown: down,
                duration: Date().timeIntervalSince(since),
                failure: failure
            )
        }

        // MARK: - Sockets

        static func loopback(port: UInt16) -> sockaddr_in {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            return address
        }

        static func writeAll(_ fd: Int32, _ buffer: [UInt8], _ count: Int) -> Bool {
            var offset = 0
            while offset < count {
                let written = buffer[offset..<count].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }

        /// Connects to the device itself: its IPv4 address and port, TCP within 5 seconds, or a connected UDP socket.
        /// The address is a checked private unicast one (`LANEndpoint.parse`); no name is ever resolved.
        public static func connectToDevice(_ endpoint: LANEndpoint) -> Result<Int32, ConnectFailure> {
            let tcp = endpoint.transport == .tcp
            let fd = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, tcp ? IPPROTO_TCP : IPPROTO_UDP)
            guard fd >= 0 else { return .failure(ConnectFailure(reason: "socket: errno \(errno)", timedOut: false)) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = endpoint.port.bigEndian
            guard inet_pton(AF_INET, endpoint.host, &address.sin_addr) == 1 else {
                close(fd)
                return .failure(ConnectFailure(reason: "not an IPv4 address", timedOut: false))
            }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let started = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if started != 0, errno == EINPROGRESS {
                var wait = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)]
                let ready = poll(&wait, 1, 5000)
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                guard ready > 0, error == 0 else {
                    close(fd)
                    return .failure(
                        ConnectFailure(
                            reason: ready == 0 ? "the device did not answer" : String(cString: strerror(error)),
                            timedOut: ready == 0
                        )
                    )
                }
            } else if started != 0 {
                let reason = String(cString: strerror(errno))
                close(fd)
                return .failure(ConnectFailure(reason: reason, timedOut: false))
            }
            _ = fcntl(fd, F_SETFL, flags)
            return .success(fd)
        }
    }

    /// Numbers for LAN connections in the audit log, above the gatekeeper's, so the two never collide.
    final class LANConnectionNumbers: @unchecked Sendable {
        static let shared = LANConnectionNumbers()
        private let lock = NSLock()
        private var last = 1_000_000

        func next() -> Int {
            lock.withLock {
                last += 1
                return last
            }
        }
    }
#endif
