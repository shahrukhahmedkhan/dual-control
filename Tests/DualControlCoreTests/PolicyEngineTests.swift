import Foundation
import Testing

@testable import DualControlCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func request(
    _ argv: [String],
    capability: Capability = .command,
    cwd: String = "/work/p",
    project: String = "p"
) -> ActionRequest {
    ActionRequest(capability: capability, argv: argv, cwd: cwd, projectID: project)
}

private let makeRule = AllowRule(id: "make", projectID: "p", folder: "/work/p", argv: ["make"])

@Test(
    arguments: [
        // Mode only matters for `changing` actions.
        (ApprovalMode.askEach, ["make"], Verdict.ask),
        (.allowUntil(now.addingTimeInterval(60)), ["make"], .allow),
        (.allowUntil(now), ["make"], .ask),
        (.allowUntil(now.addingTimeInterval(-60)), ["make"], .ask),
        (.allowWhileOpen, ["make"], .allow),
        // Read-only is always allowed, blocked never, privileged always asks.
        (.askEach, ["ls"], .allow),
        (.allowWhileOpen, ["sudo", "ls"], .deny),
        (.allowUntil(now.addingTimeInterval(60)), ["env", "sudo"], .deny),
    ]
)
func modes(_ mode: ApprovalMode, _ argv: [String], _ verdict: Verdict) {
    var engine = PolicyEngine(mode: mode)
    #expect(engine.evaluate(request(argv), now: now).verdict == verdict)
}

@Test(arguments: [ApprovalMode.askEach, .allowWhileOpen])
func privilegedAlwaysAsks(_ mode: ApprovalMode) {
    var engine = PolicyEngine(mode: mode, rules: [AllowRule(id: "b", projectID: "p", folder: "/", argv: ["x"])])
    #expect(engine.evaluate(request(["x"], capability: .broker), now: now).verdict == .ask)
}

@Test(
    arguments: [
        (["make"], "/work/p", "p", Verdict.allow),
        (["make"], "/work/p/sub", "p", .allow),
        (["make", "test"], "/work/p", "p", .ask),
        (["make"], "/work/p/./sub/", "p", .allow),
        (["make"], "/work/q", "p", .ask),
        (["make"], "/work/pq", "p", .ask),
        (["make"], "/work/p/../q", "p", .ask),
        (["make"], "work/p", "p", .ask),
        (["make"], "/work/p", "other", .ask),
        (["/usr/bin/make"], "/work/p", "p", .ask),
        (["cmake"], "/work/p", "p", .ask),
        (["mak"], "/work/p", "p", .ask),
    ]
)
func allowRules(_ argv: [String], _ cwd: String, _ project: String, _ verdict: Verdict) {
    var engine = PolicyEngine(mode: .askEach, rules: [makeRule])
    #expect(engine.evaluate(request(argv, cwd: cwd, project: project), now: now).verdict == verdict)
}

@Test func rulesNeverOverrideBlockedAndEmptyArgvMatchesNothing() {
    var engine = PolicyEngine(
        mode: .askEach,
        rules: [
            AllowRule(id: "s", projectID: "p", folder: "/work/p", argv: ["sudo", "ls"]),
            AllowRule(id: "all", projectID: "p", folder: "/", argv: []),
        ]
    )
    #expect(engine.evaluate(request(["sudo", "ls"]), now: now).verdict == .deny)
    #expect(engine.evaluate(request([]), now: now).verdict != .allow)
}

@Test func rulesOnlyApplyToCommands() {
    var engine = PolicyEngine(
        mode: .askEach,
        rules: [AllowRule(id: "t", projectID: "p", folder: "/work/p", argv: ["make"])]
    )
    #expect(engine.evaluate(request(["make"], capability: .terminal), now: now).verdict == .ask)
}

@Test func terminalTextAlwaysFollowsTheApprovalMode() {
    var engine = PolicyEngine(mode: .askEach)
    for text in ["ls\n", "cat README.md\n", "git status\n", "pwd\n"] {
        let decision = engine.evaluate(request([text], capability: .terminal), now: now)
        #expect(decision.verdict == .ask)
        #expect(decision.ruleID == "mode.ask-each")
    }
    #expect(engine.evaluate(request(["sudo ls\n"], capability: .terminal), now: now).verdict == .deny)
    engine.setMode(.allowWhileOpen)
    #expect(engine.evaluate(request(["ls\n"], capability: .terminal), now: now).verdict == .allow)
    #expect(engine.evaluate(request(["100"], capability: .terminalRead), now: now).verdict == .allow)
}

@Test func stopDeniesEverythingUntilResetAndDropsToAskEach() {
    var engine = PolicyEngine(mode: .allowWhileOpen)
    engine.stop()
    let stopped = engine.evaluate(request(["ls"]), now: now)
    #expect(stopped.verdict == .deny)
    #expect(stopped.ruleID == "stop")
    engine.setMode(.allowWhileOpen)
    #expect(engine.evaluate(request(["ls"]), now: now).verdict == .deny)
    engine.resetAfterStop()
    #expect(engine.mode == .askEach)
    #expect(engine.evaluate(request(["make"]), now: now).verdict == .ask)
    #expect(engine.evaluate(request(["ls"]), now: now).verdict == .allow)
}

@Test func stopTakesPrecedenceOverBaton() {
    var engine = PolicyEngine(mode: .askEach)
    let applied = engine.apply(.ownerTakesOver)
    #expect(applied)
    engine.stop()
    #expect(engine.evaluate(request(["ls"]), now: now).ruleID == "stop")
}

@Test func ownerHoldingBatonDeniesEvenReadOnly() {
    var engine = PolicyEngine(mode: .allowWhileOpen)
    let applied = engine.apply(.ownerTakesOver)
    #expect(applied)
    let decision = engine.evaluate(request(["ls"]), now: now)
    #expect(decision.verdict == .deny)
    #expect(decision.reason == "owner has control")
    engine.apply(.ownerHandsBack)
    #expect(engine.evaluate(request(["ls"]), now: now).verdict == .allow)
}

@Test func pendingTakeoverRequestDenies() {
    var engine = PolicyEngine(mode: .allowWhileOpen)
    let applied = engine.apply(.claudeRequestsTakeover(reason: "needs a password"))
    #expect(applied)
    #expect(engine.evaluate(request(["ls"]), now: now).verdict == .deny)
    engine.apply(.ownerDeclinesTakeover)
    #expect(engine.baton == .claude)
}

@Test(
    arguments: [
        (Baton.claude, BatonEvent.ownerTakesOver, Baton?.some(.owner)),
        (.claude, .claudeRequestsTakeover(reason: "r"), .takeoverRequested(reason: "r")),
        (.claude, .ownerHandsBack, nil),
        (.claude, .ownerDeclinesTakeover, nil),
        (.owner, .ownerHandsBack, .claude),
        (.owner, .ownerTakesOver, nil),
        (.owner, .claudeRequestsTakeover(reason: "r"), nil),
        (.takeoverRequested(reason: "r"), .ownerTakesOver, .owner),
        (.takeoverRequested(reason: "r"), .ownerDeclinesTakeover, .claude),
        (.takeoverRequested(reason: "r"), .claudeRequestsTakeover(reason: "s"), nil),
        (.takeoverRequested(reason: "r"), .ownerHandsBack, nil),
    ]
)
func batonTransitions(_ from: Baton, _ event: BatonEvent, _ to: Baton?) {
    #expect(from.applying(event) == to)
}

@Test func invalidBatonEventLeavesStateUnchanged() {
    var engine = PolicyEngine(mode: .askEach)
    let applied = engine.apply(.ownerHandsBack)
    #expect(!applied)
    #expect(engine.baton == .claude)
}

@Test func interventionsAreCounted() {
    var engine = PolicyEngine(mode: .askEach)
    _ = engine.evaluate(request(["ls"]), now: now)
    _ = engine.evaluate(request(["make"]), now: now)
    _ = engine.evaluate(request(["make"]), now: now)
    _ = engine.evaluate(request(["sudo"]), now: now)
    engine.apply(.claudeRequestsTakeover(reason: "r"))
    engine.apply(.ownerTakesOver)
    _ = engine.evaluate(request(["ls"]), now: now)
    #expect(engine.interventions == InterventionCounter(asks: 2, takeovers: 1, denials: 2))
}

@Test func stateHeader() throws {
    var engine = PolicyEngine(mode: .askEach)
    engine.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    #expect(engine.stateHeader(now: now) == "mode: ask-each · baton: claude · blocked: sudo, efuse, keychain")
    engine.setMode(.allowUntil(now.addingTimeInterval(3600)))
    #expect(
        engine.stateHeader(now: now)
            == "mode: allow-until 09:00 · baton: claude · blocked: sudo, efuse, keychain"
    )
    #expect(
        engine.stateHeader(now: now.addingTimeInterval(3600))
            == "mode: ask-each · baton: claude · blocked: sudo, efuse, keychain"
    )
    engine.setMode(.allowWhileOpen)
    engine.apply(.ownerTakesOver)
    #expect(
        engine.stateHeader(now: now) == "mode: allow-while-open · baton: owner · blocked: sudo, efuse, keychain"
    )
    engine.apply(.ownerHandsBack)
    engine.apply(.claudeRequestsTakeover(reason: "r"))
    engine.stop()
    #expect(
        engine.stateHeader(now: now) == "mode: stopped · baton: takeover-requested · blocked: sudo, efuse, keychain"
    )
}

@Test(
    arguments: [
        (["make", "test"], "/work/p", Verdict.allow),
        (["make", "test"], "/work/p/sub", .allow),
        (["make"], "/work/p", .ask),
        (["make", "test", "extra"], "/work/p", .ask),
        (["make", "test"], "/work/q", .ask),
    ]
)
func rulesMatchTheWholeArgv(_ argv: [String], _ cwd: String, _ verdict: Verdict) {
    let rule = AllowRule(id: "e", projectID: "p", folder: "/work/p", argv: ["make", "test"])
    var engine = PolicyEngine(mode: .askEach, rules: [rule])
    #expect(engine.evaluate(request(argv, cwd: cwd), now: now).verdict == verdict)
}

@Test func rulesRoundTripAsJSON() throws {
    let rule = AllowRule(id: "r", projectID: "p", folder: "/work/p", argv: ["make", "a b"])
    #expect(try JSONDecoder().decode(AllowRule.self, from: JSONEncoder().encode(rule)) == rule)
}

/// D3 saved rules with `argvPrefix` and an `exact` flag. Only exact ones still load; nothing loads as a prefix rule.
@Test(
    arguments: [
        (#"{"id":"r","projectID":"p","folder":"/w","argvPrefix":["make"],"exact":true}"#, true),
        (#"{"id":"r","projectID":"p","folder":"/w","argvPrefix":["make"],"exact":false}"#, false),
        (#"{"id":"r","projectID":"p","folder":"/w","argvPrefix":["make"]}"#, false),
        (#"{"id":"r","projectID":"p","folder":"/w"}"#, false),
    ]
)
func legacyRulesLoadOnlyWhenExact(_ json: String, _ loads: Bool) {
    let rule = try? JSONDecoder().decode(AllowRule.self, from: Data(json.utf8))
    #expect(rule == (loads ? AllowRule(id: "r", projectID: "p", folder: "/w", argv: ["make"]) : nil))
}

@Test func ownerDenialsAndTimeoutsAreCounted() {
    var engine = PolicyEngine()
    engine.recordDenial()
    engine.recordTimeout()
    engine.recordTimeout()
    #expect(engine.interventions == InterventionCounter(asks: 0, takeovers: 0, denials: 1, timeouts: 2))
    #expect(engine.interventions.total == 3)
}

/// The owner reads the header on their own clock: local time, hours and minutes, never UTC.
@Test func allowUntilIsShownInLocalTime() throws {
    var engine = PolicyEngine(mode: .allowUntil(now.addingTimeInterval(3600)))
    engine.timeZone = try #require(TimeZone(secondsFromGMT: 5 * 3600 + 1800))
    #expect(engine.stateHeader(now: now).hasPrefix("mode: allow-until 14:30 · "))
    #expect(engine.evaluate(request(["make"]), now: now).reason == "allowed until 14:30")
    engine.timeZone = try #require(TimeZone(secondsFromGMT: -8 * 3600))
    #expect(engine.stateHeader(now: now).hasPrefix("mode: allow-until 01:00 · "))
    #expect(!engine.stateHeader(now: now).contains("Z"))
}

@Test func theSupervisorUsesItsTimeZone() throws {
    var supervisor = Supervisor(timeZone: try #require(TimeZone(secondsFromGMT: 3600)))
    supervisor.setMode(.allowUntil(now.addingTimeInterval(600)), now: now)
    #expect(supervisor.header(now: now).hasPrefix("mode: allow-until 09:10 · "))
}
