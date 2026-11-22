#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlNetwork
    @testable import DualControlSandbox

    /// D7b against the real kernel: agent processes reach an approved LAN endpoint only through its forwarder's
    /// local port, never another port or a LAN address directly. No device is needed: the forwarder's connector is
    /// pointed at an echo server on 127.0.0.1 standing in for the board.
    private final class Session {
        let base: String
        let scope: SessionScope

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in ["/D/p", "/D/.dual-control/agent-home", "/D/.dual-control/tmp"] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            scope = try ResolvedScope.make(choosing: base + "/D/p", ceiling: base + "/D")
        }

        deinit { try? FileManager.default.removeItem(atPath: base) }

        func sh(_ script: String, forwards: [LANForward]) throws -> SandboxRun {
            let sandbox = Sandbox(scope: scope, toolchains: [], lanForwards: forwards)
            return try sandbox.run(["/bin/sh", "-c", script], kind: .changing, cwd: scope.root)
        }
    }

    /// An echo server on 127.0.0.1 (TCP: echoes one connection's bytes until it closes; UDP: echoes datagrams).
    private final class Echo: @unchecked Sendable {
        let fd: Int32
        let port: UInt16

        init(udp: Bool) throws {
            let listener = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
            var address = LANForwarder.loopback(port: 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0
                }
            }
            guard bound, udp || listen(listener, 4) == 0 else { throw ConnectFailure(reason: "echo", timedOut: false) }
            fd = listener
            port = UInt16(bigEndian: address.sin_port)
            Thread {
                let fd = listener
                var buffer = [UInt8](repeating: 0, count: 4096)
                if udp {
                    while true {
                        var from = sockaddr_storage()
                        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
                        let count = withUnsafeMutablePointer(to: &from) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                recvfrom(fd, &buffer, 4096, 0, $0, &size)
                            }
                        }
                        guard count >= 0 else { return }
                        _ = withUnsafePointer(to: &from) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, buffer, count, 0, $0, size)
                            }
                        }
                    }
                }
                while true {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    while true {
                        let count = read(client, &buffer, 4096)
                        guard count > 0, write(client, buffer, count) == count else { break }
                    }
                    Darwin.close(client)
                }
            }.start()
        }

        func close() { Darwin.close(fd) }

        /// A connector that reaches this server instead of the device.
        var connector: LANConnector {
            let port = self.port
            return { endpoint in
                let fd = socket(AF_INET, endpoint.transport == .tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
                var address = LANForwarder.loopback(port: port)
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                return connected ? .success(fd) : .failure(ConnectFailure(reason: "echo", timedOut: false))
            }
        }
    }

    /// Records what a forwarder reports.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [NetworkAttempt] = []
        private var transfers: [NetworkTransfer] = []

        func add(_ attempt: NetworkAttempt) { lock.withLock { attempts.append(attempt) } }
        func add(_ transfer: NetworkTransfer) { lock.withLock { transfers.append(transfer) } }
        var all: ([NetworkAttempt], [NetworkTransfer]) { lock.withLock { (attempts, transfers) } }
    }

    private func endpoint(_ transport: String) throws -> LANEndpoint {
        try LANEndpoint.parse(host: "192.168.77.50", port: 80, transport: transport).get()
    }

    private func notPermitted(_ run: SandboxRun) -> Bool {
        run.status != 0 && run.output.contains("Operation not permitted")
    }

    @Suite(.serialized) struct LANEndpointEnforcement {
        @Test func onlyTheForwardersPortIsReachableNeverTheLANItself() throws {
            let session = try Session()
            let allowed = try Echo(udp: false)
            let other = try Echo(udp: false)
            defer {
                allowed.close()
                other.close()
            }
            let forward = LANForward(endpoint: try endpoint("tcp"), localPort: allowed.port)
            let reached = try session.sh("/usr/bin/nc -z -G 2 127.0.0.1 \(allowed.port)", forwards: [forward])
            #expect(reached.status == 0, "\(reached.output)")
            for script in [
                "/usr/bin/nc -v -z -G 2 127.0.0.1 \(other.port)",
                "/usr/bin/nc -v -z -G 2 192.168.77.50 80", "/usr/bin/nc -v -z -G 2 10.0.0.1 1883",
                "/usr/bin/nc -v -z -u -w 1 192.168.77.50 80",
            ] {
                let run = try session.sh(script, forwards: [forward])
                #expect(notPermitted(run), "\(script): \(run.output)")
            }
            // Without the approval, not even the forwarder's port.
            #expect(notPermitted(try session.sh("/usr/bin/nc -v -z -G 2 127.0.0.1 \(allowed.port)", forwards: [])))
        }

        @Test func tcpGoesThroughTheForwarderAndIsReported() throws {
            let session = try Session()
            let board = try Echo(udp: false)
            defer { board.close() }
            let reports = Reports()
            let forwarder = LANForwarder(
                endpoint: try endpoint("tcp"),
                connect: board.connector,
                onAttempt: { reports.add($0) },
                onClosed: { reports.add($0) }
            )
            let port = try forwarder.start()
            defer { forwarder.stop() }
            let forward = LANForward(endpoint: forwarder.endpoint, localPort: port)
            let run = try session.sh("printf DC-TEST-lan | /usr/bin/nc -v -w 2 127.0.0.1 \(port)", forwards: [forward])
            #expect(run.output.contains("DC-TEST-lan"), "\(run.output) \(reports.all)")
            for _ in 0..<50 where reports.all.1.isEmpty { usleep(50_000) }
            let (attempts, transfers) = reports.all
            #expect(attempts.map(\.method) == ["TCP"] && attempts.first?.host == "192.168.77.50")
            #expect(attempts.first?.decision.ruleID == "lan.endpoint" && attempts.first!.connection > 1_000_000)
            #expect(
                transfers.first?.bytesUp == 11 && transfers.first?.bytesDown == 11 && transfers.first?.failure == nil
            )
        }

        @Test func udpGoesThroughTheForwarderAndRepliesComeBack() throws {
            let session = try Session()
            let board = try Echo(udp: true)
            defer { board.close() }
            let reports = Reports()
            let forwarder = LANForwarder(
                endpoint: try endpoint("udp"),
                connect: board.connector,
                onAttempt: { reports.add($0) },
                onClosed: { reports.add($0) }
            )
            let port = try forwarder.start()
            let forward = LANForward(endpoint: forwarder.endpoint, localPort: port)
            let run = try session.sh("printf DC-TEST-udp | /usr/bin/nc -u -w 1 127.0.0.1 \(port)", forwards: [forward])
            #expect(run.output.contains("DC-TEST-udp"), "\(run.output)")
            forwarder.stop()
            let (attempts, transfers) = reports.all
            #expect(attempts.map(\.method) == ["UDP"])
            #expect(transfers.first?.bytesUp == 11 && transfers.first?.bytesDown == 11)
        }

        @Test func aDeviceThatDoesNotAnswerIsReportedAsAFailure() throws {
            let reports = Reports()
            let forwarder = LANForwarder(
                endpoint: try endpoint("tcp"),
                connect: { _ in .failure(ConnectFailure(reason: "the device did not answer", timedOut: true)) },
                onAttempt: { reports.add($0) },
                onClosed: { reports.add($0) }
            )
            let port = try forwarder.start()
            defer { forwarder.stop() }
            let client = socket(AF_INET, SOCK_STREAM, 0)
            var address = LANForwarder.loopback(port: port)
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            var byte: UInt8 = 0
            #expect(read(client, &byte, 1) == 0)
            close(client)
            for _ in 0..<50 where reports.all.1.isEmpty { usleep(50_000) }
            #expect(reports.all.1.first?.failure == "the device did not answer")
        }
    }
#endif
