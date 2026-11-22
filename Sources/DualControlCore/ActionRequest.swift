/// The kind of access an action needs.
public enum Capability: String, Sendable, Codable, CaseIterable {
    /// Text typed into the shared terminal pane.
    case terminal
    /// Reading the shared terminal pane; `argv` is the number of lines.
    case terminalRead
    /// A program started directly from an argument vector.
    case command
    /// A serial port operation.
    case serial
    /// A LAN request.
    case network
    /// A request to the privileged broker.
    case broker
    /// Writing one file in the session folder (`FileWrite`); `argv` is the operation and its operands.
    case file
}

/// Something Claude asks to do.
public struct ActionRequest: Sendable, Equatable, Codable {
    /// The access this action needs.
    public var capability: Capability
    /// Program and arguments exactly as they will be executed; never a shell string. For `terminal`, the text typed
    /// into the pane (concatenated). For `serial`, `network` and `broker`, the operation and its operands.
    public var argv: [String]
    /// Working directory, as an absolute path.
    public var cwd: String
    /// Project the action belongs to.
    public var projectID: String
    /// For `command`: seconds before the whole process group is killed; `nil` means the default.
    public var timeoutSeconds: Int?
    /// For `serial`: the USB device the port belongs to, filled in by the supervisor from the port itself (never
    /// from the call), so device rules match what is really plugged in.
    public var device: SerialDevice?
    /// For `file`: the content to write, or the patch to apply, which `argv` describes by size and SHA-256. Never
    /// encoded, so it is in no audit line.
    public var payload: [UInt8]? = nil
    /// For `terminal` and `terminalRead`: the tab; `nil` is the agent tab.
    public var tab: TerminalTab? = nil

    enum CodingKeys: String, CodingKey {
        case capability, argv, cwd, projectID, timeoutSeconds, device, tab
    }

    /// Creates a request.
    public init(
        capability: Capability,
        argv: [String],
        cwd: String,
        projectID: String,
        timeoutSeconds: Int? = nil,
        device: SerialDevice? = nil
    ) {
        self.capability = capability
        self.argv = argv
        self.cwd = cwd
        self.projectID = projectID
        self.timeoutSeconds = timeoutSeconds
        self.device = device
    }
}

/// Limits on every command Claude runs.
public enum CommandLimits {
    /// Seconds a command may run when the call names no timeout.
    public static let defaultTimeoutSeconds = 120
    /// The largest timeout a call may ask for.
    public static let maxTimeoutSeconds = 3600
    /// Combined stdout and stderr returned; the rest is counted and dropped.
    public static let maxOutputBytes = 1 << 20
}

/// What happens to a request.
public enum Verdict: String, Sendable, Codable {
    /// Runs without asking.
    case allow
    /// Waits for the owner to approve.
    case ask
    /// Never runs.
    case deny
}

/// The outcome of evaluating a request.
public struct Decision: Sendable, Equatable, Codable {
    /// What happens to the request.
    public var verdict: Verdict
    /// Human-readable explanation, shown to the owner and returned to Claude.
    public var reason: String
    /// Stable identifier of the rule that decided, e.g. `blocked.sudo` or `mode.ask-each`.
    public var ruleID: String

    /// Creates a decision.
    public init(verdict: Verdict, reason: String, ruleID: String) {
        self.verdict = verdict
        self.reason = reason
        self.ruleID = ruleID
    }
}
