#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// The app's end of the socket. Accepts connections only from processes running as the same uid, reads
    /// newline-delimited requests, and answers each with the handler's result.
    ///
    /// Each connection gets its own thread; at most `maxConnections` run at once and further clients wait in the
    /// listen backlog. Protocol errors are answered once, then the connection is closed. Nothing a client sends can
    /// crash the server.
    public final class IPCServer: @unchecked Sendable {
        /// Answers one request. The caller handle says whether the client is still waiting for the answer.
        public typealias Handler = @Sendable (IPCRequest, IPCCaller) async -> ToolResult

        /// Limits and the peer check.
        public struct Configuration: Sendable {
            /// Seconds a client has to deliver each whole request; an idle connection is closed after this long.
            public var readTimeout: TimeInterval = 10
            /// Seconds to deliver each response.
            public var writeTimeout: TimeInterval = 10
            /// Connections handled at once.
            public var maxConnections = 16
            /// The peer's uid, or `nil` if unknown. Injectable for tests.
            public var peerUID: @Sendable (Int32) -> uid_t? = { PeerCredentials.uid(of: $0) }
            /// The only uid allowed to connect.
            public var allowedUID: uid_t = getuid()

            /// Defaults.
            public init() {}
        }

        private let directory: RunDirectory
        private let configuration: Configuration
        private let handler: Handler
        private let state = NSCondition()
        private var listener: SocketConnection?
        private var wakePipe: (read: Int32, write: Int32)?
        private var acceptThread: Thread?
        private var active = 0
        private var stopping = false
        private var boundInode: ino_t?

        /// Creates a stopped server.
        public init(directory: RunDirectory, configuration: Configuration = .init(), handler: @escaping Handler) {
            self.directory = directory
            self.configuration = configuration
            self.handler = handler
        }

        deinit { stop() }

        /// Starts listening. Re-checks the directory, replaces a stale socket, and refuses to start if another
        /// instance is listening or a non-socket file is in the way.
        public func start() throws {
            state.lock()
            defer { state.unlock() }
            guard listener == nil else { return }
            _ = try RunDirectory.validate(directory.path)
            let path = directory.socketPath
            try removeStaleSocket(at: path)
            let listener = try SocketConnection.listen(at: path)
            var info = stat()
            guard lstat(path, &info) == 0 else { throw IPCError.system("lstat", errno) }
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw IPCError.system("pipe", errno) }
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            self.listener = listener
            self.wakePipe = (fds[0], fds[1])
            self.boundInode = info.st_ino
            self.stopping = false
            let listenFD = listener.fd
            let wakeFD = fds[0]
            let thread = Thread { [self] in acceptLoop(listenFD, wake: wakeFD) }
            thread.name = "DualControlIPC.accept"
            acceptThread = thread
            thread.start()
        }

        /// Stops accepting and removes the socket file. Connections in progress finish on their own.
        public func stop() {
            state.lock()
            guard let listener, let wakePipe else {
                state.unlock()
                return
            }
            stopping = true
            var byte: UInt8 = 1
            _ = write(wakePipe.write, &byte, 1)
            state.broadcast()
            // Wait for the accept loop to leave poll() before closing its descriptors.
            while acceptThread != nil { state.wait() }
            var info = stat()
            if let boundInode, lstat(directory.socketPath, &info) == 0, info.st_ino == boundInode {
                unlink(directory.socketPath)
            }
            listener.close()
            close(wakePipe.read)
            close(wakePipe.write)
            self.listener = nil
            self.wakePipe = nil
            self.boundInode = nil
            state.unlock()
        }

        private func removeStaleSocket(at path: String) throws {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == ENOENT { return }
                throw IPCError.system("lstat", errno)
            }
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw IPCError.notASocket }
            do {
                _ = try SocketConnection.connect(to: path)
                throw IPCError.alreadyRunning
            } catch IPCError.appNotRunning {
                guard unlink(path) == 0 || errno == ENOENT else { throw IPCError.system("unlink", errno) }
            }
        }

        private func acceptLoop(_ listenFD: Int32, wake: Int32) {
            defer {
                state.lock()
                acceptThread = nil
                state.broadcast()
                state.unlock()
            }
            while true {
                state.lock()
                while active >= configuration.maxConnections && !stopping { state.wait() }
                let done = stopping
                state.unlock()
                if done { return }

                var fds = [
                    pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
                ]
                let ready = poll(&fds, 2, -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if fds[1].revents != 0 { return }
                guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
                let fd = accept(listenFD, nil, nil)
                guard fd >= 0 else { continue }  // EAGAIN, ECONNABORTED, EMFILE: try again
                state.lock()
                active += 1
                state.unlock()
                let thread = Thread { [self] in
                    serve(fd)
                    state.lock()
                    active -= 1
                    state.broadcast()
                    state.unlock()
                }
                thread.name = "DualControlIPC.connection"
                thread.start()
            }
        }

        /// Handles one connection until the client closes it, it times out, or it sends something invalid.
        private func serve(_ fd: Int32) {
            guard let uid = configuration.peerUID(fd), uid == configuration.allowedUID else {
                close(fd)  // Drop silently: a stranger learns nothing.
                return
            }
            guard let connection = try? SocketConnection(adopting: fd) else { return }
            while true {
                let line: [UInt8]
                do {
                    guard
                        let next = try connection.readLine(
                            maxBytes: IPCProtocol.maxMessageBytes,
                            timeout: configuration.readTimeout
                        )
                    else { return }
                    line = next
                } catch IPCError.messageTooLarge {
                    reply(
                        IPCResponse(id: "", failure: IPCFailure(code: .tooLarge, message: "message too large")),
                        connection
                    )
                    return
                } catch IPCError.timedOut {
                    reply(
                        IPCResponse(id: "", failure: IPCFailure(code: .timeout, message: "request timed out")),
                        connection
                    )
                    return
                } catch {
                    return
                }
                switch IPCProtocol.decodeRequest(Data(line)) {
                case .failure(let failure):
                    reply(IPCResponse(id: "", failure: failure), connection)
                    return
                case .success(let request):
                    let caller = IPCCaller(connection)
                    let result = run(request, caller)
                    caller.invalidate()
                    guard reply(IPCResponse(id: request.id, result: result), connection, requestID: request.id) else {
                        return
                    }
                }
            }
        }

        /// Runs the async handler from this connection's thread.
        private func run(_ request: IPCRequest, _ caller: IPCCaller) -> ToolResult {
            let box = ResultBox()
            let done = DispatchSemaphore(value: 0)
            let handler = self.handler
            Task {
                box.set(await handler(request, caller))
                done.signal()
            }
            done.wait()
            return box.get() ?? ToolResult(text: "internal error", isError: true)
        }

        /// Sends a response; an unencodable or oversize one becomes an `internalError`. False if the write failed.
        @discardableResult
        private func reply(_ response: IPCResponse, _ connection: SocketConnection, requestID: String = "") -> Bool {
            let data: Data
            if let framed = try? IPCProtocol.frame(response) {
                data = framed
            } else {
                let failure = IPCFailure(code: .internalError, message: "result could not be sent")
                guard let framed = try? IPCProtocol.frame(IPCResponse(id: requestID, failure: failure)) else {
                    return false
                }
                data = framed
            }
            do {
                try connection.write(Array(data), timeout: configuration.writeTimeout)
                return true
            } catch {
                return false
            }
        }
    }

    /// The client of one request, while its answer is being worked out.
    public final class IPCCaller: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32

        init(_ connection: SocketConnection) {
            fd = connection.fd
        }

        /// True while the client still holds the connection open. Peeks without reading, so the request stream is
        /// untouched. Always false once the call has been answered.
        public var isConnected: Bool {
            lock.withLock {
                // The serving thread owns the descriptor and keeps it open until `invalidate`, which takes this lock.
                guard fd >= 0 else { return false }
                var byte: UInt8 = 0
                let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if count > 0 { return true }
                return count < 0 && (errno == EAGAIN || errno == EINTR)
            }
        }

        func invalidate() {
            lock.withLock { fd = -1 }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: ToolResult?

        func set(_ value: ToolResult) { lock.withLock { result = value } }
        func get() -> ToolResult? { lock.withLock { result } }
    }
#endif
