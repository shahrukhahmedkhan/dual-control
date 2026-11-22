import AppKit
import DualControlCore
import DualControlIPC
import DualControlNetwork
import DualControlSandbox
import DualControlSerial
import DualControlStore
import Foundation
import Observation
import UserNotifications

/// The approval modes offered in the window.
enum ModeChoice: String, CaseIterable, Identifiable {
    case askEach = "Ask each"
    case allowOneHour = "Allow 1 h"
    case allowTwoHours = "Allow 2 h"
    case allowWhileOpen = "Allow while open"

    var id: Self { self }
}

/// Connects the socket, the supervisor, the audit files, settings and notifications. All decisions are made by
/// `Supervisor`; this class only delivers its results, persists its audit lines and drives the clock.
@MainActor
@Observable
final class AppModel {
    private(set) var supervisor: Supervisor
    /// The clock the window shows; advanced every second.
    private(set) var now = Date()
    private(set) var serverError: String?
    /// The previous session's log failed verification.
    private(set) var auditWarning: String?
    /// This session cannot write its audit log; the app stays stopped.
    private(set) var auditError: String?
    private(set) var lastAllowChoice = ModeChoice.allowOneHour
    /// The resolved ceiling, or `nil` if it does not exist; then no session folder can be chosen.
    let ceiling = DeveloperCeiling.resolve()
    /// Why the last chosen session folder was refused.
    private(set) var scopeError: String?
    /// The admin steps, or `nil` if the owner's account cannot be put into commands safely.
    let setupGuide = DeveloperCeiling.setupGuide()
    /// The last "Check setup" results.
    private(set) var setupItems: [SetupCheck.Item] = []
    private(set) var isCheckingSetup = false
    /// The shared terminal, once the sandbox self-test passed for the session folder.
    private(set) var terminal: TerminalSession?
    /// Why the shared terminal could not start.
    private(set) var terminalError: String?
    /// The program running in the second tab, as tmux last said (D12c).
    private(set) var secondTabCommand: String?
    /// When the second tab was last asked, while Claude Code runs there.
    @ObservationIgnored private var lastSecondTabCheck = Date.distantPast
    /// The agent's own Darwin temp and cache folders, found after the self-test passed; writable in CHANGING so the
    /// /usr/bin developer stubs can keep xcrun's cache.
    @ObservationIgnored private var agentSystemFolders: [String] = []
    /// True while the owner's own pane is open (after Take over).
    private(set) var ownerPaneOpen = false
    /// Set on Hand back; the owner's pane types `SharedTerminal.handBackText` and closes.
    private(set) var handingBack = false
    /// Shell-hook files in the session folder, for the takeover card and the owner's pane; `nil` until scanned.
    private(set) var hookFiles: ShellHookFiles.Found?
    /// Agent processes still alive after the last Stop, quit sweep or launch sweep; `nil` when none survived.
    private(set) var agentSurvivors: String?

    @ObservationIgnored private var settings = SettingsStore()
    @ObservationIgnored private var store: AuditStore?
    @ObservationIgnored private var server: IPCServer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var waiters: [String: CheckedContinuation<ToolResult, Never>] = [:]
    /// The callers of waiting requests, to notice when one leaves.
    @ObservationIgnored private var callers: [String: IPCCaller] = [:]
    /// Commands running now, by execution id, with their callers (none for a background job) and job ids.
    @ObservationIgnored private var running: [String: (command: RunningCommand, caller: IPCCaller?, jobID: String?)] =
        [:]
    @ObservationIgnored private var askedForNotifications = false
    /// Open serial ports, by session id. Only ports of sessions the supervisor still has stay open.
    @ObservationIgnored private var serialPorts: [String: SerialConnection] = [:]
    /// Forwarders for the LAN endpoints the owner approved this session (D7b).
    @ObservationIgnored private var lanForwarders: [LANForwarder] = []
    /// The gatekeeper proxy, the agent's only way out; `nil` while stopped or if it could not start, and then agent
    /// processes have no network at all.
    @ObservationIgnored private var proxy: GatekeeperProxy?
    /// Where the proxy listens, for the window; `nil` when there is none.
    private(set) var proxyEndpoint: ProxyEndpoint?
    /// Why the proxy could not start.
    private(set) var proxyError: String?
    /// True while the owner's Claude Code install downloads and is checked.
    private(set) var isInstallingClaudeCode = false
    /// How the last Claude Code install or owner start went.
    private(set) var claudeCodeMessage: String?
    /// The model relay (D11): Claude Code inside reaches Anthropic's API only through it; runs with the proxy.
    @ObservationIgnored private var relay: ModelRelayServer?
    /// Where the relay listens; `nil` when there is none.
    private(set) var relayEndpoint: ModelRelayEndpoint?
    /// True if the owner saved an API key for the relay.
    private(set) var hasModelKey = false
    /// The key, read from the keychain once and handed to the relay's threads.
    @ObservationIgnored private let modelKey = ModelKeyBox()
    /// The model relay's monthly budget and spend (D12e), shared with the relay's threads.
    @ObservationIgnored private let budgetBox = RelayBudgetBox(
        RelayBudget(limit: nil, month: RelayBudget.monthKey(Date()))
    )
    /// The same, for the window.
    private(set) var relayBudget = RelayBudget(limit: nil, month: RelayBudget.monthKey(Date()))
    /// The review the owner is looking at (D11 phase 3), and the queued branch it is for.
    private(set) var review: OwnerPush.Review?
    private(set) var reviewItemID: Int?
    /// True while a review is prepared or a push runs.
    private(set) var isReviewBusy = false
    /// How the last review or push went.
    private(set) var reviewMessage: String?
    /// The repositories in the session folder (its top folder and the folders directly in it), for their auto-push
    /// and cap settings (D12b).
    private(set) var repositories: [String] = []
    /// The session folder restored at launch (D13b) while the owner has not chosen a mode or folder since: the window
    /// offers "Resume: <folder>, Allow while open".
    private(set) var resumeOffer: String?
    /// When the open agent branches of auto-pushed repositories were last counted.
    @ObservationIgnored private var lastBranchRefresh = Date.distantPast

    init() {
        let start = Date()
        // No session folder until the owner chooses one, so no command runs before that. No call is decided before
        // the audit log is open: the launch sweep below can spin the main run loop, which lets a call in early.
        supervisor = Supervisor(
            rules: settings.rules,
            deviceRules: settings.deviceRules,
            allowedHosts: settings.allowedHosts,
            approvalTimeout: settings.approvalTimeout,
            waitsForSessionStart: true,
            resolvePath: RealPath.resolve,
            lookUpPort: SerialPortList.lookUp
        )
        supervisor.restoreRepositoryPolicies(settings.repositoryPolicies)
        // Claim the socket first: it is the single-instance lock. Calls cannot be handled before init returns
        // (they run on the main actor), so none is answered before the audit log is open.
        do {
            let server = IPCServer(directory: try RunDirectory.prepare(RunDirectory.defaultPath)) {
                [weak self] request, caller in
                await self?.handle(request, caller: caller) ?? ToolResult.appNotRunning
            }
            try server.start()
            self.server = server
        } catch IPCError.alreadyRunning {
            // Leave the audit files to the running instance.
            DispatchQueue.main.async { Self.handOverToRunningInstance() }
            return
        } catch {
            serverError = "Could not start the local socket: \(error)"
        }
        // This is the only instance. If the last one crashed or was killed, the agent's processes may still run:
        // end them before anything else.
        let leftovers = Self.endAgentProcessesNow()
        do {
            let store = try AuditStore(base: AuditStore.defaultBase, sessionStart: start)
            self.store = store
            switch store.previous {
            case .none:
                supervisor.recordSessionStart(detail: "no previous session", now: start)
            case .verified(let file, let entries):
                supervisor.recordSessionStart(detail: "previous log \(file) verified, \(entries) entries", now: start)
            case .broken(let reason):
                auditWarning = reason
                supervisor.recordSessionStart(detail: "previous log check failed: \(reason)", now: start)
            }
        } catch {
            failClosed("Could not open the audit log: \(error)")
            // Stopped for good; calls are answered as denied, not as "still starting".
            supervisor.recordSessionStart(detail: "the audit log could not be opened", now: start)
        }
        if let leftovers {
            supervisor.recordSessionStart(detail: leftovers.detail, now: start)
            agentSurvivors = leftovers.warning
        }
        flushAudit()
        // Only with an audit log: every connection is recorded.
        modelKey.value = ModelKeyStore.load()
        hasModelKey = modelKey.value != nil
        if let saved = settings.relayBudget {
            budgetBox.value = saved
            relayBudget = saved
        }
        if store != nil {
            startProxy()
            restoreSession()
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Tool calls

    func handle(_ request: IPCRequest, caller: IPCCaller) async -> ToolResult {
        // Count the open agent branches first, so the cap and the result's note are current.
        if ["git_commit", "git_sync"].contains(request.tool),
            case .string(let folder)? = request.arguments["repository"],
            case .string(let branch)? = request.arguments["branch"], AgentBranches.isAgentBranch(branch),
            let repository = RealPath.resolve(folder), supervisor.scope?.contains(repository) == true
        {
            await refreshAgentBranches(repository)
        }
        // status shows each repository's branch as it is now (D13c).
        if request.tool == "status" { await refreshBranchStates(repositories) }
        let submission = supervisor.submit(request, now: Date())
        flushAudit()
        switch submission {
        case .finished(let result):
            return result
        case .pending(let id):
            callers[id] = caller
            notify(about: id)
            return await withCheckedContinuation { waiters[id] = $0 }
        case .execute(let execution):
            return await run(execution, caller: caller)
        case .jobStarted(let execution, let reply):
            runJob(execution)
            return reply
        case .jobWaiting(let id, let reply):
            notify(about: id)
            return reply
        case .cancelJob(let executionID, let reply):
            if let command = running[executionID]?.command { Task.detached { command.kill() } }
            return reply
        case .closeSerial(_, let reply):
            closeOrphanedPorts()
            return reply
        }
    }

    /// Runs a background job's command with no caller to wait for it; its outcome goes to the supervisor's job.
    private func runJob(_ execution: Execution) {
        Task { _ = await run(execution, caller: nil) }
    }

    /// Runs an allowed or approved action. Fails closed: `Supervisor.begin` re-checks everything (the caller is
    /// still there, Stop, baton, session folder, sandbox, the policy decision) and nothing runs unless its
    /// "starting" entry is in the audit file.
    private func run(_ execution: Execution, caller: IPCCaller?) async -> ToolResult {
        let store = self.store
        var auditFailure: String?
        // A background job has no caller by design; everything else needs one still waiting.
        let connected = execution.jobID != nil || caller?.isConnected == true
        let attempt = supervisor.begin(execution, callerConnected: connected, now: Date()) {
            lines,
            head in
            // Only the store here: the supervisor is being changed while this runs.
            guard let store else {
                auditFailure = "the audit log is not open"
                return false
            }
            do {
                try store.append(lines, head: head)
                return true
            } catch {
                auditFailure = "\(error)"
                return false
            }
        }
        if let auditFailure, self.store != nil {
            self.store = nil
            failClosed("Could not write the audit log: \(auditFailure)")
        }
        let launch: Launch
        switch attempt {
        case .refused(let refusal):
            flushAudit()
            return refusal
        case .launch(let started):
            launch = started
        }
        let result: ToolResult
        switch execution.request.capability {
        case .command:
            result = await runCommand(launch, caller: caller)
        case .serial:
            result = await runSerial(launch, caller: caller)
        case .network:
            result = openLANEndpoint(launch)
        case .file:
            result = await runFile(launch, caller: caller)
        default:
            result = await runInTerminal(launch)
        }
        flushAudit()
        return result
    }

    /// Runs a command as the agent in its sandbox until it ends, times out, or Stop, quitting or its caller leaving
    /// kills it.
    private func runCommand(_ launch: Launch, caller: IPCCaller?) async -> ToolResult {
        let id = launch.execution.id
        let sandbox = agentSandbox(launch.scope)
        // A flasher's ESP-IDF environment is derived first, so a fresh export run is recorded as part of it.
        var idf: IDFDerivation?
        if launch.serialPort != nil {
            let derivation = await Task.detached { sandbox.idfEnvironment(for: launch) }.value
            if derivation.fresh {
                var problem: String?
                if case .failure(let failure) = derivation.result { problem = failure.description }
                supervisor.recordIDFEnvironment(launch, install: derivation.install, problem: problem, now: Date())
                flushAudit()
            }
            idf = derivation
        }
        // git_sync: the owner's git fetches the remote first and leaves a bundle the agent's script fetches from.
        var sync: OwnerPush.SyncBundle?
        let push = launch.gitSync == nil ? nil : ownerPush()
        if launch.gitSync != nil {
            guard let push else {
                return supervisor.complete(launch.execution, output: nil, failure: "git is not installed", now: Date())
            }
            let root = launch.scope.gitSync
            let repository = launch.request.cwd
            let prepared = await Task.detached { () -> Result<OwnerPush.SyncBundle, OwnerPush.Problem> in
                if let problem = OwnerPush.prepareSyncFolder(root, denyACLUser: AgentEnvironment.user) {
                    return .failure(problem)
                }
                return push.syncBundle(repository: repository, root: root)
            }.value
            switch prepared {
            case .failure(let problem):
                let failure = "the remote could not be fetched: \(problem.description)"
                return supervisor.complete(launch.execution, output: nil, failure: failure, now: Date())
            case .success(let bundle):
                sync = bundle
            }
        }
        let started: Result<RunningCommand, Error> = await Task.detached { [idf, sync] in
            Result { try sandbox.start(launch, idf: idf, sync: sync) }
        }.value
        defer {
            if let push, let sync { Task.detached { push.discard(sync) } }
        }
        switch started {
        case .failure(let error):
            return supervisor.complete(launch.execution, output: nil, failure: "\(error)", now: Date())
        case .success(let command):
            running[id] = (command, caller, launch.execution.jobID)
            // Stop, quitting or job_cancel may have come while it started.
            let cancelled = launch.execution.jobID.flatMap { supervisor.job($0)?.cancelRequested } == true
            if supervisor.engine.isStopped || cancelled { Task.detached { command.kill() } }
            // A new repository is checked (and removed if wrong) before anyone is told it is there; a finished
            // ESP-IDF install is copied into the owner's toolchain folder first.
            let (outcome, copy) = await Task.detached {
                sandbox.finishToolchain(launch, sandbox.finishGit(launch, command.wait()))
            }.value
            if launch.gitCommit, outcome.status == 0, !outcome.killed { queueCommit(launch, output: outcome.output) }
            if case .update(let branch)? = launch.gitSync, outcome.status == 0, !outcome.killed,
                let tip = GitSync.rebasedTip(outcome.output)
            {
                queueCommit(launch, output: tip, rebased: branch)
            }
            if let copy {
                supervisor.recordToolchain(
                    launch,
                    install: copy.install,
                    digest: copy.digest,
                    problem: copy.problem,
                    now: Date()
                )
                flushAudit()
            }
            running.removeValue(forKey: id)
            if let repository = repository(holding: launch.request.cwd) {
                Task { await refreshBranchStates([repository]) }
            }
            let callerLeft = caller.map { !$0.isConnected } ?? false
            return supervisor.finish(launch, outcome: outcome, callerLeft: callerLeft, now: Date())
        }
    }

    /// Runs a `write_file` or `apply_patch` as the agent: for a patch, reads the file, checks it may still run, applies
    /// the patch; then writes. Each step is killed by Stop, quitting or its caller leaving like a command.
    private func runFile(_ launch: Launch, caller: IPCCaller?) async -> ToolResult {
        let sandbox = agentSandbox(launch.scope)
        let path = FileRequest(argv: launch.request.argv)?.path ?? ""
        func step(_ command: [String]) async -> Result<CommandOutcome, FileWrite.Problem> {
            let started: Result<RunningCommand, Error> = await Task.detached {
                Result { try sandbox.startFileStep(launch, command) }
            }.value
            guard case .success(let running) = started else {
                return .failure(FileWrite.Problem(description: "it could not start"))
            }
            self.running[launch.execution.id] = (running, caller, nil)
            if supervisor.engine.isStopped { Task.detached { running.kill() } }
            let outcome = await Task.detached { running.wait() }.value
            self.running.removeValue(forKey: launch.execution.id)
            return .success(outcome)
        }
        var current: [UInt8]?
        if FileWrite.needsCurrent(launch.request) {
            switch await step(FileWrite.readArgv(path: path)).flatMap(FileWrite.readResult) {
            case .failure(let problem):
                return supervisor.finishFile(launch, .failure(problem), now: Date())
            case .success(let bytes):
                current = bytes
            }
            guard supervisor.mayExecute(launch.execution), caller.map(\.isConnected) ?? true else {
                return supervisor.finishFile(
                    launch,
                    .failure(FileWrite.Problem(description: "it is no longer allowed")),
                    now: Date()
                )
            }
        }
        let outcome: Result<FileWritten, FileWrite.Problem>
        switch FileWrite.contentToWrite(launch.request, current: current) {
        case .failure(let problem):
            outcome = .failure(problem)
        case .success(let plan):
            outcome = await step(FileWrite.writeArgv(path: path, expected: plan.expected, content: plan.content))
                .flatMap { FileWrite.writeResult($0, content: plan.content) }
        }
        return supervisor.finishFile(launch, outcome, now: Date())
    }

    private func runInTerminal(_ launch: Launch) async -> ToolResult {
        guard let terminal else {
            return supervisor.complete(
                launch.execution,
                output: nil,
                failure: "the shared terminal is not running",
                now: Date()
            )
        }
        let request = launch.request
        // Claude Code starts only from an install that still matches its hash and Anthropic's signature.
        if let version = launch.claudeCode {
            let store = ClaudeCodeStore(scope: launch.scope, denyACLUser: AgentEnvironment.user)
            if case .failure(let problem) = await Task.detached(operation: { store.verify(version: version) }).value {
                return supervisor.complete(launch.execution, output: nil, failure: problem.description, now: Date())
            }
        }
        let outcome: Result<String?, Error> = await Task.detached {
            Result {
                switch request.capability {
                case .terminalRead:
                    return try terminal.read(lines: Int(request.argv.first ?? "") ?? 100, tab: request.tab ?? .agent)
                default:
                    try terminal.send(request.argv.joined(), tab: request.tab ?? .agent)
                    return nil
                }
            }
        }.value
        if launch.claudeCode != nil { refreshSecondTab(after: 2) }
        switch outcome {
        case .success(let output):
            return supervisor.complete(launch.execution, output: output, failure: nil, now: Date())
        case .failure(let error):
            return supervisor.complete(launch.execution, output: nil, failure: "\(error)", now: Date())
        }
    }

    /// Runs a serial operation. The app opens ports itself, as the owner: nothing runs as the agent.
    private func runSerial(_ launch: Launch, caller: IPCCaller?) async -> ToolResult {
        let execution = launch.execution
        func failed(_ failure: String) -> ToolResult {
            supervisor.complete(execution, output: nil, failure: failure, now: Date())
        }
        guard let operation = SerialOperation(argv: launch.request.argv) else {
            return failed("not a serial operation")
        }
        if let id = operation.session, serialPorts[id] == nil { return failed("the port is closed") }
        let port = operation.session.flatMap { serialPorts[$0] }
        let outcome: Result<SerialOutcome, Error>
        switch operation {
        case .list:
            outcome = .success(.listed(await Task.detached { SerialPortList.ports() }.value))
        case .open(let path, let settings):
            let opened = await Task.detached { Result { try SerialConnection.open(path, settings: settings) } }.value
            guard case .success(let connection) = opened else {
                if case .failure(let error) = opened { return failed("\(error)") }
                return failed("the port could not be opened")
            }
            // Nobody is left to use a port opened for a caller that left.
            guard caller?.isConnected != false else {
                Task.detached { connection.close() }
                return failed("the caller left")
            }
            let reply = supervisor.finishSerial(launch, .opened, now: Date())
            if let id = reply.openedSession {
                serialPorts[id] = connection
            } else {
                Task.detached { connection.close() }
            }
            return reply.result
        case .read(_, let maxBytes, let wait, _):
            guard let port else { return failed("the port is closed") }
            let read = await Task.detached { port.read(maxBytes: maxBytes, waitMilliseconds: wait) }.value
            outcome = .success(.read(bytes: read.bytes, dropped: read.dropped, deviceGone: read.deviceGone))
        case .write(_, let bytes):
            guard let port else { return failed("the port is closed") }
            outcome = await Task.detached { Result { try port.write(bytes) }.map { SerialOutcome.wrote } }.value
        case .reset(_, let mode):
            guard let port else { return failed("the port is closed") }
            let steps = SerialReset.steps(mode, for: launch.request.device)
            outcome = await Task.detached { Result { try port.reset(steps) }.map { SerialOutcome.reset } }.value
        }
        switch outcome {
        case .success(let done):
            return supervisor.finishSerial(launch, done, now: Date()).result
        case .failure(let error):
            return failed("\(error)")
        }
    }

    /// Closes every port whose session the supervisor no longer has: closed by Claude, Stop, quitting, an audit
    /// failure or a new session folder.
    private func closeOrphanedPorts() {
        let orphans = serialPorts.filter { supervisor.serialSessions[$0.key] == nil }
        guard !orphans.isEmpty else { return }
        for id in orphans.keys { serialPorts.removeValue(forKey: id) }
        let connections = Array(orphans.values)
        Task.detached { connections.forEach { $0.close() } }
    }

    /// Kills every running command's process group.
    private func killRunningCommands() {
        let commands = running.values.map(\.command)
        Task.detached { commands.forEach { $0.kill() } }
    }

    /// The off switch: every process the agent owns ends, whoever started it (the shared terminal too). Runs off
    /// the main thread and shows a warning if any process survives.
    private func endAgentProcesses() {
        stopTerminal()
        killRunningCommands()
        Task {
            let survivors = await Task.detached { AgentProcesses.endAll() }.value
            agentSurvivors = Self.warning(survivors)
        }
    }

    /// What the launch sweep found and did, or `nil` if no agent process was running.
    struct Sweep {
        let detail: String
        let warning: String?
    }

    /// Ends leftover agent processes at once, on this thread, before the app does anything else.
    private static func endAgentProcessesNow() -> Sweep? {
        guard let entry = getpwnam(AgentEnvironment.user) else { return nil }
        let found = AgentProcesses.list(uid: entry.pointee.pw_uid)
        guard !found.isEmpty else { return nil }
        let survivors = AgentProcesses.endAll()
        return Sweep(
            detail: "ended \(found.count) leftover agent processes; \(survivors.count) survived",
            warning: warning(survivors)
        )
    }

    private static func warning(_ survivors: [AgentProcess]) -> String? {
        guard !survivors.isEmpty else { return nil }
        let names = survivors.prefix(5).map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
        return "\(survivors.count) process(es) of \(AgentEnvironment.user) are still running after being killed: "
            + "\(names). Check Activity Monitor."
    }

    // MARK: - Owner actions

    func approve(_ id: String, alwaysAllow: Bool = false) {
        deliver(supervisor.approve(id, alwaysAllow: alwaysAllow, now: Date()).map { [$0] } ?? [])
        if alwaysAllow {
            settings.rules = supervisor.rules
            settings.deviceRules = supervisor.deviceRules
        }
    }

    func deny(_ id: String) {
        deliver(supervisor.deny(id, now: Date()).map { [$0] } ?? [])
    }

    /// Stop: denies everything waiting, kills every running command and closes the network at once, then shows the
    /// session report.
    func stop() {
        deliver(supervisor.stop(now: Date()))
        stopProxy()
        stopLANForwarders()
        endAgentProcesses()
        writeReport(show: true)
    }

    /// End session: the same as Stop (everything ends, the report is written and shown); Reset starts the next one.
    func endSession() {
        stop()
    }

    // MARK: - Session report

    /// A written session report, for the window.
    struct ShownReport: Identifiable {
        let id = UUID()
        let markdown: String
        let saved: Saved

        /// Where it was saved, or why it could not be.
        enum Saved {
            case path(String)
            case failed(String)
        }
    }

    /// The report the window shows, until dismissed.
    var shownReport: ShownReport?
    /// Audit entries the last report covered; no second report is written without new entries.
    @ObservationIgnored private var reportedEntries: Int?

    /// Summarizes this session from the audit log as written so far and saves it next to the log as Markdown. Also
    /// shown if `show`. Without an open log there is nothing to read.
    private func writeReport(show: Bool) {
        guard let store else { return }
        flushAudit()
        guard reportedEntries != supervisor.auditHead.count else { return }
        var markdown = ""
        let saved: ShownReport.Saved
        do {
            let lines = try store.lines()
            var report = SessionReport.make(lines: lines)
            // Gap 3: changed files the owner's tools would run, listed first.
            if let scope = supervisor.scope {
                report.ownerRunFiles = OwnerRunFileScan.scan(
                    root: scope.root,
                    since: report.start,
                    agentUID: OwnerRunFileScan.agentUID()
                )
                // D12d: changed files that look like credentials, right after.
                report.credentialFiles = CredentialFileScan.scan(scope: scope, since: report.start)
            }
            markdown = report.markdown
            saved = .path(try store.writeReport(markdown, entries: lines.count))
            reportedEntries = supervisor.auditHead.count
        } catch {
            saved = .failed("The session report could not be written: \(error)")
        }
        if show { shownReport = ShownReport(markdown: markdown, saved: saved) }
    }

    /// Reset is refused while the audit log cannot be written.
    var canReset: Bool { supervisor.engine.isStopped && auditError == nil }

    /// Ends a Stop. Stop ended the shared terminal and the proxy, so both start again, fresh (a new proxy port and
    /// token), the terminal if the sandbox still passes.
    func reset() {
        guard canReset else { return }
        supervisor.resetAfterStop(now: Date())
        flushAudit()
        startProxy()
        if let scope = supervisor.scope, supervisor.sandboxProblem == nil { startTerminal(for: scope) }
    }

    var modeChoice: ModeChoice {
        switch supervisor.engine.mode {
        case .askEach: return .askEach
        case .allowWhileOpen: return .allowWhileOpen
        case .allowUntil(let end): return end > now ? lastAllowChoice : .askEach
        }
    }

    func choose(_ choice: ModeChoice) {
        let now = Date()
        switch choice {
        case .askEach: supervisor.setMode(.askEach, now: now)
        case .allowOneHour: supervisor.setMode(.allowUntil(now.addingTimeInterval(3600)), now: now)
        case .allowTwoHours: supervisor.setMode(.allowUntil(now.addingTimeInterval(7200)), now: now)
        case .allowWhileOpen: supervisor.setMode(.allowWhileOpen, now: now)
        }
        if choice == .allowOneHour || choice == .allowTwoHours { lastAllowChoice = choice }
        resumeOffer = nil
        flushAudit()
    }

    /// Narrows the session to `folder`, which must resolve to a subfolder of the ceiling, and remembers it for the
    /// next launch.
    func chooseSessionFolder(_ folder: String) {
        do {
            let scope = try ResolvedScope.production(choosing: folder)
            scopeError = nil
            resumeOffer = nil
            stopTerminal()
            deliver(supervisor.setScope(scope, now: Date()))
            stopLANForwarders()
            runSelfTest(for: scope)
            scanRepositories()
            settings.lastSessionFolder = scope.root
        } catch {
            scopeError = Self.describe(error)
        }
    }

    /// At launch (D13b): the last session folder again, with every check run again (scope, setup, self-test). The
    /// mode stays ask-each; the window offers the owner one click to allow while open. A folder that no longer
    /// passes is forgotten.
    private func restoreSession() {
        guard let saved = settings.lastSessionFolder else { return }
        chooseSessionFolder(saved)
        guard let root = supervisor.scope?.root else {
            settings.lastSessionFolder = nil
            return
        }
        resumeOffer = root
        checkSetup()
    }

    /// The owner accepted the resume banner: allow while open, in the restored folder.
    func resumeSession() {
        guard resumeOffer != nil, supervisor.scope?.root == resumeOffer else { return }
        choose(.allowWhileOpen)
    }

    /// The owner closed the resume banner; the mode stays as it is.
    func dismissResumeOffer() {
        resumeOffer = nil
    }

    /// Runs the sandbox self-test as the agent, off the main thread. Until it passes, nothing runs as the agent.
    func runSelfTest(for scope: SessionScope) {
        let endpoint = proxyEndpoint
        Task {
            let (result, folders) = await Task.detached {
                let sandbox = Sandbox(scope: scope, runAs: SetupGuide.runAsAgent, proxy: endpoint)
                let result = sandbox.selfTest()
                return (result, result == .passed ? sandbox.agentSystemFolders() : [])
            }.value
            guard supervisor.scope == scope else { return }
            switch result {
            case .passed:
                agentSystemFolders = folders
                deliver(supervisor.setSandboxProblem(nil, now: Date()))
                startTerminal(for: scope)
                refreshClaudeCodeVersions()
                refreshCommitIdentity()
                let found = repositories
                Task { await refreshBranchStates(found) }
            case .failed(let reason):
                deliver(supervisor.setSandboxProblem(reason, now: Date()))
                stopTerminal()
            }
        }
    }

    /// The sandbox agent processes run in for `scope`: as the agent, through the proxy, with its own Darwin folders.
    private func agentSandbox(_ scope: SessionScope) -> Sandbox {
        Sandbox(
            scope: scope,
            runAs: SetupGuide.runAsAgent,
            proxy: proxyEndpoint,
            systemFolders: agentSystemFolders,
            lanForwards: supervisor.lanForwards,
            relay: relayEndpoint
        )
    }

    /// Starts the shared terminal as the agent, sandboxed, in the session folder.
    private func startTerminal(for scope: SessionScope) {
        stopTerminal()
        let session = TerminalSession(sandbox: agentSandbox(scope))
        Task {
            let started = await Task.detached { Result { try session.start() } }.value
            guard supervisor.scope == scope, supervisor.sandboxProblem == nil else {
                session.stop()
                return
            }
            switch started {
            case .success:
                terminal = session
                terminalError = nil
            case .failure(let error):
                terminalError = "The shared terminal could not start: \(error)"
            }
        }
    }

    private func stopTerminal() {
        guard let terminal else { return }
        self.terminal = nil
        secondTabCommand = nil
        Task.detached { terminal.stop() }
    }

    // MARK: - Review and push (D11 phase 3)

    /// The owner's push, with the real git and scratch space in the app's own folder.
    private func ownerPush() -> OwnerPush? {
        let folder = AuditStore.defaultBase + "/review"
        try? FileManager.default.createDirectory(
            atPath: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let git = Toolchain.git() else { return nil }
        return OwnerPush(git: git, scratch: folder, mapFile: folder + "/signed-commits.json")
    }

    /// Reads the owner's git identity for `git_commit`.
    func refreshCommitIdentity() {
        guard let push = ownerPush() else { return }
        Task {
            if let identity = await Task.detached(operation: { push.identity() }).value {
                supervisor.setCommitIdentity(name: identity.name, email: identity.email)
            }
        }
    }

    /// A `git_commit` ended well, or a `git_sync update` rebased the branch `rebased`: its branch goes to the review
    /// queue. The branch is read from `.git/HEAD` as text and the commit from the output, both checked; nothing in
    /// the repository runs.
    private func queueCommit(_ launch: Launch, output: String, rebased: String? = nil) {
        let repository = launch.request.cwd
        guard let head = try? String(contentsOfFile: repository + "/.git/HEAD", encoding: .utf8),
            let branch = GitReview.branch(fromHEAD: head), rebased == nil || rebased == branch,
            let commit = output.split(separator: "\n").last.map(String.init), GitReview.isObjectName(commit)
        else { return }
        supervisor.queueForReview(
            repository: repository,
            branch: branch,
            commit: commit,
            rebased: rebased != nil,
            now: Date()
        )
        flushAudit()
        if !repositories.contains(repository) { scanRepositories() }
        if supervisor.policy(for: repository).autoPush, AgentBranches.isAgentBranch(branch) {
            autoPush(repository: repository, branch: branch)
        }
    }

    /// Prepares the review of a queued branch: as the owner, never inside the agent's repository.
    func openReview(_ id: Int) {
        guard !isReviewBusy, let item = supervisor.reviewQueue.first(where: { $0.id == id }), let push = ownerPush()
        else { return }
        discardReview()
        isReviewBusy = true
        reviewMessage = "Preparing the review of \(item.branch)…"
        Task {
            let result = await Task.detached {
                push.review(repository: item.repository, branch: item.branch)
            }.value
            isReviewBusy = false
            switch result {
            case .success(let prepared):
                review = prepared
                reviewItemID = id
                reviewMessage = nil
            case .failure(let problem):
                reviewMessage = "\(item.branch): \(problem.description)"
            }
        }
    }

    /// The owner clicked Push: re-sign and push the reviewed commits, as the owner.
    func pushReview() {
        guard let review, let id = reviewItemID, let push = ownerPush(), !isReviewBusy else { return }
        isReviewBusy = true
        let lease = supervisor.reviewQueue.first(where: { $0.id == id })?.rebased == true
        Task {
            let result = await Task.detached { push.push(review, lease: lease) }.value
            isReviewBusy = false
            self.review = nil
            reviewItemID = nil
            switch result {
            case .success(let tip):
                supervisor.recordPush(
                    id,
                    remote: review.remote,
                    commits: review.commits.count,
                    signedTip: tip,
                    problem: nil,
                    now: Date()
                )
                reviewMessage = "Pushed \(review.branch) (\(review.commits.count) commits, signed)."
            case .failure(let problem):
                supervisor.recordPush(
                    id,
                    remote: review.remote,
                    commits: 0,
                    signedTip: nil,
                    problem: problem.description,
                    now: Date()
                )
                reviewMessage = "\(review.branch) was not pushed: \(problem.description)"
            }
            flushAudit()
        }
    }

    /// Closes the review without pushing.
    func discardReview() {
        if let review, let push = ownerPush() { Task.detached { push.discard(review) } }
        review = nil
        reviewItemID = nil
    }

    // MARK: - Agent branches (D12b)

    /// Finds the repositories in the session folder: its top folder and the folders directly in it with a `.git`
    /// folder (not a link), read as the owner without running anything there.
    func scanRepositories() {
        guard let root = supervisor.scope?.root else {
            repositories = []
            return
        }
        func isRepository(_ path: String) -> Bool {
            let type = (try? FileManager.default.attributesOfItem(atPath: path + "/.git"))?[.type] as? FileAttributeType
            return RealPath.resolve(path) == path && type == .typeDirectory
        }
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter {
            !$0.hasPrefix(".")
        }
        repositories = ([root] + children.sorted().map { root + "/" + $0 }).filter(isRepository)
        for repository in repositories { Task { await refreshAgentBranches(repository) } }
        let found = repositories
        Task { await refreshBranchStates(found) }
    }

    /// Reads where each of `repositories` stands (D13c), as the agent in READ-ONLY; the owner's git never runs there.
    /// Not before the sandbox self-test passed.
    private func refreshBranchStates(_ repositories: [String]) async {
        guard let scope = supervisor.scope, supervisor.sandboxProblem == nil, !repositories.isEmpty else { return }
        let sandbox = agentSandbox(scope)
        let states = await Task.detached {
            repositories.map { ($0, sandbox.branchState(in: $0)) }
        }.value
        guard supervisor.scope == scope else { return }
        for (repository, state) in states { supervisor.setBranchState(state, for: repository) }
    }

    /// The repository of the session a command ran in, if any: the deepest one that holds `folder`.
    private func repository(holding folder: String) -> String? {
        repositories.filter { folder == $0 || folder.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    /// The owner changed a repository's auto-push or cap; one click turns auto-push off.
    func setRepositoryPolicy(_ policy: RepositoryPolicy, for repository: String) {
        supervisor.setRepositoryPolicy(policy, for: repository, now: Date())
        settings.repositoryPolicies = supervisor.repositoryPolicies
        flushAudit()
        Task { await refreshAgentBranches(repository) }
    }

    /// Counts the agent branches open on `repository`'s remote, as the owner: on the remote, and without a pull
    /// request or with an open one (`gh`, when it is installed and the remote is on GitHub). With auto-push on, a
    /// branch whose pull request was merged is deleted on the remote and, as the agent, in the repository. A remote
    /// that cannot be reached leaves the last count.
    private func refreshAgentBranches(_ repository: String) async {
        guard let push = ownerPush() else { return }
        let gh = GitHubCLI.find().map { GitHubCLI(gh: $0, folder: AuditStore.defaultBase + "/review") }
        let found: (remote: String, open: [String], merged: [String])? = await Task.detached {
            guard case .success(let remote) = push.origin(of: repository),
                case .success(let branches) = push.agentBranches(on: remote)
            else { return nil }
            guard let gh, let slug = AgentBranches.gitHubSlug(remote: remote, resolveHost: GitHubCLI.resolveSSHHost)
            else { return (remote, branches, []) }
            var open: [String] = []
            var merged: [String] = []
            for branch in branches {
                let state = try? gh.state(slug: slug, branch: branch).get()
                if state == nil || AgentBranches.countsAsOpen(state ?? nil) { open.append(branch) }
                if state == .merged { merged.append(branch) }
            }
            return (remote, open, merged)
        }.value
        guard let found else { return }
        supervisor.setOpenAgentBranches(found.open, for: repository)
        guard supervisor.policy(for: repository).autoPush, !supervisor.engine.isStopped,
            let scope = supervisor.scope, scope.contains(repository)
        else { return }
        let sandbox = agentSandbox(scope)
        for branch in found.merged {
            let remote = found.remote
            let problem: String? = await Task.detached {
                if let failure = push.deleteAgentBranch(branch, on: remote) { return failure.description }
                return sandbox.deleteAgentBranch(branch, in: repository)
                    ? nil : "deleted on the remote; the repository's branch was not deleted"
            }.value
            supervisor.recordBranchCleanup(repository: repository, branch: branch, problem: problem, now: Date())
        }
        flushAudit()
    }

    /// With auto-push on: reviews and pushes `branch` as the owner, like Push as me, then opens its pull request.
    private func autoPush(repository: String, branch: String) {
        guard let push = ownerPush(), !supervisor.engine.isStopped, !isReviewBusy,
            let item = supervisor.reviewQueue.first(where: { $0.repository == repository && $0.branch == branch })
        else { return }
        isReviewBusy = true
        reviewMessage = "Pushing \(branch) automatically…"
        let gh = GitHubCLI.find().map { GitHubCLI(gh: $0, folder: AuditStore.defaultBase + "/review") }
        Task {
            defer { isReviewBusy = false }
            let review: OwnerPush.Review
            switch await Task.detached(operation: { push.review(repository: repository, branch: branch) }).value {
            case .failure(let problem):
                reviewMessage = "\(branch) was not pushed automatically: \(problem.description)"
                return
            case .success(let prepared):
                review = prepared
            }
            // Turned off, or Stop, while it was prepared: it stays in the queue for the owner.
            guard supervisor.policy(for: repository).autoPush, !supervisor.engine.isStopped else {
                push.discard(review)
                reviewMessage = nil
                return
            }
            let lease = item.rebased
            let result = await Task.detached { push.push(review, lease: lease) }.value
            switch result {
            case .success(let tip):
                supervisor.recordPush(
                    item.id,
                    remote: review.remote,
                    commits: review.commits.count,
                    signedTip: tip,
                    problem: nil,
                    automatic: true,
                    now: Date()
                )
                reviewMessage = "Pushed \(branch) automatically (\(review.commits.count) commits, signed)."
                flushAudit()
                await openPullRequest(for: review, gh: gh)
            case .failure(let problem):
                supervisor.recordPush(
                    item.id,
                    remote: review.remote,
                    commits: 0,
                    signedTip: nil,
                    problem: problem.description,
                    automatic: true,
                    now: Date()
                )
                reviewMessage = "\(branch) was not pushed automatically: \(problem.description)"
            }
            flushAudit()
            await refreshAgentBranches(repository)
        }
    }

    /// Opens (or finds) the pull request for an auto-pushed branch with the owner's `gh`; never merges.
    private func openPullRequest(for review: OwnerPush.Review, gh: GitHubCLI?) async {
        let remote = review.remote
        let slug = await Task.detached {
            AgentBranches.gitHubSlug(remote: remote, resolveHost: GitHubCLI.resolveSSHHost)
        }.value
        var problem: String?
        var url: String?
        if gh == nil {
            problem = "gh is not installed"
        } else if slug == nil {
            problem = "the remote is not on github.com"
        } else if review.defaultBranch == nil {
            problem = "the remote names no default branch"
        }
        if problem == nil, let gh, let slug, let base = review.defaultBranch {
            let title = AgentBranches.pullRequestTitle(review.tipMessage)
            let body = AgentBranches.pullRequestBody(review.tipMessage, branch: review.branch)
            let branch = review.branch
            switch await Task.detached(operation: {
                gh.openPullRequest(slug: slug, branch: branch, base: base, title: title, body: body)
            }).value {
            case .success(let opened): url = opened
            case .failure(let failure): problem = failure.description
            }
        }
        supervisor.recordPullRequest(
            repository: review.repository,
            branch: review.branch,
            url: url,
            problem: problem,
            now: Date()
        )
        reviewMessage =
            (reviewMessage ?? "") + (url.map { " Pull request: \($0)" } ?? " No pull request: \(problem ?? "")")
    }

    /// The owner drops a queued branch without pushing.
    func dismissReviewItem(_ id: Int) {
        supervisor.removeFromReview(id, now: Date())
        flushAudit()
    }

    // MARK: - Claude Code (D11)

    /// Tells the supervisor which Claude Code versions are installed in the owner's toolchain folder.
    func refreshClaudeCodeVersions() {
        guard let scope = supervisor.scope else { return }
        supervisor.setClaudeCodeVersions(ClaudeCodeStore(scope: scope, denyACLUser: nil).versions())
    }

    /// The owner installs Claude Code `version`: downloaded as the owner, checked against the release manifest and
    /// Anthropic's signature, locked into the toolchain folder. Recorded either way.
    func installClaudeCode(version: String) {
        guard let scope = supervisor.scope, !isInstallingClaudeCode else { return }
        let version = version.trimmingCharacters(in: .whitespaces)
        if let problem = ClaudeCode.versionProblem(version) {
            claudeCodeMessage = problem
            return
        }
        isInstallingClaudeCode = true
        claudeCodeMessage = "Downloading Claude Code \(version)…"
        Task {
            let result: Result<String, ClaudeCodeStore.Problem> = await Task.detached {
                switch await ClaudeCodeDownload.fetch(version: version, into: NSTemporaryDirectory()) {
                case .failure(let problem):
                    return .failure(ClaudeCodeStore.Problem(description: problem.description))
                case .success(let downloaded):
                    let store = ClaudeCodeStore(scope: scope, denyACLUser: AgentEnvironment.user)
                    return store.install(version: version, from: downloaded.file, sha256: downloaded.sha256)
                }
            }.value
            isInstallingClaudeCode = false
            let install = ClaudeCode.install(version: version, scope: scope)
            switch result {
            case .success(let digest):
                supervisor.recordClaudeCodeInstall(
                    version: version,
                    install: install,
                    digest: digest,
                    problem: nil,
                    now: Date()
                )
                claudeCodeMessage = "Claude Code \(version) installed, checked and locked."
            case .failure(let problem):
                supervisor.recordClaudeCodeInstall(
                    version: version,
                    install: install,
                    digest: nil,
                    problem: problem.description,
                    now: Date()
                )
                claudeCodeMessage = "Claude Code \(version) was not installed: \(problem.description)"
            }
            flushAudit()
            refreshClaudeCodeVersions()
        }
    }

    /// The owner starts the newest Claude Code in the shared terminal: the same fixed line `claude_code_start`
    /// types, after the same checks.
    func startClaudeCode() {
        guard let scope = supervisor.scope, let terminal, !supervisor.ownerTypingTabs.contains(.second),
            let version = ClaudeCode.newest(supervisor.claudeCodeVersions),
            let line = ClaudeCode.launchLine(version: version, scope: scope)
        else { return }
        Task {
            let store = ClaudeCodeStore(scope: scope, denyACLUser: AgentEnvironment.user)
            let outcome: Result<Void, Error> = await Task.detached {
                Result {
                    if case .failure(let problem) = store.verify(version: version) { throw problem }
                    try terminal.send(line, tab: .second)
                }
            }.value
            switch outcome {
            case .success:
                supervisor.recordOwnerClaudeCodeStart(version: version, now: Date())
                flushAudit()
                claudeCodeMessage = nil
                refreshSecondTab(after: 2)
            case .failure(let error):
                claudeCodeMessage = "Claude Code did not start: \(error)"
            }
        }
    }

    // MARK: - Terminal tabs (D12c)

    /// The owner starts or stops typing in a tab of the agent's terminal; Claude cannot type there meanwhile.
    func setOwnerTyping(in tab: TerminalTab, _ typing: Bool) {
        supervisor.setOwnerTyping(in: tab, typing, now: Date())
        flushAudit()
    }

    /// Asks tmux what runs in the second tab, so its name says "Claude Code" while it runs. Only now and then: each
    /// question is a sudo call as the agent.
    func refreshSecondTab(after seconds: Double = 0) {
        guard let terminal else {
            secondTabCommand = nil
            return
        }
        Task {
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            secondTabCommand = await Task.detached { terminal.currentCommand(tab: .second) }.value
        }
    }

    // MARK: - Baton

    /// Take over: Claude's input is locked and the owner's own pane opens (as the owner, not sandboxed).
    func takeOver() {
        let before = supervisor.engine.baton
        deliver(supervisor.apply(.ownerTakesOver, now: Date()))
        if supervisor.engine.baton == .owner, before != .owner {
            ownerPaneOpen = true
            handingBack = false
            scanHookFiles()
        }
    }

    /// Looks for files in the session folder that the owner's shell hooks would act on, off the main thread. On the
    /// takeover card and when the owner's pane opens: the agent may have written them since the last look.
    func scanHookFiles() {
        guard let root = supervisor.scope?.root else {
            hookFiles = nil
            return
        }
        Task { hookFiles = await Task.detached { ShellHookFiles.find(in: root) }.value }
    }

    /// Hand back: the owner's pane forgets cached sudo credentials and closes, then Claude gets the baton. If the
    /// pane is already closed, the baton moves at once.
    func handBack() {
        guard supervisor.engine.baton == .owner else { return }
        if ownerPaneOpen {
            handingBack = true
            // If the pane does not close (a program ignores the text), it is closed after a few seconds.
            Task {
                try? await Task.sleep(for: .seconds(3))
                if handingBack { ownerPaneClosed() }
            }
        } else {
            deliver(supervisor.apply(.ownerHandsBack, now: Date()))
        }
    }

    /// Called when the owner's pane process ends.
    func ownerPaneClosed() {
        ownerPaneOpen = false
        if handingBack {
            handingBack = false
            deliver(supervisor.apply(.ownerHandsBack, now: Date()))
        }
    }

    func declineTakeover() {
        deliver(supervisor.apply(.ownerDeclinesTakeover, now: Date()))
    }

    /// Checks every setup item, then refreshes the self-test for the current session folder.
    func checkSetup() {
        guard !isCheckingSetup else { return }
        isCheckingSetup = true
        let scope = supervisor.scope
        Task {
            setupItems = await Task.detached { SetupCheck().run(scope: scope) }.value
            isCheckingSetup = false
            if let scope { runSelfTest(for: scope) }
        }
    }

    private static func describe(_ error: ResolvedScope.Error) -> String {
        switch error {
        case .noCeiling: return "The Developer folder in your home folder does not exist."
        case .missing: return "That folder does not exist."
        case .refused(.insideWorkArea): return "That folder is the agent's own work area."
        case .refused(.protected): return "That folder holds Dual Control itself, which the agent may never change."
        case .refused: return "Choose a folder inside your Developer folder (not the Developer folder itself)."
        }
    }

    func removeRule(_ id: String) {
        supervisor.removeRule(id, now: Date())
        settings.rules = supervisor.rules
        settings.deviceRules = supervisor.deviceRules
        flushAudit()
    }

    func setApprovalTimeout(_ seconds: TimeInterval) {
        supervisor.setApprovalTimeout(seconds, now: Date())
        settings.approvalTimeout = supervisor.approvalTimeout
        flushAudit()
    }

    // MARK: - Network

    /// Starts a fresh gatekeeper proxy (new port and token) deciding with the supervisor's policy. Its reports
    /// reach the supervisor on the main queue, in the order each connection made them. If it cannot start, agent
    /// processes get no network at all.
    private func startProxy() {
        stopProxy()
        let proxy = GatekeeperProxy(
            policy: supervisor.network,
            onAttempt: { [weak self] attempt in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.supervisor.recordNetworkAttempt(attempt, now: Date())
                        self?.flushAudit()
                    }
                }
            },
            onClosed: { [weak self] transfer in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.supervisor.recordNetworkClosed(transfer, now: Date())
                        self?.flushAudit()
                    }
                }
            }
        )
        do {
            proxyEndpoint = try proxy.start()
            self.proxy = proxy
            proxyError = nil
        } catch {
            proxyError = "The network gatekeeper could not start (\(error)); agent processes have no network."
        }
        startRelay()
    }

    /// Closes the proxy and every connection through it. Processes started with its port reach nothing after.
    private func stopProxy() {
        proxy?.stop()
        proxy = nil
        proxyEndpoint = nil
        stopRelay()
    }

    /// Starts the model relay with a fresh port and session token. It runs whether or not a key is saved (without
    /// one it answers 503), so the shared terminal always has its address.
    private func startRelay() {
        stopRelay()
        let key = modelKey
        let budget = budgetBox
        let relay = ModelRelayServer(
            credential: { key.value },
            budgetRefusal: { budget.refusal() },
            onExchange: { [weak self] exchange in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.supervisor.recordModelRelay(exchange, now: Date())
                        self?.addRelaySpend(exchange.cost)
                        self?.flushAudit()
                    }
                }
            }
        )
        if let endpoint = try? relay.start() {
            self.relay = relay
            relayEndpoint = endpoint
        }
    }

    /// Closes the relay and cancels what is in flight. Stop does this with the proxy.
    private func stopRelay() {
        relay?.stop()
        relay = nil
        relayEndpoint = nil
    }

    /// Saves the owner's API key in the keychain for the relay. Why not, or `nil`.
    /// Adds an exchange's cost to this month's spend, saved at once.
    private func addRelaySpend(_ cost: Double) {
        guard cost > 0 else { return }
        var budget = budgetBox.value
        budget.add(cost, month: RelayBudget.monthKey(Date()))
        budgetBox.value = budget
        relayBudget = budget
        settings.relayBudget = budget
    }

    /// The owner sets the model relay's monthly budget in US dollars, or removes it (`nil`). Returns why not, or
    /// `nil`.
    func setRelayBudget(_ limit: Double?) -> String? {
        if let limit, let problem = RelayBudget.limitProblem(limit) { return problem }
        var budget = budgetBox.value
        budget.limit = limit
        budgetBox.value = budget
        relayBudget = budget
        settings.relayBudget = budget
        supervisor.recordRelayBudget(limit: limit, now: Date())
        flushAudit()
        return nil
    }

    func saveModelKey(_ key: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = ModelKeyStore.save(key) { return problem }
        modelKey.value = key
        hasModelKey = true
        supervisor.recordModelKeyChange(saved: true, now: Date())
        flushAudit()
        return nil
    }

    /// Removes the owner's API key; the relay answers 503 from now on.
    func removeModelKey() {
        ModelKeyStore.delete()
        modelKey.value = nil
        hasModelKey = false
        supervisor.recordModelKeyChange(saved: false, now: Date())
        flushAudit()
    }

    /// An approved `net_allow_request`: starts the endpoint's forwarder on 127.0.0.1, which reports every connection
    /// like the proxy; agent processes started from now on may reach its port.
    private func openLANEndpoint(_ launch: Launch) -> ToolResult {
        guard let endpoint = LANEndpoint(argv: launch.request.argv) else {
            return supervisor.lanEndpointOpened(launch, localPort: nil, failure: "not a LAN endpoint", now: Date())
        }
        let forwarder = LANForwarder(
            endpoint: endpoint,
            onAttempt: { [weak self] attempt in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.supervisor.recordNetworkAttempt(attempt, now: Date())
                        self?.flushAudit()
                    }
                }
            },
            onClosed: { [weak self] transfer in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.supervisor.recordNetworkClosed(transfer, now: Date())
                        self?.flushAudit()
                    }
                }
            }
        )
        do {
            let port = try forwarder.start()
            lanForwarders.append(forwarder)
            return supervisor.lanEndpointOpened(launch, localPort: port, failure: nil, now: Date())
        } catch {
            return supervisor.lanEndpointOpened(
                launch,
                localPort: nil,
                failure: "the forwarder could not start: \(error)",
                now: Date()
            )
        }
    }

    /// Closes every LAN forwarder and its connections (Stop, quitting, a new session folder).
    private func stopLANForwarders() {
        lanForwarders.forEach { $0.stop() }
        lanForwarders = []
    }

    /// Lets agent processes reach `host` from the next connection on, for this session or always (saved).
    func allowHost(_ host: String, always: Bool) {
        guard supervisor.allowHost(host, always: always, now: Date()) else { return }
        proxy?.update(supervisor.network)
        if always { settings.allowedHosts = supervisor.ownerHosts }
        flushAudit()
    }

    /// Stops allowing a host the owner added.
    func removeHost(_ host: String) {
        guard supervisor.removeHost(host, now: Date()) else { return }
        proxy?.update(supervisor.network)
        settings.allowedHosts = supervisor.ownerHosts
        flushAudit()
    }

    /// Called when the app quits: everything still waiting is denied and audited.
    func shutdown() {
        deliver(supervisor.stop(now: Date()))
        // Synchronous: the app is about to exit. Every agent process ends with it, and every port closes.
        running.values.forEach { $0.command.kill() }
        serialPorts.values.forEach { $0.close() }
        serialPorts = [:]
        _ = AgentProcesses.endAll()
        stopProxy()
        stopLANForwarders()
        // Saved, not shown: the app is quitting. Skipped if Stop already reported everything.
        writeReport(show: false)
        server?.stop()
        terminal?.stop()
        terminal = nil
    }

    // MARK: - Plumbing

    private func tick() {
        now = Date()
        deliver(supervisor.tick(now: now))
        // A caller that left gets no answer: its waiting request is withdrawn, its command killed.
        for (id, caller) in callers where !caller.isConnected {
            callers.removeValue(forKey: id)
            if supervisor.withdraw(id, now: now) {
                waiters.removeValue(forKey: id)?.resume(returning: ToolResult(text: "withdrawn", isError: true))
            }
        }
        for (id, entry) in running where entry.caller?.isConnected == false {
            let command = entry.command
            running.removeValue(forKey: id)
            Task.detached { command.kill() }
        }
        // Merged agent branches of auto-pushed repositories are cleaned up every few minutes.
        if now.timeIntervalSince(lastBranchRefresh) > 300 {
            lastBranchRefresh = now
            for repository in repositories where supervisor.policy(for: repository).autoPush {
                Task { await refreshAgentBranches(repository) }
            }
            Task { await refreshBranchStates(repositories) }
        }
        // While Claude Code runs in the second tab, check now and then that it still does.
        if secondTabCommand == "claude", now.timeIntervalSince(lastSecondTabCheck) > 30 {
            lastSecondTabCheck = now
            refreshSecondTab()
        }
        // What job_status shows for running jobs.
        for entry in running.values {
            guard let jobID = entry.jobID else { continue }
            let output = entry.command.peek()
            supervisor.updateJobOutput(jobID, tail: output.tail, totalBytes: output.totalBytes)
        }
        flushAudit()
    }

    private func deliver(_ resolutions: [Resolution]) {
        flushAudit()
        closeOrphanedPorts()
        for resolution in resolutions {
            let caller = callers.removeValue(forKey: resolution.id)
            guard let waiter = waiters.removeValue(forKey: resolution.id) else {
                // An approved background job runs without a caller.
                if let execution = resolution.execution, execution.jobID != nil {
                    runJob(execution)
                    continue
                }
                // The caller is gone: an approved action must not run for nobody.
                if let execution = resolution.execution {
                    _ = supervisor.complete(execution, output: nil, failure: "the caller is gone", now: Date())
                    flushAudit()
                }
                continue
            }
            if let execution = resolution.execution {
                Task { waiter.resume(returning: await run(execution, caller: caller)) }
            } else {
                waiter.resume(returning: resolution.result)
            }
        }
        let ids = resolutions.map(\.id)
        if !ids.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Persists the supervisor's audit lines. Until the log is open they stay queued, never dropped; after an audit
    /// failure (stopped for good) there is nowhere to write them.
    private func flushAudit() {
        guard let store else {
            if auditError != nil { _ = supervisor.drainAuditLines() }
            return
        }
        let lines = supervisor.drainAuditLines()
        do {
            try store.append(lines, head: supervisor.auditHead)
        } catch {
            self.store = nil
            failClosed("Could not write the audit log: \(error)")
        }
    }

    /// Without an audit log nothing may run: Stop, and keep Reset disabled.
    private func failClosed(_ message: String) {
        auditError = message
        stopProxy()
        endAgentProcesses()
        let resolutions = supervisor.stop(now: Date())
        _ = supervisor.drainAuditLines()
        closeOrphanedPorts()
        for resolution in resolutions {
            waiters.removeValue(forKey: resolution.id)?.resume(returning: resolution.result)
        }
    }

    private func notify(about id: String) {
        guard !NSApp.isActive, let approval = supervisor.pending.first(where: { $0.id == id }) else { return }
        let tool = approval.tool
        if askedForNotifications {
            Self.post(id: id, tool: tool)
        } else {
            askedForNotifications = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                if granted { Task { @MainActor in Self.post(id: id, tool: tool) } }
            }
        }
    }

    /// No sound, and only the tool name: the full command stays in the window, off the lock screen.
    private static func post(id: String, tool: String) {
        let content = UNMutableNotificationContent()
        content.title = "Approval waiting"
        content.body = "\(tool) is waiting for your approval in Dual Control."
        content.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Another instance owns the socket: bring it forward and quit this one.
    private static func handOverToRunningInstance() {
        let current = NSRunningApplication.current
        if let identifier = Bundle.main.bundleIdentifier {
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first { $0.processIdentifier != current.processIdentifier }?
                .activate()
        }
        NSApp.terminate(nil)
    }
}

/// The owner's API key for the model relay, shared with the relay's threads.
/// The model relay's budget, read by the relay's threads before each request and changed on the main actor.
final class RelayBudgetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var budget: RelayBudget

    init(_ budget: RelayBudget) { self.budget = budget }

    var value: RelayBudget {
        get { lock.withLock { budget } }
        set { lock.withLock { budget = newValue } }
    }

    /// Why a new request may not go upstream now, or `nil`.
    func refusal() -> String? {
        let month = RelayBudget.monthKey(Date())
        return lock.withLock { budget.refusal(month: month) }
    }
}

final class ModelKeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    var value: String? {
        get { lock.withLock { key } }
        set { lock.withLock { key = newValue } }
    }
}
