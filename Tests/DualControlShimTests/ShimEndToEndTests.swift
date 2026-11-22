#if canImport(MCP) && canImport(Darwin)
    import Darwin
    import DualControlCore
    import DualControlIPC
    import Foundation
    import MCP
    import Testing

    @testable import DualControlShim

    /// MCP client ↔ shim (in-memory transport) ↔ Unix socket ↔ test server running the app's router.
    @Test func shimForwardsToAppAndReportsWhenItIsClosed() async throws {
        var template = Array("/tmp/dc-e2e-XXXXXX".utf8CString)
        let base = try #require(mkdtemp(&template).map { String(cString: $0) })
        defer { try? FileManager.default.removeItem(atPath: base) }
        let runPath = base + "/run"

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session()
        let app = IPCServer(directory: try RunDirectory.prepare(runPath)) { request, _ in
            await session.submit(request, now: now)
        }
        try app.start()

        let shim = await MCPFrontEnd.makeServer(forwarder: Forwarder(client: IPCClient(directory: runPath)))
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await shim.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        let initialized = try await client.connect(transport: clientTransport)
        #expect(initialized.instructions == ServerInstructions.text)

        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name) == ToolCatalogue.all.map(\.name))
        let status = try #require(tools.first { $0.name == "status" })
        #expect(status.description == ToolCatalogue.named("status")?.description)
        #expect(status.annotations.readOnlyHint == true)
        let runCommand = try #require(tools.first { $0.name == "run_command" })
        let schema: JSONValue? = MCPFrontEnd.convert(runCommand.inputSchema)
        #expect(schema == ToolCatalogue.named("run_command")?.inputSchema)

        let header = Supervisor().header(now: now)
        let ok: (content: [Tool.Content], isError: Bool?) = try await client.callTool(name: "status")
        #expect(ok.content.map(text) == ["\(header)\nDual Control \(DualControlCore.version) is running."])
        #expect(ok.isError == false)

        // Allowed, and handed to the app to run; this test app runs nothing.
        let allowed: (content: [Tool.Content], isError: Bool?) = try await client.callTool(
            name: "run_command",
            arguments: ["argv": ["ls"], "cwd": "/work/p"]
        )
        #expect(allowed.content.map(text) == ["\(header)\nCould not run run_command: not run in tests."])
        #expect(allowed.isError == true)

        // App closed: tools still list, calls get a clear error.
        app.stop()
        #expect(try await client.listTools().tools.count == ToolCatalogue.all.count)
        let closed: (content: [Tool.Content], isError: Bool?) = try await client.callTool(name: "status")
        #expect(closed.content.map(text) == [ToolResult.appNotRunning.text])
        #expect(closed.isError == true)

        await client.disconnect()
        await shim.stop()
    }

    /// The app's supervisor for tests: asks are answered at once, as denied.
    private actor Session {
        var supervisor = Supervisor(
            scope: try? SessionScope(ceiling: "/work", root: "/work/p"),
            sandboxProblem: nil,
            resolvePath: { $0 }
        )

        func submit(_ request: IPCRequest, now: Date) -> ToolResult {
            switch supervisor.submit(request, now: now) {
            case .finished(let result): return result
            case .pending(let id): return supervisor.deny(id, now: now)?.result ?? .appNotRunning
            case .execute(let execution):
                return supervisor.complete(execution, output: nil, failure: "not run in tests", now: now)
            case .jobStarted(_, let reply), .jobWaiting(_, let reply), .cancelJob(_, let reply),
                .closeSerial(_, let reply):
                return reply
            }
        }
    }

    private func text(_ content: Tool.Content) -> String? {
        guard case .text(let text, _, _) = content else { return nil }
        return text
    }

    /// The user interrupts a call in the MCP client: the shim hangs up on the app, which is how the app learns to
    /// kill the command it runs for that call.
    @Test func anAbandonedCallHangsUpOnTheApp() async throws {
        var template = Array("/tmp/dc-e2e-XXXXXX".utf8CString)
        let base = try #require(mkdtemp(&template).map { String(cString: $0) })
        defer { try? FileManager.default.removeItem(atPath: base) }
        let runPath = base + "/run"

        let seen = Seen()
        let app = IPCServer(directory: try RunDirectory.prepare(runPath)) { _, caller in
            await seen.add(caller.isConnected)
            for _ in 0..<500 where caller.isConnected { try? await Task.sleep(for: .milliseconds(10)) }
            await seen.add(caller.isConnected)
            return ToolResult(text: "late", isError: false)
        }
        try app.start()
        defer { app.stop() }

        let shim = await MCPFrontEnd.makeServer(forwarder: Forwarder(client: IPCClient(directory: runPath)))
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await shim.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)

        let call = try await client.send(
            CallTool.request(.init(name: "run_command", arguments: ["argv": ["sleep", "60"], "cwd": "/work/p"]))
        )
        for _ in 0..<500 where await seen.values.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await client.cancelRequest(call.requestID, reason: "interrupted")
        for _ in 0..<500 where await seen.values.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await seen.values == [true, false])

        await client.disconnect()
        await shim.stop()
    }

    private actor Seen {
        var values: [Bool] = []
        func add(_ value: Bool) { values.append(value) }
    }

    @Test func protocolFailureBecomesToolError() async throws {
        let forwarder = Forwarder(client: IPCClient(directory: "relative/path"))
        let result = await forwarder.call(tool: "status", arguments: [:])
        #expect(result.isError)
        #expect(result.text.hasPrefix("Could not reach the Dual Control app"))
    }
#endif
