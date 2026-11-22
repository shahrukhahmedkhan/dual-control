#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlNetwork

    private let ownerKey = "sk-ant-api03-" + String(repeating: "k", count: 40)

    /// A fake Anthropic API on 127.0.0.1: answers each connection with `reply` and keeps what it received.
    final class FakeUpstream: @unchecked Sendable {
        let port: UInt16
        private let fd: Int32
        private let lock = NSLock()
        private var received: [String] = []
        let reply: String

        init(reply: String) throws {
            self.reply = reply
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0
                }
            }
            let listening = bound && listen(listener, 8) == 0
            fd = listener
            port = UInt16(bigEndian: address.sin_port)
            try #require(listening)
            let thread = Thread { [self] in serve() }
            thread.start()
        }

        var requests: [String] { lock.withLock { received } }

        private func serve() {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var data: [UInt8] = []
                var buffer = [UInt8](repeating: 0, count: 65536)
                // The head, then its Content-Length body.
                while true {
                    let count = read(client, &buffer, buffer.count)
                    guard count > 0 else { break }
                    data += buffer[..<count]
                    let text = String(decoding: data, as: UTF8.self)
                    if let end = text.range(of: "\r\n\r\n") {
                        let head = text[..<end.lowerBound].lowercased()
                        let length =
                            head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                            .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                        if text.utf8.distance(from: text.utf8.startIndex, to: end.upperBound) + length <= data.count {
                            break
                        }
                    }
                }
                lock.withLock { received.append(String(decoding: data, as: UTF8.self)) }
                _ = reply.withCString { write(client, $0, strlen($0)) }
                Darwin.close(client)
            }
        }

        func close() { Darwin.close(fd) }
    }

    /// Sends `request` to 127.0.0.1:`port` and returns everything until the server closes.
    func exchange(_ port: UInt16, _ request: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return "" }
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            out += buffer[..<count]
        }
        return String(decoding: out, as: UTF8.self)
    }

    private final class Exchanges: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [ModelRelayExchange] = []
        func add(_ exchange: ModelRelayExchange) { lock.withLock { all.append(exchange) } }
        var list: [ModelRelayExchange] { lock.withLock { all } }
    }

    private func request(
        token: String,
        path: String = "/v1/messages?beta=true",
        extra: String = "",
        body: String = #"{"model":"claude-opus-5-5","stream":true}"#
    ) -> String {
        "POST \(path) HTTP/1.1\r\nhost: 127.0.0.1\r\nauthorization: Bearer \(token)\r\n"
            + "content-type: application/json\r\nanthropic-version: 2023-06-01\r\n\(extra)"
            + "content-length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    private let streamed =
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nrequest-id: req_1\r\nset-cookie: s=1\r\n"
        + "x-internal: secret\r\ncontent-length: 27\r\n\r\nevent: ping\ndata: {\"a\":1}\n\n"

    @Test func theOwnersKeyReplacesWhateverTheAgentSentAndTheAnswerStreamsBack() throws {
        let upstream = try FakeUpstream(reply: streamed)
        defer { upstream.close() }
        let seen = Exchanges()
        let relay = ModelRelayServer(
            upstream: "http://127.0.0.1:\(upstream.port)",
            credential: { ownerKey },
            onExchange: seen.add
        )
        let endpoint = try relay.start()
        defer { relay.stop() }
        let token = try #require(endpoint.variables["ANTHROPIC_AUTH_TOKEN"])
        let reply = exchange(
            endpoint.port,
            request(token: token, extra: "x-api-key: sk-ant-agent-own\r\ncookie: c=1\r\n")
        )

        #expect(reply.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(reply)")
        #expect(reply.contains("request-id: req_1") && reply.contains("transfer-encoding: chunked"))
        #expect(reply.contains("event: ping\ndata: {\"a\":1}\n\n") && reply.hasSuffix("0\r\n\r\n"))
        #expect(!reply.contains("set-cookie") && !reply.contains("x-internal"))

        let sent = try #require(upstream.requests.first).lowercased()
        #expect(sent.hasPrefix("post /v1/messages?beta=true http/1.1\r\n"), "\(sent)")
        #expect(sent.contains("x-api-key: \(ownerKey.lowercased())"))
        #expect(!sent.contains("sk-ant-agent-own") && !sent.contains(token) && !sent.contains("authorization:"))
        #expect(!sent.contains("cookie: c=1"))
        #expect(
            sent.contains("anthropic-version: 2023-06-01")
                && sent.hasSuffix(#"{"model":"claude-opus-5-5","stream":true}"#)
        )

        let recorded = try #require(seen.list.first)
        #expect(recorded.model == "claude-opus-5-5" && recorded.status == 200 && recorded.refusal == nil)
        #expect(recorded.bytesDown == 27 && recorded.bytesUp > 0)
    }

    @Test func theUsageOfAnAnswerIsReported() throws {
        let events =
            "event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n"
            + "event: message_delta\ndata: {\"usage\":{\"output_tokens\":42}}\n\n"
        let upstream = try FakeUpstream(
            reply: "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: \(events.utf8.count)\r\n\r\n"
                + events
        )
        defer { upstream.close() }
        let seen = Exchanges()
        let relay = ModelRelayServer(
            upstream: "http://127.0.0.1:\(upstream.port)",
            credential: { ownerKey },
            onExchange: seen.add
        )
        let endpoint = try relay.start()
        defer { relay.stop() }
        _ = exchange(endpoint.port, request(token: try #require(endpoint.variables["ANTHROPIC_AUTH_TOKEN"])))
        #expect(seen.list.first?.usage == RelayUsage(inputTokens: 7, outputTokens: 42))
        #expect((seen.list.first?.cost ?? 0) > 0)
    }

    @Test func atTheBudgetNothingGoesUpstreamAndTheRefusalIsReported() throws {
        let upstream = try FakeUpstream(reply: streamed)
        defer { upstream.close() }
        let seen = Exchanges()
        let relay = ModelRelayServer(
            upstream: "http://127.0.0.1:\(upstream.port)",
            credential: { ownerKey },
            budgetRefusal: { "the owner's monthly model budget of $5.00 is used up" },
            onExchange: seen.add
        )
        let endpoint = try relay.start()
        defer { relay.stop() }
        let reply = exchange(endpoint.port, request(token: try #require(endpoint.variables["ANTHROPIC_AUTH_TOKEN"])))
        #expect(reply.hasPrefix("HTTP/1.1 403 ") && reply.contains("budget of $5.00"))
        #expect(upstream.requests.isEmpty)
        #expect(seen.list.first?.refusal?.contains("budget") == true && seen.list.first?.model == "claude-opus-5-5")
    }

    @Test func withoutTheTokenNothingGoesUpstreamAndNothingIsReported() throws {
        let upstream = try FakeUpstream(reply: streamed)
        defer { upstream.close() }
        let seen = Exchanges()
        let relay = ModelRelayServer(
            upstream: "http://127.0.0.1:\(upstream.port)",
            credential: { ownerKey },
            onExchange: seen.add
        )
        let endpoint = try relay.start()
        defer { relay.stop() }
        let reply = exchange(endpoint.port, request(token: String(repeating: "0", count: 64)))
        #expect(reply.hasPrefix("HTTP/1.1 401 "))
        #expect(!reply.contains(ownerKey))
        #expect(upstream.requests.isEmpty && seen.list.isEmpty)
    }

    @Test func otherEndpointsAndAMissingKeyAreRefusedAndReported() throws {
        let upstream = try FakeUpstream(reply: streamed)
        defer { upstream.close() }
        let seen = Exchanges()
        let keyless = ModelRelayServer(
            upstream: "http://127.0.0.1:\(upstream.port)",
            credential: { nil },
            onExchange: seen.add
        )
        let endpoint = try keyless.start()
        defer { keyless.stop() }
        let token = try #require(endpoint.variables["ANTHROPIC_AUTH_TOKEN"])
        #expect(exchange(endpoint.port, request(token: token, path: "/v1/files")).hasPrefix("HTTP/1.1 404 "))
        let noKey = exchange(endpoint.port, request(token: token))
        #expect(noKey.hasPrefix("HTTP/1.1 503 ") && noKey.contains("model key"))
        #expect(upstream.requests.isEmpty)
        #expect(seen.list.map(\.status) == [404, 503] && seen.list.allSatisfy { $0.refusal != nil })
    }

    @Test func aRedirectIsNeverFollowed() throws {
        let target = try FakeUpstream(reply: streamed)
        defer { target.close() }
        let redirecting = try FakeUpstream(
            reply: "HTTP/1.1 307 Temporary Redirect\r\nlocation: http://127.0.0.1:\(target.port)/v1/messages\r\n"
                + "content-length: 0\r\n\r\n"
        )
        defer { redirecting.close() }
        let relay = ModelRelayServer(
            upstream: "http://127.0.0.1:\(redirecting.port)",
            credential: { ownerKey },
            onExchange: { _ in }
        )
        let endpoint = try relay.start()
        defer { relay.stop() }
        let token = try #require(endpoint.variables["ANTHROPIC_AUTH_TOKEN"])
        let reply = exchange(endpoint.port, request(token: token))
        #expect(reply.hasPrefix("HTTP/1.1 307 "), "\(reply)")
        #expect(target.requests.isEmpty, "the key must not follow a redirect")
    }

    @Test func stopClosesTheRelay() throws {
        let relay = ModelRelayServer(credential: { ownerKey }, onExchange: { _ in })
        let endpoint = try relay.start()
        relay.stop()
        Thread.sleep(forTimeInterval: 0.2)
        #expect(exchange(endpoint.port, "x").isEmpty)
        #expect(relay.endpoint == nil)
    }
#endif
