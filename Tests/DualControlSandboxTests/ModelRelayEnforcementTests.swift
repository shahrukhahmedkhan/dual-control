#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlNetwork
    @testable import DualControlSandbox

    /// D11 phase 2 in the kernel: agent processes reach the model relay's port and get its URL and session token,
    /// never the owner's key. The kernel enforces the profiles for any user, so the tests run as the test user.
    private final class Fixture {
        let base: String
        let scope: SessionScope

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in [
                "/home/Developer/p", "/home/Developer/.dual-control/agent-home", "/home/Developer/.dual-control/tmp",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            scope = try ResolvedScope.make(choosing: base + "/home/Developer/p", ceiling: base + "/home/Developer")
        }

        deinit {
            try? FileManager.default.removeItem(atPath: base)
        }

        func sandbox(relay: ModelRelayEndpoint?) -> Sandbox {
            Sandbox(scope: scope, toolchains: Toolchain.readPaths(), relay: relay)
        }
    }

    private let ownerKey = "sk-ant-api03-" + String(repeating: "q", count: 40)

    /// A request with only what the agent's environment gives it.
    private let curl = #"""
        /usr/bin/curl -s -m 5 -X POST -H "authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
        -H 'content-type: application/json' --data '{"model":"m"}' "$ANTHROPIC_BASE_URL/v1/messages"; echo " exit=$?"
        """#

    @Test func theAgentReachesTheRelayWithItsTokenAndNothingElse() throws {
        let f = try Fixture()
        // No key set: the relay answers 503 itself, which proves the request got there with a valid token.
        let relay = ModelRelayServer(credential: { nil }, onExchange: { _ in })
        let endpoint = try relay.start()
        defer { relay.stop() }
        let run = try f.sandbox(relay: endpoint).run(["/bin/sh", "-c", curl], kind: .changing, cwd: f.scope.root)
        #expect(run.output.contains("model key") && run.output.contains("exit=0"), "\(run.output)")
    }

    @Test func withoutTheRelayRuleItsPortIsOutOfReach() throws {
        let f = try Fixture()
        let relay = ModelRelayServer(credential: { nil }, onExchange: { _ in })
        let endpoint = try relay.start()
        defer { relay.stop() }
        let script = "/usr/bin/nc -z -G 2 127.0.0.1 \(endpoint.port); echo exit=$?"
        let run = try f.sandbox(relay: nil).run(["/bin/sh", "-c", script], kind: .changing, cwd: f.scope.root)
        #expect(!run.output.contains("exit=0"), "\(run.output)")
    }

    @Test func noAgentProcessHoldsTheOwnersKey() throws {
        let f = try Fixture()
        let relay = ModelRelayServer(credential: { ownerKey }, onExchange: { _ in })
        let endpoint = try relay.start()
        defer { relay.stop() }
        let sandbox = f.sandbox(relay: endpoint)
        let token = try #require(endpoint.variables["ANTHROPIC_AUTH_TOKEN"])
        for kind in [SandboxKind.changing, .flashing(port: "/dev/cu.dc-test"), .cloning(target: f.scope.root + "/r")] {
            let argv = try sandbox.argv(["/usr/bin/env"], kind: kind)
            #expect(!argv.contains { $0.contains("sk-ant") }, "\(kind)")
            #expect(
                argv.contains("ANTHROPIC_AUTH_TOKEN=\(token)")
                    && argv.contains("ANTHROPIC_BASE_URL=http://127.0.0.1:\(endpoint.port)")
            )
            #expect(try sandbox.profile(kind).contains("localhost:\(endpoint.port)"), "\(kind)")
        }
        // READ-ONLY and INSTALLING get neither the variables nor the port.
        for kind in [SandboxKind.readOnly, .installing] {
            let argv = try sandbox.argv(["/usr/bin/env"], kind: kind)
            #expect(!argv.contains { $0.hasPrefix("ANTHROPIC_") }, "\(kind)")
            #expect(try !sandbox.profile(kind).contains("localhost:\(endpoint.port)"), "\(kind)")
        }
        // What a process actually sees.
        let run = try sandbox.run(["/usr/bin/env"], kind: .changing, cwd: f.scope.root)
        #expect(!run.output.contains("sk-ant") && run.output.contains("ANTHROPIC_AUTH_TOKEN=\(token)"))
    }
#endif
