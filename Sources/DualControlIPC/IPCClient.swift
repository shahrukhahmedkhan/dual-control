#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// The shim's end of the socket: one connection per call.
    public struct IPCClient: Sendable {
        /// The run directory; checked before every call.
        public var directory: String
        /// The only uid the app may run as.
        public var serverUID: uid_t = getuid()
        /// Seconds to send the request.
        public var writeTimeout: TimeInterval = 10
        /// Seconds to wait for the answer: the longest approval wait, then the longest command, plus a minute.
        public var responseTimeout: TimeInterval = 840 + 3600 + 60

        /// A client for the run directory at `directory`.
        public init(directory: String = RunDirectory.defaultPath) {
            self.directory = directory
        }

        /// Sends one request and waits for its response. Throws `IPCError.appNotRunning` if nobody is listening, and
        /// `CancellationError` once `hangUp` has been cancelled.
        public func call(_ request: IPCRequest, hangUp: HangUp = HangUp()) throws -> IPCResponse {
            let run = try RunDirectory.validate(directory)
            let connection = try SocketConnection.connect(to: run.socketPath)
            guard hangUp.attach(connection.fd) else {
                connection.close()
                throw CancellationError()
            }
            defer {
                hangUp.detach()
                connection.close()
            }
            guard PeerCredentials.uid(of: connection.fd) == serverUID else {
                throw IPCError.unsafeDirectory("socket is served by another user")
            }
            let framed: Data
            do {
                framed = try IPCProtocol.frame(request)
            } catch {
                throw IPCError.messageTooLarge
            }
            let line: [UInt8]?
            do {
                try connection.write(Array(framed), timeout: writeTimeout)
                line = try connection.readLine(maxBytes: IPCProtocol.maxMessageBytes, timeout: responseTimeout)
            } catch {
                throw hangUp.isCancelled ? CancellationError() : error
            }
            guard !hangUp.isCancelled else { throw CancellationError() }
            guard let line else { throw IPCError.connectionClosed }
            switch IPCProtocol.decodeResponse(Data(line), requestID: request.id) {
            case .success(let response):
                return response
            case .failure(let failure):
                // A protocol error the server sent before it could read our id.
                if let response = try? JSONDecoder().decode(IPCResponse.self, from: Data(line)),
                    response.id.isEmpty, response.result == nil, response.failure != nil
                {
                    return response
                }
                throw IPCError.malformed(failure.message)
            }
        }

        /// `call(_:)` on a background thread, so a long wait does not block Swift's cooperative pool. Cancelling the
        /// task hangs up at once: the app sees its caller leave, withdraws what waits and kills what runs.
        public func send(_ request: IPCRequest) async throws -> IPCResponse {
            let hangUp = HangUp()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global().async {
                        continuation.resume(with: Result { try call(request, hangUp: hangUp) })
                    }
                }
            } onCancel: {
                hangUp.cancel()
            }
        }

        /// Lets another thread end a call: `cancel` shuts the connection down, which wakes the waiting read. It never
        /// closes the descriptor, so it cannot hit a number the kernel has reused; only the call's owner closes it.
        public final class HangUp: @unchecked Sendable {
            private let lock = NSLock()
            private var fd: Int32 = -1
            private var cancelled = false

            /// A hang-up that has not been cancelled.
            public init() {}

            /// True once `cancel` was called.
            public var isCancelled: Bool { lock.withLock { cancelled } }

            /// Ends the call now, or as soon as it connects.
            public func cancel() {
                lock.withLock {
                    cancelled = true
                    if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) }
                }
            }

            /// Starts watching `fd`; false if already cancelled.
            func attach(_ fd: Int32) -> Bool {
                lock.withLock {
                    guard !cancelled else { return false }
                    self.fd = fd
                    return true
                }
            }

            /// Stops watching, before the descriptor is closed.
            func detach() {
                lock.withLock { fd = -1 }
            }
        }
    }
#endif
