import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func attempt(_ connection: Int, _ host: String, port: Int = 443, policy: NetworkPolicy = NetworkPolicy())
    -> NetworkAttempt
{
    NetworkAttempt(
        connection: connection,
        method: "CONNECT",
        host: host,
        port: port,
        decision: policy.decide(.connect, host: host, port: port)
    )
}

private func auditFields(_ supervisor: inout Supervisor) throws -> [[String: Any]] {
    try supervisor.drainAuditLines().map {
        try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

@Test func allowedConnectionsAreAuditedWhenTheyOpenAndClose() throws {
    var supervisor = Supervisor()
    _ = supervisor.drainAuditLines()
    supervisor.recordNetworkAttempt(attempt(7, "pypi.org"), now: start)
    let row = try #require(supervisor.feed.first)
    #expect(row.tool == "network" && row.summary == "CONNECT pypi.org:443")
    #expect(row.outcome == .allowed && row.ruleID == "network.allowlist" && row.result == nil)
    let opened = try auditFields(&supervisor)
    #expect(opened.count == 1)
    #expect(opened[0]["event"] as? String == "network")
    #expect(opened[0]["detail"] as? String == "n7 CONNECT pypi.org:443: allowed [network.allowlist]")

    supervisor.recordNetworkClosed(
        NetworkTransfer(
            connection: 7,
            host: "pypi.org",
            port: 443,
            bytesUp: 1200,
            bytesDown: 3_400_000,
            duration: 2.04,
            failure: nil
        ),
        now: start.addingTimeInterval(2)
    )
    #expect(supervisor.feed.count == 1)
    #expect(supervisor.feed[0].result == .transferred(up: 1200, down: 3_400_000, seconds: 2.04))
    #expect(supervisor.feed[0].result?.label == "↑1.2 KB ↓3.4 MB in 2.0 s")
    let closed = try auditFields(&supervisor)
    #expect(closed[0]["detail"] as? String == "n7 closed pypi.org:443: up 1200 B, down 3400000 B, 2.0 s")
}

@Test func failedConnectionsSayWhy() throws {
    var supervisor = Supervisor()
    supervisor.recordNetworkAttempt(attempt(3, "github.com"), now: start)
    _ = supervisor.drainAuditLines()
    supervisor.recordNetworkClosed(
        NetworkTransfer(
            connection: 3,
            host: "github.com",
            port: 443,
            bytesUp: 0,
            bytesDown: 0,
            duration: 0.1,
            failure: "resolves only to local or private addresses"
        ),
        now: start
    )
    #expect(supervisor.feed[0].result == .unreachable("resolves only to local or private addresses"))
    let fields = try auditFields(&supervisor)
    #expect(
        (fields[0]["detail"] as? String)?.hasSuffix(", failed: resolves only to local or private addresses") == true
    )
}

@Test func deniedHostsAreListedForTheOwnerOnce() throws {
    var supervisor = Supervisor()
    _ = supervisor.drainAuditLines()
    supervisor.recordNetworkAttempt(attempt(1, "Example.com"), now: start)
    supervisor.recordNetworkAttempt(attempt(2, "other.example"), now: start.addingTimeInterval(1))
    supervisor.recordNetworkAttempt(attempt(3, "example.com"), now: start.addingTimeInterval(2))
    #expect(supervisor.feed.first?.outcome == .denied)
    #expect(supervisor.feed.first?.ruleID == "network.not-allowed")
    #expect(supervisor.deniedHosts.map(\.host) == ["example.com", "other.example"])
    #expect(supervisor.deniedHosts.first?.count == 2)
    #expect(supervisor.deniedHosts.first?.lastSeen == start.addingTimeInterval(2))
    let fields = try auditFields(&supervisor)
    #expect(fields.count == 3)
    #expect(fields[0]["detail"] as? String == "n1 CONNECT Example.com:443: denied [network.not-allowed]")
    // Addresses and wrong ports are denied but cannot be allowed with a click.
    supervisor.recordNetworkAttempt(attempt(4, "1.2.3.4"), now: start)
    supervisor.recordNetworkAttempt(attempt(5, "pypi.org", port: 22), now: start)
    #expect(supervisor.deniedHosts.count == 2)
    // Denied connections are not owner interventions.
    #expect(supervisor.interventions.total == 0)
}

@Test func theDeniedListIsCapped() {
    var supervisor = Supervisor()
    for index in 0..<(Supervisor.deniedHostLimit + 5) {
        supervisor.recordNetworkAttempt(attempt(index, "h\(index).example"), now: start)
    }
    #expect(supervisor.deniedHosts.count == Supervisor.deniedHostLimit)
    #expect(supervisor.deniedHosts.first?.host == "h\(Supervisor.deniedHostLimit + 4).example")
}

@Test func theOwnerAllowsHostsForTheSessionOrAlways() throws {
    var supervisor = Supervisor(allowedHosts: ["mirror.example.org", "1.2.3.4"])
    #expect(supervisor.ownerHosts == ["mirror.example.org"])
    supervisor.recordNetworkAttempt(attempt(1, "example.com"), now: start)
    _ = supervisor.drainAuditLines()

    let forSession = supervisor.allowHost("example.com", always: false, now: start)
    #expect(forSession)
    #expect(supervisor.deniedHosts.isEmpty)
    #expect(supervisor.network.decide(.connect, host: "example.com", port: 443).ruleID == "network.session-host")
    #expect(supervisor.ownerHosts == ["mirror.example.org"])
    let always = supervisor.allowHost("Example.com", always: true, now: start)
    #expect(always)
    #expect(supervisor.ownerHosts == ["example.com", "mirror.example.org"])
    let address = supervisor.allowHost("10.0.0.1", always: true, now: start)
    let builtIn = supervisor.allowHost("github.com", always: true, now: start)
    #expect(!address && !builtIn)
    let added = try auditFields(&supervisor).compactMap { $0["detail"] as? String }
    #expect(added == ["host example.com allowed for this session", "host example.com allowed always"])

    let removed1 = supervisor.removeHost("example.com", now: start)
    let removed2 = supervisor.removeHost("example.com", now: start)
    #expect(removed1 && !removed2)
    #expect(supervisor.ownerHosts == ["mirror.example.org"])
    let removed = try auditFields(&supervisor)
    #expect(removed.count == 1)
    #expect(removed[0]["event"] as? String == "ruleRemoved")
    #expect(removed[0]["detail"] as? String == "host example.com no longer allowed")
}

@Test func untrustedHostTextIsEscaped() throws {
    var supervisor = Supervisor()
    let decision = NetworkPolicy().decide(.connect, host: "a\u{1B}[2J", port: 443)
    supervisor.recordNetworkAttempt(
        NetworkAttempt(connection: 9, method: "CONNECT", host: "a\u{1B}[2J", port: 443, decision: decision),
        now: start
    )
    #expect(supervisor.feed[0].summary == #"CONNECT a\u{1B}[2J:443"#)
    #expect(supervisor.deniedHosts.isEmpty)
}
