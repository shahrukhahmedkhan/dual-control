import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

@Test func theScriptOnlyReadsAndRunsNothingFromTheRepository() {
    #expect(BranchState.argv() == ["/bin/sh", "-c", BranchState.script, "branch_state"])
    for part in ["--no-optional-locks", "core.hooksPath=/dev/null", "core.fsmonitor=false", "safe.directory=\"$PWD\""] {
        #expect(BranchState.script.contains(part), "\(part)")
    }
    for part in ["fetch", "push", "switch", "checkout", "config", "update-ref", "commit", "reset"] {
        #expect(!BranchState.script.contains(part), "\(part)")
    }
}

@Test func theOutputIsParsedStrictly() {
    #expect(
        BranchState.parse("branch claude/x\nbase origin/main\ncounts 6\t2\n")
            == BranchState(branch: "claude/x", base: "origin/main", ahead: 2, behind: 6)
    )
    #expect(BranchState.parse("branch \nbase origin/main\ncounts 0\t0\n")?.branch == nil)
    #expect(BranchState.parse("branch main\nbase \ncounts \n") == BranchState(branch: "main", base: nil))
    // Not plain names or numbers: dropped, never shown as given.
    let odd = BranchState.parse("branch a..b\nbase upstream/main\ncounts x y\n")
    #expect(odd == BranchState(branch: nil, base: nil))
    #expect(BranchState.parse("branch main\nbase origin/main\ncounts -1\t2\n")?.ahead == nil)
    #expect(BranchState.parse("branch main\nbase origin/main\ncounts 1\t2\nextra\n") == nil)
    #expect(BranchState.parse("") == nil)
}

@Test func theSummarySaysWhereTheBranchStands() {
    #expect(
        BranchState(branch: "claude/x", base: "origin/main", ahead: 2, behind: 6).summary
            == "on claude/x, 2 ahead and 6 behind origin/main (as of the last fetch)"
    )
    #expect(
        BranchState(branch: "main", base: "origin/main", ahead: 0, behind: 0).summary
            == "on main, up to date with origin/main (as of the last fetch)"
    )
    #expect(BranchState(branch: nil, base: nil).summary == "HEAD detached, no origin branch to compare with")
}

@Test func statusShowsEachRepositorysBranchAndOnlyForTheSession() throws {
    var supervisor = Supervisor(
        scope: try SessionScope(ceiling: "/work", root: "/work/p"),
        sandboxProblem: nil,
        resolvePath: { $0 }
    )
    supervisor.setBranchState(
        BranchState(branch: "claude/x", base: "origin/main", ahead: 1, behind: 6),
        for: "/work/p/repo"
    )
    supervisor.setBranchState(BranchState(branch: "main", base: nil), for: "/elsewhere/repo")
    supervisor.setOpenAgentBranches(["claude/x"], for: "/work/p/repo")
    guard
        case .finished(let status) = supervisor.submit(IPCRequest(id: "1", tool: "status", arguments: [:]), now: start)
    else {
        Issue.record("no status")
        return
    }
    #expect(status.text.contains("repo: on claude/x, 1 ahead and 6 behind origin/main (as of the last fetch)"))
    #expect(status.text.contains("repo: 1 of 2 agent branches open"))
    #expect(!status.text.contains("elsewhere"))
    // A new session folder forgets them.
    _ = supervisor.setScope(try SessionScope(ceiling: "/work", root: "/work/q"), now: start)
    #expect(supervisor.branchStates.isEmpty)
}
