import Foundation

/// One connection attempt through the gatekeeper proxy and its decision, reported by the proxy.
public struct NetworkAttempt: Sendable, Equatable {
    /// The proxy's number for the connection, unique while the app runs.
    public let connection: Int
    /// `CONNECT`, or the plain-HTTP method.
    public let method: String
    /// The host as the agent asked for it (untrusted; escaped wherever it is shown).
    public let host: String
    /// The port asked for.
    public let port: Int
    /// What the policy decided.
    public let decision: NetworkDecision

    /// An attempt.
    public init(connection: Int, method: String, host: String, port: Int, decision: NetworkDecision) {
        self.connection = connection
        self.method = method
        self.host = host
        self.port = port
        self.decision = decision
    }
}

/// How an allowed connection ended.
public struct NetworkTransfer: Sendable, Equatable {
    /// The proxy's number for the connection.
    public let connection: Int
    /// The host, as in the attempt.
    public let host: String
    /// The port.
    public let port: Int
    /// Bytes from the agent to the server.
    public let bytesUp: Int
    /// Bytes from the server to the agent.
    public let bytesDown: Int
    /// Seconds from the attempt to the close.
    public let duration: TimeInterval
    /// Why no connection to the server was made, or `nil` if one was.
    public let failure: String?

    /// A transfer.
    public init(
        connection: Int,
        host: String,
        port: Int,
        bytesUp: Int,
        bytesDown: Int,
        duration: TimeInterval,
        failure: String?
    ) {
        self.connection = connection
        self.host = host
        self.port = port
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.duration = duration
        self.failure = failure
    }
}

/// A host the proxy refused that the owner could allow.
public struct DeniedHost: Sendable, Equatable, Identifiable {
    /// The normalized host name.
    public let host: String
    /// Refused attempts so far.
    public internal(set) var count: Int
    /// The last refused attempt.
    public internal(set) var lastSeen: Date

    /// The host name.
    public var id: String { host }
}

extension RunResult {
    /// `bytes` in decimal units with one decimal: `999 B`, `1.2 KB`, `3.4 MB`.
    static func byteCount(_ bytes: Int) -> String {
        guard bytes >= 1000 else { return "\(bytes) B" }
        var value = Double(bytes) / 1000
        for unit in ["KB", "MB", "GB"] {
            if value < 1000 || unit == "GB" { return String(format: "%.1f", value) + " " + unit }
            value /= 1000
        }
        return "\(bytes) B"
    }
}
