import Foundation

/// Host names the gatekeeper proxy can decide on.
public enum NetworkHost {
    /// `raw` as a lowercase DNS name without the trailing dot, or `nil` if it is not one: IP literals, single
    /// labels (`localhost`), wildcards, user info, ports, non-ASCII (use the `xn--` form) and over-long names are
    /// refused, so an address can never be allowed by name.
    public static func normalized(_ raw: String) -> String? {
        var name = raw.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-",
                label.utf8.allSatisfy({ isLetterOrDigit($0) || $0 == UInt8(ascii: "-") })
            else { return nil }
        }
        // A numeric last label reads as an address to some resolvers (1.2.3.4, 0x7f.1).
        guard let last = labels.last, !last.utf8.allSatisfy(isDigit) else { return nil }
        return name
    }

    static func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }

    static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }
}

/// What the gatekeeper proxy is asked for.
public enum ProxyKind: Sendable, Equatable {
    /// An HTTPS tunnel (`CONNECT host:443`). The proxy sees only the host name, never the content.
    case connect
    /// A plain-HTTP request, forwarded by the proxy; `path` is the origin-form path with its query.
    case forward(path: String)
}

/// The proxy's verdict on one connection attempt.
public struct NetworkDecision: Sendable, Equatable {
    /// True if the connection may be made.
    public let isAllowed: Bool
    /// The deciding rule, e.g. `network.allowlist` or `network.not-allowed`.
    public let ruleID: String
    /// Why, in plain words.
    public let reason: String
    /// The normalized host the owner could allow with one click, for a denial of a valid host only.
    public let allowableHost: String?

    /// The denial for a request the proxy cannot read safely (ambiguous body framing).
    public static func badRequest(_ why: String) -> NetworkDecision {
        NetworkDecision(isAllowed: false, ruleID: "network.bad-request", reason: why, allowableHost: nil)
    }

    /// A connection through an owner-approved LAN forwarder (D7b).
    public static let lanEndpoint = NetworkDecision(
        isAllowed: true,
        ruleID: "lan.endpoint",
        reason: "approved by the owner for this session",
        allowableHost: nil
    )
}

/// Which hosts agent processes may reach through the gatekeeper proxy (D7a). Hostnames only: HTTPS is never
/// intercepted, so the proxy decides on the `CONNECT` host name and sees nothing inside the tunnel.
///
/// Allowed: the verified default hosts, the owner's saved hosts ("always") and hosts the owner allowed for this
/// session, on port 443 for tunnels and port 80 for plain HTTP; nothing else. Plain-HTTP git pushes
/// (`git-receive-pack`) are refused for every host.
public struct NetworkPolicy: Sendable, Equatable {
    /// What pip, uv, git and the ESP-IDF v5.4 installer (`install.sh`, `idf_tools.py`, the component manager)
    /// actually reach: PyPI and its file host, GitHub (clones, release downloads and their redirect host, source
    /// archives) and Espressif's download, wheel and component servers.
    public static let defaultHosts = [
        "pypi.org", "files.pythonhosted.org", "github.com", "codeload.github.com",
        "release-assets.githubusercontent.com", "dl.espressif.com", "components.espressif.com",
        "components-file.espressif.com",
    ]
    /// The only port for tunnels.
    public static let tunnelPort = 443
    /// The only port for plain HTTP.
    public static let plainPort = 80

    /// Hosts the owner allowed always (saved).
    public private(set) var ownerHosts: Set<String>
    /// Hosts the owner allowed until the app quits.
    public private(set) var sessionHosts: Set<String> = []

    /// A policy with the default hosts and the owner's saved hosts; invalid saved hosts are dropped.
    public init(ownerHosts: [String] = []) {
        self.ownerHosts = Set(ownerHosts.compactMap(NetworkHost.normalized))
    }

    /// Decides one attempt to reach `host:port`.
    public func decide(_ kind: ProxyKind, host: String, port: Int) -> NetworkDecision {
        guard let name = NetworkHost.normalized(host) else {
            return Self.denied("network.bad-host", "only host names can be reached, not addresses or local names")
        }
        switch kind {
        case .connect where port != Self.tunnelPort:
            return Self.denied("network.port", "tunnels go to port \(Self.tunnelPort) only")
        case .forward where port != Self.plainPort:
            return Self.denied("network.port", "plain HTTP goes to port \(Self.plainPort) only")
        case .forward(let path) where Self.isGitPush(path):
            return Self.denied("network.git-push", "git push is refused; the agent may only clone and fetch")
        default:
            break
        }
        if Self.defaultHosts.contains(name) { return Self.allowed("network.allowlist", "a default host") }
        if ownerHosts.contains(name) { return Self.allowed("network.owner-host", "you allowed this host") }
        if sessionHosts.contains(name) {
            return Self.allowed("network.session-host", "you allowed this host for this session")
        }
        return NetworkDecision(
            isAllowed: false,
            ruleID: "network.not-allowed",
            reason: "\(name) is not an allowed host; the owner can allow it in the Dual Control window",
            allowableHost: name
        )
    }

    /// Allows `host` always or for this session. Returns the normalized host, or `nil` if it is not a valid host
    /// name or already allowed by default.
    public mutating func add(_ host: String, always: Bool) -> String? {
        guard let name = NetworkHost.normalized(host), !Self.defaultHosts.contains(name) else { return nil }
        if always {
            sessionHosts.remove(name)
            ownerHosts.insert(name)
        } else {
            sessionHosts.insert(name)
        }
        return name
    }

    /// Stops allowing an owner-added host. Returns false if it was not allowed by the owner.
    public mutating func remove(_ host: String) -> Bool {
        guard let name = NetworkHost.normalized(host) else { return false }
        let removed = ownerHosts.remove(name) != nil
        return sessionHosts.remove(name) != nil || removed
    }

    /// True if a plain-HTTP path is a git push: the smart-HTTP `git-receive-pack` service, asked for in the path or
    /// in `info/refs?service=`. Percent-escapes are decoded and case ignored first, so no spelling slips through.
    static func isGitPush(_ path: String) -> Bool {
        decoded(path).lowercased().contains("git-receive-pack")
    }

    /// `text` with every `%XX` escape decoded as a byte; malformed escapes stay as they are.
    static func decoded(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
                let value = UInt8(String(decoding: bytes[index + 1...index + 2], as: UTF8.self), radix: 16)
            {
                out.append(value)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func allowed(_ rule: String, _ reason: String) -> NetworkDecision {
        NetworkDecision(isAllowed: true, ruleID: rule, reason: reason, allowableHost: nil)
    }

    private static func denied(_ rule: String, _ reason: String) -> NetworkDecision {
        NetworkDecision(isAllowed: false, ruleID: rule, reason: reason, allowableHost: nil)
    }
}

/// Addresses the proxy never connects to, whatever a host name resolves to: this machine, the local network and
/// link-local services (such as cloud metadata at 169.254.169.254). Local devices get their own tools (D7b).
public enum NetworkAddress {
    /// True for an unspecified, loopback, private, carrier-grade NAT, link-local, multicast or reserved address,
    /// given as 4 (IPv4) or 16 (IPv6) bytes in network order; anything else of another length too.
    public static func isForbidden(_ address: [UInt8]) -> Bool {
        switch address.count {
        case 4: return isForbiddenIPv4(address)
        case 16: return isForbiddenIPv6(address)
        default: return true
        }
    }

    private static func isForbiddenIPv4(_ a: [UInt8]) -> Bool {
        switch (a[0], a[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31), (100, 64...127): return true
        case (224...255, _): return true
        default: return false
        }
    }

    private static func isForbiddenIPv6(_ a: [UInt8]) -> Bool {
        // ::, ::1 and IPv4-compatible addresses.
        if a[0..<12].allSatisfy({ $0 == 0 }) { return a[12..<15].allSatisfy { $0 == 0 } || isForbiddenIPv4(tail(a)) }
        // IPv4-mapped (::ffff:a.b.c.d) and the NAT64 prefix 64:ff9b::/96 carry an IPv4 address.
        if a[0..<10].allSatisfy({ $0 == 0 }) && a[10] == 0xFF && a[11] == 0xFF { return isForbiddenIPv4(tail(a)) }
        if a[0..<4] == [0x00, 0x64, 0xFF, 0x9B] { return isForbiddenIPv4(tail(a)) }
        // fc00::/7 unique local, fe80::/10 link-local, fec0::/10 site-local, ff00::/8 multicast.
        return a[0] & 0xFE == 0xFC || a[0] == 0xFE && a[1] & 0x80 == 0x80 || a[0] == 0xFF
    }

    private static func tail(_ a: [UInt8]) -> [UInt8] { Array(a[12..<16]) }
}

/// Where agent processes find the gatekeeper proxy: `127.0.0.1:port`, with a per-session token.
///
/// The token, not a peer check, decides who may use the proxy. macOS has no peer credentials for TCP (getpeereid
/// works on Unix sockets only, and pip, uv and git cannot use a proxy on a Unix socket), and mapping a loopback
/// connection to a process by scanning other users' file descriptors is racy and needs privileges the app does not
/// have. The token is random per proxy start, travels only in the agent's environment (which other users cannot
/// read) and in the `Proxy-Authorization` header, and is compared in constant time. The kernel sandbox is what keeps
/// agent processes on this one port.
public struct ProxyEndpoint: Sendable, Equatable, CustomStringConvertible {
    /// The user name in the proxy URL; the token is the password.
    public static let user = "dc"
    /// Hosts tools should never send to the proxy.
    public static let noProxy = "localhost,127.0.0.1,::1"

    /// The proxy's TCP port on 127.0.0.1.
    public let port: UInt16
    let token: String

    /// An endpoint, or `nil` unless `port` is non-zero and `token` is at least 32 lowercase hex digits.
    public init?(port: UInt16, token: String) {
        guard port != 0, token.utf8.count >= 32,
            token.utf8.allSatisfy({ NetworkHost.isDigit($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) })
        else { return nil }
        self.port = port
        self.token = token
    }

    /// 32 random bytes as hex, from the system's cryptographic generator.
    public static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    /// The proxy URL with the token, for the agent's environment only.
    public var url: String { "http://\(Self.user):\(token)@127.0.0.1:\(port)" }

    /// The expected `Proxy-Authorization` value.
    public var authorization: String { "Basic " + Data("\(Self.user):\(token)".utf8).base64EncodedString() }

    /// The proxy variables for agent processes: upper and lower case, since tools disagree (curl, and so git, reads
    /// only lowercase `http_proxy`). Git also gets no credential helper for the proxy itself: after a request
    /// succeeds it would hand the token to the system helper (osxkeychain) to store, which writes it to a keychain
    /// and, in the sandbox, hangs.
    public var variables: [String: String] {
        var result: [String: String] = [:]
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            result[name] = url
            result[name.lowercased()] = url
        }
        result["NO_PROXY"] = Self.noProxy
        result["no_proxy"] = Self.noProxy
        result["GIT_CONFIG_COUNT"] = "1"
        result["GIT_CONFIG_KEY_0"] = "credential.http://127.0.0.1:\(port).helper"
        result["GIT_CONFIG_VALUE_0"] = ""
        return result
    }

    /// The endpoint without its token, for logs.
    public var description: String { "127.0.0.1:\(port)" }
}
