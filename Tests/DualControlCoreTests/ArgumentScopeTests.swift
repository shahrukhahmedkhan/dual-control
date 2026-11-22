import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// A realpath stand-in. Under `/work` everything exists except names starting with `new`; `/work/p/escape` is a
/// symlink to `/elsewhere`; `/etc` and `/tmp` live under `/private`; `/dev/null` exists. Answers can be changed
/// mid-test, e.g. to swap a file for a symlink while a request waits.
private final class Disk: @unchecked Sendable {
    private let lock = NSLock()
    private var links = ["/work/p/escape": "/elsewhere", "/etc": "/private/etc", "/tmp": "/private/tmp"]

    func link(_ path: String, to target: String) { lock.withLock { links[path] = target } }

    func resolve(_ path: String) -> String? {
        // Like realpath: `..` is applied after the symlinks before it.
        var resolved: [Substring] = []
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = resolved.popLast()
            default:
                resolved.append(part)
                let current = "/" + resolved.joined(separator: "/")
                if let target = lock.withLock({ links[current] }) {
                    resolved = target.split(separator: "/")
                }
            }
        }
        let result = "/" + resolved.joined(separator: "/")
        let exists =
            result == "/" || result == "/dev/null" || result.hasPrefix("/private/") || result.hasPrefix("/elsewhere")
            || (result.hasPrefix("/work") && !resolved.contains { $0.hasPrefix("new") })
        return exists ? result : nil
    }
}

private func supervisor(_ disk: Disk = Disk(), protected: [String] = []) throws -> Supervisor {
    var supervisor = Supervisor(
        scope: try SessionScope(ceiling: "/work", root: "/work/p", protected: protected),
        sandboxProblem: nil,
        resolvePath: disk.resolve
    )
    supervisor.setMode(.allowWhileOpen, now: start)
    return supervisor
}

private func command(_ argv: [String], cwd: String = "/work/p") -> IPCRequest {
    IPCRequest(
        id: "1",
        tool: "run_command",
        arguments: ["argv": .array(argv.map(JSONValue.string)), "cwd": .string(cwd)]
    )
}

private func type(_ text: String) -> IPCRequest {
    IPCRequest(id: "t", tool: "terminal_send", arguments: ["text": .string(text)])
}

private func ruleID(_ submission: Submission, _ supervisor: Supervisor) -> String? {
    switch submission {
    case .execute: return "ran"
    case .pending: return "asked"
    case .finished: return supervisor.feed.first?.ruleID
    case .jobStarted, .jobWaiting, .cancelJob: return "job"
    case .closeSerial: return "closed"
    }
}

// MARK: - run_command arguments

@Test(
    arguments: [
        // The live case: an absolute path outside the session, under a read-only program.
        ["cat", "/Users/owner/.zshrc"],
        ["cat", "~/.zshrc"],
        ["ls", "~"],
        ["ls", "~other"],
        ["cat", "../q/file"],
        ["cat", "sub/../../q/file"],
        ["ls", ".."],
        ["ls", "/work"],
        ["ls", "/work/pq"],
        ["ls", "/tmp"],
        ["head", "-n", "1", "/etc/passwd"],
        // Symlinks are followed where they exist.
        ["cat", "escape"],
        ["cat", "escape/notes"],
        ["cat", "/work/p/escape/notes"],
        // Missing paths are resolved lexically after the longest existing prefix.
        ["mkdir", "-p", "new/../../q"],
        ["touch", "/work/p/new/../../q/x"],
        // Option values and assignments.
        ["grep", "--file=/etc/passwd", "x"],
        ["dd", "if=/etc/passwd", "of=out"],
        ["make", "DESTDIR=../install"],
        // A `..` in an assignment or option makes the whole word look like a path, which resolves inside the
        // session (`/work/p/A=/etc/passwd`); the value after `=` is what the program gets, so it is checked too.
        ["env", "A=/etc/../etc/passwd", "ls"],
        ["/usr/bin/env", "A=/work/p/../q", "ls"],
        ["grep", "--file=/etc/../etc/passwd", "x"],
        ["sh", "-c", "A=/etc/../etc/passwd ls"],
        // The agent's own HOME is not the session folder either, as an argument or a value (D9c: consistent).
        ["ls", "/work/.dual-control/agent-home"],
        ["/usr/bin/env", "IDF_TOOLS_PATH=/work/.dual-control/agent-home/.espressif", "./install.sh"],
        // Shell strings are parsed, also behind wrappers and inside each other.
        ["sh", "-c", "cat /etc/passwd"],
        ["bash", "-c", "ls; cat ../q/file"],
        ["sh", "-c", "echo hi > /work/q/x"],
        ["env", "bash", "-c", "cat ../q"],
        ["timeout", "5", "sh", "-c", "sh -c 'cat /etc/passwd'"],
        ["sh", "-c", "cd; cat .zshrc"],
    ]
)
func pathArgumentsOutsideTheSessionAreDeniedBeforeAnythingRuns(_ argv: [String]) throws {
    var supervisor = try supervisor()
    let submission = supervisor.submit(command(argv), now: start)
    #expect(ruleID(submission, supervisor) == "scope.argument", "\(argv)")
    #expect(supervisor.pending.isEmpty)
    #expect(supervisor.interventions.denials == 1)
}

@Test(
    arguments: [
        ["ls"],
        ["cat", "file"],
        ["cat", "/work/p/file"],
        ["cat", "./sub/../file"],
        ["cat", "/work/p/new/file"],
        ["ls", "/work/p"],
        ["ls", "."],
        ["cat", "/dev/null"],
        ["git", "log", "--format=%H"],
        ["make", "-j4", "CFLAGS=-O2"],
        ["echo", "a=b"],
        ["sh", "-c", "make 2>/dev/null"],
        ["sh", "-c", "cd sub && ls"],
        // The program itself is not an argument.
        ["/bin/ls", "sub"],
    ]
)
func pathArgumentsInsideTheSessionAreFine(_ argv: [String]) throws {
    var supervisor = try supervisor()
    #expect(ruleID(supervisor.submit(command(argv), now: start), supervisor) == "ran", "\(argv)")
}

@Test func protectedFoldersInsideTheSessionAreDenied() throws {
    var supervisor = try supervisor(protected: ["/work/p/vendor/dc"])
    for argv in [["cat", "vendor/dc/Package.swift"], ["ls", "/work/p/VENDOR/dc"], ["ls", "vendor/dc"]] {
        #expect(ruleID(supervisor.submit(command(argv), now: start), supervisor) == "scope.argument", "\(argv)")
    }
    #expect(ruleID(supervisor.submit(command(["ls", "vendor"]), now: start), supervisor) == "ran")
}

@Test func theDenialNamesTheArgumentAndTheSession() throws {
    var supervisor = try supervisor()
    guard case .finished(let result) = supervisor.submit(command(["cat", "/Users/owner/.zshrc"]), now: start) else {
        Issue.record("expected a denial")
        return
    }
    #expect(result.isError)
    #expect(result.text.contains("/Users/owner/.zshrc"))
    #expect(result.text.contains("/work/p"))
    #expect(result.text.contains("[scope.argument]"))
}

@Test func argumentsAreDeniedInEveryModeAndBeforeAsking() throws {
    var supervisor = try supervisor()
    supervisor.setMode(.askEach, now: start)
    #expect(ruleID(supervisor.submit(command(["make", "../q"]), now: start), supervisor) == "scope.argument")
    #expect(supervisor.interventions.asks == 0)
}

@Test func anArgumentSwappedForALinkWhileWaitingIsRefusedAtStart() throws {
    let disk = Disk()
    var supervisor = try supervisor(disk)
    supervisor.setMode(.askEach, now: start)
    guard case .pending(let id) = supervisor.submit(command(["make", "target"]), now: start) else {
        Issue.record("expected an ask")
        return
    }
    let approved = try #require(supervisor.approve(id, now: start)?.execution)
    disk.link("/work/p/target", to: "/elsewhere")
    let attempt = supervisor.begin(approved, callerConnected: true, now: start) { _, _ in true }
    guard case .refused(let refusal) = attempt else {
        Issue.record("expected a refusal")
        return
    }
    #expect(refusal.text.contains("[scope.argument]"))
}

// MARK: - terminal_send text

@Test(
    arguments: [
        "cat /etc/passwd\n",
        "cat ~/.zshrc\n",
        "echo hi > /work/q/x\n",
        "echo hi >> ../q/log\n",
        "ls ../q\n",
        "cd ..\n",
        "cd /tmp\n",
        "cd\n",
        "ls; cd\n",
        "cat escape\n",
        "make && cp out /work/q/\n",
        "bash -c 'cat /etc/passwd'\n",
        "ls /etc/*\n",
    ]
)
func terminalTextOutsideTheSessionIsDenied(_ text: String) throws {
    var supervisor = try supervisor()
    #expect(ruleID(supervisor.submit(type(text), now: start), supervisor) == "scope.argument", "\(text)")
}

@Test(arguments: ["make\n", "ls -la\n", "cat sub/file\n", "cd sub\n", "make 2>/dev/null\n", "echo a > out\n", "q"])
func terminalTextInsideTheSessionIsFine(_ text: String) throws {
    var supervisor = try supervisor()
    #expect(ruleID(supervisor.submit(type(text), now: start), supervisor) == "ran", "\(text)")
}

// MARK: - Outcome column

private func outcome(
    status: Int32 = 0,
    timedOut: Bool = false,
    killed: Bool = false,
    output: String = ""
) -> CommandOutcome {
    CommandOutcome(
        status: status,
        timedOut: timedOut,
        killed: killed,
        duration: 1,
        output: output,
        totalBytes: output.utf8.count,
        shownBytes: output.utf8.count
    )
}

private func run(
    _ supervisor: inout Supervisor,
    _ argv: [String] = ["make"],
    outcome: CommandOutcome,
    callerLeft: Bool = false,
    beforeFinish: (inout Supervisor) -> Void = { _ in }
) throws -> RunResult? {
    guard case .execute(let execution) = supervisor.submit(command(argv), now: start),
        case .launch(let launch) = supervisor.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    else {
        Issue.record("expected a launch")
        return nil
    }
    let entry = try #require(supervisor.feed.first { $0.outcome == .allowed })
    #expect(entry.result == nil)
    beforeFinish(&supervisor)
    _ = supervisor.finish(launch, outcome: outcome, callerLeft: callerLeft, now: start)
    return supervisor.feed.first { $0.id == entry.id }?.result
}

@Test func theFeedShowsHowACommandEnded() throws {
    var supervisor = try supervisor()
    #expect(try run(&supervisor, outcome: outcome()) == .exited(0))
    #expect(try run(&supervisor, outcome: outcome(status: 2)) == .exited(2))
    #expect(try run(&supervisor, outcome: outcome(status: 137, timedOut: true, killed: true)) == .timedOut)
    #expect(try run(&supervisor, outcome: outcome(status: 137, killed: true), callerLeft: true) == .callerLeft)
    #expect(try run(&supervisor, outcome: outcome(status: 137, killed: true)) == .killed)
    let denied = outcome(status: 1, output: "cat: /x: Operation not permitted\n")
    #expect(try run(&supervisor, ["cat", "file"], outcome: denied) == .blockedBySandbox(1))
    // The text alone, with exit 0, is just output.
    let printed = outcome(output: "Operation not permitted\n")
    #expect(try run(&supervisor, ["cat", "file"], outcome: printed) == .exited(0))
    let stopped = try run(&supervisor, outcome: outcome(status: 137, killed: true)) { _ = $0.stop(now: start) }
    #expect(stopped == .killedByStop)
}

@Test func anApprovedCommandsOutcomeIsOnItsApprovedLine() throws {
    var supervisor = try supervisor()
    supervisor.setMode(.askEach, now: start)
    guard case .pending(let id) = supervisor.submit(command(["make"]), now: start) else {
        Issue.record("expected an ask")
        return
    }
    let execution = try #require(supervisor.approve(id, now: start)?.execution)
    guard
        case .launch(let launch) = supervisor.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    else {
        Issue.record("expected a launch")
        return
    }
    _ = supervisor.finish(launch, outcome: outcome(status: 3), now: start)
    #expect(supervisor.feed.first { $0.outcome == .approved }?.result == .exited(3))
    #expect(supervisor.feed.first { $0.outcome == .asked }?.result == nil)
}

@Test func terminalRunsAndRunsThatNeverStartedHaveAnOutcomeToo() throws {
    var supervisor = try supervisor()
    guard case .execute(let typed) = supervisor.submit(type("make\n"), now: start) else {
        Issue.record("expected a run")
        return
    }
    let typedEntry = try #require(supervisor.feed.first)
    _ = supervisor.complete(typed, output: nil, failure: nil, now: start)
    #expect(supervisor.feed.first { $0.id == typedEntry.id }?.result == .done)

    guard case .execute(let make) = supervisor.submit(command(["make"]), now: start) else {
        Issue.record("expected a run")
        return
    }
    let makeEntry = try #require(supervisor.feed.first)
    _ = supervisor.begin(make, callerConnected: false, now: start) { _, _ in true }
    #expect(supervisor.feed.first { $0.id == makeEntry.id }?.result == .notRun)
}

@Test func outcomeLabels() {
    #expect(RunResult.exited(0).label == "exit 0")
    #expect(RunResult.exited(2).label == "exit 2")
    #expect(RunResult.timedOut.label == "timed out")
    #expect(RunResult.killedByStop.label == "killed by Stop")
    #expect(RunResult.callerLeft.label == "killed: caller left")
    #expect(RunResult.killed.label == "killed")
    #expect(RunResult.blockedBySandbox(1).label == "blocked by sandbox (exit 1)")
    #expect(RunResult.done.label == "done")
    #expect(RunResult.notRun.label == "did not run")
    #expect(RunResult.exited(0).succeeded && RunResult.done.succeeded)
    #expect(!RunResult.exited(1).succeeded && !RunResult.notRun.succeeded && !RunResult.blockedBySandbox(1).succeeded)
}

@Test func aKillAfterTheCallerLeftIsAudited() throws {
    var supervisor = try supervisor()
    _ = supervisor.drainAuditLines()
    _ = try run(&supervisor, outcome: outcome(status: 137, killed: true), callerLeft: true)
    #expect(supervisor.drainAuditLines().last?.contains("killed; caller left") == true)
}
