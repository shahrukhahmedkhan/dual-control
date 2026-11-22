import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let repo = "/work/p/repo"

private func commit(branch: String) -> IPCRequest {
    IPCRequest(
        id: "1",
        tool: "git_commit",
        arguments: ["repository": .string(repo), "message": .string("Fix it"), "branch": .string(branch)]
    )
}

private func supervisor(open: [String]? = nil, cap: Int = 2) throws -> Supervisor {
    var supervisor = Supervisor(
        scope: try SessionScope(ceiling: "/work", root: "/work/p"),
        sandboxProblem: nil,
        resolvePath: { $0 }
    )
    supervisor.setMode(.allowWhileOpen, now: start)
    supervisor.setRepositoryPolicy(RepositoryPolicy(autoPush: true, maxOpenBranches: cap), for: repo, now: start)
    if let open { supervisor.setOpenAgentBranches(open, for: repo) }
    return supervisor
}

// MARK: - Names and parsing

@Test(arguments: [
    ("claude/fix-parser", true), ("claude/a/b", true), ("claude/", false), ("main", false), ("claudex/y", false),
    ("feature/x", false), ("claude/../x", false), ("claude/x.lock", false), ("Claude/x", false),
])
func agentBranchesAreClaudeSlashPlainNames(_ name: String, _ expected: Bool) {
    #expect(AgentBranches.isAgentBranch(name) == expected, "\(name)")
}

@Test func openBranchesAreReadFromLsRemote() {
    let sha = String(repeating: "a", count: 40)
    let output = """
        \(sha)\trefs/heads/claude/b
        \(sha)\trefs/heads/claude/a
        \(sha)\trefs/heads/main
        junk
        \(sha)\trefs/heads/claude/../x
        \(sha)\trefs/heads/claude/a

        """
    #expect(AgentBranches.parseHeads(output) == ["claude/a", "claude/b"])
}

@Test func gitHubRepositoriesAreNamedFromTheirRemote() {
    let none: (String) -> String? = { _ in nil }
    #expect(AgentBranches.gitHubSlug(remote: "https://github.com/o/n.git", resolveHost: none) == "o/n")
    #expect(AgentBranches.gitHubSlug(remote: "https://github.com/o/n", resolveHost: none) == "o/n")
    #expect(AgentBranches.gitHubSlug(remote: "git@github.com:o/n.git", resolveHost: none) == "o/n")
    #expect(AgentBranches.gitHubSlug(remote: "ssh://git@github.com/o/n.git", resolveHost: none) == "o/n")
    // An SSH host alias counts only if ssh resolves it to github.com.
    let alias: (String) -> String? = { $0 == "github-personal" ? "github.com" : "gitlab.com" }
    #expect(AgentBranches.gitHubSlug(remote: "git@github-personal:o/n.git", resolveHost: alias) == "o/n")
    #expect(AgentBranches.gitHubSlug(remote: "git@work:o/n.git", resolveHost: alias) == nil)
    #expect(AgentBranches.gitHubSlug(remote: "https://gitlab.com/o/n.git", resolveHost: none) == nil)
    #expect(AgentBranches.gitHubSlug(remote: "https://github.com/o/n/extra", resolveHost: none) == nil)
    #expect(AgentBranches.gitHubSlug(remote: "https://github.com/-o/n", resolveHost: none) == nil)
}

@Test func thePullRequestTextComesFromTheCommitAndCannotMentionAnyone() {
    let message = "Fix the parser\n\nThanks @someone, see ```code```.\n"
    #expect(AgentBranches.pullRequestTitle(message) == "Fix the parser")
    #expect(AgentBranches.pullRequestTitle(String(repeating: "x", count: 500)).count == 200)
    #expect(AgentBranches.pullRequestTitle("\n\n") == "Agent changes")
    let body = AgentBranches.pullRequestBody(message, branch: "claude/fix")
    // The agent's words sit in a fence longer than any backtick run in them, so nothing in them is rendered.
    #expect(body.contains("````\nFix the parser\n\nThanks @someone, see ```code```.\n````"))
    #expect(body.contains("Dual Control") && body.contains("claude/fix"))
}

@Test func repositoryPoliciesAreOffByDefaultWithACapOfTwo() throws {
    let policy = RepositoryPolicy()
    #expect(!policy.autoPush && policy.maxOpenBranches == 2)
    #expect(RepositoryPolicy(autoPush: true, maxOpenBranches: 99).maxOpenBranches == AgentBranches.capRange.upperBound)
    #expect(RepositoryPolicy(autoPush: true, maxOpenBranches: 0).maxOpenBranches == 1)
    let decoded = try JSONDecoder().decode(RepositoryPolicy.self, from: JSONEncoder().encode(policy))
    #expect(decoded == policy)
}

// MARK: - The cap

@Test func aNewAgentBranchIsRefusedAtTheCap() throws {
    var full = try supervisor(open: ["claude/a", "claude/b"])
    guard case .finished(let result) = full.submit(commit(branch: "claude/c"), now: start) else {
        Issue.record("ran")
        return
    }
    #expect(result.isError)
    #expect(result.text.contains("2 of 2") && result.text.contains("merge or close one first"))
    #expect(result.text.contains("claude/a") && result.text.contains("claude/b"))
}

@Test func committingToAnOpenOrQueuedBranchIsAlwaysFine() throws {
    var full = try supervisor(open: ["claude/a", "claude/b"])
    guard case .execute = full.submit(commit(branch: "claude/a"), now: start) else {
        Issue.record("refused an open branch")
        return
    }
    full.queueForReview(repository: repo, branch: "claude/local", commit: String(repeating: "c", count: 40), now: start)
    guard case .execute = full.submit(commit(branch: "claude/local"), now: start) else {
        Issue.record("refused a queued branch")
        return
    }
    // Other branch names are not agent branches; the cap does not count them.
    guard case .execute = full.submit(commit(branch: "feature/x"), now: start) else {
        Issue.record("refused a non-agent branch")
        return
    }
}

@Test func belowTheCapOrWithAnUnknownCountANewBranchIsFine() throws {
    var roomy = try supervisor(open: ["claude/a", "claude/b"], cap: 3)
    guard case .execute = roomy.submit(commit(branch: "claude/c"), now: start) else {
        Issue.record("refused below the cap")
        return
    }
    var unknown = try supervisor(open: nil)
    guard case .execute = unknown.submit(commit(branch: "claude/c"), now: start) else {
        Issue.record("refused with an unknown count")
        return
    }
}

@Test func theAgentIsToldTheCountAndTheCap() throws {
    var some = try supervisor(open: ["claude/a"])
    guard case .execute(let execution) = some.submit(commit(branch: "claude/a"), now: start),
        case .launch(let launch) = some.begin(execution, callerConnected: true, now: start, persist: { _, _ in true })
    else {
        Issue.record("did not launch")
        return
    }
    let outcome = CommandOutcome(
        status: 0,
        timedOut: false,
        killed: false,
        duration: 1,
        output: "",
        totalBytes: 0,
        shownBytes: 0
    )
    let result = some.finish(launch, outcome: outcome, now: start)
    #expect(result.text.contains("Agent branches open on the remote: 1 of 2 (claude/a)"))
    #expect(result.text.contains("pushed automatically"))
    guard case .finished(let status) = some.submit(IPCRequest(id: "2", tool: "status", arguments: [:]), now: start)
    else {
        Issue.record("no status")
        return
    }
    #expect(status.text.contains("repo: 1 of 2 agent branches open"))
}

// MARK: - Audit

@Test func policyChangesAutoPushesPullRequestsAndCleanupsAreAudited() throws {
    var s = try supervisor(open: [])
    s.setRepositoryPolicy(RepositoryPolicy(autoPush: false, maxOpenBranches: 3), for: repo, now: start)
    s.queueForReview(repository: repo, branch: "claude/a", commit: String(repeating: "c", count: 40), now: start)
    let id = try #require(s.reviewQueue.first?.id)
    s.recordPush(
        id,
        remote: "git@github.com:o/n.git",
        commits: 2,
        signedTip: "abc",
        problem: nil,
        automatic: true,
        now: start
    )
    s.recordPullRequest(
        repository: repo,
        branch: "claude/a",
        url: "https://github.com/o/n/pull/7",
        problem: nil,
        now: start
    )
    s.recordBranchCleanup(repository: repo, branch: "claude/a", problem: nil, now: start)
    let lines = s.drainAuditLines()
    #expect(lines.contains { $0.contains("auto-push on, at most 2") })
    #expect(lines.contains { $0.contains("auto-push off, at most 3") })
    #expect(lines.contains { $0.contains("auto-pushed claude/a") })
    #expect(lines.contains { $0.contains("pull request for claude/a: https://github.com/o/n/pull/7") })
    #expect(lines.contains { $0.contains("deleted merged claude/a") })
    #expect(s.reviewQueue.isEmpty)
}

// MARK: - gh and cleanup

@Test func pullRequestStatesComeFromGhWithForksIgnored() {
    func entry(_ state: String, _ head: String = "claude/a", fork: Bool = false) -> String {
        #"{"state":"\#(state)","headRefName":"\#(head)","isCrossRepository":\#(fork)}"#
    }
    func state(_ entries: [String]) -> AgentBranches.PullRequestState? {
        AgentBranches.pullRequestState(listJSON: "[" + entries.joined(separator: ",") + "]", branch: "claude/a")
    }
    #expect(state([]) == nil)
    #expect(state([entry("MERGED")]) == .merged)
    #expect(state([entry("CLOSED"), entry("OPEN")]) == .open)
    #expect(state([entry("CLOSED"), entry("MERGED")]) == .merged)
    #expect(state([entry("MERGED", fork: true)]) == nil)
    #expect(state([entry("MERGED", "claude/b")]) == nil)
    #expect(AgentBranches.pullRequestState(listJSON: "not json", branch: "claude/a") == nil)
    #expect(AgentBranches.countsAsOpen(nil) && AgentBranches.countsAsOpen(.open))
    #expect(!AgentBranches.countsAsOpen(.closed) && !AgentBranches.countsAsOpen(.merged))
}

@Test func theLocalDeleteIsAFixedScriptWithTheBranchAsItsArgument() {
    #expect(
        AgentBranches.deleteArgv(branch: "claude/a")
            == ["/bin/sh", "-c", AgentBranches.deleteScript, "delete_branch", "claude/a"]
    )
    for part in ["core.hooksPath=/dev/null", "core.fsmonitor=false", "switch --quiet --detach", "branch --quiet -D"] {
        #expect(AgentBranches.deleteScript.contains(part), "\(part)")
    }
    #expect(!AgentBranches.deleteScript.contains("push"))
}
