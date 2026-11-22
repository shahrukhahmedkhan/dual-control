#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlNetwork

    /// A server on 127.0.0.1 standing in for the internet: it records every byte each connection sends until the
    /// client stops (EOF or a quiet second) and either echoes or answers once with `reply` after a complete head.
    private final class FakeServer: @unchecked Sendable {
        let port: UInt16
        private let fd: Int32
        private let lock = NSLock()
        private var received: [[UInt8]] = []

        init(reply: [UInt8]? = nil) throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            self.fd = fd
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
                }
            }
            try #require(ok && listen(fd, 16) == 0)
            port = UInt16(bigEndian: address.sin_port)
            let listener = fd
            Thread { [self] in
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    Thread { [self] in serve(client, reply: reply) }.start()
                }
            }.start()
        }

        deinit { close(fd) }

        private func serve(_ client: Int32, reply: [UInt8]?) {
            var got: [UInt8] = []
            var answered = false
            while let chunk = readSome(client, timeout: 1) {
                got += chunk
                if let reply {
                    if !answered, String(decoding: got, as: UTF8.self).contains("\r\n\r\n") {
                        answered = true
                        _ = writeAll(client, reply)
                        shutdown(client, SHUT_WR)
                    }
                } else {
                    _ = writeAll(client, chunk)
                }
            }
            lock.withLock { received.append(got) }
            close(client)
        }

        /// What each finished connection sent, in order of finishing.
        func connections(waitingFor count: Int) -> [[UInt8]] {
            for _ in 0..<50 where lock.withLock({ received.count }) < count { usleep(100_000) }
            return lock.withLock { received }
        }
    }

    /// Events the proxy reported, and the hosts it connected to.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var attempts: [NetworkAttempt] = []
        private(set) var closed: [NetworkTransfer] = []
        private(set) var dialed: [String] = []

        func attempt(_ value: NetworkAttempt) { lock.withLock { attempts.append(value) } }
        func close(_ value: NetworkTransfer) { lock.withLock { closed.append(value) } }
        func dial(_ host: String) { lock.withLock { dialed.append(host) } }

        func snapshot() -> (attempts: [NetworkAttempt], closed: [NetworkTransfer], dialed: [String]) {
            lock.withLock { (attempts, closed, dialed) }
        }

        func closedEvents(waitingFor count: Int) -> [NetworkTransfer] {
            for _ in 0..<50 where lock.withLock({ closed.count }) < count { usleep(100_000) }
            return lock.withLock { closed }
        }
    }

    private func connectLoopback(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else {
            close(fd)
            return nil
        }
        prepare(fd)
        return fd
    }

    /// A proxy whose connector always reaches `server`, whatever the host.
    private func makeProxy(_ server: FakeServer?, _ recorder: Recorder, policy: NetworkPolicy = NetworkPolicy())
        throws -> (GatekeeperProxy, ProxyEndpoint)
    {
        let port = server?.port
        let proxy = GatekeeperProxy(
            policy: policy,
            connect: { host, _ in
                recorder.dial(host)
                guard let port, let fd = connectLoopback(port) else {
                    return .failure(ConnectFailure(reason: "the server refused", timedOut: false))
                }
                return .success(fd)
            },
            onAttempt: recorder.attempt,
            onClosed: recorder.close
        )
        return (proxy, try proxy.start())
    }

    /// Sends `text` to the proxy, then reads everything until the proxy closes (or 5 s pass).
    private func exchange(_ endpoint: ProxyEndpoint, _ text: String, halfClose: Bool = false) throws -> String {
        let fd = try #require(connectLoopback(endpoint.port))
        defer { close(fd) }
        #expect(writeAll(fd, Array(text.utf8)))
        if halfClose { shutdown(fd, SHUT_WR) }
        var got: [UInt8] = []
        while let chunk = readSome(fd, timeout: 5) { got += chunk }
        return String(decoding: got, as: UTF8.self)
    }

    private func auth(_ endpoint: ProxyEndpoint) -> String {
        "Proxy-Authorization: \(endpoint.authorization)\r\n"
    }

    @Test func anAllowedTunnelCarriesBytesAndIsReported() throws {
        let server = try FakeServer()
        let recorder = Recorder()
        let (proxy, endpoint) = try makeProxy(server, recorder)
        defer { proxy.stop() }
        let reply = try exchange(
            endpoint,
            "CONNECT pypi.org:443 HTTP/1.1\r\nHost: pypi.org:443\r\n\(auth(endpoint))\r\nping",
            halfClose: true
        )
        #expect(reply == "HTTP/1.1 200 Connection established\r\n\r\nping")
        let closed = recorder.closedEvents(waitingFor: 1)
        let events = recorder.snapshot()
        #expect(events.attempts.map(\.decision.ruleID) == ["network.allowlist"])
        #expect(events.attempts.first?.host == "pypi.org" && events.attempts.first?.port == 443)
        #expect(events.dialed == ["pypi.org"])
        #expect(closed.count == 1)
        #expect(closed.first?.bytesUp == 4 && closed.first?.bytesDown == 4 && closed.first?.failure == nil)
        #expect(closed.first?.connection == events.attempts.first?.connection)
    }

    @Test func aDeniedHostIsNeverDialed() throws {
        let recorder = Recorder()
        let (proxy, endpoint) = try makeProxy(nil, recorder)
        defer { proxy.stop() }
        let reply = try exchange(endpoint, "CONNECT example.com:443 HTTP/1.1\r\n\(auth(endpoint))\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(reply.contains("example.com is not an allowed host"))
        #expect(reply.contains("[network.not-allowed]"))
        let events = recorder.snapshot()
        #expect(events.attempts.map(\.decision.ruleID) == ["network.not-allowed"])
        #expect(events.dialed.isEmpty && events.closed.isEmpty)
    }

    @Test func withoutTheTokenNothingHappens() throws {
        let recorder = Recorder()
        let (proxy, endpoint) = try makeProxy(nil, recorder)
        defer { proxy.stop() }
        let none = try exchange(endpoint, "CONNECT pypi.org:443 HTTP/1.1\r\n\r\n")
        #expect(none.hasPrefix("HTTP/1.1 407 Proxy Authentication Required\r\n"))
        #expect(none.contains("Proxy-Authenticate: Basic realm=\"Dual Control\"\r\n"))
        let other = try #require(ProxyEndpoint(port: endpoint.port, token: ProxyEndpoint.newToken()))
        let wrong = try exchange(endpoint, "CONNECT pypi.org:443 HTTP/1.1\r\n\(auth(other))\r\n")
        #expect(wrong.hasPrefix("HTTP/1.1 407 "))
        let garbage = try exchange(endpoint, "\u{16}\u{3}\u{1}\u{2}\u{0}\r\n\r\n")
        #expect(garbage.hasPrefix("HTTP/1.1 400 "))
        let events = recorder.snapshot()
        #expect(events.attempts.isEmpty && events.dialed.isEmpty)
    }

    @Test func plainHTTPSendsExactlyOneRewrittenRequest() throws {
        let server = try FakeServer(
            reply: Array("HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\nhi".utf8)
        )
        let recorder = Recorder()
        let (proxy, endpoint) = try makeProxy(server, recorder)
        defer { proxy.stop() }
        // A body, then a second request smuggled after it on the same connection.
        let reply = try exchange(
            endpoint,
            "POST http://pypi.org/simple/ HTTP/1.1\r\nHost: evil.com\r\n\(auth(endpoint))Connection: keep-alive\r\n"
                + "Content-Length: 4\r\n\r\nbody"
                + "POST http://pypi.org/x/git-receive-pack HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        )
        #expect(reply == "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi")
        let sent = try #require(server.connections(waitingFor: 1).first)
        #expect(
            String(decoding: sent, as: UTF8.self)
                == "POST /simple/ HTTP/1.1\r\nHost: pypi.org\r\nContent-Length: 4\r\nConnection: close\r\n\r\nbody"
        )
        #expect(!String(decoding: sent, as: UTF8.self).contains(endpoint.authorization))
        let closed = recorder.closedEvents(waitingFor: 1)
        #expect(closed.first?.bytesUp == sent.count)
    }

    @Test func chunkedBodiesStopAtTheirEnd() throws {
        let server = try FakeServer(reply: Array("HTTP/1.1 204 No Content\r\n\r\n".utf8))
        let recorder = Recorder()
        let (proxy, endpoint) = try makeProxy(server, recorder)
        defer { proxy.stop() }
        _ = try exchange(
            endpoint,
            "POST http://github.com/a.git/git-upload-pack HTTP/1.1\r\n\(auth(endpoint))Transfer-Encoding: chunked\r\n"
                + "\r\n4\r\nwant\r\n0\r\n\r\nGET http://github.com/a.git/git-receive-pack HTTP/1.1\r\n\r\n"
        )
        let sent = String(decoding: try #require(server.connections(waitingFor: 1).first), as: UTF8.self)
        #expect(sent.hasSuffix("\r\n\r\n4\r\nwant\r\n0\r\n\r\n"))
        #expect(!sent.contains("receive-pack"))
    }

    @Test func gitPushAndAmbiguousBodiesAreRefusedBeforeDialing() throws {
        let recorder = Recorder()
        let (proxy, endpoint) = try makeProxy(nil, recorder)
        defer { proxy.stop() }
        let push = try exchange(
            endpoint,
            "GET http://github.com/a/b.git/info/refs?service=git-receive-pack HTTP/1.1\r\n\(auth(endpoint))\r\n"
        )
        #expect(push.hasPrefix("HTTP/1.1 403 ") && push.contains("[network.git-push]"))
        let smuggle = try exchange(
            endpoint,
            "POST http://pypi.org/ HTTP/1.1\r\n\(auth(endpoint))Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n"
        )
        #expect(smuggle.hasPrefix("HTTP/1.1 400 ") && smuggle.contains("[network.bad-request]"))
        let events = recorder.snapshot()
        #expect(events.attempts.map(\.decision.ruleID) == ["network.git-push", "network.bad-request"])
        #expect(events.dialed.isEmpty)
    }

    @Test func anUnreachableServerIsReportedWithWhy() throws {
        let recorder = Recorder()
        let (proxy, endpoint) = try makeProxy(nil, recorder)
        defer { proxy.stop() }
        let reply = try exchange(endpoint, "CONNECT github.com:443 HTTP/1.1\r\n\(auth(endpoint))\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"))
        let closed = recorder.closedEvents(waitingFor: 1)
        #expect(closed.first?.failure == "the server refused")
        #expect(closed.first?.bytesUp == 0 && closed.first?.bytesDown == 0)
    }

    @Test func hostsTheOwnerAllowsWorkAtOnce() throws {
        let server = try FakeServer()
        let recorder = Recorder()
        let (proxy, endpoint) = try makeProxy(server, recorder)
        defer { proxy.stop() }
        var policy = NetworkPolicy()
        _ = policy.add("example.com", always: false)
        proxy.update(policy)
        let reply = try exchange(
            endpoint,
            "CONNECT example.com:443 HTTP/1.1\r\n\(auth(endpoint))\r\nx",
            halfClose: true
        )
        #expect(reply == "HTTP/1.1 200 Connection established\r\n\r\nx")
        #expect(recorder.snapshot().attempts.first?.decision.ruleID == "network.session-host")
    }

    @Test func stopClosesOpenTunnelsAndTheListener() throws {
        let server = try FakeServer()
        let recorder = Recorder()
        let (proxy, endpoint) = try makeProxy(server, recorder)
        let fd = try #require(connectLoopback(endpoint.port))
        defer { close(fd) }
        #expect(writeAll(fd, Array("CONNECT pypi.org:443 HTTP/1.1\r\n\(auth(endpoint))\r\n".utf8)))
        let established = try #require(readSome(fd, timeout: 5))
        #expect(established == ProxyResponse.established)
        let began = Date()
        proxy.stop()
        // The tunnel ends at once: end of stream, not the 300 s idle timeout.
        #expect(readSome(fd, timeout: 5) == nil)
        #expect(Date().timeIntervalSince(began) < 3)
        #expect(proxy.endpoint == nil)
        usleep(200_000)
        #expect(connectLoopback(endpoint.port) == nil)
        #expect(recorder.closedEvents(waitingFor: 1).count == 1)
        #expect(throws: ConnectFailure.self) { try proxy.start() }
    }

    @Test func eachStartHasItsOwnPortAndToken() throws {
        let recorder = Recorder()
        let (first, a) = try makeProxy(nil, recorder)
        let (second, b) = try makeProxy(nil, recorder)
        defer {
            first.stop()
            second.stop()
        }
        #expect(a.port != b.port)
        #expect(a.authorization != b.authorization)
    }

    @Test func theRealConnectorNeverReachesThisMachine() {
        // localhost resolves to loopback: refused before any connection is tried.
        let local = PublicConnector.connect(host: "localhost", port: 9)
        #expect(
            local == .failure(ConnectFailure(reason: "it resolves only to local or private addresses", timedOut: false))
        )
        let missing = PublicConnector.connect(host: "dual-control-test.invalid", port: 443)
        #expect(missing == .failure(ConnectFailure(reason: "the host name could not be resolved", timedOut: false)))
    }
#endif
