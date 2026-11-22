#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlSandbox

    @Test func theListingFindsProcessesByUser() {
        let own = AgentProcesses.list(uid: getuid())
        #expect(own.contains { $0.pid == getpid() })
        #expect(own.allSatisfy { !$0.name.isEmpty })
        #expect(AgentProcesses.list(uid: 4_000_000).isEmpty)
    }

    /// A stand-in for the kernel: kill takes effect after `lag` rounds, and some processes may keep coming back.
    private final class FakeKernel: @unchecked Sendable {
        var processes: [AgentProcess]
        var respawning: Set<pid_t> = []
        var kills = 0

        init(_ pids: [pid_t]) { processes = pids.map { AgentProcess(pid: $0, name: "p\($0)") } }

        func kill() {
            kills += 1
            processes.removeAll { !respawning.contains($0.pid) }
        }
    }

    @Test func endingStopsAsSoonAsNoneRemain() {
        let kernel = FakeKernel([10, 11, 12])
        let survivors = AgentProcesses.end(kill: kernel.kill, list: { kernel.processes }, rounds: 3, settle: 0)
        #expect(survivors.isEmpty)
        #expect(kernel.kills == 1)
    }

    @Test func endingWithNothingRunningKillsNothing() {
        let kernel = FakeKernel([])
        #expect(AgentProcesses.end(kill: kernel.kill, list: { kernel.processes }, rounds: 3, settle: 0).isEmpty)
        #expect(kernel.kills == 0)
    }

    @Test func survivorsAreReportedAfterEveryRound() {
        let kernel = FakeKernel([10, 11])
        kernel.respawning = [11]
        let survivors = AgentProcesses.end(kill: kernel.kill, list: { kernel.processes }, rounds: 3, settle: 0)
        #expect(survivors == [AgentProcess(pid: 11, name: "p11")])
        #expect(kernel.kills == 3)
    }

    @Test func aMissingAgentUserHasNoProcesses() {
        #expect(AgentProcesses.endAll(user: "dc-test-no-such-user").isEmpty)
    }

    @Test func theKillCommandRunsKillMinusOneAsTheAgentInAnOpenSandbox() {
        #expect(
            AgentProcesses.killArgv(runAs: SetupGuide.runAsAgent)
                == SetupGuide.runAsAgent + [
                    "/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/bin/kill", "-KILL", "-1",
                ]
        )
    }
#endif
