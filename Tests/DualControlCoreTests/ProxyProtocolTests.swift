import Testing

@testable import DualControlCore

private let token = String(repeating: "5e", count: 32)
private let endpoint = ProxyEndpoint(port: 50123, token: token)

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func parsed(_ text: String) throws -> ProxyRequest {
    guard case .complete(let request, _) = try ProxyRequest.parse(bytes(text)) else {
        Issue.record("incomplete")
        throw ProxyProtocolError.malformed("incomplete")
    }
    return request
}

private func auth() -> String {
    "Proxy-Authorization: \(endpoint?.authorization ?? "")\r\n"
}

@Test func connectRequestsAreParsed() throws {
    let text = "CONNECT pypi.org:443 HTTP/1.1\r\nHost: pypi.org:443\r\n\(auth())User-Agent: pip\r\n\r\nEXTRA"
    guard case .complete(let request, let length) = try ProxyRequest.parse(bytes(text)) else {
        Issue.record("incomplete")
        return
    }
    #expect(request.kind == .connect)
    #expect(request.method == "CONNECT")
    #expect(request.host == "pypi.org")
    #expect(request.port == 443)
    #expect(length == text.utf8.count - "EXTRA".utf8.count)
    #expect(request.header("user-agent") == ["pip"])
}

@Test func absoluteFormRequestsAreParsed() throws {
    let request = try parsed("GET http://GitHub.com/a/b.git/info/refs?service=git-upload-pack HTTP/1.1\r\n\r\n")
    #expect(request.kind == .forward(path: "/a/b.git/info/refs?service=git-upload-pack"))
    #expect(request.host == "GitHub.com")
    #expect(request.port == 80)
    #expect(try parsed("HEAD http://pypi.org:8080 HTTP/1.0\r\n\r\n").kind == .forward(path: "/"))
    #expect(try parsed("HEAD http://pypi.org:8080 HTTP/1.0\r\n\r\n").port == 8080)
    #expect(try parsed("GET http://pypi.org?x HTTP/1.1\r\n\r\n").kind == .forward(path: "/?x"))
}

@Test func incompleteHeadsWaitForMoreAndLargeOnesAreRefused() throws {
    #expect(try ProxyRequest.parse(bytes("CONNECT pypi.org:443 HTTP/1.1\r\nHost: x\r\n")) == .incomplete)
    let huge = "GET http://pypi.org/ HTTP/1.1\r\nX: " + String(repeating: "a", count: ProxyRequest.maxHeadBytes)
    #expect(throws: ProxyProtocolError.tooLarge) { try ProxyRequest.parse(bytes(huge)) }
}

@Test(
    arguments: [
        "CONNECT pypi.org HTTP/1.1\r\n\r\n",
        "CONNECT pypi.org:0 HTTP/1.1\r\n\r\n",
        "CONNECT pypi.org:65536 HTTP/1.1\r\n\r\n",
        "CONNECT pypi.org:+443 HTTP/1.1\r\n\r\n",
        "CONNECT pypi.org:443/x HTTP/1.1\r\n\r\n",
        "CONNECT [::1]:443 HTTP/1.1\r\n\r\n",
        "CONNECT user@pypi.org:443 HTTP/1.1\r\n\r\n",
        "GET /relative HTTP/1.1\r\n\r\n",
        "GET https://pypi.org/ HTTP/1.1\r\n\r\n",
        "GET ftp://pypi.org/ HTTP/1.1\r\n\r\n",
        "GET http://user:pw@pypi.org/ HTTP/1.1\r\n\r\n",
        "GET http:///x HTTP/1.1\r\n\r\n",
        "GET http://pypi.org/a#frag HTTP/1.1\r\n\r\n",
        "GET http://pypi.org/a b HTTP/1.1\r\n\r\n",
        "GET http://pypi.org/ HTTP/2.0\r\n\r\n",
        "GET http://pypi.org/\r\n\r\n",
        "G\u{1}T http://pypi.org/ HTTP/1.1\r\n\r\n",
        "GET http://pypi.org/ HTTP/1.1\r\nX-A: 1\r\n folded\r\n\r\n",
        "GET http://pypi.org/ HTTP/1.1\r\nNo colon\r\n\r\n",
        "GET http://pypi.org/ HTTP/1.1\r\nBad Name: 1\r\n\r\n",
        "GET http://pypi.org/ HTTP/1.1\r\nX: a\u{0}b\r\n\r\n",
        "GET http://pypi.org/ HTTP/1.1\nX: a\r\n\r\n",
        "GET http://pypi.org/ HTTP/1.1\r\nX: a\rb\r\n\r\n",
        "GET http://pypi.org/ HTTP/1.1\r\nX: caf\u{E9}\r\n\r\n",
    ]
)
func malformedRequestsAreRefused(_ text: String) {
    #expect(throws: ProxyProtocolError.self) { try ProxyRequest.parse(bytes(text)) }
}

@Test func onlyTheSessionTokenAuthenticates() throws {
    let endpoint = try #require(endpoint)
    let good = try parsed("CONNECT pypi.org:443 HTTP/1.1\r\n\(auth())\r\n")
    #expect(good.isAuthorized(by: endpoint))
    #expect(!(try parsed("CONNECT pypi.org:443 HTTP/1.1\r\n\r\n")).isAuthorized(by: endpoint))
    let other = try #require(ProxyEndpoint(port: 50123, token: String(repeating: "e5", count: 32)))
    #expect(!good.isAuthorized(by: other))
    let twice = try parsed("CONNECT pypi.org:443 HTTP/1.1\r\n\(auth())\(auth())\r\n")
    #expect(!twice.isAuthorized(by: endpoint))
    // The scheme is case-insensitive; the credentials are not.
    let lower = try parsed(
        "CONNECT pypi.org:443 HTTP/1.1\r\nproxy-authorization: basic \(endpoint.authorization.dropFirst(6))\r\n\r\n"
    )
    #expect(lower.isAuthorized(by: endpoint))
    let mangled = try parsed(
        "CONNECT pypi.org:443 HTTP/1.1\r\nProxy-Authorization: \(endpoint.authorization.lowercased())\r\n\r\n"
    )
    #expect(!mangled.isAuthorized(by: endpoint))
}

@Test func forwardedHeadsDropHopByHopHeadersAndTheToken() throws {
    let request = try parsed(
        "POST http://github.com/a.git/git-upload-pack HTTP/1.0\r\nHost: evil.com\r\n\(auth())"
            + "Proxy-Connection: keep-alive\r\nConnection: keep-alive, X-Secret\r\nX-Secret: 1\r\nKeep-Alive: 5\r\n"
            + "Upgrade: websocket\r\nExpect: 100-continue\r\nTE: trailers\r\nContent-Length: 3\r\n"
            + "Content-Type: application/x-git-upload-pack-request\r\n\r\n"
    )
    let head = String(decoding: request.forwardedHead(), as: UTF8.self)
    #expect(
        head == "POST /a.git/git-upload-pack HTTP/1.1\r\nHost: github.com\r\nContent-Length: 3\r\n"
            + "Content-Type: application/x-git-upload-pack-request\r\nConnection: close\r\n\r\n"
    )
    let port = try parsed("GET http://pypi.org:8080/x HTTP/1.1\r\n\r\n")
    #expect(String(decoding: port.forwardedHead(), as: UTF8.self).contains("Host: pypi.org:8080\r\n"))
}

@Test func bodiesAreFramedStrictly() throws {
    #expect(try parsed("GET http://pypi.org/ HTTP/1.1\r\n\r\n").bodyFraming() == .none)
    #expect(try parsed("POST http://pypi.org/ HTTP/1.1\r\nContent-Length: 12\r\n\r\n").bodyFraming() == .length(12))
    #expect(
        try parsed("POST http://pypi.org/ HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n").bodyFraming()
            == .length(5)
    )
    #expect(
        try parsed("POST http://pypi.org/ HTTP/1.1\r\nTransfer-Encoding: Chunked\r\n\r\n").bodyFraming() == .chunked
    )
    for smuggling in [
        "Content-Length: 5\r\nContent-Length: 6\r\n",
        "Content-Length: 5, 6\r\n",
        "Content-Length: -1\r\n",
        "Content-Length: +5\r\n",
        "Content-Length: 0x5\r\n",
        "Content-Length: 99999999999999999999\r\n",
        "Content-Length: 5\r\nTransfer-Encoding: chunked\r\n",
        "Transfer-Encoding: gzip, chunked\r\n",
        "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n",
        "Transfer-Encoding: identity\r\n",
    ] {
        let request = try parsed("POST http://pypi.org/ HTTP/1.1\r\n\(smuggling)\r\n")
        #expect(throws: ProxyProtocolError.self, "\(smuggling)") { try request.bodyFraming() }
    }
}

@Test func chunkedBodiesEndExactlyAtTheirLastChunk() throws {
    var scanner = ChunkedBodyScanner()
    let body = bytes("4\r\nWiki\r\n5;ext=1\r\npedia\r\nA\r\n0123456789\r\n0\r\nTrailer: x\r\n\r\n")
    let next = bytes("POST /git-receive-pack HTTP/1.1\r\n\r\n")
    // One byte at a time, then the rest with a smuggled request after it.
    var consumed = 0
    for byte in body.prefix(10) { consumed += try scanner.consume([byte][...]) }
    consumed += try scanner.consume((Array(body.dropFirst(10)) + next)[...])
    #expect(scanner.isDone)
    #expect(consumed == body.count)
    #expect(try scanner.consume(next[...]) == 0)
}

@Test(arguments: ["Z\r\n", "-1\r\n", "\r\n", "4\nWiki", "4\r\nWikiXX", "FFFFFFFFFFFFFFFFF\r\n", " 4\r\n"])
func badChunksAreRefused(_ text: String) {
    var scanner = ChunkedBodyScanner()
    #expect(throws: ProxyProtocolError.self) { _ = try scanner.consume(bytes(text)[...]) }
}

@Test func responseHeadsAreForcedToClose() throws {
    var rewriter = ResponseHeadRewriter()
    let upstream = bytes(
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\n"
            + "Content-Length: 2\r\n\r\nhi"
    )
    var out: [UInt8] = []
    for byte in upstream.prefix(20) { out += try rewriter.feed([byte][...]) }
    out += try rewriter.feed(upstream.dropFirst(20))
    #expect(rewriter.isDone)
    #expect(
        String(decoding: out, as: UTF8.self)
            == "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
    )
    #expect(try rewriter.feed(bytes("more")[...]) == bytes("more"))
    var bad = ResponseHeadRewriter()
    #expect(throws: ProxyProtocolError.self) { _ = try bad.feed(bytes("SSH-2.0-x\r\n\r\n")[...]) }
}

@Test func refusalsAreSmallHTTPResponsesThatClose() {
    let text = String(decoding: ProxyResponse.refusal(403, "host not allowed: x [network.not-allowed]"), as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
    #expect(text.contains("Connection: close\r\n"))
    #expect(text.hasSuffix("\r\n\r\nDual Control: host not allowed: x [network.not-allowed]\n"))
    let challenge = String(decoding: ProxyResponse.refusal(407, "x"), as: UTF8.self)
    #expect(challenge.contains("Proxy-Authenticate: Basic realm=\"Dual Control\"\r\n"))
    #expect(String(decoding: ProxyResponse.established, as: UTF8.self) == "HTTP/1.1 200 Connection established\r\n\r\n")
}
