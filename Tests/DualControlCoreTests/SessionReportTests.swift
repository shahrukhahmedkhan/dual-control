import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func command(_ argv: [String], cwd: String = "/work/p") -> IPCRequest {
    IPCRequest(
        id: "1",
        tool: "run_command",
        arguments: ["argv": .array(argv.map(JSONValue.string)), "cwd": .string(cwd)]
    )
}

private struct Unexpected: Error {}

/// A supervisor run that records every line, in order, as the app would persist them.
private struct Session {
    var supervisor = Supervisor(
        scope: try? SessionScope(ceiling: "/work", root: "/work/p"),
        sandboxProblem: nil,
        resolvePath: { ToolRouter.normalizedFolder($0) }
    )
    var lines: [String] = []

    mutating func drain() { lines += supervisor.drainAuditLines() }

    /// Asks for `argv` at `asked`, then approves it `after` seconds later and runs it to `status`.
    mutating func approveAndRun(_ argv: [String], asked: Date, after: TimeInterval, status: Int32) throws {
        guard case .pending(let id) = supervisor.submit(command(argv), now: asked) else { throw Unexpected() }
        drain()
        guard let execution = supervisor.approve(id, now: asked.addingTimeInterval(after))?.execution else {
            throw Unexpected()
        }
        drain()
        try run(execution, at: asked.addingTimeInterval(after), status: status)
    }

    mutating func run(_ execution: Execution, at time: Date, status: Int32, timedOut: Bool = false) throws {
        var persisted: [String] = []
        let attempt = supervisor.begin(execution, callerConnected: true, now: time) { new, _ in
            persisted += new
            return true
        }
        lines += persisted
        guard case .launch(let launch) = attempt else { throw Unexpected() }
        let outcome = CommandOutcome(
            status: status,
            timedOut: timedOut,
            killed: timedOut,
            duration: 1.5,
            output: "",
            totalBytes: 10,
            shownBytes: 10,
            tail: nil
        )
        _ = supervisor.finish(launch, outcome: outcome, now: time.addingTimeInterval(1.5))
        drain()
    }
}

@Test func aSupervisedSessionIsSummarized() throws {
    var session = Session()
    // As the app does it: the folder is chosen, then the self-test passes.
    _ = session.supervisor.setScope(try SessionScope(ceiling: "/work", root: "/work/p"), now: start)
    _ = session.supervisor.setSandboxProblem(nil, now: start)
    session.drain()
    // Approved after half a second (rubber-stamped) and after 30 s; one denied; one never answered.
    try session.approveAndRun(["make"], asked: start, after: 0.5, status: 0)
    try session.approveAndRun(["make", "test"], asked: start.addingTimeInterval(10), after: 30, status: 2)
    guard
        case .pending(let denied) = session.supervisor.submit(command(["rm", "x"]), now: start.addingTimeInterval(60))
    else { throw Unexpected() }
    _ = session.supervisor.deny(denied, now: start.addingTimeInterval(65))
    _ = session.supervisor.submit(command(["touch", "y"]), now: start.addingTimeInterval(70))
    _ = session.supervisor.tick(now: start.addingTimeInterval(70 + 601))
    // Blocked, and outside the session folder.
    _ = session.supervisor.submit(command(["sudo", "ls"]), now: start.addingTimeInterval(80))
    _ = session.supervisor.submit(command(["ls"], cwd: "/etc"), now: start.addingTimeInterval(81))
    // Allowed without asking, then timed out.
    session.supervisor.setMode(.allowWhileOpen, now: start.addingTimeInterval(90))
    guard
        case .execute(let quick) = session.supervisor.submit(
            command(["sleep", "999"]),
            now: start.addingTimeInterval(91)
        )
    else { throw Unexpected() }
    session.drain()
    try session.run(quick, at: start.addingTimeInterval(91), status: 137, timedOut: true)
    _ = session.supervisor.stop(now: start.addingTimeInterval(100))
    session.drain()

    let report = SessionReport.make(lines: session.lines)
    #expect(report.chain == "verified, \(session.lines.count) entries")
    #expect(report.start == start)
    #expect(report.end == start.addingTimeInterval(100))
    #expect(report.commands == ["exit 0": 1, "exit 2": 1, "timed out": 1])
    #expect(report.ranOutside.isEmpty)
    #expect(report.refusedOutside == 1)
    #expect(report.denials.map(\.rule) == ["blocked.sudo", "owner.denied", "owner.timeout", "scope.outside"])
    #expect(report.denials.allSatisfy { $0.count == 1 })
    #expect(report.approvals.map(\.verdict) == [.approved, .approved, .denied, .timedOut])
    #expect(report.approvals.map(\.seconds) == [0.5, 30, 5, 601])
    #expect(report.rubberStamped.map(\.summary) == ["make"])
    #expect(report.stops == 1)

    let markdown = report.markdown
    #expect(markdown.hasPrefix("# Dual Control session report\n"))
    #expect(markdown.contains("Commands that ran outside the session folder: **0**"))
    #expect(markdown.contains("| exit 0 | 1 |"))
    #expect(markdown.contains("Approvals under 2 s (rubber-stamped): **1**"))
    #expect(markdown.contains("- make (0.5 s)"))
}

@Test func onlyTheEntriesSinceTheLastResetCount() throws {
    var session = Session()
    try session.approveAndRun(["make"], asked: start, after: 5, status: 0)
    _ = session.supervisor.stop(now: start.addingTimeInterval(10))
    session.supervisor.resetAfterStop(now: start.addingTimeInterval(20))
    session.drain()
    try session.approveAndRun(["make", "again"], asked: start.addingTimeInterval(30), after: 4, status: 1)
    let report = SessionReport.make(lines: session.lines)
    #expect(report.start == start.addingTimeInterval(20))
    #expect(report.commands == ["exit 1": 1])
    #expect(report.stops == 0)
    // The chain is still checked from the start of the file.
    #expect(report.chain == "verified, \(session.lines.count) entries")
}

@Test func aCommandThatRanOutsideTheFolderIsFlagged() throws {
    let request = ActionRequest(capability: .command, argv: ["make"], cwd: "/work/other", projectID: "/work/other")
    let records = [
        AuditRecord(seq: 0, time: start, event: "scopeChanged", detail: "/work/p"),
        AuditRecord(seq: 1, time: start, event: "starting", detail: "x1", request: request),
        AuditRecord(seq: 2, time: start, event: "starting", detail: "x2", request: request.with(cwd: "/work/p/sub")),
        AuditRecord(seq: 3, time: start, event: "starting", detail: "x3", request: request.with(cwd: "/work/pp")),
    ]
    let report = SessionReport.make(records: records, chain: "not checked")
    #expect(report.ranOutside == ["/work/other", "/work/pp"])
    #expect(report.markdown.contains("Commands that ran outside the session folder: **2** ⚠️"))
}

@Test func networkUseIsSummedPerHost() {
    let lines = [
        "n1 CONNECT pypi.org:443: allowed [network.allowlist]",
        "n2 CONNECT files.pythonhosted.org:443: allowed [network.allowlist]",
        "n1 closed pypi.org:443: up 1200 B, down 30000 B, 1.0 s",
        "n2 closed files.pythonhosted.org:443: up 900 B, down 1000000 B, 2.0 s",
        "n3 CONNECT pypi.org:443: allowed [network.allowlist]",
        "n3 closed pypi.org:443: up 100 B, down 0 B, 0.1 s, failed: the server refused",
        "n4 CONNECT evil.example:443: denied [network.not-allowed]",
        "n5 CONNECT evil.example:443: denied [network.not-allowed]",
        "n6 GET github.com:80: denied [network.git-push]",
    ]
    let records = lines.enumerated().map {
        AuditRecord(seq: $0.offset, time: start, event: "network", detail: $0.element)
    }
    let report = SessionReport.make(records: records, chain: "not checked")
    #expect(
        report.network == [
            HostTraffic(host: "files.pythonhosted.org:443", allowed: 1, denied: 0, failed: 0, up: 900, down: 1_000_000),
            HostTraffic(host: "pypi.org:443", allowed: 2, denied: 0, failed: 1, up: 1300, down: 30000),
            HostTraffic(host: "evil.example:443", allowed: 0, denied: 2, failed: 0, up: 0, down: 0),
            HostTraffic(host: "github.com:80", allowed: 0, denied: 1, failed: 0, up: 0, down: 0),
        ]
    )
    #expect(report.markdown.contains("| pypi.org:443 | 2 | 0 | 1.3 KB | 30.0 KB |"))
    #expect(report.markdown.contains("| evil.example:443 | 0 | 2 | 0 B | 0 B |"))
}

@Test func serialPortsAreListedWithWhatWasDone() {
    func serial(_ argv: [String]) -> ActionRequest {
        ActionRequest(capability: .serial, argv: argv, cwd: "/work/p", projectID: "/work/p")
    }
    let records = [
        AuditRecord(
            seq: 0,
            time: start,
            event: "starting",
            detail: "a1",
            request: serial(["open", "/dev/cu.usbserial-1", "115200", "8N1", "none"])
        ),
        AuditRecord(
            seq: 1,
            time: start,
            event: "executed",
            detail: "a1 ok: opened serial-abc",
            request: serial(["open", "/dev/cu.usbserial-1", "115200", "8N1", "none"])
        ),
        AuditRecord(
            seq: 2,
            time: start,
            event: "starting",
            detail: "x2",
            request: serial(["write", "serial-abc", "68690a"])
        ),
        AuditRecord(
            seq: 3,
            time: start,
            event: "executed",
            detail: "x2 ok: 3 bytes",
            request: serial(["write", "serial-abc", "68690a"])
        ),
        AuditRecord(
            seq: 4,
            time: start,
            event: "starting",
            detail: "x3",
            request: serial(["reset", "serial-abc", "run"])
        ),
        AuditRecord(
            seq: 5,
            time: start,
            event: "serialClosed",
            detail: "serial-abc /dev/cu.usbserial-1: closed by Claude"
        ),
    ]
    let report = SessionReport.make(records: records, chain: "not checked")
    #expect(report.serial == [SerialUse(port: "/dev/cu.usbserial-1", opens: 1, writes: 1, bytesWritten: 3, resets: 1)])
    #expect(report.markdown.contains("| /dev/cu.usbserial-1 | 1 | 1 | 3 | 1 |"))
}

@Test func aBrokenChainIsReportedNotHidden() throws {
    var session = Session()
    try session.approveAndRun(["make"], asked: start, after: 5, status: 0)
    var lines = session.lines
    lines[1] = lines[1].replacingOccurrences(of: "\"make\"", with: "\"mak3\"")
    let report = SessionReport.make(lines: lines + ["not json"])
    #expect(report.chain.hasPrefix("BROKEN at line 2"))
    #expect(report.markdown.contains("Audit chain: BROKEN at line 2"))
    #expect(report.unreadable == 1)
}

@Test func untrustedTextCannotShapeTheMarkdown() {
    let hostile = ActionRequest(
        capability: .command,
        argv: ["echo", "| x | [link](http://e) `code` \u{1B}[2J\n# Title"],
        cwd: "/work/p",
        projectID: "/work/p"
    )
    let records = [
        AuditRecord(
            seq: 0,
            time: start,
            event: "decision",
            detail: "run_command",
            request: hostile,
            decision: Decision(verdict: .deny, reason: "r", ruleID: "blocked.x|y")
        )
    ]
    let markdown = SessionReport.make(records: records, chain: "not checked").markdown
    #expect(!markdown.contains("[link](http://e)"))
    #expect(!markdown.contains("`code`"))
    #expect(!markdown.contains("\u{1B}"))
    #expect(!markdown.contains("\n# Title"))
    #expect(markdown.contains(#"blocked.x\|y"#))
}

extension ActionRequest {
    fileprivate func with(cwd: String) -> ActionRequest {
        var copy = self
        copy.cwd = cwd
        return copy
    }
}
