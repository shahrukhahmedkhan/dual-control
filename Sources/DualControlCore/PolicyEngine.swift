import Foundation

/// How `changing` actions are approved.
public enum ApprovalMode: Sendable, Equatable {
    /// The owner approves each action.
    case askEach
    /// Allowed without asking until the given time, then back to asking.
    case allowUntil(Date)
    /// Allowed without asking while the app stays open.
    case allowWhileOpen
}

/// Lets a project run exactly one argument vector inside one folder, without asking. There are no prefix rules.
public struct AllowRule: Sendable, Equatable, Codable {
    /// Stable identifier, reported as `rule.<id>`.
    public var id: String
    /// Project the rule belongs to.
    public var projectID: String
    /// Absolute folder; the request's working directory must be inside it.
    public var folder: String
    /// The whole argument vector that may run. An empty one matches nothing.
    public var argv: [String]

    /// Creates a rule.
    public init(id: String, projectID: String, folder: String, argv: [String]) {
        self.id = id
        self.projectID = projectID
        self.folder = folder
        self.argv = argv
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, folder, argv
        // How D3 saved rules.
        case argvPrefix, exact
    }

    /// Decodes a rule. A rule saved by D3 (`argvPrefix` + `exact`) loads only if it was exact; anything else throws.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectID = try container.decode(String.self, forKey: .projectID)
        folder = try container.decode(String.self, forKey: .folder)
        if let argv = try container.decodeIfPresent([String].self, forKey: .argv) {
            self.argv = argv
        } else if try container.decodeIfPresent(Bool.self, forKey: .exact) == true {
            argv = try container.decode([String].self, forKey: .argvPrefix)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .argv,
                in: container,
                debugDescription: "Prefix rules are not supported."
            )
        }
    }

    /// Encodes a rule in the current format.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(folder, forKey: .folder)
        try container.encode(argv, forKey: .argv)
    }

    /// Only `command` requests match, and only when their argument vector equals `argv`.
    /// Paths are compared lexically; resolving symlinks is the caller's job (it needs I/O).
    func matches(_ request: ActionRequest) -> Bool {
        guard request.capability == .command, request.projectID == projectID, !argv.isEmpty, request.argv == argv,
            let folderParts = Self.components(folder), let cwdParts = Self.components(request.cwd)
        else { return false }
        return cwdParts.starts(with: folderParts)
    }

    /// Normalized components of an absolute path, or `nil` for a relative one.
    static func components(_ path: String) -> [Substring]? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return parts
    }
}

/// Lets the session folder use one USB serial device (`serial_open`, `serial_write`, `serial_reset`) without
/// asking. The device is its USB vendor and product id and its serial number; a device without a serial number
/// cannot have a rule, since it cannot be told apart from others of its model.
public struct DeviceRule: Sendable, Equatable, Codable {
    /// Stable identifier, reported as `rule.<id>`.
    public var id: String
    /// The session folder it was added in; it applies only while that is the session folder.
    public var folder: String
    /// The device.
    public var device: SerialDevice

    /// Creates a rule.
    public init(id: String, folder: String, device: SerialDevice) {
        self.id = id
        self.folder = folder
        self.device = device
    }

    /// The device, and which USB ports the rule covers, escaped.
    public var label: String {
        var plain = device
        plain.locationID = nil
        return device.needsLocation ? device.label + " only" : plain.label + " on any USB port"
    }

    /// Only changing serial requests for this device (`SerialDevice.isCovered(by:)`) in exactly this session
    /// folder.
    func matches(_ request: ActionRequest) -> Bool {
        guard request.capability == .serial, request.device?.isCovered(by: device) == true, request.cwd == folder
        else { return false }
        switch SerialOperation(argv: request.argv) {
        case .open, .write, .reset: return true
        case .list, .read, nil: return false
        }
    }
}

/// Who controls the shared terminal.
public enum Baton: Sendable, Equatable {
    /// Claude may act.
    case claude
    /// The owner has taken over; every Claude action is denied.
    case owner
    /// Claude asked the owner to take over (for example to type a password) and waits.
    case takeoverRequested(reason: String)

    /// The state after `event`, or `nil` if the event is not valid in this state.
    public func applying(_ event: BatonEvent) -> Baton? {
        switch (self, event) {
        case (.claude, .claudeRequestsTakeover(let reason)): return .takeoverRequested(reason: reason)
        case (.claude, .ownerTakesOver), (.takeoverRequested, .ownerTakesOver): return .owner
        case (.takeoverRequested, .ownerDeclinesTakeover), (.owner, .ownerHandsBack): return .claude
        default: return nil
        }
    }
}

/// Something that moves the baton.
public enum BatonEvent: Sendable, Equatable {
    /// Claude asks the owner to take over.
    case claudeRequestsTakeover(reason: String)
    /// The owner takes over the terminal.
    case ownerTakesOver
    /// The owner hands control back to Claude.
    case ownerHandsBack
    /// The owner declines Claude's takeover request.
    case ownerDeclinesTakeover
}

/// Counts every time the owner had to step in (UX-001).
public struct InterventionCounter: Sendable, Equatable, Codable {
    /// Actions that waited for approval.
    public var asks = 0
    /// Times the owner took over the terminal.
    public var takeovers = 0
    /// Actions that were denied, by the engine or by the owner.
    public var denials = 0
    /// Asks the owner left unanswered until they timed out.
    public var timeouts = 0

    /// All interventions.
    public var total: Int { asks + takeovers + denials + timeouts }

    /// Creates a counter.
    public init(asks: Int = 0, takeovers: Int = 0, denials: Int = 0, timeouts: Int = 0) {
        self.asks = asks
        self.takeovers = takeovers
        self.denials = denials
        self.timeouts = timeouts
    }
}

/// Decides every request. Pure and deterministic: the caller supplies the time.
///
/// Order: Stop → baton → blocked → read-only → privileged (always asks) → allow and device rules → approval mode.
public struct PolicyEngine: Sendable {
    /// Current approval mode.
    public private(set) var mode: ApprovalMode
    /// Current baton holder.
    public private(set) var baton: Baton = .claude
    /// True after Stop until the owner resets.
    public private(set) var isStopped = false
    /// Per-project allow rules.
    public var rules: [AllowRule]
    /// Per-session-folder serial device rules.
    public var deviceRules: [DeviceRule] = []
    /// Interventions so far.
    public private(set) var interventions = InterventionCounter()
    /// The owner's time zone: times in the header and in reasons are their local clock time.
    public var timeZone = TimeZone.current

    /// Shown in the state header; the full lists live in `Classifier`.
    static let blockedSummary = "sudo, efuse, keychain"

    /// Creates an engine.
    public init(mode: ApprovalMode = .askEach, rules: [AllowRule] = []) {
        self.mode = mode
        self.rules = rules
    }

    /// Changes the approval mode. Has no effect on decisions while stopped.
    public mutating func setMode(_ mode: ApprovalMode) {
        self.mode = mode
    }

    /// Global kill: denies everything until `resetAfterStop()`.
    public mutating func stop() {
        isStopped = true
    }

    /// Ends a Stop. The mode drops back to ask-each so the owner re-grants trust explicitly.
    public mutating func resetAfterStop() {
        isStopped = false
        mode = .askEach
    }

    /// Moves the baton. Returns false, changing nothing, if the event is not valid now.
    @discardableResult
    public mutating func apply(_ event: BatonEvent) -> Bool {
        guard let next = baton.applying(event) else { return false }
        if next == .owner { interventions.takeovers += 1 }
        baton = next
        return true
    }

    /// Decides a request and counts asks and denials.
    public mutating func evaluate(_ request: ActionRequest, now: Date) -> Decision {
        let decision = decide(request, now: now)
        switch decision.verdict {
        case .allow: break
        case .ask: interventions.asks += 1
        case .deny: interventions.denials += 1
        }
        return decision
    }

    /// Counts an asked request that the owner, Stop or a baton change denied.
    public mutating func recordDenial() {
        interventions.denials += 1
    }

    /// Counts an asked request that timed out unanswered.
    public mutating func recordTimeout() {
        interventions.timeouts += 1
    }

    func decide(_ request: ActionRequest, now: Date) -> Decision {
        if isStopped {
            return Decision(verdict: .deny, reason: "stopped by the owner", ruleID: "stop")
        }
        switch baton {
        case .claude: break
        case .owner: return Decision(verdict: .deny, reason: "owner has control", ruleID: "baton.owner")
        case .takeoverRequested:
            return Decision(verdict: .deny, reason: "waiting for the owner to take over", ruleID: "baton.requested")
        }
        let risk = Classifier.classify(request)
        switch risk.tier {
        case .blocked: return Decision(verdict: .deny, reason: risk.reason, ruleID: risk.ruleID)
        case .readOnly: return Decision(verdict: .allow, reason: risk.reason, ruleID: risk.ruleID)
        case .privileged: return Decision(verdict: .ask, reason: risk.reason, ruleID: risk.ruleID)
        case .changing: break
        }
        if let rule = rules.first(where: { $0.matches(request) }) {
            return Decision(verdict: .allow, reason: "allowed by a project rule", ruleID: "rule.\(rule.id)")
        }
        if let rule = deviceRules.first(where: { $0.matches(request) }) {
            return Decision(verdict: .allow, reason: "allowed by a device rule", ruleID: "rule.\(rule.id)")
        }
        switch mode {
        case .allowWhileOpen:
            return Decision(verdict: .allow, reason: "allowed while the app is open", ruleID: "mode.allow-while-open")
        case .allowUntil(let end) where now < end:
            return Decision(verdict: .allow, reason: "allowed until \(clockTime(end))", ruleID: "mode.allow-until")
        case .allowUntil, .askEach:
            return Decision(verdict: .ask, reason: "\(risk.reason); asking the owner", ruleID: "mode.ask-each")
        }
    }

    /// One-line state summary prepended to every tool result (SAFE-002), e.g.
    /// `mode: ask-each · baton: claude · blocked: sudo, efuse, keychain`.
    public func stateHeader(now: Date) -> String {
        let modeText: String
        switch mode {
        case _ where isStopped: modeText = "stopped"
        case .allowUntil(let end) where now < end: modeText = "allow-until \(clockTime(end))"
        case .allowUntil, .askEach: modeText = "ask-each"
        case .allowWhileOpen: modeText = "allow-while-open"
        }
        let batonText: String
        switch baton {
        case .claude: batonText = "claude"
        case .owner: batonText = "owner"
        case .takeoverRequested: batonText = "takeover-requested"
        }
        return "mode: \(modeText) · baton: \(batonText) · blocked: \(Self.blockedSummary)"
    }

    /// `HH:mm` (or `HH:mm:ss`) in `timeZone`. Allow-until lasts at most two hours, so the time alone is clear.
    func clockTime(_ date: Date, seconds: Bool = false) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return seconds ? time + String(format: ":%02d", parts.second ?? 0) : time
    }
}
