import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func commit(_ arguments: [String: JSONValue]) -> IPCRequest {
    IPCRequest(id: "1", tool: "git_commit", arguments: arguments)
}

private func commit(_ repository: String = "/work/p/repo", _ message: String = "Fix the parser") -> IPCRequest {
    commit(["repository": .string(repository), "message": .string(message)])
}

private func supervisor(_ mode: ApprovalMode) throws -> Supervisor {
    var supervisor = Supervisor(
        scope: try SessionScope(ceiling: "/work", root: "/work/p"),
        sandboxProblem: nil,
        resolvePath: { $0 }
    )
    supervisor.setMode(mode, now: start)
    return supervisor
}

// MARK: - git_commit

@Test func aCommitIsTheFixedScriptWithTheMessageAndIdentityAsArguments() {
    let argv = GitCommit.argv(message: "m; rm -rf ~", name: "Owner", email: "o@example.invalid")
    #expect(
        argv == ["/bin/sh", "-c", GitCommit.script, "git_commit", "m; rm -rf ~", "Owner", "o@example.invalid", ""]
    )
    #expect(GitCommit.isCommit(argv))
    #expect(!GitCommit.isCommit(["/bin/sh", "-c", "echo", "git_commit", "m", "n", "e"]))
    // Hooks, fsmonitor and signing off, never the agent's global config; never pushes.
    for part in ["core.hooksPath=/dev/null", "core.fsmonitor=false", "commit.gpgsign=false", "--no-verify", "add -A"] {
        #expect(GitCommit.script.contains(part), "\(part)")
    }
    #expect(!GitCommit.script.contains("push") && GitCommit.environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
}

@Test(arguments: ["", String(repeating: "x", count: 5000), "a\u{0}b", "a\u{1B}[2Jb"])
func badMessagesAreRefused(_ message: String) {
    guard case .invalid = ToolRouter.route(commit("/work/p/repo", message)) else {
        Issue.record("routed")
        return
    }
}

@Test(arguments: [
    ["message": JSONValue.string("m")], ["repository": .string("/work/p/r")],
    [
        "repository": .string("/work/p/r"), "message": .string("m"), "push": .bool(true),
    ],
])
func onlyRepositoryAndMessageAreAccepted(_ arguments: [String: JSONValue]) {
    guard case .invalid = ToolRouter.route(commit(arguments)) else {
        Issue.record("routed")
        return
    }
}

@Test func aCommitRunsInTheRepositoryWithTheOwnersIdentityAndFollowsTheApprovalMode() throws {
    var asking = try supervisor(.askEach)
    guard case .pending = asking.submit(commit(), now: start) else {
        Issue.record("did not ask")
        return
    }
    var allowing = try supervisor(.allowWhileOpen)
    allowing.setCommitIdentity(name: "Owner Name", email: "1+owner@users.noreply.github.com")
    guard case .execute(let execution) = allowing.submit(commit(), now: start) else {
        Issue.record("did not run")
        return
    }
    #expect(execution.request.cwd == "/work/p/repo")
    #expect(
        execution.request.argv
            == GitCommit.argv(message: "Fix the parser", name: "Owner Name", email: "1+owner@users.noreply.github.com")
    )
    guard
        case .launch(let launch) = allowing.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    else {
        Issue.record("did not launch")
        return
    }
    #expect(launch.gitCommit && !launch.readOnly)
}

@Test func withoutTheOwnersIdentityTheAgentsOwnIsUsed() throws {
    var allowing = try supervisor(.allowWhileOpen)
    allowing.setCommitIdentity(name: "bad\nname", email: "x")
    guard case .execute(let execution) = allowing.submit(commit(), now: start) else {
        Issue.record("did not run")
        return
    }
    #expect(execution.request.argv.suffix(3) == [GitCommit.agentName, GitCommit.agentEmail, ""])
}

@Test func aBranchOfTheAgentsOwnIsPassedAndTheDefaultBranchIsRefused() throws {
    var allowing = try supervisor(.allowWhileOpen)
    let request = commit([
        "repository": .string("/work/p/repo"), "message": .string("m"), "branch": .string("claude/fix"),
    ])
    guard case .execute(let execution) = allowing.submit(request, now: start) else {
        Issue.record("did not run")
        return
    }
    #expect(execution.request.argv.last == "claude/fix" && GitCommit.isCommit(execution.request.argv))
    for bad in ["main", "master", "-b", "a..b", "x y"] {
        let refused = commit(["repository": .string("/work/p/repo"), "message": .string("m"), "branch": .string(bad)])
        guard case .invalid = ToolRouter.route(refused) else {
            Issue.record("\(bad) was routed")
            continue
        }
    }
}

@Test func aCommitOutsideTheSessionIsRefused() throws {
    var allowing = try supervisor(.allowWhileOpen)
    guard case .finished(let result) = allowing.submit(commit("/elsewhere/repo"), now: start) else {
        Issue.record("ran")
        return
    }
    #expect(result.isError && result.text.contains("scope.outside"))
}

@Test func theSameScriptThroughRunCommandIsNoCommit() throws {
    var allowing = try supervisor(.allowWhileOpen)
    let argv = GitCommit.argv(message: "m", name: "n", email: "e@x")
    let request = IPCRequest(
        id: "1",
        tool: "run_command",
        arguments: ["argv": .array(argv.map(JSONValue.string)), "cwd": .string("/work/p")]
    )
    if case .execute(let execution) = allowing.submit(request, now: start),
        case .launch(let launch) = allowing.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    {
        #expect(!launch.gitCommit)
    }
}

// MARK: - The review queue

@Test func commitsAreQueuedForTheOwnerAndNeverPushedByThemselves() throws {
    var supervisor = try supervisor(.allowWhileOpen)
    _ = supervisor.drainAuditLines()
    supervisor.queueForReview(repository: "/work/p/repo", branch: "claude/fix", commit: "abc1234", now: start)
    supervisor.queueForReview(repository: "/work/p/repo", branch: "claude/fix", commit: "def5678", now: start)
    supervisor.queueForReview(repository: "/work/p/other", branch: "feature", commit: "0123abc", now: start)
    #expect(supervisor.reviewQueue.map(\.branch) == ["claude/fix", "feature"])
    #expect(supervisor.reviewQueue[0].commit == "def5678")
    let id = supervisor.reviewQueue[0].id
    supervisor.recordPush(id, remote: "git@host:o/r.git", commits: 2, signedTip: "fedcba9", problem: nil, now: start)
    #expect(supervisor.reviewQueue.map(\.branch) == ["feature"])
    supervisor.recordPush(
        supervisor.reviewQueue[0].id,
        remote: "x",
        commits: 0,
        signedTip: nil,
        problem: "the remote refused it",
        now: start
    )
    #expect(supervisor.reviewQueue.count == 1, "a failed push stays queued")
    supervisor.removeFromReview(supervisor.reviewQueue[0].id, now: start)
    #expect(supervisor.reviewQueue.isEmpty)
    let lines = supervisor.drainAuditLines()
    #expect(lines.contains { $0.contains("queued for review: /work/p/repo claude/fix abc1234") })
    #expect(
        lines.contains { $0.contains("owner pushed claude/fix to git@host:o/r.git: 2 commits, signed tip fedcba9") }
    )
    #expect(lines.contains { $0.contains("push of feature failed: the remote refused it") })
    #expect(lines.contains { $0.contains("removed from review: /work/p/other feature") })
}

// MARK: - Remotes and branches

@Test(arguments: [
    "https://github.com/o/r.git", "git@github.com:o/r.git", "git@github-personal:owner/dual-control.git",
    "ssh://git@github.com/o/r.git", "ssh://git@host:2222/o/r",
])
func pushRemotesMayBeHTTPSOrSSH(_ url: String) {
    #expect(GitReview.remoteProblem(url) == nil)
}

@Test(arguments: [
    "", "ext::sh -c touch% /tmp/x", "file:///tmp/r", "/tmp/r", "../r", "-oProxyCommand=x:r", "git@host:-x",
    "http://github.com/o/r", "git@host:o/r name", "ssh://-oProxyCommand=x/r", "git@host:o/r\n", "fd::3",
    "https://user:pw@github.com/o/r",
])
func otherRemotesAreRefused(_ url: String) {
    #expect(GitReview.remoteProblem(url) != nil)
}

@Test func theDefaultBranchIsNeverPushed() {
    #expect(GitReview.branchProblem("claude/fix", defaultBranch: "main") == nil)
    for branch in ["main", "master", "trunk", "HEAD", "-x", "a..b", "a/.b", "x.lock", "/a", "a b", "a~1", "a:b", ""] {
        #expect(GitReview.branchProblem(branch, defaultBranch: "trunk") != nil, "\(branch)")
    }
}

@Test func theRemoteHeadIsReadFromLsRemote() {
    let output = """
        ref: refs/heads/develop\tHEAD
        1111111111111111111111111111111111111111\tHEAD
        2222222222222222222222222222222222222222\trefs/heads/claude/fix
        """
    let remote = GitReview.parseLsRemote(output, branch: "claude/fix")
    #expect(remote.defaultBranch == "develop")
    #expect(remote.defaultTip == "1111111111111111111111111111111111111111")
    #expect(remote.branchTip == "2222222222222222222222222222222222222222")
    #expect(
        GitReview.parseLsRemote("", branch: "x")
            == GitReview.RemoteState(defaultBranch: nil, defaultTip: nil, branchTip: nil)
    )
}

@Test func theBranchIsReadFromHEADOnly() {
    #expect(GitReview.branch(fromHEAD: "ref: refs/heads/claude/fix\n") == "claude/fix")
    #expect(GitReview.branch(fromHEAD: "1111111111111111111111111111111111111111\n") == nil)
    #expect(GitReview.branch(fromHEAD: "ref: refs/tags/v1\n") == nil)
}
