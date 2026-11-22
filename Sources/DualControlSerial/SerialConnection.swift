#if canImport(Darwin)
    import DualControlCore
    import Foundation

    /// An open port: a thread reads it continuously into a `SerialBuffer` so nothing is lost between reads. Every
    /// method may be called from any thread; `close()` any number of times.
    public final class SerialConnection: @unchecked Sendable {
        private let line: any SerialLine
        private let condition = NSCondition()
        private var buffer: SerialBuffer
        private var gone = false
        private var closing = false
        private let readerDone = DispatchSemaphore(value: 0)
        /// Serializes writes and resets.
        private let control = NSLock()

        /// Starts reading `line` into a buffer of `capacity` bytes.
        public init(line: any SerialLine, capacity: Int = SerialLimits.bufferBytes) {
            self.line = line
            buffer = SerialBuffer(capacity: capacity)
            let thread = Thread { [self] in readLoop() }
            thread.name = "serial reader"
            thread.start()
        }

        /// Opens `port` with termios and starts reading it.
        public static func open(_ port: String, settings: SerialSettings) throws(SerialError) -> SerialConnection {
            SerialConnection(line: try TermiosLine(path: port, settings: settings))
        }

        private func readLoop() {
            defer { readerDone.signal() }
            while true {
                condition.lock()
                let stop = closing
                condition.unlock()
                if stop { return }
                do {
                    let bytes = try line.receive(timeoutMilliseconds: 100)
                    guard !bytes.isEmpty else { continue }
                    condition.lock()
                    buffer.append(bytes)
                    condition.broadcast()
                    condition.unlock()
                } catch {
                    condition.lock()
                    gone = true
                    condition.broadcast()
                    condition.unlock()
                    return
                }
            }
        }

        /// Takes up to `maxBytes` of the oldest buffered bytes, waiting up to `waitMilliseconds` for the first one.
        /// Also says how many were dropped before them and whether the device is gone.
        public func read(maxBytes: Int, waitMilliseconds: Int) -> (bytes: [UInt8], dropped: Int, deviceGone: Bool) {
            let deadline = Date().addingTimeInterval(Double(waitMilliseconds) / 1000)
            condition.lock()
            defer { condition.unlock() }
            while buffer.count == 0, !gone, !closing, condition.wait(until: deadline) {}
            let taken = buffer.take(maxBytes)
            return (taken.bytes, taken.dropped, gone || closing)
        }

        /// Sends `bytes`.
        public func write(_ bytes: [UInt8]) throws(SerialError) {
            control.lock()
            defer { control.unlock() }
            guard isUsable else { throw .closed }
            try line.send(bytes)
        }

        /// Runs a reset sequence on DTR and RTS.
        public func reset(_ steps: [SerialResetStep]) throws(SerialError) {
            control.lock()
            defer { control.unlock() }
            guard isUsable else { throw .closed }
            for step in steps {
                switch step {
                case .dtr(let value): try line.setModemLines(dtr: value, rts: nil)
                case .rts(let value): try line.setModemLines(dtr: nil, rts: value)
                case .wait(let milliseconds): Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
                }
            }
        }

        private var isUsable: Bool {
            condition.lock()
            defer { condition.unlock() }
            return !gone && !closing
        }

        /// Stops the reader, then closes the line; buffered bytes are discarded.
        public func close() {
            condition.lock()
            let first = !closing
            closing = true
            condition.broadcast()
            condition.unlock()
            guard first else { return }
            readerDone.wait()
            control.withLock { line.close() }
        }

        deinit {
            close()
        }
    }
#endif
