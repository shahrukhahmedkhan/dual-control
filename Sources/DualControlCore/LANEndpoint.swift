/// One device on the owner's local network that agent programs may reach (D7b), such as an ESP32's HTTP or MQTT
/// port. The agent asks with `net_allow_request`; only the owner can approve it (privileged tier: every mode asks),
/// for the current session only. Seatbelt cannot name a remote address other than localhost, so the kernel never
/// lets agent processes reach the network itself: the app runs a forwarder for each approved endpoint on 127.0.0.1,
/// the CHANGING profile allows just that local port, and the forwarder connects only to the approved address and
/// reports every connection to the audit log like the gatekeeper's. Only unicast IPv4 addresses in the private
/// ranges (10/8, 172.16/12, 192.168/16): no names (no DNS, no mDNS), no broadcast or network addresses.
public struct LANEndpoint: Sendable, Hashable, CustomStringConvertible {
    /// TCP or UDP.
    public enum Transport: String, Sendable, Hashable, CaseIterable {
        /// A stream: HTTP, MQTT, telnet-like consoles.
        case tcp
        /// Datagrams to and from the device.
        case udp
    }

    /// The device's address, dotted decimal.
    public let host: String
    /// The device's port.
    public let port: UInt16
    /// TCP or UDP.
    public let transport: Transport

    /// The program name `argv` starts with, so the request reads as what it is in the feed and the audit log.
    static let program = "net_allow"

    /// `udp 192.168.1.50:5000`.
    public var description: String { "\(transport.rawValue) \(host):\(port)" }

    /// The endpoint, or why it cannot be one.
    public static func parse(host: String, port: Int, transport: String) -> Result<LANEndpoint, LANEndpointProblem> {
        guard let kind = Transport(rawValue: transport) else {
            return .failure(LANEndpointProblem(description: "`protocol` must be tcp or udp"))
        }
        guard (1...65535).contains(port) else {
            return .failure(LANEndpointProblem(description: "`port` must be 1 to 65535"))
        }
        guard let octets = octets(host) else {
            return .failure(
                LANEndpointProblem(description: "`host` must be an IPv4 address such as 192.168.1.50, not a name")
            )
        }
        guard isPrivateUnicast(octets) else {
            return .failure(
                LANEndpointProblem(
                    description: "`host` must be a single device in a private range (10.x, 172.16-31.x, "
                        + "192.168.x), not a network or broadcast address"
                )
            )
        }
        return .success(LANEndpoint(host: host, port: UInt16(port), transport: kind))
    }

    /// The four bytes of a dotted-decimal IPv4 address with no leading zeros, or `nil`.
    public static func octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ ("0"..."9").contains($0) }),
                part == "0" || !part.hasPrefix("0"), let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// In 10/8, 172.16/12 or 192.168/16, and not ending in 0 or 255 (a network or broadcast address in the usual
    /// /24 home networks).
    static func isPrivateUnicast(_ a: [UInt8]) -> Bool {
        let privateRange: Bool
        switch (a[0], a[1]) {
        case (10, _), (172, 16...31), (192, 168): privateRange = true
        default: privateRange = false
        }
        return privateRange && a[3] != 0 && a[3] != 255
    }

    /// The request's argument vector: `net_allow <tcp|udp> <host>:<port> <why>`.
    func argv(why: String) -> [String] {
        [Self.program, transport.rawValue, "\(host):\(port)", why]
    }

    /// The endpoint a request's `argv` names, or `nil`.
    public init?(argv: [String]) {
        guard argv.count == 4, argv[0] == Self.program, let colon = argv[2].lastIndex(of: ":"),
            let port = Int(argv[2][argv[2].index(after: colon)...]),
            case .success(let endpoint) = Self.parse(
                host: String(argv[2][..<colon]),
                port: port,
                transport: argv[1]
            )
        else { return nil }
        self = endpoint
    }

    init(host: String, port: UInt16, transport: Transport) {
        self.host = host
        self.port = port
        self.transport = transport
    }
}

/// Why a host and port cannot be a LAN endpoint.
public struct LANEndpointProblem: Error, Sendable, Equatable, CustomStringConvertible {
    /// What was wrong.
    public let description: String
}

/// An approved endpoint and the local port its forwarder listens on.
public struct LANForward: Sendable, Equatable {
    /// The device.
    public let endpoint: LANEndpoint
    /// The forwarder's port on 127.0.0.1, the only one agent programs may use to reach it.
    public let localPort: UInt16

    /// A forward.
    public init(endpoint: LANEndpoint, localPort: UInt16) {
        self.endpoint = endpoint
        self.localPort = localPort
    }
}
