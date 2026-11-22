#if canImport(Darwin)
    import Darwin
    import DualControlCore

    /// The proxy's real connections: it resolves the name itself, skips every address `NetworkAddress` forbids, and
    /// connects to an address it checked, so DNS cannot point an allowed name at this machine or the local network.
    public enum PublicConnector {
        /// Seconds to wait for each address to answer.
        public static let timeoutSeconds: Int32 = 10

        /// A connected socket to `host:port`, or why not.
        @Sendable public static func connect(host: String, port: Int) -> Result<Int32, ConnectFailure> {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else {
                return .failure(ConnectFailure(reason: "the host name could not be resolved", timedOut: false))
            }
            defer { freeaddrinfo(list) }
            var sawForbidden = false
            var timedOut = false
            var cursor: UnsafeMutablePointer<addrinfo>? = list
            while let entry = cursor {
                cursor = entry.pointee.ai_next
                guard let address = entry.pointee.ai_addr, let bytes = addressBytes(address) else { continue }
                if NetworkAddress.isForbidden(bytes) {
                    sawForbidden = true
                    continue
                }
                switch attempt(entry.pointee) {
                case .some(let fd): return .success(fd)
                case .none where errno == ETIMEDOUT: timedOut = true
                case .none: break
                }
            }
            if sawForbidden && !timedOut {
                return .failure(
                    ConnectFailure(reason: "it resolves only to local or private addresses", timedOut: false)
                )
            }
            return .failure(
                ConnectFailure(
                    reason: timedOut ? "the server did not answer" : "the server refused",
                    timedOut: timedOut
                )
            )
        }

        /// The address as 4 or 16 bytes in network order.
        static func addressBytes(_ address: UnsafeMutablePointer<sockaddr>) -> [UInt8]? {
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
                }
            case AF_INET6:
                return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                }
            default:
                return nil
            }
        }

        /// A connected, blocking socket, or `nil` with errno set (ETIMEDOUT after `timeoutSeconds`).
        private static func attempt(_ entry: addrinfo) -> Int32? {
            let fd = socket(entry.ai_family, entry.ai_socktype, entry.ai_protocol)
            guard fd >= 0 else { return nil }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var connected = Darwin.connect(fd, entry.ai_addr, entry.ai_addrlen) == 0
            if !connected && errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                var ready: Int32
                repeat { ready = poll(&pfd, 1, timeoutSeconds * 1000) } while ready < 0 && errno == EINTR
                if ready == 0 {
                    close(fd)
                    errno = ETIMEDOUT
                    return nil
                }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                connected = ready > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
                if !connected { errno = error }
            }
            guard connected else {
                let saved = errno
                close(fd)
                errno = saved
                return nil
            }
            _ = fcntl(fd, F_SETFL, flags)
            return fd
        }
    }
#endif
