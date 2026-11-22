#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import DualControlNetwork
    import Foundation
    import Testing

    @testable import DualControlSandbox

    /// The kernel half of the gatekeeper (D7a), on the real kernel: CHANGING processes reach only the proxy's
    /// port, and through the real proxy the tools git uses pick up the proxy variables and the token.
    private final class NetFixture {
        let base: String
        let scope: SessionScope

        init() throws {
            var template = Array("/tmp/dc-net-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in [
                "/home/Developer/p", "/home/Developer/.dual-control/agent-home", "/home/Developer/.dual-control/tmp",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            scope = try ResolvedScope.make(choosing: base + "/home/Developer/p", ceiling: base + "/home/Developer")
        }

        deinit { try? FileManager.default.removeItem(atPath: base) }

        func sandbox(_ proxy: ProxyEndpoint?) -> Sandbox {
            Sandbox(scope: scope, toolchains: Toolchain.readPaths(), proxy: proxy)
        }
    }

    /// A TCP listener on 127.0.0.1 that answers every connection once with `reply` after a request head and
    /// records the heads it got.
    private final class Listener: @unchecked Sendable {
        let fd: Int32
        let port: UInt16
        private let lock = NSLock()
        private var heads: [String] = []

        init(reply: String = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nDC-TEST\r\n") throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            self.fd = fd
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
                }
            }
            try #require(bound && listen(fd, 16) == 0)
            port = UInt16(bigEndian: address.sin_port)
            Thread { [self] in
                while true {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    Thread { [self] in
                        var got = ""
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        while !got.contains("\r\n\r\n") {
                            let count = read(client, &buffer, buffer.count)
                            guard count > 0 else { break }
                            got += String(decoding: buffer[..<count], as: UTF8.self)
                        }
                        lock.withLock { heads.append(got) }
                        _ = reply.withCString { write(client, $0, strlen($0)) }
                        close(client)
                    }.start()
                }
            }.start()
        }

        deinit { close(fd) }

        func received() -> [String] { lock.withLock { heads } }
    }

    /// Refused by the kernel, not by the listener: netcat is run with `-v` so it says why.
    private func refused(_ run: SandboxRun) -> Bool {
        run.status != 0 && run.output.contains("Operation not permitted")
    }

    @Test func changingReachesOnlyTheProxyPort() throws {
        let f = try NetFixture()
        let proxy = try Listener()
        let other = try Listener()
        let endpoint = try #require(ProxyEndpoint(port: proxy.port, token: ProxyEndpoint.newToken()))
        let sandbox = f.sandbox(endpoint)
        func run(_ argv: [String]) throws -> SandboxRun { try sandbox.run(argv, kind: .changing, cwd: f.scope.root) }

        #expect(try run(["/usr/bin/nc", "-z", "-G", "2", "127.0.0.1", String(proxy.port)]).status == 0)
        #expect(refused(try run(["/usr/bin/nc", "-v", "-z", "-G", "2", "127.0.0.1", String(other.port)])))
        #expect(refused(try run(["/usr/bin/nc", "-v", "-z", "-G", "2", "1.1.1.1", "443"])))
        #expect(refused(try run(["/usr/bin/nc", "-v", "-6", "-z", "-G", "2", "::1", String(proxy.port)])))
        usleep(200_000)
        #expect(other.received().isEmpty)
        // No DNS: the resolver's socket is out of reach, so no lookup can carry data out.
        let lookup = try run(["/usr/bin/nc", "-v", "-z", "-G", "2", "example.com", "443"])
        #expect(lookup.status != 0 && !lookup.output.contains("succeeded"))
        // No listening and no UDP.
        let perl = """
            use Socket;
            socket(T, PF_INET, SOCK_STREAM, 0) or die "socket: $!";
            print bind(T, sockaddr_in(0, INADDR_ANY)) ? "bound\\n" : "bind: $!\\n";
            socket(U, PF_INET, SOCK_DGRAM, 0) or die "socket: $!";
            print send(U, "x", 0, sockaddr_in(53, inet_aton("8.8.8.8"))) ? "sent\\n" : "send: $!\\n";
            """
        let sockets = try run(["/usr/bin/perl", "-e", perl])
        #expect(sockets.output == "bind: Operation not permitted\nsend: Operation not permitted\n", "\(sockets.output)")
    }

    @Test func withoutAProxyThereIsNoNetworkAtAll() throws {
        let f = try NetFixture()
        let listener = try Listener()
        let run = try f.sandbox(nil).run(
            ["/usr/bin/nc", "-v", "-z", "-G", "2", "127.0.0.1", String(listener.port)],
            kind: .changing,
            cwd: f.scope.root
        )
        #expect(refused(run))
        #expect(listener.received().isEmpty)
    }

    @Test func theAgentEnvironmentPointsAtTheProxy() throws {
        let f = try NetFixture()
        let endpoint = try #require(ProxyEndpoint(port: 50123, token: ProxyEndpoint.newToken()))
        let changing = try f.sandbox(endpoint).run(["/usr/bin/env"], kind: .changing, cwd: f.scope.root)
        #expect(changing.output.contains("https_proxy=\(endpoint.url)\n"))
        #expect(changing.output.contains("HTTPS_PROXY=\(endpoint.url)\n"))
        #expect(changing.output.contains("NO_PROXY=localhost,127.0.0.1,::1\n"))
        // READ-ONLY has no network, so it gets no token either.
        let readOnly = try f.sandbox(endpoint).run(["/usr/bin/env"], kind: .readOnly, cwd: f.scope.root)
        #expect(!readOnly.output.lowercased().contains("proxy"))
    }

    /// Curl and git, inside the sandbox, through the real proxy: plain HTTP is forwarded with the token checked
    /// (git answers the 407 challenge with it), HTTPS to a host that is not allowed is refused with 403.
    @Test func toolsGoThroughTheProxyAndItsAllowlist() throws {
        let f = try NetFixture()
        let server = try Listener()
        let dialed = Dialed()
        let proxy = GatekeeperProxy(
            policy: NetworkPolicy(),
            connect: { host, _ in
                dialed.add(host)
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                address.sin_port = server.port.bigEndian
                let ok = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                return ok ? .success(fd) : .failure(ConnectFailure(reason: "refused", timedOut: false))
            },
            onAttempt: { _ in },
            onClosed: { _ in }
        )
        let endpoint = try proxy.start()
        defer { proxy.stop() }
        let sandbox = f.sandbox(endpoint)
        func run(_ argv: [String]) throws -> SandboxRun { try sandbox.run(argv, kind: .changing, cwd: f.scope.root) }

        let plain = try run(["/usr/bin/curl", "-sS", "-m", "10", "http://pypi.org/simple/"])
        #expect(plain.output.contains("DC-TEST"), "\(plain.output)")
        let denied = try run(["/usr/bin/curl", "-sS", "-m", "10", "https://example.com/"])
        #expect(denied.status != 0)
        #expect(denied.output.contains("403"), "\(denied.output)")

        let git = try #require(Toolchain.git())
        _ = try run([git, "ls-remote", "http://github.com/espressif/esp-idf.git"])
        let heads = server.received()
        #expect(heads.contains { $0.hasPrefix("GET /simple/ HTTP/1.1\r\nHost: pypi.org\r\n") })
        #expect(heads.contains { $0.hasPrefix("GET /espressif/esp-idf.git/info/refs?service=git-upload-pack ") })
        #expect(!heads.contains { $0.contains(endpoint.authorization) })
        #expect(dialed.hosts == ["pypi.org", "github.com"])
    }

    /// The hosts a test connector was asked for.
    private final class Dialed: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []

        func add(_ host: String) { lock.withLock { list.append(host) } }
        var hosts: [String] { lock.withLock { list } }
    }
#endif
