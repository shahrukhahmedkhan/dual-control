import Crypto
import Foundation

/// A request waiting for the owner.
public struct PendingApproval: Sendable, Equatable, Identifiable {
    /// Approval id, unique within the session.
    public let id: String
    /// Tool that made the request.
    public let tool: String
    /// What would run.
    public let request: ActionRequest
    /// Why the engine asked.
    public let decision: Decision
    /// Risk tier of the request.
    public let tier: RiskTier
    /// When it started waiting.
    public let askedAt: Date
    /// When it is denied if still unanswered.
    public let deadline: Date
    /// The background job it belongs to, if `run_command` was called with `background: true`.
    public internal(set) var jobID: String? = nil

    /// True if "Approve and always allow" is offered: rules only ever apply to `changing` commands, and to
    /// `changing` serial requests for a device that can be told apart (`SerialDevice.canBeRemembered`).
    public var canAlwaysAllow: Bool {
        guard tier == .changing else { return false }
        switch request.capability {
        case .command: return true
        case .serial: return request.device?.canBeRemembered == true
        default: return false
        }
    }
}

/// How a feed entry ended.
public enum FeedOutcome: String, Sendable, Equatable {
    /// Allowed by the engine.
    case allowed
    /// Waiting for the owner.
    case asked
    /// Denied by the engine, Stop or the baton.
    case denied
    /// Approved by the owner.
    case approved
    /// Denied by the owner.
    case ownerDenied
    /// Denied because nobody answered in time.
    case timedOut
    /// Allowed or approved, but it could not run.
    case failed

    /// Text for the Decision column.
    public var label: String {
        switch self {
        case .allowed: return "Allowed"
        case .asked: return "Asked"
        case .denied: return "Denied"
        case .approved: return "Approved"
        case .ownerDenied: return "Denied by you"
        case .timedOut: return "Timed out"
        case .failed: return "Failed"
        }
    }
}

/// How an allowed or approved action actually ended, so "Allowed" is never mistaken for "it worked".
public enum RunResult: Sendable, Equatable {
    /// The command exited with this status.
    case exited(Int32)
    /// The command failed with "Operation not permitted": the kernel sandbox refused something. Read from its
    /// output, which is untrusted, so it is only ever shown, never used to decide.
    case blockedBySandbox(Int32)
    /// The timeout killed it.
    case timedOut
    /// Stop killed it.
    case killedByStop
    /// Its caller left (the call was abandoned), so it was killed.
    case callerLeft
    /// It was killed otherwise, e.g. the app quit.
    case killed
    /// Claude cancelled its job.
    case cancelled
    /// Terminal text was typed, or the terminal was read.
    case done
    /// It was allowed but never started.
    case notRun
    /// A network connection carried these bytes up and down for this many seconds.
    case transferred(up: Int, down: Int, seconds: TimeInterval)
    /// A network connection was allowed but the server could not be reached; why.
    case unreachable(String)

    /// Text for the Outcome column.
    public var label: String {
        switch self {
        case .transferred(let up, let down, let seconds):
            return "↑\(Self.byteCount(up)) ↓\(Self.byteCount(down)) in \(String(format: "%.1f", seconds)) s"
        case .unreachable(let why): return "unreachable: \(why)"
        case .exited(let status): return "exit \(status)"
        case .blockedBySandbox(let status): return "blocked by sandbox (exit \(status))"
        case .timedOut: return "timed out"
        case .killedByStop: return "killed by Stop"
        case .callerLeft: return "killed: caller left"
        case .killed: return "killed"
        case .cancelled: return "cancelled"
        case .done: return "done"
        case .notRun: return "did not run"
        }
    }

    /// True if it ran and ended well.
    public var succeeded: Bool {
        if case .transferred = self { return true }
        return self == .exited(0) || self == .done
    }
}

/// One line of the live activity feed.
public struct FeedEntry: Sendable, Equatable, Identifiable {
    /// Unique, increasing id.
    public let id: Int
    /// When it happened.
    public let time: Date
    /// Tool name, escaped.
    public let tool: String
    /// Short escaped summary of the arguments.
    public let summary: String
    /// What happened.
    public let outcome: FeedOutcome
    /// The deciding rule.
    public let ruleID: String
    /// How it ended, once an allowed or approved action has run; `nil` for everything else and while it runs.
    public internal(set) var result: RunResult?
}

/// Where a background job is.
public enum JobState: String, Sendable, Equatable {
    /// Waiting for the owner's approval.
    case waiting
    /// Allowed or approved, and running (or about to start).
    case running
    /// Ended on its own.
    case done
    /// Denied, withdrawn, or it could not start.
    case denied
    /// Killed: timeout, Stop, quitting, or `job_cancel`.
    case killed
}

/// A background command (`run_command` with `background: true`). Kept for this app session only.
public struct Job: Sendable, Equatable, Identifiable {
    /// Random, unguessable id, e.g. `job-1f3a…` (16 hex digits).
    public let id: String
    /// The command, escaped.
    public let summary: String
    /// When it was asked for.
    public let createdAt: Date
    /// Where it is now.
    public internal(set) var state: JobState
    /// How it ended.
    public internal(set) var result: RunResult?
    /// Why it was denied or could not start.
    public internal(set) var reason: String?
    /// Seconds it ran, once it ended.
    public internal(set) var duration: TimeInterval?
    /// The end of its output so far: at most `Supervisor.jobOutputLimit` characters.
    public internal(set) var output = ""
    /// Bytes it wrote in all.
    public internal(set) var totalBytes = 0
    /// True once Claude asked to cancel it.
    public internal(set) var cancelRequested = false
    var approvalID: String?
    var executionID: String?
    var startedAt: Date?
}

/// What `Supervisor.submit` did with a call.
public enum Submission: Sendable, Equatable {
    /// Answered at once.
    case finished(ToolResult)
    /// Waiting for the owner; answered later through a `Resolution` with this approval id.
    case pending(id: String)
    /// Allowed: the app runs it (if `Supervisor.mayExecute` still says so) and answers with `Supervisor.complete`.
    case execute(Execution)
    /// A background job was allowed: the app answers with `reply` at once and runs `execution` without a caller.
    case jobStarted(Execution, reply: ToolResult)
    /// A background job waits for the owner: the app tells the owner and answers with `reply` at once. If it is
    /// approved, its `Resolution` carries an execution with a `jobID`, which the app runs without a caller.
    case jobWaiting(approvalID: String, reply: ToolResult)
    /// Claude cancelled a running job: the app kills the execution with this id and answers with `reply`.
    case cancelJob(executionID: String, reply: ToolResult)
    /// Claude closed a serial session: the app closes its port and answers with `reply`.
    case closeSerial(session: String, reply: ToolResult)
}

/// How a serial operation the app ran went. Failures go to `Supervisor.complete` instead.
public enum SerialOutcome: Sendable, Equatable {
    /// `list`: the ports found.
    case listed([SerialPortInfo])
    /// `open`: the port is open.
    case opened
    /// `read`: the bytes taken from the buffer, how many were dropped before them, and whether the device is gone.
    case read(bytes: [UInt8], dropped: Int, deviceGone: Bool)
    /// `write`: every byte was sent.
    case wrote
    /// `reset`: the sequence ran.
    case reset
}

/// A file `write_file` or `apply_patch` wrote: its size and SHA-256.
public struct FileWritten: Sendable, Equatable {
    /// Bytes written.
    public let bytes: Int
    /// SHA-256 of the file now, lowercase hex.
    public let sha256: String

    /// Creates a record of a write.
    public init(bytes: Int, sha256: String) {
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// The result of a serial operation, and for `open` the new session the app keeps the port for.
public struct SerialReply: Sendable, Equatable {
    /// The caller's result.
    public let result: ToolResult
    /// The new session's id. `nil` after an `open` means the app must close the port at once.
    public let openedSession: String?
}

/// An allowed or approved action for the app to run.
public struct Execution: Sendable, Equatable {
    /// The approval id if it waited, otherwise a fresh id.
    public let id: String
    /// Tool that made the request.
    public let tool: String
    /// What to run.
    public let request: ActionRequest
    /// Why it may run.
    public let decision: Decision
    /// The session folder it was allowed for.
    let scope: SessionScope?
    /// The background job it runs for; `nil` for a call that waits for its result.
    public internal(set) var jobID: String? = nil
}

/// An execution that passed every check right before running, with its "starting" entry persisted. Only
/// `Supervisor.begin` makes one, so nothing can run without it.
public struct Launch: Sendable, Equatable {
    /// What was allowed.
    public let execution: Execution
    /// The session folder it runs in.
    public let scope: SessionScope
    /// True for the read-only tier: it runs in the READ-ONLY profile; everything else runs in CHANGING.
    public let readOnly: Bool
    /// For a recognised flasher or monitor (`FlasherCommand`), the one port it names with `-p`/`--port`, which
    /// its CHANGING profile alone may open; `nil` for everything else.
    public let serialPort: String?
    /// Seconds before a command's process group is killed.
    public let timeoutSeconds: Int
    /// For `git_clone` and `git_init`, the repository it makes, which its CLONING profile alone may write `.git` in;
    /// `nil` for everything else, also the same command line through run_command.
    public var git: GitLaunch? = nil
    /// For `esp_idf_install`, the ESP-IDF version it installs, which its INSTALLING profile alone may build and the
    /// app copies into the owner's toolchain folder when it ends; `nil` for everything else, also the same command
    /// line through run_command.
    public var toolchain: String? = nil
    /// For `claude_code_start`, the Claude Code version its fixed line starts, whose install the app checks right
    /// before typing it; `nil` for everything else, also the same text through terminal_send.
    public var claudeCode: String? = nil
    /// True for `git_commit`'s fixed script, which the app runs with the real git; `false` for everything else, also
    /// the same command line through run_command.
    public var gitCommit = false
    /// For `git_sync`, its action: the app fetches the remote as the owner, then runs the fixed script with the real
    /// git; `nil` for everything else, also the same command line through run_command.
    public var gitSync: GitSync.Action? = nil

    /// What to run.
    public var request: ActionRequest { execution.request }
}

/// What `Supervisor.begin` decided.
public enum StartAttempt: Sendable, Equatable {
    /// Run it.
    case launch(Launch)
    /// Do not run it; this is the caller's result.
    case refused(ToolResult)
}

/// How a command ended.
public struct CommandOutcome: Sendable, Equatable {
    /// Exit status, or 128 + signal.
    public var status: Int32
    /// The timeout ended it.
    public var timedOut: Bool
    /// Its process group was killed: timeout, Stop, quitting, or the caller leaving.
    public var killed: Bool
    /// Seconds from start to exit.
    public var duration: TimeInterval
    /// The first `shownBytes` of stdout and stderr, interleaved, decoded as UTF-8.
    public var output: String
    /// Bytes the command wrote in all.
    public var totalBytes: Int
    /// Bytes kept in `output`.
    public var shownBytes: Int
    /// The end of the output, for jobs whose output was longer than `output` keeps; `nil` if `output` is all of it.
    public var tail: String?

    /// Creates an outcome.
    public init(
        status: Int32,
        timedOut: Bool,
        killed: Bool,
        duration: TimeInterval,
        output: String,
        totalBytes: Int,
        shownBytes: Int,
        tail: String? = nil
    ) {
        self.tail = tail
        self.status = status
        self.timedOut = timedOut
        self.killed = killed
        self.duration = duration
        self.output = output
        self.totalBytes = totalBytes
        self.shownBytes = shownBytes
    }
}

/// The answer to a call that waited.
public struct Resolution: Sendable, Equatable {
    /// Approval id from `Submission.pending`.
    public let id: String
    /// Result for the waiting caller. With an `execution`, it is only the answer for when it cannot run after all.
    public let result: ToolResult
    /// Set when the owner approved something the app runs: run it, then answer with `Supervisor.complete`.
    public var execution: Execution?

    init(id: String, result: ToolResult, execution: Execution? = nil) {
        self.id = id
        self.result = result
        self.execution = execution
    }
}

/// The supervision session: routes every call through the policy engine, keeps asks waiting for the owner, times
/// them out, and records everything in the feed and the audit chain. Pure: the caller supplies the time, delivers
/// resolutions to waiting callers, and persists `drainAuditLines()`.
///
/// Pending asks are only ever decided by the owner, a timeout, Stop or a baton change. Changing the mode affects
/// new requests only, so granting "allow for 1 h" never approves what is already waiting.
public struct Supervisor: Sendable {
    /// Allowed approval timeouts: at least a minute, and shorter than the shim's 15-minute wait for an answer.
    public static let approvalTimeoutRange: ClosedRange<TimeInterval> = 60...840
    /// Feed entries kept.
    public static let feedLimit = 500
    /// Characters of output kept per job: the end, where the result usually is.
    public static let jobOutputLimit = 64 << 10
    /// Jobs kept; the oldest ended ones go first.
    public static let jobLimit = 200

    /// The policy engine.
    public private(set) var engine: PolicyEngine
    /// Waiting requests, oldest first.
    public private(set) var pending: [PendingApproval] = []
    /// Recent activity, newest first.
    public private(set) var feed: [FeedEntry] = []
    /// Seconds an ask waits before it is denied.
    public private(set) var approvalTimeout: TimeInterval
    /// The session folder; without one no command runs.
    public private(set) var scope: SessionScope?
    /// Why the sandbox cannot be trusted for this session folder, or `nil` once its self-test passed. While set,
    /// nothing runs as the agent.
    public private(set) var sandboxProblem: String?
    /// This session's background jobs, by id.
    public private(set) var jobs: [String: Job] = [:]
    /// Open serial sessions, by id. The app closes every port that is not here.
    public private(set) var serialSessions: [String: SerialSession] = [:]
    /// Which hosts the gatekeeper proxy lets agent processes reach; the app hands it to the proxy after changes.
    public private(set) var network: NetworkPolicy
    /// Hosts the proxy refused that the owner could allow, most recent first.
    public private(set) var deniedHosts: [DeniedHost] = []
    /// LAN endpoints the owner approved this session and their forwarders' local ports (D7b); the CHANGING profile
    /// lets agent processes reach those ports only. Cleared by Stop and by a new session folder.
    public private(set) var lanForwards: [LANForward] = []
    /// The Claude Code versions installed in the owner's toolchain folder, as the app last found them;
    /// `claude_code_start` starts the newest.
    public private(set) var claudeCodeVersions: [String] = []
    /// Branches with commits from `git_commit` waiting for the owner to review and push, oldest first.
    public private(set) var reviewQueue: [ReviewItem] = []
    /// Terminal tabs the owner is typing in (D12c): Claude cannot type there until the owner hands the tab back.
    public private(set) var ownerTypingTabs: Set<TerminalTab> = []
    /// The owner's git name and email, which `git_commit` uses; `nil` until the app found valid ones.
    public private(set) var commitIdentity: (name: String, email: String)?
    /// What the owner chose per repository (D12b): auto-push and the cap on open agent branches.
    public private(set) var repositoryPolicies: [String: RepositoryPolicy] = [:]
    /// The agent branches open on each repository's remote, as the app last counted them (D12b).
    public private(set) var openAgentBranches: [String: [String]] = [:]
    /// Each repository's branch and how far it is from the remote's default branch, as the app last read them
    /// (D13c). Cleared by a new session folder.
    public private(set) var branchStates: [String: BranchState] = [:]
    private var nextReviewID = 1
    /// Denied hosts kept.
    public static let deniedHostLimit = 50

    /// The problem before the self-test has run for the current session folder.
    public static let sandboxNotChecked = "the sandbox self-test has not run"

    /// Resolves a path like realpath(3): absolute, symlinks followed, on-disk case; `nil` if it does not exist.
    private let resolvePath: @Sendable (String) -> String?
    /// Finds a listed serial port that is plugged in now.
    private let lookUpPort: @Sendable (String) -> SerialPortInfo?
    /// Ports last reset into the ROM bootloader; a session opened on one refuses writes.
    private var bootloaderPorts: Set<String> = []

    private var audit: AuditLog
    private var auditOutbox: [String] = []
    private var nextApproval = 1
    private var nextFeedID = 1
    /// The feed entry that allowed or approved each execution, by execution id, for its outcome.
    private var executionEntries: [String: Int] = [:]
    /// The feed entry of each open proxy connection, by connection number, for how it ended.
    private var networkEntries: [Int: Int] = [:]
    /// False until `recordSessionStart` when the app asked to wait for it.
    private var sessionStarted: Bool

    /// Starts a session with saved rules and timeout. `auditHead` continues an existing chain. Working directories
    /// and path arguments are resolved with `resolvePath` and must be inside `scope`; the default resolver resolves
    /// nothing. Times are shown in `timeZone`. With `waitsForSessionStart`, every call is refused, and nothing is
    /// recorded for it, until `recordSessionStart`: the app opens its audit log first. Serial ports are looked up
    /// with `lookUpPort`; the default finds none. `allowedHosts` are the owner's saved network hosts.
    public init(
        rules: [AllowRule] = [],
        deviceRules: [DeviceRule] = [],
        allowedHosts: [String] = [],
        approvalTimeout: TimeInterval = 600,
        auditHead: AuditHead = .genesis,
        scope: SessionScope? = nil,
        sandboxProblem: String? = sandboxNotChecked,
        timeZone: TimeZone = .current,
        waitsForSessionStart: Bool = false,
        resolvePath: @escaping @Sendable (String) -> String? = { _ in nil },
        lookUpPort: @escaping @Sendable (String) -> SerialPortInfo? = { _ in nil }
    ) {
        sessionStarted = !waitsForSessionStart
        engine = PolicyEngine(mode: .askEach, rules: rules)
        engine.deviceRules = deviceRules
        engine.timeZone = timeZone
        network = NetworkPolicy(ownerHosts: allowedHosts)
        self.approvalTimeout = Self.clamped(approvalTimeout)
        audit = AuditLog(head: auditHead)
        self.scope = scope
        self.sandboxProblem = sandboxProblem
        self.resolvePath = resolvePath
        self.lookUpPort = lookUpPort
    }

    /// Project allow rules.
    public var rules: [AllowRule] { engine.rules }
    /// Serial device rules.
    public var deviceRules: [DeviceRule] { engine.deviceRules }
    /// Interventions so far.
    public var interventions: InterventionCounter { engine.interventions }
    /// Position after the last audit entry, including entries not drained yet.
    public var auditHead: AuditHead { audit.head }

    /// The state header for results and the window.
    public func header(now: Date) -> String {
        engine.stateHeader(now: now)
    }

    /// Audit lines produced since the last call, oldest first. The caller must persist them in order.
    public mutating func drainAuditLines() -> [String] {
        defer { auditOutbox = [] }
        return auditOutbox
    }

    // MARK: - Calls

    /// Routes and decides one call.
    public mutating func submit(_ call: IPCRequest, now: Date) -> Submission {
        guard sessionStarted else {
            return .finished(result("Dual Control is still starting; try again in a moment.", isError: true, now: now))
        }
        let toolName = DisplayText.summary(call.tool, limit: 64)
        switch ToolRouter.route(call) {
        case .unknown:
            let decision = Decision(verdict: .deny, reason: "unknown tool", ruleID: "tool.unknown")
            note(toolName, summary: "", decision: decision, request: nil, now: now)
            return .finished(result("Unknown tool: \(call.tool)", isError: true, now: now))
        case .invalid(let tool, let message):
            let decision = Decision(verdict: .deny, reason: "invalid arguments: \(message)", ruleID: "args.invalid")
            note(tool, summary: message, decision: decision, request: nil, now: now)
            return .finished(result("Invalid arguments: \(message).", isError: true, now: now))
        case .notImplemented(let tool):
            let decision = Decision(verdict: .deny, reason: "not implemented yet", ruleID: "tool.not-implemented")
            note(tool, summary: "", decision: decision, request: nil, now: now)
            return .finished(result("\(tool) is not implemented yet.", isError: true, now: now))
        case .status:
            let decision = Decision(verdict: .allow, reason: "status is read-only", ruleID: "tool.status")
            note("status", summary: "", decision: decision, request: nil, now: now)
            var lines = ["Dual Control \(DualControlCore.version) is running."]
            for repository in Set(openAgentBranches.keys).union(branchStates.keys).sorted() {
                let name = DisplayText.escaped(AgentBranches.name(of: repository))
                if let state = branchStates[repository] { lines.append("\(name): \(state.summary)") }
                if let open = openAgentBranches[repository] {
                    let policy = policy(for: repository)
                    lines.append(
                        "\(name): \(open.count) of \(policy.maxOpenBranches) agent branches open "
                            + "(auto-push \(policy.autoPush ? "on" : "off"))"
                    )
                }
            }
            return .finished(result(lines.joined(separator: "\n"), isError: false, now: now))
        case .action(let tool, let request):
            return submit(tool, request, now: now)
        case .takeover(let reason):
            return requestTakeover(reason, now: now)
        case .job(let tool, let request):
            return submitJob(tool, request, now: now)
        case .jobStatus(let id, let lines):
            return jobStatus(id, lines: lines, now: now)
        case .jobCancel(let id):
            return cancelJob(id, now: now)
        case .activity(let limit):
            return activity(limit: limit, now: now)
        case .serialClose(let session):
            return closeSerial(session, now: now)
        }
    }

    private mutating func submit(
        _ tool: String,
        _ request: ActionRequest,
        jobID: String? = nil,
        now: Date
    ) -> Submission {
        var request = request
        // An unknown session is a mistake, not something the owner had to stop: it is not counted.
        if request.capability == .serial, let session = SerialOperation(argv: request.argv)?.session,
            serialSessions[session] == nil
        {
            let decision = Decision(verdict: .deny, reason: "no such serial session", ruleID: "serial.no-session")
            note(tool, summary: Self.summary(request), decision: decision, request: request, now: now)
            let shown = DisplayText.summary(session, limit: 64)
            return .finished(
                result("No serial session \(shown) is open; open one with serial_open.", isError: true, now: now)
            )
        }
        // An endpoint approved already: the same forwarder, without asking again.
        if request.capability == .network, let endpoint = LANEndpoint(argv: request.argv),
            let forward = lanForwards.first(where: { $0.endpoint == endpoint })
        {
            let decision = Decision(verdict: .allow, reason: "approved earlier this session", ruleID: "lan.approved")
            note(tool, summary: Self.summary(request), decision: decision, request: request, now: now)
            return .finished(result(Self.lanMessage(forward), isError: false, now: now))
        }
        // The install runs in the session folder; its fixed script names paths outside it, which only it may.
        let isInstall = tool == ToolCatalogue.espIdfInstall.name
        if isInstall, let scope {
            request.cwd = scope.root
            request.projectID = scope.root
        }
        // The fixed line for the newest install names the owner's toolchain folder, which only it may.
        let isClaudeCode = tool == ToolCatalogue.claudeCodeStart.name
        if isClaudeCode {
            guard let scope, let version = ClaudeCode.newest(claudeCodeVersions),
                let line = ClaudeCode.launchLine(version: version, scope: scope)
            else {
                let denial = Decision(
                    verdict: .deny,
                    reason: scope == nil
                        ? "no session folder is chosen"
                        : "Claude Code is not installed; the owner installs it in the window",
                    ruleID: scope == nil ? "scope.none" : "claude-code.none"
                )
                note(tool, summary: "", decision: denial, request: request, now: now)
                return .finished(result(Self.denial(denial), isError: true, now: now))
            }
            request.argv = [line]
            request.tab = .second
        }
        // The fixed commit script: the message is data, not paths, and the identity is the owner's.
        let isCommit = tool == ToolCatalogue.gitCommit.name
        if isCommit, request.argv.count == 2 {
            let identity = commitIdentity ?? (GitCommit.agentName, GitCommit.agentEmail)
            request.argv = GitCommit.argv(
                message: request.argv[0],
                name: identity.name,
                email: identity.email,
                branch: request.argv[1]
            )
        }
        // The fixed sync script: the action and branch are checked names, the identity is the owner's.
        let isSync = tool == ToolCatalogue.gitSync.name
        if isSync, request.argv.count == 2 {
            let identity = commitIdentity ?? (GitCommit.agentName, GitCommit.agentEmail)
            let branch = request.argv[1].isEmpty ? nil : request.argv[1]
            if case .success(let action) = GitSync.parse(request.argv[0], branch: branch) {
                request.argv = GitSync.argv(action, name: identity.name, email: identity.email)
            }
        }
        if isSync, !GitSync.isSync(request.argv) {
            let denial = Decision(verdict: .deny, reason: "not a git_sync action", ruleID: "git-sync.invalid")
            note(tool, summary: "", decision: denial, request: request, now: now)
            return .finished(result(Self.denial(denial), isError: true, now: now))
        }
        if let denial = scoped(&request, checkArguments: !isInstall && !isClaudeCode && !isCommit && !isSync) {
            engine.recordDenial()
            note(tool, summary: Self.summary(request), decision: denial, request: request, now: now)
            return .finished(result(Self.denial(denial), isError: true, now: now))
        }
        // A new agent branch only below the owner's cap; a mistake to fix, not something the owner stopped.
        var makesBranch = isCommit && GitCommit.isCommit(request.argv)
        if isSync, case .start? = GitSync.action(of: request.argv) { makesBranch = true }
        if makesBranch, let refusal = branchCapRefusal(request) {
            let denial = Decision(verdict: .deny, reason: refusal, ruleID: "branches.cap")
            note(tool, summary: Self.summary(request), decision: denial, request: request, now: now)
            return .finished(result(Self.denial(denial), isError: true, now: now))
        }
        if let denial = tabDenial(request) {
            note(tool, summary: Self.summary(request), decision: denial, request: request, now: now)
            return .finished(result(Self.denial(denial), isError: true, now: now))
        }
        let decision = engine.evaluate(request, now: now)
        switch decision.verdict {
        case .allow where Self.isExecutable(request):
            let id = "x\(nextApproval)"
            nextApproval += 1
            note(tool, summary: Self.summary(request), decision: decision, request: request, detail: id, now: now)
            executionEntries[id] = feed.first?.id
            return .execute(
                Execution(id: id, tool: tool, request: request, decision: decision, scope: scope, jobID: jobID)
            )
        case .allow:
            note(tool, summary: Self.summary(request), decision: decision, request: request, now: now)
            return .finished(
                result("Allowed (\(decision.ruleID)). \(tool) is not implemented yet.", isError: true, now: now)
            )
        case .deny:
            note(tool, summary: Self.summary(request), decision: decision, request: request, now: now)
            return .finished(result(Self.denial(decision), isError: true, now: now))
        case .ask:
            let id = "a\(nextApproval)"
            nextApproval += 1
            pending.append(
                PendingApproval(
                    id: id,
                    tool: tool,
                    request: request,
                    decision: decision,
                    tier: Classifier.classify(request).tier,
                    askedAt: now,
                    deadline: now.addingTimeInterval(approvalTimeout),
                    jobID: jobID
                )
            )
            note(tool, summary: Self.summary(request), decision: decision, request: request, detail: id, now: now)
            return .pending(id: id)
        }
    }

    /// Replaces the working directory with its resolved form, or returns why the request may not run. Checked before
    /// the policy engine, so nothing outside the session folder (working directory or path arguments), and nothing
    /// without a working sandbox, is even considered. Terminal text has no working directory of its own: the pane
    /// always starts in the session folder.
    private func scoped(_ request: inout ActionRequest, checkArguments: Bool = true) -> Decision? {
        if request.capability == .serial { return serialScoped(&request) }
        if request.capability == .command || !request.cwd.isEmpty {
            guard let scope else {
                return Decision(verdict: .deny, reason: "no session folder is chosen", ruleID: "scope.none")
            }
            guard let resolved = resolvePath(request.cwd) else {
                return Decision(
                    verdict: .deny,
                    reason: request.capability == .file
                        ? "the folder does not exist; make it first (run_command mkdir -p)"
                        : "the working directory does not exist",
                    ruleID: "scope.unresolved"
                )
            }
            guard scope.contains(resolved) else {
                return Decision(
                    verdict: .deny,
                    reason: "the working directory is outside the session folder \(DisplayText.escaped(scope.root))",
                    ruleID: "scope.outside"
                )
            }
            // Until D5 derives projects from shared folders, the working directory stands in for the project.
            if request.projectID == ToolRouter.normalizedFolder(request.cwd) { request.projectID = resolved }
            request.cwd = resolved
        }
        if checkArguments, let scope,
            let denial = ArgumentScope.violation(
                request,
                scope: scope,
                resolvePath: resolvePath,
                isFreePort: { whyNotFlashable($0) }
            )
        {
            return denial
        }
        if request.capability == .command || Self.isExecutable(request), let problem = sandboxProblem {
            return Self.sandboxDenial(problem)
        }
        return nil
    }

    /// Serial requests belong to the session folder (device rules are per folder) and carry the device the port
    /// really belongs to. The app opens ports itself; nothing runs as the agent, so the sandbox does not matter.
    private func serialScoped(_ request: inout ActionRequest) -> Decision? {
        guard let scope else {
            return Decision(verdict: .deny, reason: "no session folder is chosen", ruleID: "scope.none")
        }
        request.cwd = scope.root
        request.projectID = scope.root
        switch SerialOperation(argv: request.argv) {
        case nil:
            return Decision(verdict: .deny, reason: "not a serial operation", ruleID: "serial.invalid")
        case .list:
            request.device = nil
        case .open(let port, _):
            if let open = serialSessions.values.first(where: { $0.port == port }) {
                return Decision(
                    verdict: .deny,
                    reason: "the port is already open in session \(open.id); use it or close it first",
                    ruleID: "serial.busy"
                )
            }
            guard serialSessions.count < SerialLimits.maxSessions else {
                return Decision(
                    verdict: .deny,
                    reason: "\(SerialLimits.maxSessions) serial sessions are open; close one first",
                    ruleID: "serial.too-many"
                )
            }
            guard let info = lookUpPort(port), info.path == port else {
                return Decision(
                    verdict: .deny,
                    reason: "\(DisplayText.escaped(port)) is not connected (see serial_list)",
                    ruleID: "serial.unknown-port"
                )
            }
            request.device = info.device
        case .read(let id, _, _, _), .write(let id, _), .reset(let id, _):
            guard let session = serialSessions[id] else {
                return Decision(verdict: .deny, reason: "no such serial session", ruleID: "serial.no-session")
            }
            request.device = session.device
            if case .write = SerialOperation(argv: request.argv), session.writesRefused {
                return Decision(
                    verdict: .deny,
                    reason: "this serial session was reset into the ROM bootloader (or opened while its device was "
                        + "there), where raw bytes could write eFuses; flash with run_command (esptool or idf.py), or "
                        + "serial_reset run, close this session and open a new one",
                    ruleID: "blocked.serial-bootloader"
                )
            }
        }
        return nil
    }

    static func sandboxDenial(_ problem: String) -> Decision {
        Decision(
            verdict: .deny,
            reason: "the sandbox is not available: \(DisplayText.escaped(problem))",
            ruleID: "sandbox.unavailable"
        )
    }

    // MARK: - Running

    /// Actions the app runs: commands, the shared terminal and serial ports.
    static func isExecutable(_ request: ActionRequest) -> Bool {
        [.command, .terminal, .terminalRead, .serial, .network, .file].contains(request.capability)
    }

    /// The last step before running `execution`. Re-checks everything that may have changed while it waited (the
    /// caller is still there, Stop, the baton, the session folder and sandbox, the policy decision, and that the
    /// working directory still resolves to itself), then records "starting" and hands every pending audit line,
    /// with the head after them, to `persist`. Only if `persist` returns true is there a `Launch`; otherwise nothing
    /// runs, and an audit failure also stops the session. A refusal is the result for the caller. `persist` runs
    /// while this supervisor is being changed, so it must not touch it.
    public mutating func begin(
        _ execution: Execution,
        callerConnected: Bool,
        now: Date,
        persist: ([String], AuditHead) -> Bool
    ) -> StartAttempt {
        if let problem = startProblem(execution, callerConnected: callerConnected, now: now) {
            return .refused(complete(execution, output: nil, failure: problem, now: now))
        }
        guard let scope = execution.scope else {
            return .refused(complete(execution, output: nil, failure: "it is no longer allowed", now: now))
        }
        record(.starting, request: execution.request, detail: execution.id, now: now)
        guard persist(drainAuditLines(), audit.head) else {
            engine.stop()
            return .refused(
                complete(execution, output: nil, failure: "the audit log could not be written", now: now)
            )
        }
        let request = execution.request
        if let jobID = execution.jobID { jobs[jobID]?.startedAt = now }
        // Fail closed: a bootloader reset refuses writes from the moment it starts, whether or not it works.
        if case .reset(let id, .bootloader)? = SerialOperation(argv: request.argv), let session = serialSessions[id] {
            serialSessions[id]?.writesRefused = true
            bootloaderPorts.insert(session.port)
        }
        let readOnly = Classifier.classify(request).tier == .readOnly
        let flasher =
            request.capability == .command && !readOnly
            && FlasherCommand.isRecognised(request.argv, scope: scope, resolve: resolvePath)
        return .launch(
            Launch(
                execution: execution,
                scope: scope,
                readOnly: readOnly,
                // Resolved now, right before it runs; `startProblem` has just checked it names one free port.
                serialPort: flasher ? FlasherCommand.portArguments(request.argv).first?.port : nil,
                timeoutSeconds: request.timeoutSeconds ?? CommandLimits.defaultTimeoutSeconds,
                git: Self.gitLaunch(execution),
                toolchain: execution.tool == ToolCatalogue.espIdfInstall.name
                    ? ESPIDFInstall.version(of: request.argv) : nil,
                claudeCode: execution.tool == ToolCatalogue.claudeCodeStart.name
                    ? ClaudeCode.version(ofLaunchLine: request.argv.joined(), scope: scope) : nil,
                gitCommit: execution.tool == ToolCatalogue.gitCommit.name && GitCommit.isCommit(request.argv),
                gitSync: execution.tool == ToolCatalogue.gitSync.name ? GitSync.action(of: request.argv) : nil
            )
        )
    }

    /// The repository a `git_clone` or `git_init` execution makes: the folder its fixed command line ends with.
    static func gitLaunch(_ execution: Execution) -> GitLaunch? {
        let argv = execution.request.argv
        guard let target = argv.last else { return nil }
        switch execution.tool {
        case ToolCatalogue.gitClone.name:
            return GitLaunch(kind: .clone, target: target, url: argv.dropLast().last)
        case ToolCatalogue.gitInit.name:
            return GitLaunch(kind: .initialize, target: target, url: nil)
        default:
            return nil
        }
    }

    /// Why a flasher may not name `port`, or `nil`: it must be a USB serial device serial_list shows that no
    /// Dual Control serial session holds.
    private func whyNotFlashable(_ port: String) -> String? {
        guard SerialPorts.isListed(port), lookUpPort(port)?.device != nil else {
            return "serial_list does not show it as a USB serial device"
        }
        if serialSessions.values.contains(where: { $0.port == port }) {
            return "a Dual Control serial session has it open; close that session first"
        }
        return nil
    }

    private func startProblem(_ execution: Execution, callerConnected: Bool, now: Date) -> String? {
        guard callerConnected else { return "the caller disconnected" }
        if let jobID = execution.jobID, jobs[jobID]?.cancelRequested == true { return "the job was cancelled" }
        guard mayExecute(execution) else { return "it is no longer allowed" }
        let request = execution.request
        let current = engine.decide(request, now: now)
        switch current.verdict {
        case .deny:
            return "\(current.reason) [\(current.ruleID)]"
        case .ask where execution.decision.ruleID != "owner.approved":
            return "it needs the owner's approval now [\(current.ruleID)]"
        case .ask, .allow:
            break
        }
        if let denial = tabDenial(request) { return "\(denial.reason) [\(denial.ruleID)]" }
        if [.command, .file].contains(request.capability) {
            guard let scope, resolvePath(request.cwd) == request.cwd, scope.contains(request.cwd) else {
                return "the working directory changed [scope.changed]"
            }
        }
        // A session may have closed, a write may now be refused, or another device may sit on the port.
        if request.capability == .serial {
            var current = request
            if let denial = serialScoped(&current) { return "\(denial.reason) [\(denial.ruleID)]" }
            guard current.device == request.device else {
                return "a different device is on the port now [serial.device-changed]"
            }
        }
        // A path may have been swapped for a symlink while it waited. The app's fixed lines are checked by the app.
        if ![
            ToolCatalogue.espIdfInstall.name, ToolCatalogue.claudeCodeStart.name, ToolCatalogue.gitCommit.name,
            ToolCatalogue.gitSync.name,
        ].contains(execution.tool),
            let scope,
            let denial = ArgumentScope.violation(
                request,
                scope: scope,
                resolvePath: resolvePath,
                isFreePort: { whyNotFlashable($0) }
            )
        {
            return "\(denial.reason) [\(denial.ruleID)]"
        }
        return nil
    }

    /// Records how a command ended and builds its result: status and duration, then the output as untrusted data.
    /// The audit gets the status and byte counts, never the output. `callerLeft` is true if it was killed because
    /// its caller abandoned the call.
    public mutating func finish(
        _ launch: Launch,
        outcome: CommandOutcome,
        callerLeft: Bool = false,
        now: Date
    ) -> ToolResult {
        let seconds = String(format: "%.1f", outcome.duration)
        var detail =
            "\(launch.execution.id) exit \(outcome.status) in \(seconds) s; \(outcome.totalBytes) bytes, "
            + "\(outcome.shownBytes) shown"
        if outcome.timedOut { detail += "; timed out" }
        if outcome.killed { detail += "; killed" }
        if outcome.killed, callerLeft { detail += "; caller left" }
        record(.executed, request: launch.request, detail: detail, now: now)
        var runResult = Self.result(of: outcome, stopped: engine.isStopped, callerLeft: callerLeft)
        if let jobID = launch.execution.jobID, var job = jobs[jobID] {
            if outcome.killed, job.cancelRequested { runResult = .cancelled }
            job.state = outcome.killed || outcome.timedOut ? .killed : .done
            job.result = runResult
            job.duration = outcome.duration
            job.output = Self.tail(outcome.tail ?? outcome.output)
            job.totalBytes = outcome.totalBytes
            jobs[jobID] = job
        }
        setResult(runResult, for: launch.execution)
        var message: String
        if outcome.timedOut {
            message = "Timed out after \(launch.timeoutSeconds) s; its process group was killed."
        } else if outcome.killed {
            message =
                "Killed after \(seconds) s (Stop, the app quit, or the caller left); its process group was killed."
        } else {
            message = "Exit status \(outcome.status) after \(seconds) s."
        }
        if outcome.totalBytes > outcome.shownBytes {
            message += "\nOutput truncated: the first \(outcome.shownBytes) of \(outcome.totalBytes) bytes."
        }
        if launch.gitCommit, let open = openAgentBranches[launch.request.cwd] {
            message += "\n" + AgentBranches.note(open: open, policy: policy(for: launch.request.cwd))
        }
        var generator = SystemRandomNumberGenerator()
        return ResultEnvelope.make(
            header: engine.stateHeader(now: now),
            message: message,
            untrusted: (.command, outcome.output, ResultEnvelope.makeBoundary(using: &generator)),
            isError: outcome.status != 0 || outcome.timedOut || outcome.killed
        )
    }

    static func result(of outcome: CommandOutcome, stopped: Bool, callerLeft: Bool) -> RunResult {
        if outcome.timedOut { return .timedOut }
        if outcome.killed { return stopped ? .killedByStop : callerLeft ? .callerLeft : .killed }
        if outcome.status != 0, outcome.output.contains("Operation not permitted") {
            return .blockedBySandbox(outcome.status)
        }
        return .exited(outcome.status)
    }

    /// The caller of a waiting request has gone: the request is denied and can no longer be approved. False if it
    /// is not waiting.
    public mutating func withdraw(_ id: String, now: Date) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        let approval = pending.remove(at: index)
        engine.recordDenial()
        let decision = Decision(verdict: .deny, reason: "the caller disconnected", ruleID: "caller.disconnected")
        endWaitingJob(approval, decision)
        record(.decision, request: approval.request, decision: decision, detail: id, now: now)
        addFeed(approval.tool, Self.summary(approval.request), .denied, decision.ruleID, now: now)
        return true
    }

    /// True if `execution` may still run now: not stopped, Claude holds the baton, the session folder is unchanged
    /// and its sandbox self-test passed. The app checks this right before running, after the audit is written.
    public func mayExecute(_ execution: Execution) -> Bool {
        !engine.isStopped && engine.baton == .claude && execution.scope != nil && execution.scope == scope
            && (sandboxProblem == nil || execution.request.capability == .serial)
    }

    /// Records how a run went and builds the result. Terminal contents are returned as untrusted data.
    public mutating func complete(_ execution: Execution, output: String?, failure: String?, now: Date) -> ToolResult {
        if let failure {
            record(.executed, request: execution.request, detail: "\(execution.id) failed: \(failure)", now: now)
            setResult(.notRun, for: execution)
            if let jobID = execution.jobID {
                jobs[jobID]?.state = .denied
                jobs[jobID]?.result = .notRun
                jobs[jobID]?.reason = failure
            }
            addFeed(execution.tool, Self.summary(execution.request), .failed, execution.decision.ruleID, now: now)
            return result("Could not run \(execution.tool): \(failure).", isError: true, now: now)
        }
        record(.executed, request: execution.request, detail: "\(execution.id) ok", now: now)
        setResult(.done, for: execution)
        switch execution.request.capability {
        case .terminalRead:
            var generator = SystemRandomNumberGenerator()
            let boundary = ResultEnvelope.makeBoundary(using: &generator)
            return ResultEnvelope.make(
                header: engine.stateHeader(now: now),
                message: "The shared terminal's last \(execution.request.argv.first ?? "") lines:",
                untrusted: (.terminal, output ?? "", boundary)
            )
        case .network:
            return result(output ?? "", isError: false, now: now)
        default:
            return result("Typed into the shared terminal.", isError: false, now: now)
        }
    }

    // MARK: - Files

    /// Records how a `write_file` or `apply_patch` ended and builds its result. The audit gets the size and SHA-256
    /// written, never the content.
    public mutating func finishFile(
        _ launch: Launch,
        _ outcome: Result<FileWritten, FileWrite.Problem>,
        now: Date
    ) -> ToolResult {
        switch outcome {
        case .failure(let problem):
            return complete(launch.execution, output: nil, failure: problem.description, now: now)
        case .success(let written):
            let detail = "\(launch.execution.id) ok: wrote \(written.bytes) bytes, sha256 \(written.sha256)"
            record(.executed, request: launch.request, detail: detail, now: now)
            setResult(.done, for: launch.execution)
            let path = FileRequest(argv: launch.request.argv).map { DisplayText.escaped($0.path) } ?? "the file"
            return result("Wrote \(path): \(written.bytes) bytes, sha256 \(written.sha256).", isError: false, now: now)
        }
    }

    // MARK: - Serial

    /// Records how a serial operation ended and builds its result; device output is returned as untrusted data,
    /// never written to the audit. For `open`, the session it registers, unless Stop or a new session folder came
    /// while the port opened: then the app closes it at once.
    public mutating func finishSerial(_ launch: Launch, _ outcome: SerialOutcome, now: Date) -> SerialReply {
        let execution = launch.execution
        let request = launch.request
        var generator = SystemRandomNumberGenerator()
        func reply(_ message: String, untrusted: String? = nil, session: String? = nil) -> SerialReply {
            setResult(.done, for: execution)
            let block = untrusted.map { (UntrustedSource.serial, $0, ResultEnvelope.makeBoundary(using: &generator)) }
            let made = ResultEnvelope.make(header: engine.stateHeader(now: now), message: message, untrusted: block)
            return SerialReply(result: made, openedSession: session)
        }
        switch (SerialOperation(argv: request.argv), outcome) {
        case (.list, .listed(let ports)):
            let shown = ports.filter { SerialPorts.isListed($0.path) }
            record(.executed, request: request, detail: "\(execution.id) ok: \(shown.count) ports", now: now)
            let lines = shown.map(\.line).joined(separator: "\n")
            return reply(
                shown.isEmpty ? "No serial ports are connected." : "\(shown.count) serial ports:",
                untrusted: lines
            )
        case (.open(let port, let settings), .opened):
            guard !engine.isStopped, launch.scope == scope, serialSessions.count < SerialLimits.maxSessions,
                !serialSessions.values.contains(where: { $0.port == port })
            else {
                return SerialReply(
                    result: complete(execution, output: nil, failure: "it is no longer allowed", now: now),
                    openedSession: nil
                )
            }
            let id = "serial-" + String(format: "%016llx", generator.next() as UInt64)
            let refused = bootloaderPorts.contains(port)
            serialSessions[id] = SerialSession(
                id: id,
                port: port,
                device: request.device,
                settings: settings,
                openedAt: now,
                writesRefused: refused
            )
            record(.executed, request: request, detail: "\(execution.id) ok: opened \(id)", now: now)
            var message = "Opened \(DisplayText.escaped(port)) at \(settings.description) as session \(id). "
            message += "Read it with serial_read; close it with serial_close."
            if refused { message += " Its device was last reset into the bootloader, so serial_write is refused." }
            return reply(message, session: id)
        case (.read(let id, _, _, let hex), .read(let bytes, let dropped, let gone)):
            record(.executed, request: request, detail: "\(execution.id) ok: \(bytes.count) bytes", now: now)
            var message = "Read \(bytes.count) bytes from \(id)\(hex ? " (hex dump)" : "")."
            if dropped > 0 {
                message += "\n\(dropped) older bytes were dropped before these: the buffer was full."
            }
            if gone { message += "\nThe device is gone (unplugged or reset its USB); close this session." }
            return reply(message, untrusted: hex ? SerialText.hexDump(bytes) : SerialText.render(bytes))
        case (.write(let id, let bytes), .wrote):
            record(.executed, request: request, detail: "\(execution.id) ok: \(bytes.count) bytes", now: now)
            return reply("Sent \(bytes.count) bytes to \(id).")
        case (.reset(let id, let mode), .reset):
            if mode == .run, let session = serialSessions[id] { bootloaderPorts.remove(session.port) }
            record(.executed, request: request, detail: "\(execution.id) ok: reset \(mode.rawValue)", now: now)
            var message = "Reset \(id) into \(mode.rawValue)."
            if mode == .bootloader {
                message += " serial_write is now refused in this session; close it before flashing with run_command."
            }
            return reply(message)
        default:
            return SerialReply(
                result: complete(execution, output: nil, failure: "the app reported the wrong outcome", now: now),
                openedSession: nil
            )
        }
    }

    /// Records that the ESP-IDF environment was derived from `install` for `launch`, a flasher that is starting,
    /// in the audit log and the feed. `problem` says why it cannot be used, or `nil` if it can.
    public mutating func recordIDFEnvironment(_ launch: Launch, install: String, problem: String?, now: Date) {
        let execution = launch.execution
        let outcome = problem.map { "failed: " + $0 } ?? "ok"
        let summary = "esp-idf env derived from \(install)" + (problem.map { ": failed: " + $0 } ?? "")
        record(
            .idfEnvironment,
            request: execution.request,
            decision: execution.decision,
            detail: "\(execution.id): esp-idf env derived from \(DisplayText.escaped(install)): "
                + DisplayText.escaped(outcome),
            now: now
        )
        let approved = execution.decision.ruleID == "owner.approved"
        addFeed(
            execution.tool,
            DisplayText.summary(summary, limit: 300),
            problem == nil ? (approved ? .approved : .allowed) : .failed,
            execution.decision.ruleID,
            now: now
        )
        if problem == nil { feed[0].result = .done }
    }

    /// Records, as part of `launch`, that an install was copied into the owner's toolchain folder with `digest`
    /// (SHA-256 of its manifest), or that it was refused or failed its check (`problem`). Called after the install
    /// job ends and before it is finished, and when a flasher's install fails its check.
    public mutating func recordToolchain(
        _ launch: Launch,
        install: String,
        digest: String?,
        problem: String?,
        now: Date
    ) {
        let execution = launch.execution
        let outcome = problem.map { "failed: " + $0 } ?? "sha256 " + (digest ?? "")
        record(
            .toolchain,
            request: execution.request,
            decision: execution.decision,
            detail: "\(execution.id): toolchain \(DisplayText.escaped(install)): " + DisplayText.escaped(outcome),
            now: now
        )
        let summary = "toolchain \(install)" + (problem.map { ": failed: " + $0 } ?? ": checked")
        addFeed(
            execution.tool,
            DisplayText.summary(summary, limit: 300),
            problem == nil ? .allowed : .failed,
            execution.decision.ruleID,
            now: now
        )
        if problem == nil { feed[0].result = .done }
    }

    /// The Claude Code versions installed in the owner's toolchain folder, as the app found them.
    public mutating func setClaudeCodeVersions(_ versions: [String]) {
        claudeCodeVersions = versions.filter { ClaudeCode.versionProblem($0) == nil }
    }

    /// The owner installed Claude Code `version` in the window (D11): into `install` with this hash, or why not.
    public mutating func recordClaudeCodeInstall(
        version: String,
        install: String,
        digest: String?,
        problem: String?,
        now: Date
    ) {
        let outcome = problem.map { "failed: " + $0 } ?? "sha256 " + (digest ?? "")
        record(
            .claudeCode,
            detail: "claude code \(DisplayText.escaped(version)) installed in \(DisplayText.escaped(install)): "
                + DisplayText.escaped(outcome),
            now: now
        )
        addFeed(
            "claude_code_install",
            DisplayText.summary(
                "Claude Code \(version)" + (problem.map { ": failed: " + $0 } ?? ": installed"),
                limit: 300
            ),
            problem == nil ? .allowed : .failed,
            "owner.claude-code",
            now: now
        )
        if problem == nil { feed[0].result = .done }
    }

    /// The owner started Claude Code `version` in the shared terminal from the window: typed by the owner, so not
    /// decided, but recorded.
    public mutating func recordOwnerClaudeCodeStart(version: String, now: Date) {
        record(.claudeCode, detail: "owner started claude code \(DisplayText.escaped(version))", now: now)
        addFeed(
            ToolCatalogue.claudeCodeStart.name,
            DisplayText.summary("owner started Claude Code \(version)", limit: 120),
            .allowed,
            "owner.claude-code",
            now: now
        )
        feed[0].result = .done
    }

    // MARK: - Network

    /// Finishes an approved `net_allow_request` (`launch`): its forwarder listens on `localPort`, or could not be
    /// started (`failure`). Recorded in the audit log; from now on new agent processes may reach that port.
    public mutating func lanEndpointOpened(_ launch: Launch, localPort: UInt16?, failure: String?, now: Date)
        -> ToolResult
    {
        guard let endpoint = LANEndpoint(argv: launch.request.argv), let localPort, failure == nil else {
            return complete(launch.execution, output: nil, failure: failure ?? "not a LAN endpoint", now: now)
        }
        let forward = LANForward(endpoint: endpoint, localPort: localPort)
        lanForwards.removeAll { $0.endpoint == endpoint }
        lanForwards.append(forward)
        record(.ruleAdded, detail: "lan \(endpoint) via 127.0.0.1:\(localPort) for this session", now: now)
        return complete(launch.execution, output: Self.lanMessage(forward), failure: nil, now: now)
    }

    static func lanMessage(_ forward: LANForward) -> String {
        let endpoint = forward.endpoint
        return "Approved for this session: \(endpoint) is reachable at 127.0.0.1:\(forward.localPort) "
            + "(\(endpoint.transport.rawValue)), for run_command programs started from now on. Connect there, not "
            + "to \(endpoint.host)."
    }

    /// Forgets every approved LAN endpoint; the app closes their forwarders.
    private mutating func forgetLANForwards(_ why: String, now: Date) {
        for forward in lanForwards {
            record(.ruleRemoved, detail: "lan \(forward.endpoint) via 127.0.0.1:\(forward.localPort): \(why)", now: now)
        }
        lanForwards = []
    }

    /// The owner's saved hosts, sorted, for settings and the Rules sheet.
    public var ownerHosts: [String] { network.ownerHosts.sorted() }

    /// Records a connection attempt the proxy decided: in the audit log and as a "network" feed row. A refused
    /// host the owner could allow goes to `deniedHosts`. Not an intervention: the owner was not asked.
    public mutating func recordNetworkAttempt(_ attempt: NetworkAttempt, now: Date) {
        let decision = attempt.decision
        let target = "\(DisplayText.escaped(attempt.host)):\(attempt.port)"
        let verdict = decision.isAllowed ? "allowed" : "denied"
        record(
            .network,
            detail: "n\(attempt.connection) \(DisplayText.escaped(attempt.method)) \(target): \(verdict) "
                + "[\(decision.ruleID)]",
            now: now
        )
        addFeed(
            "network",
            DisplayText.summary("\(attempt.method) \(attempt.host):\(attempt.port)", limit: 120),
            decision.isAllowed ? .allowed : .denied,
            decision.ruleID,
            now: now
        )
        if decision.isAllowed {
            networkEntries[attempt.connection] = nextFeedID - 1
        } else if let host = decision.allowableHost {
            var entry = deniedHosts.first { $0.host == host } ?? DeniedHost(host: host, count: 0, lastSeen: now)
            deniedHosts.removeAll { $0.host == host }
            entry.count += 1
            entry.lastSeen = now
            deniedHosts.insert(entry, at: 0)
            if deniedHosts.count > Self.deniedHostLimit {
                deniedHosts.removeLast(deniedHosts.count - Self.deniedHostLimit)
            }
        }
    }

    /// Records how an allowed connection ended: bytes each way and duration, or why the server was not reached.
    public mutating func recordNetworkClosed(_ transfer: NetworkTransfer, now: Date) {
        var detail =
            "n\(transfer.connection) closed \(DisplayText.escaped(transfer.host)):\(transfer.port): "
            + "up \(transfer.bytesUp) B, down \(transfer.bytesDown) B, \(String(format: "%.1f", transfer.duration)) s"
        if let failure = transfer.failure { detail += ", failed: " + DisplayText.escaped(failure) }
        record(.network, detail: detail, now: now)
        guard let entryID = networkEntries.removeValue(forKey: transfer.connection),
            let index = feed.firstIndex(where: { $0.id == entryID })
        else { return }
        feed[index].result =
            transfer.failure.map { .unreachable(DisplayText.summary($0, limit: 120)) }
            ?? .transferred(up: transfer.bytesUp, down: transfer.bytesDown, seconds: transfer.duration)
    }

    // MARK: - Review and push (D11 phase 3)

    /// The owner's git identity for `git_commit`, if it is valid (`GitCommit.isIdentity`); otherwise none.
    public mutating func setCommitIdentity(name: String, email: String) {
        commitIdentity = GitCommit.isIdentity(name: name, email: email) ? (name, email) : nil
    }

    /// A `git_commit` ended well: `branch` of `repository` now waits for the owner (one entry per branch).
    /// `rebased` (a `git_sync update` moved it): its push may replace the remote branch with a lease, until pushed.
    public mutating func queueForReview(
        repository: String,
        branch: String,
        commit: String,
        rebased: Bool = false,
        now: Date
    ) {
        if let index = reviewQueue.firstIndex(where: { $0.repository == repository && $0.branch == branch }) {
            reviewQueue[index].commit = commit
            reviewQueue[index].queuedAt = now
            reviewQueue[index].rebased = reviewQueue[index].rebased || rebased
        } else {
            var item = ReviewItem(
                id: nextReviewID,
                repository: repository,
                branch: branch,
                commit: commit,
                queuedAt: now
            )
            item.rebased = rebased
            reviewQueue.append(item)
            nextReviewID += 1
        }
        record(
            .review,
            detail: "queued for review: \(DisplayText.escaped(repository)) \(DisplayText.escaped(branch)) "
                + DisplayText.escaped(commit) + (rebased ? " (rebased)" : ""),
            now: now
        )
    }

    /// The owner dismissed a queued branch without pushing it.
    public mutating func removeFromReview(_ id: Int, now: Date) {
        guard let index = reviewQueue.firstIndex(where: { $0.id == id }) else { return }
        let item = reviewQueue.remove(at: index)
        record(
            .review,
            detail: "removed from review: \(DisplayText.escaped(item.repository)) \(DisplayText.escaped(item.branch))",
            now: now
        )
    }

    /// The owner pushed a queued branch (it leaves the queue), or the push failed (it stays).
    public mutating func recordPush(
        _ id: Int,
        remote: String,
        commits: Int,
        signedTip: String?,
        problem: String?,
        automatic: Bool = false,
        now: Date
    ) {
        guard let index = reviewQueue.firstIndex(where: { $0.id == id }) else { return }
        let item = reviewQueue[index]
        let branch = DisplayText.escaped(item.branch)
        if let problem {
            record(.review, detail: "push of \(branch) failed: " + DisplayText.escaped(problem), now: now)
        } else {
            reviewQueue.remove(at: index)
            record(
                .review,
                detail: "\(automatic ? "auto-pushed" : "owner pushed") \(branch) to \(DisplayText.escaped(remote)): "
                    + "\(commits) commits, signed tip "
                    + DisplayText.escaped(signedTip ?? ""),
                now: now
            )
        }
        addFeed(
            "push",
            DisplayText.summary("\(item.branch) → \(remote)" + (problem.map { ": " + $0 } ?? ""), limit: 160),
            problem == nil ? .allowed : .failed,
            automatic ? "owner.auto-push" : "owner.push",
            now: now
        )
        if problem == nil { feed[0].result = .done }
    }

    // MARK: - Agent branches (D12b)

    /// The owner's choice for `repository`, or the defaults.
    public func policy(for repository: String) -> RepositoryPolicy {
        repositoryPolicies[repository] ?? RepositoryPolicy()
    }

    /// The owner changed a repository's auto-push or cap in the window.
    public mutating func setRepositoryPolicy(_ policy: RepositoryPolicy, for repository: String, now: Date) {
        guard repositoryPolicies[repository] != policy else { return }
        repositoryPolicies[repository] = policy
        record(
            .settingsChanged,
            detail: "repository \(DisplayText.escaped(repository)): \(policy.description)",
            now: now
        )
    }

    /// Policies saved earlier, at launch; not a change, so not recorded.
    public mutating func restoreRepositoryPolicies(_ policies: [String: RepositoryPolicy]) {
        repositoryPolicies = policies
    }

    /// Where `repository` stands (D13c), or `nil` to forget it; only repositories in the session folder.
    public mutating func setBranchState(_ state: BranchState?, for repository: String) {
        guard state == nil || scope?.contains(repository) == true else { return }
        branchStates[repository] = state
    }

    /// The agent branches the app found open on `repository`'s remote.
    public mutating func setOpenAgentBranches(_ branches: [String], for repository: String) {
        openAgentBranches[repository] = branches.filter(AgentBranches.isAgentBranch).sorted()
    }

    /// Why `git_commit`'s or `git_sync start`'s fixed command line may not make its branch, or `nil`: a new
    /// `claude/*` branch (not open on the remote, not waiting in the review queue) while the cap is reached. An
    /// unknown count does not refuse.
    private func branchCapRefusal(_ request: ActionRequest) -> String? {
        let repository = request.cwd
        let branch = GitSync.action(of: request.argv)?.branch ?? request.argv[7]
        guard AgentBranches.isAgentBranch(branch), let open = openAgentBranches[repository], !open.contains(branch),
            !reviewQueue.contains(where: { $0.repository == repository && $0.branch == branch })
        else { return nil }
        let cap = policy(for: repository).maxOpenBranches
        return open.count >= cap ? AgentBranches.capRefusal(repository: repository, open: open, cap: cap) : nil
    }

    /// The app opened (or found open) a pull request for an auto-pushed branch, or could not.
    public mutating func recordPullRequest(
        repository: String,
        branch: String,
        url: String?,
        problem: String?,
        now: Date
    ) {
        let shown = DisplayText.escaped(branch)
        let detail =
            problem.map { "pull request for \(shown) not opened: " + DisplayText.escaped($0) }
            ?? "pull request for \(shown): " + DisplayText.escaped(url ?? "")
        record(.review, detail: "\(DisplayText.escaped(repository)) " + detail, now: now)
        addFeed(
            "pull request",
            DisplayText.summary("\(branch) " + (problem.map { "failed: " + $0 } ?? url ?? ""), limit: 160),
            problem == nil ? .allowed : .failed,
            "owner.auto-push",
            now: now
        )
        if problem == nil { feed[0].result = .done }
    }

    /// The app deleted a merged agent branch on the remote and in the repository, or could not.
    public mutating func recordBranchCleanup(repository: String, branch: String, problem: String?, now: Date) {
        let shown = DisplayText.escaped(branch)
        let detail =
            problem.map { "deleting merged \(shown) failed: " + DisplayText.escaped($0) } ?? "deleted merged \(shown)"
        record(.review, detail: "\(DisplayText.escaped(repository)) " + detail, now: now)
        if problem == nil, var open = openAgentBranches[repository] {
            open.removeAll { $0 == branch }
            openAgentBranches[repository] = open
        }
    }

    /// The owner saved or removed the model relay's API key in the window; the key itself is never recorded.
    public mutating func recordModelKeyChange(saved: Bool, now: Date) {
        record(.settingsChanged, detail: saved ? "model relay key saved" : "model relay key removed", now: now)
    }

    /// The owner set or removed the model relay's monthly budget (D12e).
    public mutating func recordRelayBudget(limit: Double?, now: Date) {
        record(
            .settingsChanged,
            detail: "model relay monthly budget: " + (limit.map { String(format: "$%.2f", $0) } ?? "none"),
            now: now
        )
    }

    /// Records one request through the model relay (D11): path, model, status, sizes and duration, or why the relay
    /// refused it; never its body.
    public mutating func recordModelRelay(_ exchange: ModelRelayExchange, now: Date) {
        let path = DisplayText.escaped(exchange.path)
        var detail = "m\(exchange.number) POST \(path)"
        if let refusal = exchange.refusal {
            detail += ": refused \(exchange.status): " + DisplayText.escaped(refusal)
        } else {
            detail +=
                " model \(DisplayText.escaped(exchange.model)): \(exchange.status), up \(exchange.bytesUp) B, "
                + "down \(exchange.bytesDown) B, \(String(format: "%.1f", exchange.duration)) s"
            if let usage = exchange.usage { detail += "; \(usage.summary); $" + String(format: "%.4f", exchange.cost) }
        }
        record(.network, detail: detail, now: now)
        let allowed = exchange.refusal == nil
        addFeed(
            "model",
            DisplayText.summary("relay \(exchange.path)" + (allowed ? " · \(exchange.model)" : ""), limit: 120),
            allowed ? .allowed : .denied,
            allowed ? "relay.model" : "relay.refused",
            now: now
        )
        if allowed {
            feed[0].result = .transferred(up: exchange.bytesUp, down: exchange.bytesDown, seconds: exchange.duration)
        }
    }

    /// The owner allows `host` for this session or always. Returns false if it is not a host name or is already a
    /// default host.
    public mutating func allowHost(_ host: String, always: Bool, now: Date) -> Bool {
        guard let name = network.add(host, always: always) else { return false }
        deniedHosts.removeAll { $0.host == name }
        record(.ruleAdded, detail: "host \(name) allowed \(always ? "always" : "for this session")", now: now)
        return true
    }

    /// The owner stops allowing a host they added. Returns false if they had not.
    public mutating func removeHost(_ host: String, now: Date) -> Bool {
        guard network.remove(host), let name = NetworkHost.normalized(host) else { return false }
        record(.ruleRemoved, detail: "host \(name) no longer allowed", now: now)
        return true
    }

    /// `serial_close`: always allowed, since it only ends Claude's own session.
    private mutating func closeSerial(_ id: String, now: Date) -> Submission {
        let tool = ToolCatalogue.serialClose.name
        let shown = DisplayText.summary(id, limit: 64)
        let decision = Decision(verdict: .allow, reason: "Claude closes its own session", ruleID: "tool.serial-close")
        note(tool, summary: shown, decision: decision, request: nil, now: now)
        guard let session = serialSessions.removeValue(forKey: id) else {
            return .finished(result("No serial session \(shown) is open.", isError: true, now: now))
        }
        record(.serialClosed, detail: "\(id) \(DisplayText.escaped(session.port)): closed by Claude", now: now)
        return .closeSerial(session: id, reply: result("Closed \(id).", isError: false, now: now))
    }

    /// Forgets every serial session; the app closes their ports.
    private mutating func closeAllSerial(_ reason: String, now: Date) {
        for id in serialSessions.keys.sorted() {
            guard let session = serialSessions.removeValue(forKey: id) else { continue }
            record(.serialClosed, detail: "\(id) \(DisplayText.escaped(session.port)): \(reason)", now: now)
        }
    }

    /// Claude asks the owner to take over. Not an intervention until the owner actually takes over.
    private mutating func requestTakeover(_ reason: String, now: Date) -> Submission {
        let tool = ToolCatalogue.requestTakeover.name
        let shown = DisplayText.summary(reason, limit: 200)
        guard !engine.isStopped, engine.apply(.claudeRequestsTakeover(reason: shown)) else {
            let decision = Decision(
                verdict: .deny,
                reason: "a takeover cannot be requested now",
                ruleID: "baton.unavailable"
            )
            note(tool, summary: shown, decision: decision, request: nil, now: now)
            return .finished(result(Self.denial(decision), isError: true, now: now))
        }
        let decision = Decision(verdict: .allow, reason: "asked the owner to take over", ruleID: "baton.requested")
        note(tool, summary: shown, decision: decision, request: nil, now: now)
        record(.baton, detail: engine.stateHeader(now: now), now: now)
        return .finished(
            result(
                "Asked the owner to take over. Your actions are denied until they hand back or decline.",
                isError: false,
                now: now
            )
        )
    }

    // MARK: - Jobs

    /// The job with this id, if this session has it.
    public func job(_ id: String) -> Job? { jobs[id] }

    /// The latest output of a running job, from the app (about once a second).
    public mutating func updateJobOutput(_ id: String, tail: String, totalBytes: Int) {
        guard jobs[id]?.state == .running else { return }
        jobs[id]?.output = Self.tail(tail)
        jobs[id]?.totalBytes = totalBytes
    }

    /// `run_command` with `background: true`: decided exactly like a command, but answered at once.
    private mutating func submitJob(_ tool: String, _ request: ActionRequest, now: Date) -> Submission {
        var generator = SystemRandomNumberGenerator()
        let id = "job-" + String(format: "%016llx", generator.next() as UInt64)
        let submission = submit(tool, request, jobID: id, now: now)
        var job = Job(id: id, summary: Self.summary(request), createdAt: now, state: .running)
        switch submission {
        case .execute(let execution):
            job.executionID = execution.id
            add(job)
            let reply = "Started as job \(id). Check it with job_status; stop it with job_cancel."
            return .jobStarted(execution, reply: result(reply, isError: false, now: now))
        case .pending(let approvalID):
            job.state = .waiting
            job.approvalID = approvalID
            add(job)
            let reply =
                "Job \(id) is waiting for the owner's approval; it starts once approved. Check it with job_status."
            return .jobWaiting(approvalID: approvalID, reply: result(reply, isError: false, now: now))
        default:
            return submission
        }
    }

    private mutating func add(_ job: Job) {
        jobs[job.id] = job
        guard jobs.count > Self.jobLimit else { return }
        let ended = jobs.values.filter { ![.waiting, .running].contains($0.state) }.sorted {
            $0.createdAt < $1.createdAt
        }
        for old in ended.prefix(jobs.count - Self.jobLimit) { jobs.removeValue(forKey: old.id) }
    }

    /// A waiting job's approval was decided against it.
    private mutating func endWaitingJob(_ approval: PendingApproval, _ decision: Decision) {
        guard let jobID = approval.jobID else { return }
        jobs[jobID]?.state = .denied
        jobs[jobID]?.reason = "\(decision.reason) [\(decision.ruleID)]"
    }

    private mutating func jobStatus(_ id: String, lines: Int, now: Date) -> Submission {
        let tool = ToolCatalogue.jobStatus.name
        let shown = DisplayText.summary(id, limit: 64)
        let decision = Decision(verdict: .allow, reason: "job_status is read-only", ruleID: "tool.job-status")
        note(tool, summary: shown, decision: decision, request: nil, now: now)
        guard let job = jobs[id] else {
            return .finished(result("No job \(shown) in this session.", isError: true, now: now))
        }
        var message = "Job \(id) (\(job.summary)): "
        switch job.state {
        case .waiting:
            message += "waiting for the owner's approval"
            if let deadline = pending.first(where: { $0.id == job.approvalID })?.deadline {
                message += "; denied if unanswered in \(Self.duration(deadline.timeIntervalSince(now)))"
            }
            message += "."
        case .running:
            message += "running for \(Self.seconds(now.timeIntervalSince(job.startedAt ?? job.createdAt)))."
        case .done, .killed:
            let label = job.result?.label ?? job.state.rawValue
            message += "\(job.state.rawValue): \(label) after \(Self.seconds(job.duration ?? 0))."
        case .denied:
            message += job.result == .notRun ? "did not run: " : "denied: "
            message += "\(job.reason ?? "no reason recorded")."
        }
        guard [.running, .done, .killed].contains(job.state) else {
            return .finished(result(message, isError: false, now: now))
        }
        var all = job.output.components(separatedBy: "\n")
        if job.output.hasSuffix("\n") { all.removeLast() }
        let kept = all.suffix(lines)
        let text = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        message += "\nOutput: the last \(kept.count) lines; \(job.totalBytes) bytes in all."
        var generator = SystemRandomNumberGenerator()
        return .finished(
            ResultEnvelope.make(
                header: engine.stateHeader(now: now),
                message: message,
                untrusted: (.command, text, ResultEnvelope.makeBoundary(using: &generator))
            )
        )
    }

    private mutating func cancelJob(_ id: String, now: Date) -> Submission {
        let tool = ToolCatalogue.jobCancel.name
        let shown = DisplayText.summary(id, limit: 64)
        let decision = Decision(verdict: .allow, reason: "Claude cancels its own job", ruleID: "tool.job-cancel")
        note(tool, summary: shown, decision: decision, request: nil, now: now)
        guard let job = jobs[id] else {
            return .finished(result("No job \(shown) in this session.", isError: true, now: now))
        }
        switch job.state {
        case .waiting:
            if let index = pending.firstIndex(where: { $0.id == job.approvalID }) {
                let approval = pending.remove(at: index)
                let withdrawn = Decision(verdict: .deny, reason: "cancelled by Claude", ruleID: "job.cancelled")
                endWaitingJob(approval, withdrawn)
                record(.decision, request: approval.request, decision: withdrawn, detail: approval.id, now: now)
                addFeed(approval.tool, Self.summary(approval.request), .denied, withdrawn.ruleID, now: now)
            }
            return .finished(result("Job \(id) was waiting for approval; it is withdrawn.", isError: false, now: now))
        case .running:
            jobs[id]?.cancelRequested = true
            guard let executionID = job.executionID else {
                return .finished(result("Job \(id) is being cancelled.", isError: false, now: now))
            }
            let reply = "Job \(id) is being cancelled; its process group is killed."
            return .cancelJob(executionID: executionID, reply: result(reply, isError: false, now: now))
        case .done, .denied, .killed:
            return .finished(result("Job \(id) has already ended (\(job.state.rawValue)).", isError: false, now: now))
        }
    }

    /// The newest `limit` feed entries as the window shows them, in local time.
    private mutating func activity(limit: Int, now: Date) -> Submission {
        let rows = feed.prefix(limit).map { entry in
            [
                engine.clockTime(entry.time, seconds: true), entry.tool, entry.summary, entry.outcome.label,
                entry.result?.label ?? "-", entry.ruleID,
            ].joined(separator: " | ")
        }
        let decision = Decision(verdict: .allow, reason: "activity is read-only", ruleID: "tool.activity")
        note(ToolCatalogue.activity.name, summary: "", decision: decision, request: nil, now: now)
        var generator = SystemRandomNumberGenerator()
        return .finished(
            ResultEnvelope.make(
                header: engine.stateHeader(now: now),
                message: "The last \(rows.count) activity entries, newest first "
                    + "(time | tool | summary | decision | outcome | rule):",
                untrusted: (.activity, rows.joined(separator: "\n"), ResultEnvelope.makeBoundary(using: &generator))
            )
        )
    }

    static func tail(_ text: String) -> String {
        text.count > jobOutputLimit ? String(text.suffix(jobOutputLimit)) : text
    }

    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f s", max(0, interval))
    }

    // MARK: - Owner answers

    /// Approves a waiting request. With `alwaysAllow`, also adds an exact-argv rule for its folder; that is refused
    /// (returning `nil`, changing nothing) unless the request offers it.
    public mutating func approve(_ id: String, alwaysAllow: Bool = false, now: Date) -> Resolution? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        let approval = pending[index]
        guard !alwaysAllow || approval.canAlwaysAllow else { return nil }
        pending.remove(at: index)
        let decision = Decision(verdict: .allow, reason: "approved by the owner", ruleID: "owner.approved")
        record(.ownerApproved, request: approval.request, decision: decision, detail: id, now: now)
        addFeed(approval.tool, Self.summary(approval.request), .approved, decision.ruleID, now: now)
        if Self.isExecutable(approval.request) { executionEntries[id] = feed.first?.id }
        if let jobID = approval.jobID {
            jobs[jobID]?.state = .running
            jobs[jobID]?.executionID = id
        }
        if alwaysAllow {
            if approval.request.capability == .serial {
                addDeviceRule(for: approval.request, now: now)
            } else {
                addRule(for: approval.request, now: now)
            }
        }
        if Self.isExecutable(approval.request) {
            let execution = Execution(
                id: id,
                tool: approval.tool,
                request: approval.request,
                decision: decision,
                scope: scope,
                jobID: approval.jobID
            )
            let fallback = "Approved by the owner, but \(approval.tool) could not run."
            return Resolution(id: id, result: result(fallback, isError: true, now: now), execution: execution)
        }
        let message = "Approved by the owner. \(approval.tool) is not implemented yet."
        return Resolution(id: id, result: result(message, isError: true, now: now))
    }

    /// Denies a waiting request.
    public mutating func deny(_ id: String, now: Date) -> Resolution? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        let approval = pending.remove(at: index)
        engine.recordDenial()
        let decision = Decision(verdict: .deny, reason: "denied by the owner", ruleID: "owner.denied")
        endWaitingJob(approval, decision)
        record(.ownerDenied, request: approval.request, decision: decision, detail: id, now: now)
        addFeed(approval.tool, Self.summary(approval.request), .ownerDenied, decision.ruleID, now: now)
        return Resolution(id: id, result: result("Denied by the owner [owner.denied].", isError: true, now: now))
    }

    /// Advances time: ends an expired allow-until mode, and denies asks past their deadline.
    public mutating func tick(now: Date) -> [Resolution] {
        if case .allowUntil(let end) = engine.mode, now >= end {
            engine.setMode(.askEach)
            record(.modeChanged, detail: "allow-until expired; ask-each", now: now)
        }
        var resolutions: [Resolution] = []
        while let index = pending.firstIndex(where: { $0.deadline <= now }) {
            let approval = pending.remove(at: index)
            engine.recordTimeout()
            let decision = Decision(verdict: .deny, reason: "no answer from the owner", ruleID: "owner.timeout")
            endWaitingJob(approval, decision)
            record(.approvalTimedOut, request: approval.request, decision: decision, detail: approval.id, now: now)
            addFeed(approval.tool, Self.summary(approval.request), .timedOut, decision.ruleID, now: now)
            let waited = Self.duration(approval.deadline.timeIntervalSince(approval.askedAt))
            let message = "No answer from the owner within \(waited); denied [owner.timeout]."
            resolutions.append(Resolution(id: approval.id, result: result(message, isError: true, now: now)))
        }
        return resolutions
    }

    // MARK: - Owner controls

    /// Changes the approval mode. Ignored while stopped; Reset decides the mode then.
    public mutating func setMode(_ mode: ApprovalMode, now: Date) {
        guard !engine.isStopped else { return }
        engine.setMode(mode)
        record(.modeChanged, detail: engine.stateHeader(now: now), now: now)
    }

    /// Stop: denies everything, including every waiting request, until `resetAfterStop`.
    public mutating func stop(now: Date) -> [Resolution] {
        engine.stop()
        record(.stopped, now: now)
        ownerTypingTabs = []
        closeAllSerial("closed by Stop", now: now)
        forgetLANForwards("closed by Stop", now: now)
        return denyAllPending(now: now)
    }

    /// Ends a Stop; the mode is ask-each again.
    public mutating func resetAfterStop(now: Date) {
        guard engine.isStopped else { return }
        engine.resetAfterStop()
        record(.reset, detail: engine.stateHeader(now: now), now: now)
    }

    /// The owner starts or stops typing in a tab of the shared terminal (D12c). The tab's keystrokes are the owner's
    /// until then; Claude may still read it and use the other tab.
    public mutating func setOwnerTyping(in tab: TerminalTab, _ typing: Bool, now: Date) {
        guard ownerTypingTabs.contains(tab) != typing else { return }
        if typing {
            ownerTypingTabs.insert(tab)
        } else {
            ownerTypingTabs.remove(tab)
        }
        record(
            .baton,
            detail: typing ? "owner types in the \(tab.rawValue) tab" : "owner handed the \(tab.rawValue) tab back",
            now: now
        )
    }

    /// Why Claude may not type into the tab `request` names, or `nil`.
    private func tabDenial(_ request: ActionRequest) -> Decision? {
        guard request.capability == .terminal, ownerTypingTabs.contains(request.tab ?? .agent) else { return nil }
        return Decision(
            verdict: .deny,
            reason: "the owner is typing in the \((request.tab ?? .agent).rawValue) tab",
            ruleID: "baton.tab"
        )
    }

    /// Moves the baton. Unless Claude still holds it afterwards, every waiting request is denied.
    public mutating func apply(_ event: BatonEvent, now: Date) -> [Resolution] {
        guard engine.apply(event) else { return [] }
        record(.baton, detail: engine.stateHeader(now: now), now: now)
        return engine.baton == .claude ? [] : denyAllPending(now: now)
    }

    /// Changes the session folder. Everything waiting was asked for the old one, so it is denied.
    public mutating func setScope(_ scope: SessionScope?, now: Date) -> [Resolution] {
        guard scope != self.scope else { return [] }
        self.scope = scope
        sandboxProblem = Self.sandboxNotChecked
        ownerTypingTabs = []
        branchStates = [:]
        record(.scopeChanged, detail: scope.map { DisplayText.escaped($0.root) } ?? "none", now: now)
        closeAllSerial("closed: the session folder changed", now: now)
        forgetLANForwards("closed: the session folder changed", now: now)
        let decision = Decision(verdict: .deny, reason: "the session folder changed", ruleID: "scope.changed")
        return denyAllPending(now: now, because: decision)
    }

    /// Records the sandbox self-test for the current session folder: `nil` if it passed. A failure denies everything
    /// waiting.
    public mutating func setSandboxProblem(_ problem: String?, now: Date) -> [Resolution] {
        sandboxProblem = problem
        record(.sandboxChecked, detail: problem.map(DisplayText.escaped) ?? "passed", now: now)
        guard let problem else { return [] }
        return denyAllPending(now: now, because: Self.sandboxDenial(problem))
    }

    /// Removes a project or device rule.
    public mutating func removeRule(_ id: String, now: Date) {
        if let index = engine.rules.firstIndex(where: { $0.id == id }) {
            let rule = engine.rules.remove(at: index)
            record(.ruleRemoved, detail: Self.describe(rule), now: now)
        } else if let index = engine.deviceRules.firstIndex(where: { $0.id == id }) {
            let rule = engine.deviceRules.remove(at: index)
            record(.ruleRemoved, detail: Self.describe(rule), now: now)
        }
    }

    /// Sets the approval timeout, clamped to `approvalTimeoutRange`. Requests already waiting keep their deadline.
    public mutating func setApprovalTimeout(_ seconds: TimeInterval, now: Date) {
        approvalTimeout = Self.clamped(seconds)
        record(.settingsChanged, detail: "approval timeout \(Int(approvalTimeout)) s", now: now)
    }

    /// Records the start of a session, e.g. the result of verifying the previous log.
    public mutating func recordSessionStart(detail: String, now: Date) {
        sessionStarted = true
        record(.sessionStarted, detail: detail, now: now)
    }

    // MARK: - Helpers

    /// Denies every waiting request, for `decision` or else for what the engine says now (Stop, baton).
    private mutating func denyAllPending(now: Date, because decision: Decision? = nil) -> [Resolution] {
        let waiting = pending
        pending = []
        return waiting.map { approval in
            engine.recordDenial()
            let decision = decision ?? engine.decide(approval.request, now: now)
            endWaitingJob(approval, decision)
            record(.decision, request: approval.request, decision: decision, detail: approval.id, now: now)
            addFeed(approval.tool, Self.summary(approval.request), .denied, decision.ruleID, now: now)
            return Resolution(id: approval.id, result: result(Self.denial(decision), isError: true, now: now))
        }
    }

    private mutating func addRule(for request: ActionRequest, now: Date) {
        guard let folder = ToolRouter.normalizedFolder(request.cwd) else { return }
        let digest = SHA256.hash(data: Data(([folder] + request.argv).joined(separator: "\0").utf8))
        let id = "p" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let rule = AllowRule(
            id: id,
            projectID: request.projectID,
            folder: folder,
            argv: request.argv
        )
        guard !engine.rules.contains(where: { $0.id == rule.id }) else { return }
        engine.rules.append(rule)
        record(.ruleAdded, detail: Self.describe(rule), now: now)
    }

    /// A rule for the request's device in the session folder. Only offered when the device can be told apart; one
    /// that needs its USB port gets a rule of its own per port.
    private mutating func addDeviceRule(for request: ActionRequest, now: Date) {
        guard let device = request.device, device.canBeRemembered, let serialNumber = device.serialNumber else {
            return
        }
        var key = [request.cwd, String(device.vendorID), String(device.productID), serialNumber]
        if device.needsLocation, let locationID = device.locationID { key.append(String(locationID)) }
        let digest = SHA256.hash(data: Data(key.joined(separator: "\0").utf8))
        let rule = DeviceRule(
            id: "d" + digest.prefix(6).map { String(format: "%02x", $0) }.joined(),
            folder: request.cwd,
            device: device
        )
        guard !engine.deviceRules.contains(where: { $0.id == rule.id }) else { return }
        engine.deviceRules.append(rule)
        record(.ruleAdded, detail: Self.describe(rule), now: now)
    }

    /// Shows how `execution` ended on the feed line that allowed or approved it.
    private mutating func setResult(_ result: RunResult, for execution: Execution) {
        guard let entryID = executionEntries.removeValue(forKey: execution.id),
            let index = feed.firstIndex(where: { $0.id == entryID })
        else { return }
        feed[index].result = result
    }

    private mutating func note(
        _ tool: String,
        summary: String,
        decision: Decision,
        request: ActionRequest?,
        detail: String? = nil,
        now: Date
    ) {
        record(.decision, request: request, decision: decision, detail: detail ?? tool, now: now)
        let outcome: FeedOutcome
        switch decision.verdict {
        case .allow: outcome = .allowed
        case .ask: outcome = .asked
        case .deny: outcome = .denied
        }
        addFeed(tool, summary, outcome, decision.ruleID, now: now)
    }

    private mutating func addFeed(_ tool: String, _ summary: String, _ outcome: FeedOutcome, _ rule: String, now: Date)
    {
        feed.insert(
            FeedEntry(id: nextFeedID, time: now, tool: tool, summary: summary, outcome: outcome, ruleID: rule),
            at: 0
        )
        nextFeedID += 1
        if feed.count > Self.feedLimit { feed.removeLast(feed.count - Self.feedLimit) }
    }

    /// Appends to the audit chain. If an entry cannot be encoded, fails closed: Stop.
    private mutating func record(
        _ event: AuditEvent,
        request: ActionRequest? = nil,
        decision: Decision? = nil,
        detail: String? = nil,
        now: Date
    ) {
        do {
            auditOutbox.append(try audit.append(event, request: request, decision: decision, detail: detail, at: now))
        } catch {
            engine.stop()
        }
    }

    private func result(_ message: String, isError: Bool, now: Date) -> ToolResult {
        ResultEnvelope.make(header: engine.stateHeader(now: now), message: message, isError: isError)
    }

    static func denial(_ decision: Decision) -> String {
        "Denied: \(decision.reason) [\(decision.ruleID)]."
    }

    static func summary(_ request: ActionRequest) -> String {
        let limit = 120
        let text: String
        switch request.capability {
        case .command: text = DisplayText.argv(request.argv)
        case .serial: text = SerialOperation(argv: request.argv)?.summary ?? DisplayText.argv(request.argv)
        case .file: text = FileRequest(argv: request.argv)?.summary ?? DisplayText.argv(request.argv)
        case .network:
            text =
                LANEndpoint(argv: request.argv).map { "reach \($0) — " + DisplayText.escaped(request.argv[3]) }
                ?? DisplayText.argv(request.argv)
        default: text = DisplayText.escaped(request.argv.joined())
        }
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    static func describe(_ rule: AllowRule) -> String {
        "rule \(rule.id): exactly \(DisplayText.argv(rule.argv)) in "
            + DisplayText.escaped(rule.folder)
    }

    static func describe(_ rule: DeviceRule) -> String {
        "rule \(rule.id): serial device \(rule.label) in \(DisplayText.escaped(rule.folder))"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole % 60 == 0 { return whole == 60 ? "1 minute" : "\(whole / 60) minutes" }
        return "\(whole) seconds"
    }

    static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        guard !seconds.isNaN else { return 600 }
        return min(max(seconds, approvalTimeoutRange.lowerBound), approvalTimeoutRange.upperBound)
    }
}
