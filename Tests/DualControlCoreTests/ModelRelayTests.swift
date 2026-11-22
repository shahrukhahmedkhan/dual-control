import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let token = String(repeating: "a1", count: 32)
private let endpoint: ModelRelayEndpoint = {
    guard let endpoint = ModelRelayEndpoint(port: 4100, token: token) else { fatalError("the test endpoint is valid") }
    return endpoint
}()

private func head(_ text: String) throws -> RelayRequestHead {
    let bytes = Array(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    guard case .complete(let head, let length) = try RelayRequestHead.parse(bytes) else {
        throw RelayRequestHead.ParseError(description: "incomplete")
    }
    #expect(length == bytes.count)
    return head
}

private func messages(
    _ target: String = "/v1/messages?beta=true",
    method: String = "POST",
    auth: String = "authorization: Bearer \(token)",
    extra: String = "content-length: 12\n"
) throws -> RelayRequestHead {
    try head("\(method) \(target) HTTP/1.1\nhost: 127.0.0.1:4100\n\(auth)\n\(extra)\n")
}

// MARK: - The endpoint

@Test func theAgentGetsOnlyTheRelayURLAndTheSessionToken() {
    #expect(
        endpoint.variables == ["ANTHROPIC_BASE_URL": "http://127.0.0.1:4100", "ANTHROPIC_AUTH_TOKEN": token]
    )
    #expect(ModelRelayEndpoint(port: 0, token: token) == nil)
    #expect(ModelRelayEndpoint(port: 1, token: "short") == nil)
    #expect(ModelRelayEndpoint(port: 1, token: String(repeating: "Z", count: 64)) == nil)
}

// MARK: - Parsing

@Test func aHeadIsParsedOnceComplete() throws {
    let parsed = try messages()
    #expect(parsed.method == "POST" && parsed.target == "/v1/messages?beta=true")
    #expect(parsed.value("Content-Length") == "12" && parsed.value("HOST") == "127.0.0.1:4100")
    guard case .incomplete = try RelayRequestHead.parse(Array("POST / HTTP/1.1\r\nhost: x\r\n".utf8)) else {
        Issue.record("complete too early")
        return
    }
}

@Test(arguments: [
    "POST /v1/messages HTTP/1.0\r\n\r\n", "POST  /v1/messages HTTP/1.1\r\n\r\n", "POST /v1/messages\r\n\r\n",
    "POST /v1/messages HTTP/1.1\r\nbad header\r\n\r\n", "POST /v1/messages HTTP/1.1\r\nx: a\u{0}b\r\n\r\n",
    "POST /v1/messages HTTP/1.1\r\n x: folded\r\n\r\n",
])
func malformedHeadsAreRefused(_ text: String) {
    #expect(throws: RelayRequestHead.ParseError.self) { try RelayRequestHead.parse(Array(text.utf8)) }
}

@Test func anOversizedHeadIsRefused() {
    let text = "POST /v1/messages HTTP/1.1\r\nx: " + String(repeating: "a", count: RelayRequestHead.maxHeadBytes)
    #expect(throws: RelayRequestHead.ParseError.self) { try RelayRequestHead.parse(Array(text.utf8)) }
}

// MARK: - Deciding

@Test func messagesWithTheSessionTokenAreForwarded() throws {
    for target in ["/v1/messages", "/v1/messages?beta=true", "/v1/messages/count_tokens?beta=true"] {
        guard case .forward(let path, let length, _) = ModelRelayPolicy.decide(try messages(target), endpoint: endpoint)
        else {
            Issue.record("\(target) refused")
            continue
        }
        #expect(path == target && length == 12)
    }
    // x-api-key works too (ANTHROPIC_API_KEY).
    let keyed = try messages(auth: "x-api-key: \(token)")
    guard case .forward = ModelRelayPolicy.decide(keyed, endpoint: endpoint) else {
        Issue.record("x-api-key refused")
        return
    }
}

@Test(arguments: ["", "authorization: Bearer nope", "authorization: Basic \(token)", "x-api-key: sk-ant-real"])
func withoutTheSessionTokenNothingIsForwarded(_ auth: String) throws {
    let request = try messages(auth: auth.isEmpty ? "x-other: 1" : auth)
    #expect(
        ModelRelayPolicy.decide(request, endpoint: endpoint) == .refuse(401, "the session token is missing or wrong")
    )
}

@Test(arguments: [
    ("GET", "/v1/messages"), ("POST", "/v1/models"), ("POST", "/v1/files"), ("POST", "/v1/messages/batches"),
    ("POST", "/v1/messages?beta=true&x=1"), ("POST", "/v1/messages?other=1"), ("POST", "http://evil/v1/messages"),
    ("POST", "/v1/messages/../files"), ("POST", "/v1/messages#x"), ("DELETE", "/v1/messages"),
])
func onlyTheMessagesEndpointsArePassed(_ method: String, _ target: String) throws {
    guard
        case .refuse(let status, _) = ModelRelayPolicy.decide(try messages(target, method: method), endpoint: endpoint)
    else {
        Issue.record("\(method) \(target) forwarded")
        return
    }
    #expect([404, 405].contains(status))
}

@Test func theBodyMustHaveALengthWithinTheLimit() throws {
    let chunked = try messages(extra: "transfer-encoding: chunked\n")
    #expect(ModelRelayPolicy.decide(chunked, endpoint: endpoint) == .refuse(411, "a Content-Length is required"))
    let none = try messages(extra: "")
    #expect(ModelRelayPolicy.decide(none, endpoint: endpoint) == .refuse(411, "a Content-Length is required"))
    let both = try messages(extra: "content-length: 5\ntransfer-encoding: chunked\n")
    #expect(ModelRelayPolicy.decide(both, endpoint: endpoint) == .refuse(411, "a Content-Length is required"))
    let twice = try messages(extra: "content-length: 5\ncontent-length: 6\n")
    #expect(ModelRelayPolicy.decide(twice, endpoint: endpoint) == .refuse(400, "the Content-Length is not valid"))
    let huge = try messages(extra: "content-length: \(ModelRelayPolicy.maxBodyBytes + 1)\n")
    #expect(ModelRelayPolicy.decide(huge, endpoint: endpoint) == .refuse(413, "the request is too large"))
    let signed = try messages(extra: "content-length: -1\n")
    #expect(ModelRelayPolicy.decide(signed, endpoint: endpoint) == .refuse(400, "the Content-Length is not valid"))
}

@Test func onlyKnownHeadersGoUpstreamAndNeverTheAgentsCredentials() throws {
    let request = try messages(
        extra: """
            content-length: 12
            x-api-key: sk-ant-agent-supplied
            content-type: application/json
            anthropic-version: 2023-06-01
            anthropic-beta: a,b
            x-stainless-os: MacOS
            x-claude-code-session-id: s1
            cookie: c=1
            proxy-authorization: Basic x
            accept-encoding: gzip
            x-forwarded-for: 1.2.3.4

            """
    )
    guard case .forward(_, _, let headers) = ModelRelayPolicy.decide(request, endpoint: endpoint) else {
        Issue.record("refused")
        return
    }
    let names = headers.map { $0.0 }
    #expect(
        Set(names) == [
            "content-type", "anthropic-version", "anthropic-beta", "x-stainless-os", "x-claude-code-session-id",
        ]
    )
    #expect(!headers.contains { $0.1.contains(token) || $0.1.contains("sk-ant") })
}

// MARK: - The credential

@Test func onlyAnAnthropicAPIKeyCanBeSaved() {
    #expect(ModelRelayPolicy.keyProblem("sk-ant-api03-" + String(repeating: "x", count: 40)) == nil)
    for bad in ["", "sk-ant-", "hello", "sk-ant-api03-a b", "sk-ant-api03-\u{1B}x", String(repeating: "s", count: 300)]
    {
        #expect(ModelRelayPolicy.keyProblem(bad) != nil, "\(bad)")
    }
}

// MARK: - Audit

@Test func theModelIsReadFromTheBodyButNothingElse() {
    #expect(ModelRelayPolicy.model(Data(#"{"model":"claude-opus-5-5","messages":[]}"#.utf8)) == "claude-opus-5-5")
    #expect(ModelRelayPolicy.model(Data("not json".utf8)) == "?")
    #expect(ModelRelayPolicy.model(Data(#"{"model":"a\u001bb"}"#.utf8)) == "?")
    #expect(ModelRelayPolicy.model(Data(#"{"model":"\#(String(repeating: "m", count: 200))"}"#.utf8)) == "?")
}

@Test func everyRelayRequestIsAuditedWithoutItsBody() throws {
    var supervisor = Supervisor(scope: try SessionScope(ceiling: "/work", root: "/work/p"), sandboxProblem: nil)
    _ = supervisor.drainAuditLines()
    supervisor.recordModelRelay(
        ModelRelayExchange(
            number: 3,
            path: "/v1/messages?beta=true",
            model: "claude-opus-5-5",
            status: 200,
            bytesUp: 1200,
            bytesDown: 3400,
            duration: 2.5,
            refusal: nil
        ),
        now: start
    )
    supervisor.recordModelRelay(
        ModelRelayExchange(
            number: 4,
            path: "/v1/files",
            model: "?",
            status: 404,
            bytesUp: 0,
            bytesDown: 0,
            duration: 0,
            refusal: "only the messages endpoints"
        ),
        now: start
    )
    supervisor.recordModelKeyChange(saved: true, now: start)
    let all = supervisor.drainAuditLines()
    #expect(all.last?.contains("model relay key saved") == true && all.last?.contains("sk-ant") == false)
    let lines = Array(all.dropLast())
    #expect(lines.count == 2)
    #expect(
        lines[0].contains("m3 POST /v1/messages?beta=true model claude-opus-5-5: 200, up 1200 B, down 3400 B, 2.5 s")
    )
    #expect(lines[1].contains("m4 POST /v1/files: refused 404: only the messages endpoints"))
    #expect(supervisor.feed.first?.tool == "model" && supervisor.feed.first?.outcome == .denied)
    #expect(supervisor.feed[1].outcome == .allowed)
}
