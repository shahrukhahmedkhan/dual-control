import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func sync(_ arguments: [String: JSONValue]) -> IPCRequest {
    IPCRequest(id: "1", tool: "git_sync", arguments: arguments)
}

private func sync(_ action: String, branch: String? = nil, repository: String = "/work/p/repo") -> IPCRequest {
    var arguments: [String: JSONValue] = ["repository": .string(repository), "action": .string(action)]
    if let branch { arguments["branch"] = .string(branch) }
    return sync(arguments)
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

@Test func aSyncIsTheFixedScriptWithTheActionBranchAndIdentityAsArguments() {
    let argv = GitSync.argv(.start(branch: "claude/fix"), name: "Owner", email: "o@example.invalid")
    #expect(argv == ["/bin/sh", "-c", GitSync.script, "git_sync", "start", "claude/fix", "Owner", "o@example.invalid"])
    #expect(GitSync.action(of: argv) == .start(branch: "claude/fix"))
    #expect(GitSync.action(of: GitSync.argv(.switchToDefault, name: "n", email: "e@x")) == .switchToDefault)
    // Another script, or an action the tool would refuse, is no sync.
    #expect(!GitSync.isSync(["/bin/sh", "-c", "echo", "git_sync", "fetch", "", "n", "e"]))
    #expect(!GitSync.isSync(["/bin/sh", "-c", GitSync.script, "git_sync", "update", "main", "n", "e"]))
    #expect(!GitSync.isSync(["/bin/sh", "-c", GitSync.script, "git_sync", "push", "", "n", "e"]))
}

@Test func theScriptRunsNothingFromTheRepositoryNeverWritesConfigAndNeverPushes() {
    for part in [
        "core.hooksPath=/dev/null", "core.fsmonitor=false", "commit.gpgsign=false", "gc.auto=0",
        "maintenance.auto=false", "safe.directory=\"$PWD\"", "protocol.allow=never", "protocol.file.allow=always",
        "fetch.fsckObjects=true", "--prune", "--no-tags", "--no-write-fetch-head", "--no-track", "--ff-only",
        "rebase --abort", "\"+refs/heads/*:refs/remotes/origin/*\"",
    ] {
        #expect(GitSync.script.contains(part), "\(part)")
    }
    // Only the bundle the app wrote is fetched; nothing is pushed, merged into, forced or configured.
    for part in ["push", "git config", " config ", "--force", "reset --hard", "--track ", "merge --no-ff"] {
        #expect(!GitSync.script.contains(part), "\(part)")
    }
    #expect(GitSync.environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
    #expect(GitSync.environment["GIT_CONFIG_NOSYSTEM"] == "1")
}

@Test func actionsAndBranchesAreChecked() throws {
    #expect(try GitSync.parse("fetch", branch: nil).get() == .fetch)
    #expect(try GitSync.parse("default", branch: nil).get() == .switchToDefault)
    #expect(try GitSync.parse("start", branch: "claude/x").get() == .start(branch: "claude/x"))
    #expect(try GitSync.parse("update", branch: "claude/a/b").get() == .update(branch: "claude/a/b"))
    let refused: [(String, String?)] = [
        ("fetch", "claude/x"), ("default", "main"), ("start", nil), ("update", nil), ("start", "main"),
        ("update", "feature"), ("update", "claude/"), ("start", "claude/a..b"),
        ("push", nil), ("rebase", "claude/x"), ("", nil),
    ]
    for (action, branch) in refused {
        guard case .failure = GitSync.parse(action, branch: branch) else {
            Issue.record("\(action) \(branch ?? "-") was accepted")
            continue
        }
    }
}

@Test(arguments: [
    ["repository": JSONValue.string("/work/p/r")], ["action": .string("fetch")],
    ["repository": .string("/work/p/r"), "action": .string("fetch"), "force": .bool(true)],
    ["repository": .string("/work/p/r"), "action": .string("start"), "branch": .int(1)],
    ["repository": .string("relative"), "action": .string("fetch")],
    ["repository": .string("/work/p/r/.git"), "action": .string("fetch")],
])
func onlyRepositoryActionAndBranchAreAccepted(_ arguments: [String: JSONValue]) {
    guard case .invalid = ToolRouter.route(sync(arguments)) else {
        Issue.record("routed")
        return
    }
}

@Test func aSyncRunsInTheRepositoryWithTheOwnersIdentityAndFollowsTheApprovalMode() throws {
    var asking = try supervisor(.askEach)
    guard case .pending = asking.submit(sync("fetch"), now: start) else {
        Issue.record("did not ask")
        return
    }
    var allowing = try supervisor(.allowWhileOpen)
    allowing.setCommitIdentity(name: "Owner Name", email: "1+owner@users.noreply.github.com")
    guard case .execute(let execution) = allowing.submit(sync("update", branch: "claude/fix"), now: start) else {
        Issue.record("did not run")
        return
    }
    #expect(execution.request.cwd == "/work/p/repo")
    #expect(
        execution.request.argv
            == GitSync.argv(
                .update(branch: "claude/fix"),
                name: "Owner Name",
                email: "1+owner@users.noreply.github.com"
            )
    )
    #expect(execution.request.timeoutSeconds == GitSync.timeoutSeconds)
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
    #expect(launch.gitSync == .update(branch: "claude/fix") && !launch.readOnly && !launch.gitCommit)
}

@Test func aSyncOutsideTheSessionIsRefused() throws {
    var allowing = try supervisor(.allowWhileOpen)
    guard case .finished(let result) = allowing.submit(sync("fetch", repository: "/elsewhere/repo"), now: start)
    else {
        Issue.record("ran")
        return
    }
    #expect(result.isError && result.text.contains("scope.outside"))
}

@Test func theSameScriptThroughRunCommandIsNoSync() throws {
    var allowing = try supervisor(.allowWhileOpen)
    let argv = GitSync.argv(.fetch, name: "n", email: "e@x")
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
        #expect(launch.gitSync == nil)
    }
}

@Test func startingANewBranchRespectsTheCapButAnOpenOneIsFine() throws {
    var allowing = try supervisor(.allowWhileOpen)
    allowing.setOpenAgentBranches(["claude/a", "claude/b"], for: "/work/p/repo")
    guard case .finished(let refused) = allowing.submit(sync("start", branch: "claude/c"), now: start) else {
        Issue.record("ran at the cap")
        return
    }
    #expect(refused.isError && refused.text.contains("branches.cap"))
    guard case .execute = allowing.submit(sync("start", branch: "claude/a"), now: start) else {
        Issue.record("an open branch was refused")
        return
    }
    // Rebasing or fetching makes no new branch.
    guard case .execute = allowing.submit(sync("update", branch: "claude/c"), now: start),
        case .execute = allowing.submit(sync("fetch"), now: start)
    else {
        Issue.record("refused")
        return
    }
}

@Test func onlyAMovedUpdateCountsAsRebased() {
    let tip = String(repeating: "a", count: 40)
    #expect(GitSync.rebasedTip("Fetched origin.\nrebased: yes\nbranch: claude/x\nbehind 0, ahead 1\n\(tip)\n") == tip)
    #expect(GitSync.rebasedTip("Fetched origin.\nclaude/x is already on origin/main.\n\(tip)\n") == nil)
    #expect(GitSync.rebasedTip("rebased: yes\nnot a commit\n") == nil)
}

@Test func aRebasedBranchStaysMarkedUntilPushed() throws {
    var supervisor = try supervisor(.allowWhileOpen)
    supervisor.queueForReview(repository: "/work/p/repo", branch: "claude/x", commit: "abc1234", now: start)
    #expect(supervisor.reviewQueue[0].rebased == false)
    supervisor.queueForReview(
        repository: "/work/p/repo",
        branch: "claude/x",
        commit: "def5678",
        rebased: true,
        now: start
    )
    supervisor.queueForReview(repository: "/work/p/repo", branch: "claude/x", commit: "0123abc", now: start)
    #expect(supervisor.reviewQueue.count == 1 && supervisor.reviewQueue[0].rebased)
    #expect(supervisor.drainAuditLines().contains { $0.contains("(rebased)") })
}

@Test func theDefaultBranchMayBeMainButNeverHEADOrOdd() {
    for name in ["main", "master", "develop", "release/1.0"] { #expect(GitSync.isDefaultBranch(name), "\(name)") }
    for name in ["HEAD", "", "-x", "a..b", "a b", "x.lock", "$(id)"] {
        #expect(!GitSync.isDefaultBranch(name), "\(name)")
    }
}

@Test func theCatalogueOffersGitSync() {
    #expect(ToolCatalogue.named("git_sync")?.isReadOnly == false)
    #expect(ServerInstructions.text.contains("git_sync"))
}
