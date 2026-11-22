#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlIPC

    /// A fresh directory under /tmp (short, so socket paths fit in `sun_path`), removed at the end.
    final class TempDir {
        let path: String

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            guard let made = mkdtemp(&template) else { throw IPCError.system("mkdtemp", errno) }
            path = String(cString: made)
        }

        deinit { try? FileManager.default.removeItem(atPath: path) }

        var run: String { path + "/run" }
    }

    private func mode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    private let echoHandler: IPCServer.Handler = { request, _ in
        ToolResult(text: "\(request.tool):\(request.id)", isError: false)
    }

    private func startServer(
        _ dir: TempDir,
        configuration: IPCServer.Configuration = .init(),
        handler: @escaping IPCServer.Handler = echoHandler
    ) throws -> IPCServer {
        let server = IPCServer(
            directory: try RunDirectory.prepare(dir.run),
            configuration: configuration,
            handler: handler
        )
        try server.start()
        return server
    }

    /// Raw connection for sending arbitrary bytes.
    private func connect(_ dir: TempDir) throws -> SocketConnection {
        try SocketConnection.connect(to: RunDirectory.validate(dir.run).socketPath)
    }

    // Swift Testing runs tests on the cooperative pool, which is only as wide as the core count. The server's
    // handler needs a pool thread too, so tests must never block one: every blocking socket call goes through
    // `offPool`, and client calls use the Dispatch-backed `send`.
    extension SocketConnection: @unchecked Sendable {}

    /// Each call gets a thread of its own: Dispatch's global queues can be starved by other tests on a busy machine.
    private func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
        }
    }

    private func write(_ connection: SocketConnection, _ bytes: [UInt8]) async throws {
        try await offPool { try connection.write(bytes, timeout: 5) }
    }

    private func readResponse(_ connection: SocketConnection) async throws -> IPCResponse? {
        let line = try await offPool { try connection.readLine(maxBytes: IPCProtocol.maxMessageBytes, timeout: 5) }
        guard let line else { return nil }
        return try JSONDecoder().decode(IPCResponse.self, from: Data(line))
    }

    // MARK: - Run directory

    @Test func prepareCreatesPrivateDirectory() async throws {
        let dir = try TempDir()
        let run = try RunDirectory.prepare(dir.run)
        #expect(mode(dir.run) == 0o700)
        #expect(run.socketPath == dir.run + "/dualcontrol.sock")
        _ = try RunDirectory.prepare(dir.run)  // idempotent
    }

    @Test(arguments: [mode_t(0o755), 0o750, 0o701, 0o777, 0o1700, 0o500])
    func wrongDirectoryModeIsRefused(_ bad: mode_t) async throws {
        let dir = try TempDir()
        #expect(mkdir(dir.run, 0o700) == 0)
        #expect(chmod(dir.run, bad) == 0)
        #expect(throws: IPCError.unsafeDirectory("mode is \(String(bad, radix: 8)), expected 700")) {
            try RunDirectory.prepare(dir.run)
        }
        #expect(mode(dir.run) == bad)  // never "fixed" silently
        _ = chmod(dir.run, 0o700)
    }

    @Test func symlinkedDirectoryIsRefused() async throws {
        let dir = try TempDir()
        let real = dir.path + "/real"
        #expect(mkdir(real, 0o700) == 0)
        #expect(symlink(real, dir.run) == 0)
        #expect(throws: IPCError.unsafeDirectory("not a directory or is a symlink")) {
            try RunDirectory.prepare(dir.run)
        }
    }

    @Test func regularFileInPlaceOfDirectoryIsRefused() async throws {
        let dir = try TempDir()
        #expect(FileManager.default.createFile(atPath: dir.run, contents: nil))
        #expect(throws: IPCError.unsafeDirectory("not a directory or is a symlink")) {
            try RunDirectory.prepare(dir.run)
        }
    }

    @Test func wrongOwnerIsRefused() async throws {
        let dir = try TempDir()
        #expect(mkdir(dir.run, 0o700) == 0)
        #expect(throws: IPCError.unsafeDirectory("owned by uid \(getuid()), expected \(getuid() + 1)")) {
            try RunDirectory.validate(dir.run, owner: getuid() + 1)
        }
    }

    @Test func overlongSocketPathIsRefused() async throws {
        let dir = try TempDir()
        let deep = try RunDirectory.prepare(dir.path + "/" + String(repeating: "d", count: 100))
        #expect(throws: IPCError.pathTooLong) { try IPCServer(directory: deep, handler: echoHandler).start() }
        await #expect(throws: IPCError.pathTooLong) {
            try await IPCClient(directory: deep.path).send(IPCRequest(id: "1", tool: "s"))
        }
    }

    // MARK: - Server lifecycle

    @Test func socketIsOwnerOnlyAndRemovedOnStop() async throws {
        let dir = try TempDir()
        let server = try startServer(dir)
        #expect(mode(dir.run + "/dualcontrol.sock") == 0o600)
        server.stop()
        #expect(mode(dir.run + "/dualcontrol.sock") == nil)
    }

    @Test func staleSocketIsReplaced() async throws {
        let dir = try TempDir()
        let path = try RunDirectory.prepare(dir.run).socketPath
        // Bind and close without unlinking, like a crashed app.
        let stale = try SocketConnection.listen(at: path)
        stale.close()
        #expect(mode(path) != nil)
        // A process another test spawns at this moment briefly holds a copy of every descriptor (posix_spawn copies
        // the table before exec closes them), keeping the closed listener alive. A crashed app's socket has no such
        // copy, so wait until it is really dead, as it would be.
        for _ in 0..<200 {
            guard (try? SocketConnection.connect(to: path)) != nil else { break }
            usleep(5_000)
        }
        #expect(throws: IPCError.appNotRunning) { try SocketConnection.connect(to: path) }
        let server = try startServer(dir)
        defer { server.stop() }
        let response = try await IPCClient(directory: dir.run).send(IPCRequest(id: "1", tool: "status"))
        #expect(response.result?.text == "status:1")
    }

    @Test func secondServerIsRefusedWhileFirstRuns() async throws {
        let dir = try TempDir()
        let first = try startServer(dir)
        defer { first.stop() }
        #expect(throws: IPCError.alreadyRunning) { try startServer(dir) }
        #expect(try await IPCClient(directory: dir.run).send(IPCRequest(id: "2", tool: "x")).result?.text == "x:2")
    }

    @Test func nonSocketFileAtSocketPathIsRefused() async throws {
        let dir = try TempDir()
        let path = try RunDirectory.prepare(dir.run).socketPath
        #expect(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)))
        #expect(throws: IPCError.notASocket) { try startServer(dir) }
        #expect(FileManager.default.contents(atPath: path) == Data("x".utf8))
    }

    // MARK: - Framing

    @Test func severalRequestsOnOneConnection() async throws {
        let dir = try TempDir()
        let server = try startServer(dir)
        defer { server.stop() }
        let connection = try connect(dir)
        let both =
            try IPCProtocol.frame(IPCRequest(id: "a", tool: "t")) + IPCProtocol.frame(IPCRequest(id: "b", tool: "u"))
        try await write(connection, Array(both))
        #expect(try await readResponse(connection)?.result?.text == "t:a")
        #expect(try await readResponse(connection)?.result?.text == "u:b")
    }

    @Test func malformedInputGetsErrorAndServerSurvives() async throws {
        let dir = try TempDir()
        let server = try startServer(dir)
        defer { server.stop() }
        for garbage in [
            "not json\n", "{}\n", "\n", "\u{0}\u{1}\u{FF}\n",
            #"{"version":2,"id":"1","tool":"s","arguments":{}}"# + "\n",
        ] {
            let connection = try connect(dir)
            try await write(connection, Array(garbage.utf8))
            let response = try #require(try await readResponse(connection))
            #expect(response.result == nil)
            #expect(response.failure?.code == .malformed || response.failure?.code == .unsupportedVersion)
            #expect(try await readResponse(connection) == nil)  // closed after a protocol error
        }
        #expect(try await IPCClient(directory: dir.run).send(IPCRequest(id: "ok", tool: "s")).result?.text == "s:ok")
    }

    @Test func invalidUTF8IsMalformed() async throws {
        let dir = try TempDir()
        let server = try startServer(dir)
        defer { server.stop() }
        let connection = try connect(dir)
        try await write(connection, [0x7B, 0xC3, 0x28, 0x7D, 0x0A])
        #expect(try await readResponse(connection)?.failure?.code == .malformed)
    }

    @Test func oversizeMessageIsRejected() async throws {
        let dir = try TempDir()
        let server = try startServer(dir)
        defer { server.stop() }
        let connection = try connect(dir)
        // Exactly one byte over the limit, no newline yet: the server must not wait for the rest.
        try await write(connection, Array(repeating: 0x20, count: IPCProtocol.maxMessageBytes + 1))
        let response = try #require(try await readResponse(connection))
        #expect(response.failure?.code == .tooLarge)
        #expect(try await readResponse(connection) == nil)
    }

    @Test func messageAtTheLimitIsAccepted() async throws {
        let dir = try TempDir()
        let server = try startServer(dir) { request, _ in
            ToolResult(text: "\(request.tool.count):\(request.id)", isError: false)
        }
        defer { server.stop() }
        let empty = try IPCProtocol.frame(IPCRequest(id: "1", tool: "")).count - 1
        let tool = String(repeating: "t", count: IPCProtocol.maxMessageBytes - empty)
        let response = try await IPCClient(directory: dir.run).send(IPCRequest(id: "1", tool: tool))
        #expect(response.result?.text == "\(tool.count):1")
    }

    @Test func slowSenderTimesOut() async throws {
        let dir = try TempDir()
        var configuration = IPCServer.Configuration()
        // Long enough that the partial write below lands before the server gives up, even on a loaded machine.
        configuration.readTimeout = 1
        let server = try startServer(dir, configuration: configuration)
        defer { server.stop() }
        let connection = try connect(dir)
        // Written inline, not through the busy global queue, so the partial message always lands before the
        // server's deadline; a few bytes on a fresh socket never block.
        try connection.write(Array(#"{"version":1"#.utf8), timeout: 1)
        // Timed on the reading thread itself: waiting for a pool thread is the test machine's delay, not the
        // server's.
        let (response, after, elapsed) = try await offPool {
            let started = Date()
            let response = try connection.readLine(maxBytes: IPCProtocol.maxMessageBytes, timeout: 5)
            let after = try connection.readLine(maxBytes: IPCProtocol.maxMessageBytes, timeout: 5)
            return (response, after, Date().timeIntervalSince(started))
        }
        let decoded = try response.map { try JSONDecoder().decode(IPCResponse.self, from: Data($0)) }
        #expect(decoded?.failure?.code == .timeout)
        #expect(after == nil)
        #expect(elapsed < 3)
    }

    @Test func idleConnectionIsClosed() async throws {
        let dir = try TempDir()
        var configuration = IPCServer.Configuration()
        configuration.readTimeout = 0.2
        let server = try startServer(dir, configuration: configuration)
        defer { server.stop() }
        let connection = try connect(dir)
        #expect(try await readResponse(connection)?.failure?.code == .timeout)
    }

    @Test func oversizeResultBecomesInternalError() async throws {
        let dir = try TempDir()
        let server = try startServer(dir) { _, _ in
            ToolResult(text: String(repeating: "x", count: 2 << 20), isError: false)
        }
        defer { server.stop() }
        let response = try await IPCClient(directory: dir.run).send(IPCRequest(id: "1", tool: "t"))
        #expect(response.failure?.code == .internalError)
    }

    // MARK: - Peer check

    /// Sends a valid request. The server may close before the write lands (EPIPE) or after it (EOF); either way
    /// nothing must come back.
    /// The server may hang up before the client has even configured its end; that is a drop too.
    private func isDroppedWithoutAnswer(_ dir: TempDir) async throws -> Bool {
        do {
            let connection = try connect(dir)
            try await write(connection, Array(try IPCProtocol.frame(IPCRequest(id: "1", tool: "status"))))
            return try await readResponse(connection) == nil
        } catch IPCError.connectionClosed {
            return true
        }
    }

    @Test func wrongPeerUIDIsDroppedWithoutAnswer() async throws {
        let dir = try TempDir()
        let seen = Box<Bool>(false)
        var configuration = IPCServer.Configuration()
        configuration.peerUID = { _ in getuid() + 1 }
        let server = try startServer(dir, configuration: configuration) { _, _ in
            seen.value = true
            return ToolResult(text: "leak", isError: false)
        }
        defer { server.stop() }
        #expect(try await isDroppedWithoutAnswer(dir))
        await #expect(throws: IPCError.self) {
            try await IPCClient(directory: dir.run).send(IPCRequest(id: "2", tool: "status"))
        }
        #expect(seen.value == false)
    }

    /// A peer that hangs up straight away makes the client's setsockopt fail with EINVAL; that is a closed
    /// connection, not a system error.
    @Test func aDropBeforeConfigurationIsAClosedConnection() async throws {
        let dir = try TempDir()
        var configuration = IPCServer.Configuration()
        configuration.peerUID = { _ in getuid() + 1 }
        let server = try startServer(dir, configuration: configuration)
        defer { server.stop() }
        let client = IPCClient(directory: dir.run)
        for i in 0..<300 {
            do {
                _ = try await client.send(IPCRequest(id: "\(i)", tool: "status"))
                Issue.record("a dropped connection was answered")
            } catch let error as IPCError {
                #expect(error == .connectionClosed, "\(error)")
            }
        }
    }

    @Test func adoptingASocketWhosePeerLeftIsAClosedConnection() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        close(fds[1])
        #expect(throws: IPCError.connectionClosed) { try SocketConnection(adopting: fds[0]) }
    }

    @Test func unknownPeerIsDropped() async throws {
        let dir = try TempDir()
        var configuration = IPCServer.Configuration()
        configuration.peerUID = { _ in nil }
        let server = try startServer(dir, configuration: configuration)
        defer { server.stop() }
        #expect(try await isDroppedWithoutAnswer(dir))
    }

    @Test func realPeerUIDIsOwnUID() async throws {
        let dir = try TempDir()
        let server = try startServer(dir)
        defer { server.stop() }
        let connection = try connect(dir)
        #expect(PeerCredentials.uid(of: connection.fd) == getuid())
    }

    // MARK: - Client

    @Test func clientReportsAppNotRunning() async throws {
        let dir = try TempDir()
        // No directory at all.
        await #expect(throws: IPCError.appNotRunning) {
            try await IPCClient(directory: dir.run).send(IPCRequest(id: "1", tool: "s"))
        }
        // Directory but no socket.
        _ = try RunDirectory.prepare(dir.run)
        await #expect(throws: IPCError.appNotRunning) {
            try await IPCClient(directory: dir.run).send(IPCRequest(id: "1", tool: "s"))
        }
        // Stale socket with nobody listening.
        try SocketConnection.listen(at: dir.run + "/dualcontrol.sock").close()
        await #expect(throws: IPCError.appNotRunning) {
            try await IPCClient(directory: dir.run).send(IPCRequest(id: "1", tool: "s"))
        }
        // Stopped server.
        try startServer(dir).stop()
        await #expect(throws: IPCError.appNotRunning) {
            try await IPCClient(directory: dir.run).send(IPCRequest(id: "1", tool: "s"))
        }
    }

    @Test func clientRefusesUnsafeDirectory() async throws {
        let dir = try TempDir()
        let server = try startServer(dir)
        defer { server.stop() }
        #expect(chmod(dir.run, 0o755) == 0)
        await #expect(throws: IPCError.unsafeDirectory("mode is 755, expected 700")) {
            try await IPCClient(directory: dir.run).send(IPCRequest(id: "1", tool: "s"))
        }
        _ = chmod(dir.run, 0o700)
    }

    @Test func clientTimesOutOnSlowApp() async throws {
        let dir = try TempDir()
        let server = try startServer(dir) { _, _ in
            try? await Task.sleep(for: .seconds(2))
            return ToolResult(text: "late", isError: false)
        }
        defer { server.stop() }
        var client = IPCClient(directory: dir.run)
        client.responseTimeout = 0.2
        await #expect(throws: IPCError.timedOut) { try await client.send(IPCRequest(id: "1", tool: "s")) }
    }

    @Test func clientAsyncCall() async throws {
        let dir = try TempDir()
        let server = try startServer(dir)
        defer { server.stop() }
        let response = try await IPCClient(directory: dir.run).send(IPCRequest(id: "z", tool: "status"))
        #expect(response.result?.text == "status:z")
    }

    @Test func concurrentClients() async throws {
        let dir = try TempDir()
        let server = try startServer(dir)
        defer { server.stop() }
        let client = IPCClient(directory: dir.run)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<32 {
                group.addTask { try await client.send(IPCRequest(id: "\(i)", tool: "t")).result?.text == "t:\(i)" }
            }
            for try await ok in group { #expect(ok) }
        }
    }

    // MARK: - Caller

    /// The app asks, before it runs anything for a call that waited, whether the caller is still there.
    @Test func theHandlerSeesWhetherTheCallerIsStillConnected() async throws {
        let dir = try TempDir()
        let whileWaiting = Box<[Bool]>([])
        let kept = Box<IPCCaller?>(nil)
        let server = try startServer(dir) { _, caller in
            kept.value = caller
            var seen = [caller.isConnected]
            // Wait (up to 5 s) for the client to hang up, as it does while an approval waits.
            for _ in 0..<500 where caller.isConnected { try? await Task.sleep(for: .milliseconds(10)) }
            seen.append(caller.isConnected)
            whileWaiting.value = seen
            return ToolResult(text: "late", isError: false)
        }
        defer { server.stop() }
        let connection = try connect(dir)
        try await write(connection, Array(try IPCProtocol.frame(IPCRequest(id: "1", tool: "run_command"))))
        try await Task.sleep(for: .milliseconds(200))
        connection.close()
        for _ in 0..<500 where whileWaiting.value.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(whileWaiting.value == [true, false])
        // Once the call has been answered, the caller is gone for good.
        for _ in 0..<100 where kept.value?.isConnected != false { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kept.value?.isConnected == false)
    }

    /// Cancelling the client's task (the MCP client abandoned the call) hangs up at once, so the app sees the caller
    /// leave and kills what it runs for it.
    @Test func cancellingTheClientHangsUp() async throws {
        let dir = try TempDir()
        let seen = Box<[Bool]>([])
        let server = try startServer(dir) { _, caller in
            seen.value = [caller.isConnected]
            for _ in 0..<500 where caller.isConnected { try? await Task.sleep(for: .milliseconds(10)) }
            seen.value += [caller.isConnected]
            return ToolResult(text: "late", isError: false)
        }
        defer { server.stop() }
        let call = Task { try await IPCClient(directory: dir.run).send(IPCRequest(id: "c", tool: "run_command")) }
        for _ in 0..<500 where seen.value.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        call.cancel()
        let result = await call.result
        #expect(throws: CancellationError.self) { try result.get() }
        for _ in 0..<500 where seen.value.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(seen.value == [true, false])
    }

    @Test func aClientCancelledBeforeItConnectsSendsNothing() async throws {
        let dir = try TempDir()
        let handled = Box(false)
        let server = try startServer(dir) { request, _ in
            handled.value = true
            return ToolResult(text: request.id, isError: false)
        }
        defer { server.stop() }
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await IPCClient(directory: dir.run).send(IPCRequest(id: "c", tool: "status"))
        }
        let result = await call.result
        #expect(throws: CancellationError.self) { try result.get() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!handled.value)
    }

    @Test func aCallerThatStaysIsConnectedUntilAnswered() async throws {
        let dir = try TempDir()
        let seen = Box<Bool?>(nil)
        let server = try startServer(dir) { request, caller in
            seen.value = caller.isConnected
            return ToolResult(text: request.id, isError: false)
        }
        defer { server.stop() }
        #expect(try await IPCClient(directory: dir.run).send(IPCRequest(id: "s", tool: "status")).result?.text == "s")
        #expect(seen.value == true)
    }

    /// The client waits for the longest approval plus the longest command, so a long command is not cut off.
    @Test func theClientWaitsForTheLongestApprovalAndCommand() {
        #expect(IPCClient().responseTimeout == 840 + 3600 + 60)
    }

    // MARK: - Descriptor ownership

    /// True if `fd` is still an open descriptor.
    private func isOpen(_ fd: Int32) -> Bool { fcntl(fd, F_GETFD) != -1 }

    /// Each descriptor is closed exactly once. A second close() can hit a number the kernel has already handed to
    /// another connection, so canary descriptors opened by other threads must never be closed under them.
    @Test func failedAdoptionClosesItsDescriptorOnce() async throws {
        let stop = Box(false)
        let closedUnderUs = Box(0)
        let canaries = (0..<4).map { _ in
            Thread {
                while !stop.value {
                    var fds: [Int32] = [0, 0]
                    guard pipe(&fds) == 0 else { continue }
                    for _ in 0..<20 where !isOpen(fds[0]) || !isOpen(fds[1]) { closedUnderUs.value += 1 }
                    close(fds[0])
                    close(fds[1])
                }
            }
        }
        canaries.forEach { $0.start() }
        try await offPool {
            for _ in 0..<20_000 {
                var fds: [Int32] = [0, 0]
                guard pipe(&fds) == 0 else { throw IPCError.system("pipe", errno) }
                // Not a socket: configuring it fails, and the connection must own and close it once.
                #expect(throws: IPCError.self) { try SocketConnection(adopting: fds[0]) }
                close(fds[1])
            }
        }
        stop.value = true
        #expect(closedUnderUs.value == 0)
    }

    /// Start, probe and stop servers while clients connect and hang up at once: every round must bind cleanly and
    /// every real request must be answered.
    @Test func serverStressKeepsDescriptorsApart() async throws {
        let dir = try TempDir()
        let path = try RunDirectory.prepare(dir.run).socketPath
        let client = IPCClient(directory: dir.run)
        for round in 0..<40 {
            let server = try startServer(dir)
            #expect(throws: IPCError.alreadyRunning) { try startServer(dir) }
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for i in 0..<8 {
                    group.addTask {
                        try await offPool { try SocketConnection.connect(to: path).close() }
                        let id = "\(round)-\(i)"
                        return try await client.send(IPCRequest(id: id, tool: "t")).result?.text == "t:\(id)"
                    }
                }
                for try await ok in group { #expect(ok) }
            }
            server.stop()
        }
    }

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
#endif
