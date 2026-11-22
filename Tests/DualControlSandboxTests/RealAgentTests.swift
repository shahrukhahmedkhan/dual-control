#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlSandbox

    /// Opt-in checks against a real agent setup, which CI does not have: run as the owner with
    /// `DC_REAL_AGENT_ROOT=<a session folder under ~/Developer> swift test --filter RealAgent`. They run labelled
    /// commands that write nothing, as `claude-agent` through the production sudo rule, and check that the
    /// timeout and `kill()` end the agent's whole process group from the owner's side.
    private let realRoot = ProcessInfo.processInfo.environment["DC_REAL_AGENT_ROOT"]

    private func realLaunch(_ scope: SessionScope, _ argv: [String], readOnly: Bool, timeout: Int) -> Launch {
        let request = ActionRequest(
            capability: .command,
            argv: argv,
            cwd: scope.root,
            projectID: scope.root,
            timeoutSeconds: timeout
        )
        let decision = Decision(verdict: .allow, reason: "test", ruleID: "test")
        let execution = Execution(id: "x1", tool: "run_command", request: request, decision: decision, scope: scope)
        return Launch(
            execution: execution,
            scope: scope,
            readOnly: readOnly,
            serialPort: nil,
            timeoutSeconds: timeout
        )
    }

    /// Processes of the agent whose command line contains `marker`, seen from the owner's side.
    private func agentProcesses(_ marker: String) -> [String] {
        guard let listing = Subprocess.run(["/bin/ps", "-axo", "user=,command="]) else { return ["ps failed"] }
        return listing.output.split(separator: "\n").map(String.init).filter {
            $0.hasPrefix(AgentEnvironment.user) && $0.contains(marker)
        }
    }

    /// One at a time: the last test kills every process the agent owns.
    @Suite(.serialized) struct RealAgent {
        @Test(.enabled(if: realRoot != nil)) func realAgentRunsAndIsKilledAsAGroup() throws {
            let scope = try ResolvedScope.production(choosing: try #require(realRoot))
            let sandbox = Sandbox(scope: scope, runAs: SetupGuide.runAsAgent)

            let echo = try sandbox.start(realLaunch(scope, ["echo", "DC-TEST"], readOnly: true, timeout: 30)).wait()
            #expect(echo.status == 0, "\(echo.output)")
            #expect(echo.output == "DC-TEST\n")

            let identity = try sandbox.start(realLaunch(scope, ["/usr/bin/id", "-un"], readOnly: true, timeout: 30))
                .wait()
            #expect(identity.output == AgentEnvironment.user + "\n")

            // The timeout kills the group, children included, although the app may not signal the agent directly.
            let marker = "sleep 31.\(UInt16.random(in: 1000...9999))"
            let script = "/bin/sleep \(marker.dropFirst(6)) & /bin/sleep \(marker.dropFirst(6)); echo DC-TEST"
            let begun = Date()
            let timedOut = try sandbox.start(realLaunch(scope, ["/bin/sh", "-c", script], readOnly: false, timeout: 2))
                .wait()
            #expect(timedOut.timedOut && timedOut.killed)
            #expect(Date().timeIntervalSince(begun) < 15)
            for _ in 0..<50 where !agentProcesses(marker).isEmpty { usleep(100_000) }
            #expect(agentProcesses(marker).isEmpty)

            // kill() (Stop, quitting) does the same at once.
            let running = try sandbox.start(realLaunch(scope, ["/bin/sh", "-c", script], readOnly: false, timeout: 60))
            usleep(500_000)
            #expect(!agentProcesses(marker).isEmpty)
            running.kill()
            let stopped = running.wait()
            #expect(stopped.killed && !stopped.timedOut)
            for _ in 0..<50 where !agentProcesses(marker).isEmpty { usleep(100_000) }
            #expect(agentProcesses(marker).isEmpty)
        }

        /// Kills every process of the agent's, the shared terminal included: run it only when nothing in the agent's
        /// terminal matters.
        @Test(.enabled(if: realRoot != nil)) func realAgentEscapedProcessesDieWithEndAll() throws {
            let scope = try ResolvedScope.production(choosing: try #require(realRoot))
            let sandbox = Sandbox(scope: scope, runAs: SetupGuide.runAsAgent)
            // `set -m` puts the background job in a process group of its own, as setsid or a daemon would.
            let marker = "sleep 301.\(UInt16.random(in: 1000...9999))"
            let script = "set -m; /bin/\(marker) & echo DC-TEST"
            let escaped = try sandbox.start(realLaunch(scope, ["/bin/sh", "-c", script], readOnly: false, timeout: 30))
            _ = escaped.wait()
            #expect(!agentProcesses(marker).isEmpty, "the escape did not work, so this proves nothing")
            let survivors = AgentProcesses.endAll()
            #expect(survivors.isEmpty, "\(survivors)")
            #expect(agentProcesses(marker).isEmpty)
            let uid = try #require(getpwnam(AgentEnvironment.user)).pointee.pw_uid
            #expect(AgentProcesses.list(uid: uid).isEmpty)
        }
    }
#endif
