#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlSerial

    /// A pty pair: the test plays the device on the controller side; the port under test opens the terminal side
    /// by path, exactly as it opens a /dev/cu.* device.
    private final class Pty: @unchecked Sendable {
        let controller: Int32
        let path: String
        private let terminal: Int32

        init() throws {
            var controller: Int32 = 0
            var terminal: Int32 = 0
            var name = [CChar](repeating: 0, count: 128)
            guard openpty(&controller, &terminal, &name, nil, nil) == 0 else { throw SerialError.closed }
            self.controller = controller
            self.terminal = terminal
            path = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Without a raw controller side, the line discipline would echo and translate.
            var options = termios()
            tcgetattr(terminal, &options)
            cfmakeraw(&options)
            tcsetattr(terminal, TCSANOW, &options)
        }

        func send(_ bytes: [UInt8]) {
            _ = bytes.withUnsafeBytes { write(controller, $0.baseAddress, $0.count) }
        }

        /// What the port wrote, waiting up to a second for `count` bytes.
        func received(_ count: Int) -> [UInt8] {
            var result: [UInt8] = []
            let deadline = Date().addingTimeInterval(1)
            while result.count < count, Date() < deadline {
                var poller = pollfd(fd: controller, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 50) > 0 else { continue }
                var buffer = [UInt8](repeating: 0, count: 256)
                let n = buffer.withUnsafeMutableBytes { read(controller, $0.baseAddress, $0.count) }
                if n > 0 { result += buffer[..<n] }
            }
            return result
        }

        private var open = true

        /// Hangs up: the device is unplugged.
        func hangUp() {
            guard open else { return }
            open = false
            close(controller)
            close(terminal)
        }

        deinit {
            hangUp()
        }
    }

    private func standard() throws -> SerialSettings { try #require(SerialSettings(baud: 115_200)) }

    /// One at a time: these tests block their thread while they wait for the port, which would starve other tests'
    /// timing on a busy machine.
    @Suite(.serialized) struct SerialPort {
        @Test func bytesTheDeviceSendsAreBufferedUntilRead() throws {
            let pty = try Pty()
            let connection = try SerialConnection.open(pty.path, settings: try standard())
            defer { connection.close() }
            pty.send(Array("ESP-ROM:esp32s3\r\n".utf8))
            pty.send(Array("boot: ok\n".utf8))
            Thread.sleep(forTimeInterval: 0.3)
            let first = connection.read(maxBytes: 5, waitMilliseconds: 0)
            #expect(first.bytes == Array("ESP-R".utf8))
            #expect(first.dropped == 0 && !first.deviceGone)
            let rest = connection.read(maxBytes: 1000, waitMilliseconds: 0)
            #expect(String(decoding: rest.bytes, as: UTF8.self) == "OM:esp32s3\r\nboot: ok\n")
        }

        @Test func aReadWaitsForTheFirstByte() throws {
            let pty = try Pty()
            let connection = try SerialConnection.open(pty.path, settings: try standard())
            defer { connection.close() }
            let started = Date()
            #expect(connection.read(maxBytes: 10, waitMilliseconds: 200).bytes.isEmpty)
            #expect(Date().timeIntervalSince(started) >= 0.19)
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.1)
                pty.send([0x41])
            }
            // Returns as soon as the byte arrives; the long wait only keeps a busy machine from failing the test.
            #expect(connection.read(maxBytes: 10, waitMilliseconds: 10_000).bytes == [0x41])
        }

        @Test func writesReachTheDevice() throws {
            let pty = try Pty()
            let connection = try SerialConnection.open(pty.path, settings: try standard())
            defer { connection.close() }
            let bytes = Array("AT\r\n".utf8) + [0x00, 0xFF]
            try connection.write(bytes)
            #expect(pty.received(bytes.count) == bytes)
            let large = [UInt8](repeating: 0x55, count: SerialLimits.maxWriteBytes)
            DispatchQueue.global().async { _ = pty.received(large.count) }
            try connection.write(large)
        }

        @Test func aFullBufferDropsTheOldestBytesAndSaysSo() throws {
            let pty = try Pty()
            let connection = SerialConnection(
                line: try TermiosLine(path: pty.path, settings: try standard()),
                capacity: 8
            )
            defer { connection.close() }
            pty.send(Array("0123456789abcdef".utf8))
            Thread.sleep(forTimeInterval: 0.3)
            let read = connection.read(maxBytes: 100, waitMilliseconds: 0)
            #expect(read.bytes == Array("89abcdef".utf8))
            #expect(read.dropped == 8)
        }

        @Test func thePortIsExclusive() throws {
            let pty = try Pty()
            let connection = try SerialConnection.open(pty.path, settings: try standard())
            #expect(throws: SerialError.busy(pty.path)) {
                _ = try TermiosLine(path: pty.path, settings: try standard())
            }
            connection.close()
            // Free again once closed.
            try TermiosLine(path: pty.path, settings: try standard()).close()
        }

        @Test func aPortAnotherProgramHoldsIsBusy() throws {
            let pty = try Pty()
            let holder = open(pty.path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_EXLOCK)
            #expect(holder >= 0)
            defer { close(holder) }
            let error = #expect(throws: SerialError.self) {
                _ = try TermiosLine(path: pty.path, settings: try standard())
            }
            #expect(error == .busy(pty.path))
            #expect(error?.description.contains("busy") == true)
        }

        @Test func aMissingPortSaysSo() {
            #expect(throws: SerialError.notFound("/dev/cu.dc-test-missing")) {
                _ = try TermiosLine(path: "/dev/cu.dc-test-missing", settings: try standard())
            }
        }

        @Test func unusualRatesAndFramingAreAccepted() throws {
            let pty = try Pty()
            let odd = try #require(SerialSettings(baud: 74_880, dataBits: 7, parity: .odd, stopBits: 2, flow: .rtsCts))
            try TermiosLine(path: pty.path, settings: odd).close()
        }

        @Test func aDeviceThatHangsUpEndsTheSession() throws {
            let pty = try Pty()
            let connection = try SerialConnection.open(pty.path, settings: try standard())
            defer { connection.close() }
            pty.send([0x41])
            Thread.sleep(forTimeInterval: 0.2)
            pty.hangUp()
            Thread.sleep(forTimeInterval: 0.3)
            let read = connection.read(maxBytes: 10, waitMilliseconds: 1000)
            #expect(read.bytes == [0x41])
            #expect(read.deviceGone)
            #expect(throws: SerialError.closed) { try connection.write([0x42]) }
        }

        @Test func closingIsIdempotentAndEndsReads() throws {
            let pty = try Pty()
            let connection = try SerialConnection.open(pty.path, settings: try standard())
            connection.close()
            connection.close()
            #expect(connection.read(maxBytes: 10, waitMilliseconds: 1000).deviceGone)
            #expect(throws: SerialError.closed) { try connection.reset([.dtr(false)]) }
        }

        /// Records modem-line changes with their times.
        private final class FakeLine: SerialLine, @unchecked Sendable {
            let lock = NSLock()
            var changes: [(dtr: Bool?, rts: Bool?, at: Date)] = []
            var closed = false

            func receive(timeoutMilliseconds: Int32) throws(SerialError) -> [UInt8] {
                Thread.sleep(forTimeInterval: Double(timeoutMilliseconds) / 1000)
                return []
            }
            func send(_ bytes: [UInt8]) throws(SerialError) {}
            func setModemLines(dtr: Bool?, rts: Bool?) throws(SerialError) {
                lock.withLock { changes.append((dtr, rts, Date())) }
            }
            func close() { lock.withLock { closed = true } }
        }

        @Test func resetsDriveDTRAndRTSInOrderWithTheirWaits() throws {
            let line = FakeLine()
            let connection = SerialConnection(line: line, capacity: 16)
            let steps = SerialReset.steps(.bootloader, for: nil)
            try connection.reset(steps)
            connection.close()
            #expect(line.closed)
            let recorded = line.changes.map { change -> SerialResetStep in
                change.dtr.map(SerialResetStep.dtr) ?? .rts(change.rts ?? false)
            }
            #expect(recorded == steps.filter { if case .wait = $0 { return false } else { return true } })
            // DTR is asserted at least 100 ms after RTS was: the chip is held in reset first.
            let rtsAsserted = try #require(line.changes.first { $0.rts == true }?.at)
            let dtrAsserted = try #require(line.changes.first { $0.dtr == true }?.at)
            #expect(dtrAsserted.timeIntervalSince(rtsAsserted) >= 0.09)
        }

        @Test func listingNeverShowsDialInOrHiddenPorts() {
            for port in SerialPortList.ports() {
                #expect(SerialPorts.isListed(port.path), "\(port.path)")
            }
            #expect(SerialPortList.lookUp("/dev/tty.Bluetooth-Incoming-Port") == nil)
            #expect(SerialPortList.lookUp("/dev/cu.Bluetooth-Incoming-Port") == nil)
        }
    }
#endif
