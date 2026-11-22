import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func sampleLines(count: Int = 4) throws -> [String] {
    var log = AuditLog()
    var lines: [String] = []
    for index in 0..<count {
        let request = ActionRequest(
            capability: .command,
            argv: ["echo", "line \(index)\n\"quoted\" \u{1b}[31m"],
            cwd: "/work/p",
            projectID: "p"
        )
        let decision = Decision(verdict: .ask, reason: "asking", ruleID: "mode.ask-each")
        let time = start.addingTimeInterval(Double(index))
        lines.append(try log.append(.decision, request: request, decision: decision, at: time))
    }
    return lines
}

private func isInvalid(_ result: AuditVerification, at line: Int) -> Bool {
    if case .invalid(line, _) = result { return true }
    return false
}

@Test func appendedLinesVerify() throws {
    let lines = try sampleLines()
    #expect(lines.allSatisfy { !$0.contains("\n") })
    guard case .valid(let head) = AuditLog.verify(lines) else {
        Issue.record("expected valid log")
        return
    }
    #expect(head.count == 4)
    #expect(AuditLog.verify([]) == .valid(.genesis))
}

@Test func resumingFromHeadContinuesTheChain() throws {
    let lines = try sampleLines()
    guard case .valid(let head) = AuditLog.verify(lines) else {
        Issue.record("expected valid log")
        return
    }
    var resumed = AuditLog(head: head)
    let next = try resumed.append(.stopped, detail: "owner pressed Stop", at: start)
    #expect(AuditLog.verify(lines + [next]) == .valid(resumed.head))
}

@Test func editedContentIsDetected() throws {
    var lines = try sampleLines()
    lines[1] = lines[1].replacingOccurrences(of: "\"ask\"", with: "\"allow\"")
    #expect(isInvalid(AuditLog.verify(lines), at: 1))
}

@Test func editWithRecomputedHashBreaksTheNextLink() throws {
    let lines = try sampleLines()
    guard case .valid(let afterFirst) = AuditLog.verify([lines[0]]) else {
        Issue.record("expected valid log")
        return
    }
    // A forger rebuilds line 1 with a valid hash, but line 2 still points at the original.
    var forger = AuditLog(head: afterFirst)
    let forged = try forger.append(.decision, detail: "forged", at: start)
    #expect(isInvalid(AuditLog.verify([lines[0], forged] + lines[2...]), at: 2))
}

@Test func deletionReorderingAndGarbageAreDetected() throws {
    let lines = try sampleLines()
    #expect(isInvalid(AuditLog.verify([lines[0], lines[2], lines[3]]), at: 1))
    #expect(isInvalid(AuditLog.verify(Array(lines.dropFirst())), at: 0))
    #expect(isInvalid(AuditLog.verify([lines[0], lines[2], lines[1], lines[3]]), at: 1))
    #expect(isInvalid(AuditLog.verify([lines[0], "{}"]), at: 1))
    #expect(isInvalid(AuditLog.verify([lines[0], "not json"]), at: 1))
    #expect(isInvalid(AuditLog.verify([lines[0], lines[1] + " "]), at: 1))
    #expect(isInvalid(AuditLog.verify([lines[0], lines[1].replacingOccurrences(of: ":", with: " : ")]), at: 1))
}

@Test func truncationIsOnlyDetectableAgainstAnAnchoredHead() throws {
    let lines = try sampleLines()
    guard case .valid(let full) = AuditLog.verify(lines),
        case .valid(let truncated) = AuditLog.verify(Array(lines.dropLast()))
    else {
        Issue.record("expected valid logs")
        return
    }
    #expect(truncated != full)
}
