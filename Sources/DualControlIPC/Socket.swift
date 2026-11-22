#if canImport(Darwin)
    import Darwin
    import Foundation

    /// Errors from the local socket layer.
    public enum IPCError: Error, Equatable, Sendable {
        /// The run directory is missing protections; the message says which.
        case unsafeDirectory(String)
        /// The socket path does not fit in `sockaddr_un`.
        case pathTooLong
        /// Another app instance is already listening.
        case alreadyRunning
        /// Something other than a socket sits at the socket path; it is left alone.
        case notASocket
        /// Nobody is listening: the app is closed.
        case appNotRunning
        /// The other side did not finish a message in time.
        case timedOut
        /// A message exceeded `IPCProtocol.maxMessageBytes`.
        case messageTooLarge
        /// The other side closed the connection mid-message or before answering.
        case connectionClosed
        /// The other side sent something that is not a valid message.
        case malformed(String)
        /// A system call failed with `errno`.
        case system(String, Int32)
    }

    /// The private directory holding the socket. Every user of it checks it first.
    public struct RunDirectory: Sendable, Equatable {
        /// Absolute path of the directory.
        public let path: String

        /// Socket file inside the directory.
        public var socketPath: String { path + "/dualcontrol.sock" }

        /// `~/Library/Application Support/DualControl/run` for the current user.
        public static var defaultPath: String {
            let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
            return home + "/Library/Application Support/DualControl/run"
        }

        /// Creates the directory with mode 0700 if it is missing (parents too), then validates it. An existing
        /// directory with the wrong mode is refused, not repaired.
        public static func prepare(_ path: String) throws -> RunDirectory {
            var info = stat()
            if lstat(path, &info) != 0 {
                guard errno == ENOENT else { throw IPCError.system("lstat", errno) }
                let parent = (path as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(
                    atPath: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw IPCError.system("mkdir", errno) }
                // mkdir applies the umask; set the exact mode on the directory just created.
                guard chmod(path, 0o700) == 0 else { throw IPCError.system("chmod", errno) }
            }
            return try validate(path)
        }

        /// Checks that `path` is a real directory (not a symlink), owned by `owner`, with mode exactly 0700.
        public static func validate(_ path: String, owner: uid_t = getuid()) throws -> RunDirectory {
            guard path.hasPrefix("/"), !path.contains("\0") else { throw IPCError.unsafeDirectory("not absolute") }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == ENOENT { throw IPCError.appNotRunning }
                throw IPCError.system("lstat", errno)
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw IPCError.unsafeDirectory("not a directory or is a symlink")
            }
            guard info.st_uid == owner else {
                throw IPCError.unsafeDirectory("owned by uid \(info.st_uid), expected \(owner)")
            }
            let mode = info.st_mode & 0o7777
            guard mode == 0o700 else {
                throw IPCError.unsafeDirectory("mode is \(String(mode, radix: 8)), expected 700")
            }
            return RunDirectory(path: path)
        }
    }

    /// Reads the uid of the process at the other end of a Unix socket.
    public enum PeerCredentials {
        /// The peer's effective uid, or `nil` if the kernel cannot tell.
        public static func uid(of fd: Int32) -> uid_t? {
            var uid: uid_t = 0
            var gid: gid_t = 0
            return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        }
    }

    /// One Unix stream socket. Non-blocking; every read and write has a deadline. Not thread-safe: one owner.
    ///
    /// The connection owns its descriptor from `init` on and closes it exactly once, in `close()` or `deinit`.
    /// Nothing else may close `fd`: a second close() can hit a number the kernel has already reused for another
    /// connection.
    final class SocketConnection {
        let fd: Int32
        private var buffer: [UInt8] = []
        private var isClosed = false

        /// Takes ownership of `fd`, even if configuring it fails (then it is closed once, by `deinit`).
        init(adopting fd: Int32) throws {
            self.fd = fd
            var on: Int32 = 1
            // Every stored property is set, so throwing here runs deinit, which closes fd.
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                throw IPCError.system("configure socket", errno)
            }
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                // Darwin answers EINVAL once the peer has hung up, e.g. a server dropping a stranger.
                if errno == EINVAL { throw IPCError.connectionClosed }
                throw IPCError.system("configure socket", errno)
            }
        }

        deinit { close() }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(fd)
        }

        /// Connects to a listening socket. Nobody listening → `appNotRunning`.
        static func connect(to path: String) throws -> SocketConnection {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw IPCError.system("socket", errno) }
            let result = try withAddress(path) { Darwin.connect(fd, $0, $1) }
            guard result == 0 else {
                let error = errno
                Darwin.close(fd)
                if error == ENOENT || error == ECONNREFUSED { throw IPCError.appNotRunning }
                throw IPCError.system("connect", error)
            }
            return try SocketConnection(adopting: fd)
        }

        /// Binds and listens at `path`; the caller has made sure nothing is there.
        static func listen(at path: String, backlog: Int32 = 32) throws -> SocketConnection {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw IPCError.system("socket", errno) }
            let connection = try SocketConnection(adopting: fd)
            guard try withAddress(path, { bind(fd, $0, $1) }) == 0 else { throw IPCError.system("bind", errno) }
            // The directory is already 0700; this is the second wall.
            guard chmod(path, 0o600) == 0 else { throw IPCError.system("chmod", errno) }
            guard Darwin.listen(fd, backlog) == 0 else { throw IPCError.system("listen", errno) }
            return connection
        }

        /// Reads one newline-terminated message, without the newline. `nil` on a clean close before any byte.
        /// The whole message must arrive within `timeout` seconds, so a slow sender cannot hold the connection.
        func readLine(maxBytes: Int, timeout: TimeInterval) throws -> [UInt8]? {
            let deadline = Deadline(timeout)
            var scanned = 0
            while true {
                if let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                    let line = Array(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard line.count <= maxBytes else { throw IPCError.messageTooLarge }
                    return line
                }
                scanned = buffer.count
                guard buffer.count <= maxBytes else { throw IPCError.messageTooLarge }
                try wait(for: Int16(POLLIN), until: deadline)
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    buffer.append(contentsOf: chunk[..<count])
                } else if count == 0 {
                    if buffer.isEmpty { return nil }
                    throw IPCError.connectionClosed
                } else if errno != EAGAIN && errno != EINTR {
                    if errno == ECONNRESET || errno == ENOTCONN { throw IPCError.connectionClosed }
                    throw IPCError.system("read", errno)
                }
            }
        }

        /// Writes all bytes within `timeout` seconds.
        func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
            let deadline = Deadline(timeout)
            var offset = 0
            while offset < bytes.count {
                try wait(for: Int16(POLLOUT), until: deadline)
                let count = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if count >= 0 {
                    offset += count
                } else if errno != EAGAIN && errno != EINTR {
                    if errno == EPIPE || errno == ECONNRESET || errno == ENOTCONN { throw IPCError.connectionClosed }
                    throw IPCError.system("write", errno)
                }
            }
        }

        /// Waits until the socket is ready for `events` or the deadline passes.
        private func wait(for events: Int16, until deadline: Deadline) throws {
            while true {
                let remaining = deadline.remainingMilliseconds
                guard remaining > 0 else { throw IPCError.timedOut }
                var pfd = pollfd(fd: fd, events: events, revents: 0)
                let ready = poll(&pfd, 1, remaining)
                if ready > 0 { return }
                if ready < 0 && errno != EINTR { throw IPCError.system("poll", errno) }
            }
        }

        private static func withAddress(
            _ path: String,
            _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
        ) throws -> Int32 {
            var address = sockaddr_un()
            let bytes = Array(path.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard !bytes.contains(0), bytes.count < capacity else { throw IPCError.pathTooLong }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
    }

    /// A point in monotonic time.
    struct Deadline {
        let end: UInt64

        init(_ seconds: TimeInterval) {
            end = clock_gettime_nsec_np(CLOCK_MONOTONIC) + UInt64(max(0, seconds) * 1_000_000_000)
        }

        var remainingMilliseconds: Int32 {
            let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
            guard end > now else { return 0 }
            return Int32(clamping: (end - now + 999_999) / 1_000_000)
        }
    }
#endif
