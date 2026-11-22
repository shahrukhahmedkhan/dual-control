#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// Why a serial operation failed.
    public enum SerialError: Error, Equatable, CustomStringConvertible {
        /// Another program has the port open exclusively, e.g. a flash or a monitor.
        case busy(String)
        /// The port does not exist (any more).
        case notFound(String)
        /// `open` failed otherwise.
        case openFailed(String, Int32)
        /// The line settings were refused.
        case configureFailed(String)
        /// DTR or RTS could not be set.
        case modemLinesFailed(Int32)
        /// Writing failed, or the device stopped taking bytes.
        case writeFailed(Int32)
        /// The device is gone or the session is closed.
        case closed

        /// What went wrong, for the caller's result.
        public var description: String {
            switch self {
            case .busy(let path):
                return "\(DisplayText.escaped(path)) is busy: another program (a flash or a monitor?) has it open"
            case .notFound(let path): return "\(DisplayText.escaped(path)) does not exist; is the device plugged in?"
            case .openFailed(let path, let code):
                return "\(DisplayText.escaped(path)) could not be opened: \(String(cString: strerror(code)))"
            case .configureFailed(let what): return "the line settings were refused: \(what)"
            case .modemLinesFailed(let code): return "DTR/RTS could not be set: \(String(cString: strerror(code)))"
            case .writeFailed(let code):
                return code == 0
                    ? "the device stopped taking bytes" : "writing failed: \(String(cString: strerror(code)))"
            case .closed: return "the port is closed or the device is gone"
            }
        }
    }

    /// A serial line: the port I/O behind `SerialConnection`, so it can be tested with a pty pair or a fake.
    public protocol SerialLine: AnyObject, Sendable {
        /// Waits up to `timeoutMilliseconds` for bytes and returns what arrived, empty if none. Throws once the
        /// device is gone.
        func receive(timeoutMilliseconds: Int32) throws(SerialError) -> [UInt8]
        /// Sends every byte or throws.
        func send(_ bytes: [UInt8]) throws(SerialError)
        /// Asserts (`true`) or clears a modem line; `nil` leaves it.
        func setModemLines(dtr: Bool?, rts: Bool?) throws(SerialError)
        /// Closes the line. Called once, after the last `receive` has returned.
        func close()
    }

    /// A tty opened with termios: raw, non-blocking, exclusive.
    public final class TermiosLine: SerialLine, @unchecked Sendable {
        // <sys/ttycom.h> and <IOKit/serial/ioss.h> define these with function-like macros, which Swift does not
        // import.
        static let tiocexcl: UInt = 0x2000_740D
        static let tiocmbis: UInt = 0x8004_746C
        static let tiocmbic: UInt = 0x8004_746B
        static let iossiospeed: UInt = 0x8008_5402
        static let tiocmDTR: Int32 = 0x2
        static let tiocmRTS: Int32 = 0x4

        private let fd: Int32

        /// Opens `path` so that no other program can open it while it is open: `O_EXLOCK` fails at once if another
        /// program holds the lock, and `TIOCEXCL` makes every later open fail with "busy".
        public init(path: String, settings: SerialSettings) throws(SerialError) {
            let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_EXLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                switch errno {
                case EBUSY, EAGAIN: throw .busy(path)
                case ENOENT, ENXIO: throw .notFound(path)
                case let code: throw .openFailed(path, code)
                }
            }
            self.fd = fd
            do throws(SerialError) {
                guard ioctl(fd, Self.tiocexcl) == 0 else { throw .openFailed(path, errno) }
                try configure(settings)
            } catch {
                Darwin.close(fd)
                throw error
            }
        }

        private func configure(_ settings: SerialSettings) throws(SerialError) {
            var options = termios()
            guard tcgetattr(fd, &options) == 0 else { throw .configureFailed("tcgetattr: \(errno)") }
            cfmakeraw(&options)
            options.c_cflag |= tcflag_t(CLOCAL | CREAD)
            options.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CCTS_OFLOW | CRTS_IFLOW)
            let sizes = [5: CS5, 6: CS6, 7: CS7, 8: CS8]
            options.c_cflag |= tcflag_t(sizes[settings.dataBits] ?? CS8)
            switch settings.parity {
            case .none: break
            case .even: options.c_cflag |= tcflag_t(PARENB)
            case .odd: options.c_cflag |= tcflag_t(PARENB | PARODD)
            }
            if settings.stopBits == 2 { options.c_cflag |= tcflag_t(CSTOPB) }
            if settings.flow == .rtsCts { options.c_cflag |= tcflag_t(CCTS_OFLOW | CRTS_IFLOW) }
            options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
            // VMIN 0, VTIME 0: reads never block; `receive` waits with poll.
            withUnsafeMutableBytes(of: &options.c_cc) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 0
            }
            cfsetspeed(&options, speed_t(settings.baud))
            if tcsetattr(fd, TCSANOW, &options) == 0 { return }
            // A rate termios does not know: set a standard one, then the real one through the driver.
            cfsetspeed(&options, speed_t(B9600))
            var speed = speed_t(settings.baud)
            guard tcsetattr(fd, TCSANOW, &options) == 0, ioctl(fd, Self.iossiospeed, &speed) == 0 else {
                throw .configureFailed("\(settings.description): \(String(cString: strerror(errno)))")
            }
        }

        /// Polls, then reads what is there.
        public func receive(timeoutMilliseconds: Int32) throws(SerialError) -> [UInt8] {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, timeoutMilliseconds)
            if ready < 0 {
                if errno == EINTR { return [] }
                throw .closed
            }
            if ready == 0 { return [] }
            if poller.revents & Int16(POLLNVAL) != 0 { throw .closed }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Array(bytes[..<count]) }
            if count < 0, errno == EAGAIN || errno == EINTR { return [] }
            // Readable but nothing to read, or an error: the device hung up.
            throw .closed
        }

        /// Writes in a loop, waiting for room; gives up if it takes over 5 s.
        public func send(_ bytes: [UInt8]) throws(SerialError) {
            var offset = 0
            let deadline = Date().addingTimeInterval(5)
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { buffer in
                    Darwin.write(
                        fd,
                        UnsafeRawBufferPointer(rebasing: buffer[offset...]).baseAddress,
                        buffer.count - offset
                    )
                }
                if written > 0 {
                    offset += written
                    continue
                }
                guard written < 0, errno == EAGAIN || errno == EINTR else {
                    throw .writeFailed(written < 0 ? errno : 0)
                }
                guard Date() < deadline else { throw .writeFailed(0) }
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&poller, 1, 100)
            }
        }

        /// TIOCMBIS / TIOCMBIC.
        public func setModemLines(dtr: Bool?, rts: Bool?) throws(SerialError) {
            for (wanted, bit) in [(dtr, Self.tiocmDTR), (rts, Self.tiocmRTS)] {
                guard let wanted else { continue }
                var bits = bit
                guard ioctl(fd, wanted ? Self.tiocmbis : Self.tiocmbic, &bits) == 0 else {
                    throw .modemLinesFailed(errno)
                }
            }
        }

        /// Closes the descriptor, which also drops the exclusive lock.
        public func close() {
            Darwin.close(fd)
        }
    }
#endif
