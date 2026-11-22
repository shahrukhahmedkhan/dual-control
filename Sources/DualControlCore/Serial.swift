import Foundation

/// The identity of a USB serial device: what "always allow this device" matches. Only a device with a USB serial
/// number can be told apart from others of the same model. Many boards report a default serial number instead
/// (TinyUSB's `123456`, a CP210x's `0001`), so for those, and for a number two connected devices share, the
/// device is also told apart by the USB port it is plugged into (its IOKit location).
public struct SerialDevice: Sendable, Equatable, Hashable, Codable {
    /// USB vendor id.
    public var vendorID: Int
    /// USB product id.
    public var productID: Int
    /// USB serial number, if the device reports one.
    public var serialNumber: String?
    /// IOKit `locationID`: the physical USB port (and hub ports) the device is plugged into.
    public var locationID: Int?
    /// True if another connected device, on another USB port, reports the same VID:PID and serial number.
    public var serialNumberShared: Bool

    /// Creates an identity.
    public init(
        vendorID: Int,
        productID: Int,
        serialNumber: String? = nil,
        locationID: Int? = nil,
        serialNumberShared: Bool = false
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.locationID = locationID
        self.serialNumberShared = serialNumberShared
    }

    private enum CodingKeys: String, CodingKey {
        case vendorID, productID, serialNumber, locationID, serialNumberShared
    }

    /// Decodes an identity; ones saved before locations were recorded have neither location field.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vendorID = try container.decode(Int.self, forKey: .vendorID)
        productID = try container.decode(Int.self, forKey: .productID)
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber)
        locationID = try container.decodeIfPresent(Int.self, forKey: .locationID)
        serialNumberShared = try container.decodeIfPresent(Bool.self, forKey: .serialNumberShared) ?? false
    }

    /// Serial numbers that firmware and USB bridges ship with, compared ignoring case.
    static let defaultSerialNumbers: Set<String> = [
        "0", "0001", "000000", "00000000", "000000000000", "0000000000000000", "0123456789", "0123456789abcdef",
        "123456", "12345678", "123456789", "1234567890", "123456789abc", "abcdef", "ffffffff", "ffffffffffff",
    ]

    /// True if the serial number is a known default, or is blank or one character repeated.
    public var hasDefaultSerialNumber: Bool {
        guard let serialNumber else { return false }
        let trimmed = serialNumber.trimmingCharacters(in: .whitespaces).lowercased()
        return Set(trimmed).count <= 1 || Self.defaultSerialNumbers.contains(trimmed)
    }

    /// True if the serial number alone does not tell this device apart: a rule for it also needs its USB port.
    public var needsLocation: Bool { hasDefaultSerialNumber || serialNumberShared }

    /// True if "always allow this device" can be offered: it has a serial number, plus a location if it needs one.
    public var canBeRemembered: Bool { serialNumber != nil && (!needsLocation || locationID != nil) }

    /// True if a rule made for `remembered` covers this device: same VID:PID and serial number, and the same USB
    /// port if either of them needs one.
    public func isCovered(by remembered: SerialDevice) -> Bool {
        guard remembered.canBeRemembered, canBeRemembered, vendorID == remembered.vendorID,
            productID == remembered.productID, serialNumber == remembered.serialNumber
        else { return false }
        return !(needsLocation || remembered.needsLocation) || locationID == remembered.locationID
    }

    /// `VID:PID` in lowercase hex, e.g. `303a:1001`.
    public var vidPid: String { Self.hex4(vendorID) + ":" + Self.hex4(productID) }

    /// E.g. `303a:1001 serial 1A2B at USB location 0x14100000`, escaped.
    public var label: String {
        var text =
            vidPid
            + (serialNumber.map { " serial " + DisplayText.summary($0, limit: 64) } ?? " (no serial number)")
        if serialNumber != nil, needsLocation { text += " (not unique)" }
        if let locationID { text += " at USB location 0x" + Self.hex(locationID, digits: 8) }
        return text
    }

    /// Espressif's built-in USB-JTAG-serial (ESP32-S3, -C3, -C6, …), which resets with its own DTR/RTS sequence.
    public var isEspressifUSBJTAGSerial: Bool { vendorID == 0x303A && productID == 0x1001 }

    static func hex4(_ value: Int) -> String { hex(value & 0xFFFF, digits: 4) }

    static func hex(_ value: Int, digits: Int) -> String {
        let hex = String(UInt64(truncatingIfNeeded: value), radix: 16)
        return String(repeating: "0", count: max(0, digits - hex.count)) + hex
    }
}

/// A serial port as `serial_list` shows it.
public struct SerialPortInfo: Sendable, Equatable, Codable {
    /// The callout device, e.g. `/dev/cu.usbserial-1410`.
    public var path: String
    /// The USB device behind it, if it is a USB device.
    public var device: SerialDevice?
    /// USB product name.
    public var product: String?
    /// USB manufacturer name.
    public var manufacturer: String?

    /// Creates a port description.
    public init(path: String, device: SerialDevice? = nil, product: String? = nil, manufacturer: String? = nil) {
        self.path = path
        self.device = device
        self.product = product
        self.manufacturer = manufacturer
    }

    /// One line: path, then USB identity and names, all escaped.
    public var line: String {
        var parts = [DisplayText.escaped(path)]
        if let device { parts.append("USB " + device.label) }
        if let product { parts.append("product \"\(DisplayText.summary(product, limit: 80))\"") }
        if let manufacturer { parts.append("manufacturer \"\(DisplayText.summary(manufacturer, limit: 80))\"") }
        return parts.joined(separator: " · ")
    }
}

/// Which ports Claude may see and open.
public enum SerialPorts {
    /// macOS ports that are never a device on a desk.
    static let hiddenNames = ["bluetooth-incoming-port", "debug-console"]

    /// True for a callout device `/dev/cu.<name>` (never a `/dev/tty.*` dial-in device, which waits for carrier),
    /// other than Bluetooth-Incoming-Port and debug-console.
    public static func isListed(_ path: String) -> Bool {
        guard path.hasPrefix("/dev/cu."), !path.contains("\0") else { return false }
        let name = path.dropFirst("/dev/cu.".count)
        guard !name.isEmpty, !name.contains("/") else { return false }
        return !hiddenNames.contains { name.lowercased().contains($0) }
    }

    /// `ports` with `serialNumberShared` set on every device whose VID:PID and serial number another device, on
    /// another USB port, also reports. Several ports of one device (a dual UART) share one location: not shared.
    public static func markingSharedSerialNumbers(_ ports: [SerialPortInfo]) -> [SerialPortInfo] {
        struct Key: Hashable {
            let vendorID: Int
            let productID: Int
            let serialNumber: String
        }
        func key(_ device: SerialDevice?) -> Key? {
            guard let device, let serialNumber = device.serialNumber else { return nil }
            return Key(vendorID: device.vendorID, productID: device.productID, serialNumber: serialNumber)
        }
        var locations: [Key: Set<Int?>] = [:]
        var unplaced: [Key: Int] = [:]
        for port in ports {
            guard let key = key(port.device) else { continue }
            locations[key, default: []].insert(port.device?.locationID)
            if port.device?.locationID == nil { unplaced[key, default: 0] += 1 }
        }
        return ports.map { port in
            guard let key = key(port.device) else { return port }
            var port = port
            // Without a location, two ports with the same number cannot be shown to be one device.
            port.device?.serialNumberShared = (locations[key]?.count ?? 0) > 1 || (unplaced[key] ?? 0) > 1
            return port
        }
    }
}

/// Limits on serial sessions.
public enum SerialLimits {
    /// Bytes buffered per session between reads; the oldest are dropped first.
    public static let bufferBytes = 1 << 20
    /// The most bytes one `serial_write` sends.
    public static let maxWriteBytes = 4 << 10
    /// The most bytes one `serial_read` returns.
    public static let maxReadBytes = 64 << 10
    /// What `serial_read` returns when the call names no size.
    public static let defaultReadBytes = 4 << 10
    /// The longest `serial_read` waits for data: well under the relay's cut-off for a call.
    public static let maxWaitMilliseconds = 30_000
    /// How long `serial_read` waits when the call names no wait.
    public static let defaultWaitMilliseconds = 1_000
    /// Sessions open at once.
    public static let maxSessions = 8
    /// Baud rates a session may use.
    public static let baudRange = 50...12_000_000
}

/// Line settings for `serial_open`.
public struct SerialSettings: Sendable, Equatable, Codable {
    /// Parity bit.
    public enum Parity: String, Sendable, Codable, CaseIterable {
        case none, even, odd
    }

    /// Flow control.
    public enum Flow: String, Sendable, Codable, CaseIterable {
        case none
        case rtsCts = "rts_cts"
    }

    /// Bits per second.
    public var baud: Int
    /// 5 to 8.
    public var dataBits: Int
    /// Parity.
    public var parity: Parity
    /// 1 or 2.
    public var stopBits: Int
    /// Flow control.
    public var flow: Flow

    /// Creates settings; `nil` if a value is out of range.
    public init?(baud: Int, dataBits: Int = 8, parity: Parity = .none, stopBits: Int = 1, flow: Flow = .none) {
        guard SerialLimits.baudRange.contains(baud), (5...8).contains(dataBits), [1, 2].contains(stopBits) else {
            return nil
        }
        self.baud = baud
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flow = flow
    }

    /// The operands of an `open` request: baud, framing like `8N1`, flow.
    var operands: [String] {
        [String(baud), "\(dataBits)\(parity.rawValue.prefix(1).uppercased())\(stopBits)", flow.rawValue]
    }

    /// Parses `operands`.
    init?(operands: ArraySlice<String>) {
        let values = Array(operands)
        guard values.count == 3, let baud = Int(values[0]) else { return nil }
        let framing = Array(values[1])
        guard framing.count == 3, let dataBits = Int(String(framing[0])), let stopBits = Int(String(framing[2])),
            let parity = Parity.allCases.first(where: { $0.rawValue.prefix(1).uppercased() == String(framing[1]) }),
            let flow = Flow(rawValue: values[2])
        else { return nil }
        self.init(baud: baud, dataBits: dataBits, parity: parity, stopBits: stopBits, flow: flow)
    }

    /// E.g. `115200 8N1, flow none`.
    public var description: String { "\(operands[0]) \(operands[1]), flow \(flow.rawValue)" }
}

/// A serial operation, decoded from an `ActionRequest` with the `serial` capability. The request's `argv` is the
/// operation's name and its operands, so the audit and the feed record exactly what was asked.
public enum SerialOperation: Sendable, Equatable {
    /// Lists ports; never opens one.
    case list
    /// Opens `port`.
    case open(port: String, SerialSettings)
    /// Returns up to `maxBytes` buffered bytes, waiting up to `waitMilliseconds` for the first.
    case read(session: String, maxBytes: Int, waitMilliseconds: Int, hex: Bool)
    /// Sends bytes.
    case write(session: String, bytes: [UInt8])
    /// Pulses DTR/RTS.
    case reset(session: String, SerialResetMode)

    /// The request's `argv`.
    public var argv: [String] {
        switch self {
        case .list: return ["list"]
        case .open(let port, let settings): return ["open", port] + settings.operands
        case .read(let session, let maxBytes, let wait, let hex):
            return ["read", session, String(maxBytes), String(wait), hex ? "hex" : "text"]
        case .write(let session, let bytes): return ["write", session, SerialText.hexString(bytes)]
        case .reset(let session, let mode): return ["reset", session, mode.rawValue]
        }
    }

    /// Decodes `argv`, or `nil` if it is not a well-formed operation.
    public init?(argv: [String]) {
        guard let name = argv.first else { return nil }
        switch (name, argv.count) {
        case ("list", 1):
            self = .list
        case ("open", 5):
            guard let settings = SerialSettings(operands: argv[2...]) else { return nil }
            self = .open(port: argv[1], settings)
        case ("read", 5):
            guard let maxBytes = Int(argv[2]), let wait = Int(argv[3]), ["hex", "text"].contains(argv[4]) else {
                return nil
            }
            self = .read(session: argv[1], maxBytes: maxBytes, waitMilliseconds: wait, hex: argv[4] == "hex")
        case ("write", 3):
            guard let bytes = SerialText.bytes(hex: argv[2]) else { return nil }
            self = .write(session: argv[1], bytes: bytes)
        case ("reset", 3):
            guard let mode = SerialResetMode(rawValue: argv[2]) else { return nil }
            self = .reset(session: argv[1], mode)
        default:
            return nil
        }
    }

    /// The session it acts on, if any.
    public var session: String? {
        switch self {
        case .list, .open: return nil
        case .read(let session, _, _, _), .write(let session, _), .reset(let session, _): return session
        }
    }

    /// One escaped line for the feed and the approval card.
    public var summary: String {
        switch self {
        case .list: return "list ports"
        case .open(let port, let settings): return "open \(DisplayText.escaped(port)) at \(settings.description)"
        case .read(let session, let maxBytes, let wait, let hex):
            return "read \(DisplayText.escaped(session)) up to \(maxBytes) bytes, wait \(wait) ms\(hex ? ", hex" : "")"
        case .write(let session, let bytes):
            return "write \(DisplayText.escaped(session)) \(bytes.count) bytes: \"\(SerialText.inline(bytes))\""
        case .reset(let session, let mode): return "reset \(DisplayText.escaped(session)) into \(mode.rawValue)"
        }
    }
}

/// An open serial port, as the supervisor knows it. The app holds the port itself.
public struct SerialSession: Sendable, Equatable, Identifiable {
    /// Random, unguessable id, e.g. `serial-1f3a…` (16 hex digits).
    public let id: String
    /// The callout device.
    public let port: String
    /// The USB device, when it was opened.
    public let device: SerialDevice?
    /// Line settings.
    public let settings: SerialSettings
    /// When it was opened.
    public let openedAt: Date
    /// True once it was reset into the ROM bootloader, or opened while its device was there: `serial_write` is
    /// refused for the rest of the session.
    public internal(set) var writesRefused: Bool
}

/// `run` restarts the firmware; `bootloader` restarts into the ROM download mode.
public enum SerialResetMode: String, Sendable, Codable, CaseIterable {
    case run, bootloader
}

/// One step of a reset: set a modem line (`true` asserts it), or wait.
public enum SerialResetStep: Sendable, Equatable {
    case dtr(Bool)
    case rts(Bool)
    case wait(milliseconds: Int)
}

/// DTR/RTS reset sequences, as esptool drives them. On the classic auto-reset circuit, RTS asserted alone holds
/// EN (reset) low and DTR asserted alone holds IO0 (boot mode) low; both or neither do nothing.
public enum SerialReset {
    /// The steps for `mode` on `device`: Espressif's USB-JTAG-serial gets its own sequence, everything else the
    /// classic one.
    public static func steps(_ mode: SerialResetMode, for device: SerialDevice?) -> [SerialResetStep] {
        let usbJTAG = device?.isEspressifUSBJTAGSerial == true
        switch (mode, usbJTAG) {
        case (.run, false):
            return [.dtr(false), .rts(true), .wait(milliseconds: 100), .rts(false)]
        case (.run, true):
            return [.dtr(false), .rts(true), .wait(milliseconds: 200), .rts(false), .wait(milliseconds: 200)]
        case (.bootloader, false):
            return [
                .dtr(false), .rts(true), .wait(milliseconds: 100), .dtr(true), .rts(false), .wait(milliseconds: 50),
                .dtr(false),
            ]
        case (.bootloader, true):
            return [
                .rts(false), .dtr(false), .wait(milliseconds: 100), .dtr(true), .rts(false), .wait(milliseconds: 100),
                .rts(true), .dtr(false), .rts(true), .wait(milliseconds: 100), .rts(false), .dtr(false),
            ]
        }
    }
}

/// A fixed-capacity byte buffer that keeps the newest bytes and counts the ones it dropped.
public struct SerialBuffer: Sendable {
    /// The most bytes it holds.
    public let capacity: Int
    private var storage: [UInt8]
    private var start = 0
    /// Bytes held now.
    public private(set) var count = 0
    /// Bytes dropped since the last `take`.
    public private(set) var dropped = 0

    /// An empty buffer.
    public init(capacity: Int = SerialLimits.bufferBytes) {
        self.capacity = max(1, capacity)
        storage = [UInt8](repeating: 0, count: self.capacity)
    }

    /// Adds `bytes`, dropping the oldest ones that no longer fit.
    public mutating func append(_ bytes: some Collection<UInt8>) {
        var bytes = bytes[...]
        if bytes.count > capacity {
            dropped += count + bytes.count - capacity
            start = 0
            count = 0
            bytes = bytes.suffix(capacity)
        }
        let overflow = count + bytes.count - capacity
        if overflow > 0 {
            start = (start + overflow) % capacity
            count -= overflow
            dropped += overflow
        }
        for byte in bytes {
            storage[(start + count) % capacity] = byte
            count += 1
        }
    }

    /// Removes and returns up to `maxBytes` of the oldest bytes, with how many were dropped before them.
    public mutating func take(_ maxBytes: Int) -> (bytes: [UInt8], dropped: Int) {
        let n = min(max(0, maxBytes), count)
        var bytes = [UInt8]()
        bytes.reserveCapacity(n)
        for i in 0..<n { bytes.append(storage[(start + i) % capacity]) }
        start = (start + n) % capacity
        count -= n
        defer { dropped = 0 }
        return (bytes, dropped)
    }
}

/// How serial bytes are shown. Device output is untrusted, so only printable ASCII, newlines and tabs pass through;
/// everything else is an escape, which output cannot forge because backslashes are escaped too.
public enum SerialText {
    /// Printable ASCII, `\n` and `\t` as they are; `\r` before `\n` dropped; `\\`, `\r` and every other byte as
    /// `\xNN`-style escapes.
    public static func render(_ bytes: [UInt8]) -> String {
        var text = ""
        text.reserveCapacity(bytes.count)
        for (index, byte) in bytes.enumerated() {
            switch byte {
            case UInt8(ascii: "\r") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "\n"):
                continue
            case UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                text.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                text += escape(byte)
            }
        }
        return text
    }

    /// Like `render`, but newlines and tabs are escaped too: one line.
    public static func inline(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            switch byte {
            case UInt8(ascii: "\n"): return "\\n"
            case UInt8(ascii: "\t"): return "\\t"
            default: return escape(byte)
            }
        }.joined()
    }

    static func escape(_ byte: UInt8) -> String {
        switch byte {
        case UInt8(ascii: "\\"): return "\\\\"
        case UInt8(ascii: "\r"): return "\\r"
        case 0x20...0x7E: return String(Unicode.Scalar(byte))
        default: return "\\x" + hexByte(byte)
        }
    }

    /// 16 bytes per line: offset, hex bytes, then the printable ones.
    public static func hexDump(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map(hexByte).joined(separator: " ")
            let padding = String(repeating: " ", count: (16 - row.count) * 3)
            let ascii = String(row.map { (0x20...0x7E).contains($0) ? Character(Unicode.Scalar($0)) : "." })
            let position = String(offset, radix: 16)
            return String(repeating: "0", count: max(0, 8 - position.count)) + position + "  " + hex + padding
                + "  |" + ascii + "|"
        }.joined(separator: "\n")
    }

    /// Lowercase hex digits, no separators.
    public static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map(hexByte).joined()
    }

    /// Bytes from pairs of hex digits; spaces are ignored. `nil` for anything else.
    public static func bytes(hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var high: UInt8?
        for scalar in hex.unicodeScalars where scalar != " " {
            guard scalar.isASCII, let digit = hexDigits.firstIndex(of: Character(scalar).lowercased().first ?? " ")
            else { return nil }
            let value = UInt8(hexDigits.distance(from: hexDigits.startIndex, to: digit))
            if let first = high {
                bytes.append(first << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return high == nil ? bytes : nil
    }

    static let hexDigits = "0123456789abcdef"

    static func hexByte(_ byte: UInt8) -> String {
        let hex = String(byte, radix: 16)
        return hex.count == 1 ? "0" + hex : hex
    }
}
