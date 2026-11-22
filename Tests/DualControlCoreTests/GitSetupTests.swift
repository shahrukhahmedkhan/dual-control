import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let url = "https://github.com/espressif/esp-idf-template.git"

private func call(_ tool: String, _ arguments: [String: JSONValue]) -> IPCRequest {
    IPCRequest(id: "1", tool: tool, arguments: arguments)
}

private func clone(_ url: String, _ folder: String, background: Bool? = nil) -> IPCRequest {
    var arguments: [String: JSONValue] = ["url": .string(url), "folder": .string(folder)]
    if let background { arguments["background"] = .bool(background) }
    return call("git_clone", arguments)
}

extension ToolRoute {
    fileprivate var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }
}

// MARK: - Routing

@Test func aCloneRunsTheRealGitWithAFixedCommandLine() {
    let request = ActionRequest(
        capability: .command,
        argv: [
            "git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never", "-c",
            "protocol.https.allow=always", "clone", "--template=", "--no-recurse-submodules", "--", url,
            "/work/p/blink",
        ],
        cwd: "/work/p",
        projectID: "/work/p",
        timeoutSeconds: GitSetup.timeoutSeconds
    )
    #expect(ToolRouter.route(clone(url, "/work/p/blink")) == .action(tool: "git_clone", request))
    #expect(ToolRouter.route(clone(url, "/work/p/blink", background: true)) == .job(tool: "git_clone", request))
}

@Test func anInitRunsTheRealGitWithAFixedCommandLine() {
    let request = ActionRequest(
        capability: .command,
        argv: [
            "git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "init", "--template=", "--",
            "/work/p/new",
        ],
        cwd: "/work/p",
        projectID: "/work/p",
        timeoutSeconds: 60
    )
    #expect(
        ToolRouter.route(call("git_init", ["folder": .string("/work/p/new")])) == .action(tool: "git_init", request)
    )
}

@Test(
    arguments: [
        "http://github.com/a/b.git", "ssh://github.com/a/b.git", "git@github.com:a/b.git", "file:///work/q/.git",
        "https://user:token@github.com/a/b.git", "https://user@github.com/a/b.git", "https://github.com/a/../b.git",
        "https:///a/b.git", "https://github.com/a b.git", "https://github.com/a/b.git\n", "-uhttps://github.com/a",
        "ext::sh -c touch% /tmp/x", "", "HTTPS://github.com/a/b.git?x=1#y\u{1B}",
    ]
)
func onlyPlainHTTPSURLsCanBeCloned(_ url: String) {
    guard case .invalid(let tool, _) = ToolRouter.route(clone(url, "/work/p/blink")) else {
        Issue.record("\(url) was routed")
        return
    }
    #expect(tool == "git_clone")
}

@Test(arguments: ["relative/blink", "/work/p/.git", "/work/p/x/.GIT/hooks", "/work/p/sub/.git/modules", "/", ""])
func theFolderMustBeAnAbsoluteNewRepository(_ folder: String) {
    #expect(ToolRouter.route(clone(url, folder)).isInvalid, "\(folder)")
    #expect(ToolRouter.route(call("git_init", ["folder": .string(folder)])).isInvalid, "\(folder)")
}

@Test func unexpectedArgumentsAreInvalid() {
    #expect(
        ToolRouter.route(
            call("git_clone", ["url": .string(url), "folder": .string("/work/p/b"), "depth": .int(1)])
        ).isInvalid
    )
    #expect(ToolRouter.route(call("git_init", ["folder": .string("/work/p/b"), "bare": .bool(true)])).isInvalid)
}

// MARK: - Deciding and launching

private func supervisor(_ mode: ApprovalMode) throws -> Supervisor {
    var supervisor = Supervisor(
        scope: try SessionScope(ceiling: "/work", root: "/work/p"),
        sandboxProblem: nil,
        // Like realpath: the new folders and anything with an empty component (a URL after the cwd) do not exist.
        resolvePath: { path in
            path.hasPrefix("/work/p/blink") || path.hasPrefix("/work/p/new") || path.contains("//") ? nil : path
        }
    )
    supervisor.setMode(mode, now: start)
    return supervisor
}

@Test func aCloneAsksInAskEachAndItsLaunchNamesTheNewRepository() throws {
    var asking = try supervisor(.askEach)
    let submission = asking.submit(clone(url, "/work/p/blink"), now: start)
    guard case .pending = submission else {
        Issue.record("a clone did not ask: \(submission)")
        return
    }
    var allowing = try supervisor(.allowWhileOpen)
    guard case .execute(let execution) = allowing.submit(clone(url, "/work/p/blink"), now: start) else {
        Issue.record("a clone did not run")
        return
    }
    guard
        case .launch(let launch) = allowing.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    else {
        Issue.record("a clone did not launch")
        return
    }
    #expect(launch.git == GitLaunch(kind: .clone, target: "/work/p/blink", url: url))
    #expect(!launch.readOnly)
}

@Test func theSameCommandLineThroughRunCommandGetsNoGitException() throws {
    var allowing = try supervisor(.allowWhileOpen)
    let argv = GitSetup.cloneArgv(url: url, folder: "/work/p/blink")
    let request = call("run_command", ["argv": .array(argv.map(JSONValue.string)), "cwd": .string("/work/p")])
    guard case .execute(let execution) = allowing.submit(request, now: start),
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
    #expect(launch.git == nil)
}

// MARK: - What a new repository may contain

private let cloned: [(String, String)] = [
    ("core.repositoryformatversion", "0"), ("core.filemode", "true"), ("core.bare", "false"),
    ("core.logallrefupdates", "true"), ("core.ignorecase", "true"), ("core.precomposeunicode", "true"),
    ("remote.origin.url", url), ("remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"),
    ("branch.master.remote", "origin"), ("branch.master.merge", "refs/heads/master"),
]

@Test func whatGitWritesForACloneOrInitIsAccepted() {
    #expect(GitSetup.configProblem(cloned, kind: .clone, url: url) == nil)
    #expect(GitSetup.configProblem(Array(cloned.prefix(6)), kind: .initialize, url: nil) == nil)
}

@Test(
    arguments: [
        ("core.hookspath", "/work/p/h"), ("core.fsmonitor", "/work/p/x"), ("core.sshcommand", "sh"),
        ("core.pager", "sh"), ("core.editor", "vi"), ("core.worktree", "/work"), ("core.bare", "true"),
        ("include.path", "/work/p/c"), ("includeif.gitdir:/.path", "x"), ("filter.x.smudge", "sh"),
        ("alias.st", "!sh"), ("remote.origin.url", "https://evil.example/x.git"), ("remote.other.url", url),
        ("remote.origin.uploadpack", "sh"), ("branch.master.remote", "origin\nx"), ("diff.x.textconv", "sh"),
    ]
)
func anythingElseInTheConfigFailsTheClone(_ key: String, _ value: String) {
    #expect(GitSetup.configProblem(cloned + [(key, value)], kind: .clone, url: url) != nil, "\(key)")
}

@Test func anInitHasNoRemote() {
    #expect(GitSetup.configProblem(cloned, kind: .initialize, url: nil) != nil)
}

// MARK: - The CLONING profile

private let scope = try? SessionScope(ceiling: "/Users/o/Developer", root: "/Users/o/Developer/p")

@Test func cloningLiftsTheGitDeniesOnlyInTheNewRepository() throws {
    let profile = try SandboxProfile.changing(scope: #require(scope), gitTarget: "/Users/o/Developer/p/blink")
        .split(separator: "\n").map(String.init)
    let git = try #require(profile.firstIndex { $0.hasPrefix("(deny file-write*") && $0.contains("hooks") })
    let target = try #require(profile.firstIndex(of: #"(allow file-write* (subpath "/Users/o/Developer/p/blink"))"#))
    let persistence = try #require(profile.firstIndex { $0.contains("LaunchAgents") })
    let protected = try #require(profile.lastIndex { $0.hasPrefix("(deny file-read* file-write*") })
    #expect(git < target && target < persistence && target < protected)
    // Nothing else changes: the same profile without the one line.
    var without = profile
    without.remove(at: target)
    #expect(without.joined(separator: "\n") + "\n" == (try SandboxProfile.changing(scope: #require(scope))))
}

@Test(arguments: ["/Users/o/Developer/p", "/Users/o/Developer/other/x", "/Users/o/Developer/p/../q", "relative", ""])
func theNewRepositoryMustBeInsideTheSessionFolder(_ target: String) throws {
    let scope = try #require(scope)
    #expect(throws: SandboxProfile.Error.self) { try SandboxProfile.changing(scope: scope, gitTarget: target) }
}
