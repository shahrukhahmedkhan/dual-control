import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

@Test(arguments: [
    ("192.168.1.50", 80, "tcp"), ("10.0.0.2", 5000, "udp"), ("172.16.5.4", 1883, "tcp"),
    ("172.31.255.254", 65535, "tcp"), ("192.168.0.1", 1, "udp"),
])
func privateUnicastAddressesAreEndpoints(_ host: String, _ port: Int, _ transport: String) throws {
    let endpoint = try LANEndpoint.parse(host: host, port: port, transport: transport).get()
    #expect(endpoint.description == "\(transport) \(host):\(port)")
    #expect(LANEndpoint(argv: endpoint.argv(why: "test")) == endpoint)
}

@Test(arguments: [
    // Names (no DNS, no mDNS), public, loopback, link-local, CGNAT, multicast and other ranges.
    ("esp32.local", 80, "tcp"), ("printer", 80, "tcp"), ("8.8.8.8", 53, "udp"), ("127.0.0.1", 80, "tcp"),
    ("169.254.1.1", 80, "tcp"), ("100.64.0.1", 80, "tcp"), ("224.0.0.251", 5353, "udp"), ("172.32.0.1", 80, "tcp"),
    ("11.0.0.1", 80, "tcp"),
    // Network and broadcast addresses.
    ("192.168.1.255", 80, "udp"), ("192.168.1.0", 80, "tcp"), ("10.255.255.255", 9, "udp"),
    // Not plain dotted decimal.
    ("192.168.01.5", 80, "tcp"), ("192.168.1", 80, "tcp"), (" 192.168.1.5", 80, "tcp"), ("192.168.1.5 ", 80, "tcp"),
    ("0xC0.168.1.5", 80, "tcp"), ("192.168.1.256", 80, "tcp"), ("fd00::1", 80, "tcp"), ("", 80, "tcp"),
    // Ports and protocols.
    ("192.168.1.50", 0, "tcp"), ("192.168.1.50", 65536, "tcp"), ("192.168.1.50", 80, "icmp"),
    ("192.168.1.50", 80, "TCP"),
])
func everythingElseIsRefused(_ host: String, _ port: Int, _ transport: String) {
    #expect(throws: LANEndpointProblem.self, "\(host):\(port)/\(transport)") {
        try LANEndpoint.parse(host: host, port: port, transport: transport).get()
    }
}

private func request(_ arguments: [String: JSONValue]) -> IPCRequest {
    IPCRequest(id: "1", tool: "net_allow_request", arguments: arguments)
}

private let board: [String: JSONValue] = [
    "host": .string("192.168.1.50"), "port": .int(80), "why": .string("read the board's status page"),
]

@Test func theRequestBecomesANetworkActionTheOwnerDecides() {
    guard case .action(let tool, let action) = ToolRouter.route(request(board)) else {
        Issue.record("not routed")
        return
    }
    #expect(tool == "net_allow_request" && action.capability == .network)
    #expect(action.argv == ["net_allow", "tcp", "192.168.1.50:80", "read the board's status page"])
    #expect(Classifier.classify(action).tier == .privileged)
    for bad in [
        board.merging(["host": .string("esp32.local")]) { $1 }, board.merging(["port": .string("80")]) { $1 },
        board.merging(["why": .string("")]) { $1 }, board.merging(["extra": .bool(true)]) { $1 },
        board.merging(["protocol": .string("icmp")]) { $1 },
    ] {
        guard case .invalid = ToolRouter.route(request(bad)) else {
            Issue.record("\(bad) was routed")
            continue
        }
    }
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

@Test func theOwnerAlwaysDecidesThenTheForwardLastsTheSession() throws {
    // Even when everything else runs without asking.
    var allowing = try supervisor(.allowWhileOpen)
    guard case .pending(let id) = allowing.submit(request(board), now: start) else {
        Issue.record("did not ask")
        return
    }
    #expect(allowing.pending.first?.decision.ruleID == "privileged.lan-endpoint")
    #expect(allowing.feed.first?.summary == "reach tcp 192.168.1.50:80 — read the board's status page")
    let execution = try #require(allowing.approve(id, now: start)?.execution)
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
    let opened = allowing.lanEndpointOpened(launch, localPort: 50001, failure: nil, now: start)
    #expect(!opened.isError && opened.text.contains("reachable at 127.0.0.1:50001"))
    #expect(
        allowing.lanForwards == [
            LANForward(endpoint: try #require(LANEndpoint(argv: launch.request.argv)), localPort: 50001)
        ]
    )
    #expect(
        allowing.drainAuditLines().contains {
            $0.contains("lan tcp 192.168.1.50:80 via 127.0.0.1:50001 for this session")
        }
    )
    // Asked again: the same forwarder, not a second approval.
    guard case .finished(let again) = allowing.submit(request(board), now: start) else {
        Issue.record("asked again")
        return
    }
    #expect(again.text.contains("127.0.0.1:50001") && allowing.pending.isEmpty)
    // Stop ends it.
    _ = allowing.stop(now: start)
    #expect(allowing.lanForwards.isEmpty)
    #expect(allowing.drainAuditLines().contains { $0.contains("via 127.0.0.1:50001: closed by Stop") })
}

@Test func aForwarderThatCouldNotStartIsAFailure() throws {
    var allowing = try supervisor(.allowWhileOpen)
    guard case .pending(let id) = allowing.submit(request(board), now: start),
        let execution = allowing.approve(id, now: start)?.execution,
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
    let failed = allowing.lanEndpointOpened(launch, localPort: nil, failure: "bind failed", now: start)
    #expect(failed.isError && allowing.lanForwards.isEmpty)
}

@Test func theProfileAllowsOnlyTheForwardersPorts() throws {
    let scope = try SessionScope(ceiling: "/work", root: "/work/p")
    let tcp = LANForward(
        endpoint: try LANEndpoint.parse(host: "192.168.1.50", port: 80, transport: "tcp").get(),
        localPort: 50001
    )
    let udp = LANForward(
        endpoint: try LANEndpoint.parse(host: "10.0.0.7", port: 5000, transport: "udp").get(),
        localPort: 50002
    )
    let profile = try SandboxProfile.changing(scope: scope, lanForwards: [tcp, udp])
    #expect(profile.contains(#"(allow network-outbound (remote tcp4 "localhost:50001"))"#))
    #expect(profile.contains(#"(allow network-outbound (remote udp4 "localhost:50002"))"#))
    #expect(!profile.contains("192.168") && !profile.contains("10.0.0.7"))
    #expect(!(try SandboxProfile.changing(scope: scope)).contains("50001"))
}
