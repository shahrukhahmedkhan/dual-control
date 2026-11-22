import AppKit
import DualControlCore
import SwiftUI

struct ContentView: View {
    let model: AppModel
    @State private var showingRules = false
    @State private var showingSetup = false
    @State private var claudeCodeVersion = ClaudeCode.recommendedVersion
    @State private var showingModelKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(alerts, id: \.self) { alert in
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let warning = model.auditWarning {
                Label("Previous audit log check failed: \(warning)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            header
            resumeBanner
            scopeRow
            sandboxRow
            serialRow
            networkRow
            claudeCodeRow
            reviewRow
            repositoriesRow
            modeRow
            Divider()
            approvals
            Divider()
            TerminalPanes(model: model)
            Divider()
            activity
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 860)
        .sheet(isPresented: $showingRules) { RulesSheet(model: model) }
        .sheet(isPresented: $showingSetup) { SetupSheet(model: model) }
        .sheet(isPresented: $showingModelKey) { ModelKeySheet(model: model) }
        .sheet(
            isPresented: Binding(
                get: { model.review != nil },
                set: { if !$0 { model.discardReview() } }
            )
        ) { ReviewSheet(model: model) }
        .sheet(item: Binding(get: { model.shownReport }, set: { model.shownReport = $0 })) { ReportSheet(report: $0) }
    }

    private var alerts: [String] {
        [
            model.serverError, model.auditError.map { "\($0) Dual Control stays stopped until restarted." },
            model.agentSurvivors,
        ]
        .compactMap { $0 }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.supervisor.header(now: model.now))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text(interventionText)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.supervisor.engine.isStopped {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Stopped: everything is denied").bold().foregroundStyle(.red)
                    Button("Reset (ask each)") { model.reset() }
                        .disabled(!model.canReset)
                }
            } else {
                Button(action: model.stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.title2.bold())
                        .frame(minWidth: 120, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: .command)
                .help("Deny everything, including requests waiting for approval (⌘.)")
                Button("End session", action: model.endSession)
                    .help("Stop everything and show the session report")
            }
        }
    }

    private var interventionText: String {
        let counts = model.supervisor.interventions
        return "Interventions: \(counts.total) (asks \(counts.asks) · takeovers \(counts.takeovers) · "
            + "denials \(counts.denials) · timed out \(counts.timeouts))"
    }

    /// D13b: the last session folder came back at launch, still in ask-each; one click allows while open.
    @ViewBuilder private var resumeBanner: some View {
        if let folder = model.resumeOffer {
            HStack(spacing: 12) {
                Label("Resume: \(DisplayText.escaped(folder))", systemImage: "arrow.clockwise.circle")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Allow while open", action: model.resumeSession)
                    .disabled(model.supervisor.engine.isStopped || model.supervisor.sandboxProblem != nil)
                    .help("The folder's checks ran again at launch. Until you click, every action asks.")
                Button("Not now", action: model.dismissResumeOffer)
            }
            .padding(8)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// The session folder: commands run only inside it, and nothing outside the Developer folder can be chosen.
    private var scopeRow: some View {
        HStack(spacing: 12) {
            Text("Session folder:")
            if let root = model.supervisor.scope?.root {
                Text(DisplayText.escaped(root))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("none chosen, so no command runs").foregroundStyle(.orange)
            }
            Spacer()
            if let error = model.scopeError {
                Text(error).foregroundStyle(.red)
            }
            Button("Choose…", action: chooseSessionFolder)
                .disabled(model.ceiling == nil)
                .help(model.ceiling == nil ? "Create a Developer folder in your home folder first." : "")
            Button("Setup…") { showingSetup = true }
        }
    }

    /// Fail closed: while the self-test has not passed, nothing runs as the agent, and this says why.
    @ViewBuilder private var sandboxRow: some View {
        if model.supervisor.scope != nil, let problem = model.supervisor.sandboxProblem {
            Label(
                "Sandbox not available: \(problem). Nothing runs as the agent.",
                systemImage: "lock.trianglebadge.exclamationmark"
            )
            .foregroundStyle(.red)
            .textSelection(.enabled)
        } else if model.supervisor.scope != nil {
            Label("Sandbox self-test passed", systemImage: "lock.shield").foregroundStyle(.green)
        }
    }

    /// The owner's pinned Claude Code (D11): install a version (downloaded and checked as the owner) and start the
    /// newest in the shared terminal, as the agent.
    /// This month's model relay spend and the budget (D12e).
    private var spendText: String {
        let budget = model.relayBudget
        let spent = budget.spent(in: RelayBudget.monthKey(model.now))
        let limit = budget.limit.map { String(format: " of $%.2f", $0) } ?? " (no budget)"
        return String(format: "· $%.2f", spent) + limit + " this month"
    }

    private var spendWarning: Bool {
        guard let limit = model.relayBudget.limit else { return false }
        return model.relayBudget.spent(in: RelayBudget.monthKey(model.now)) >= limit * 0.8
    }

    @ViewBuilder private var claudeCodeRow: some View {
        if model.supervisor.scope != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text("Claude Code:")
                    if let newest = ClaudeCode.newest(model.supervisor.claudeCodeVersions) {
                        Text(newest).font(.system(.body, design: .monospaced))
                    } else {
                        Text("not installed").foregroundStyle(.secondary)
                    }
                    Text(model.hasModelKey ? "· model key set" : "· no model key")
                        .foregroundStyle(model.hasModelKey ? Color.secondary : Color.orange)
                    Text(spendText)
                        .foregroundStyle(spendWarning ? Color.orange : Color.secondary)
                        .help("Model relay spend this month at a conservative price table; requests stop at the budget")
                    Button("Model key…") { showingModelKey = true }
                        .help("Your Anthropic API key for the relay, kept in your keychain; the agent never sees it")
                    Spacer()
                    TextField("Version", text: $claudeCodeVersion)
                        .frame(width: 90)
                        .font(.system(.body, design: .monospaced))
                    Button(model.isInstallingClaudeCode ? "Installing…" : "Install") {
                        model.installClaudeCode(version: claudeCodeVersion)
                    }
                    .disabled(model.isInstallingClaudeCode)
                    .help("Download this release from Anthropic, check its SHA-256 and signature, and lock it")
                    Button("Start in shared terminal", action: model.startClaudeCode)
                        .disabled(
                            model.terminal == nil || ClaudeCode.newest(model.supervisor.claudeCodeVersions) == nil
                        )
                        .help("Type the fixed launch line into the agent's terminal")
                }
                if let message = model.claudeCodeMessage {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    /// Branches the agent committed to with `git_commit`, waiting for the owner to review and push (D11).
    @ViewBuilder private var reviewRow: some View {
        if !model.supervisor.reviewQueue.isEmpty || model.reviewMessage != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.supervisor.reviewQueue) { item in
                    HStack(spacing: 12) {
                        Label(
                            "To review: \(DisplayText.escaped(item.branch)) in "
                                + DisplayText.escaped((item.repository as NSString).lastPathComponent),
                            systemImage: "arrow.up.doc"
                        )
                        .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Review…") { model.openReview(item.id) }
                            .disabled(model.isReviewBusy)
                        Button("Dismiss") { model.dismissReviewItem(item.id) }
                    }
                }
                if let message = model.reviewMessage {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    /// Per repository in the session folder: push the agent's claude/* branches automatically and open a pull
    /// request (off by default; one click turns it off), and how many agent branches may be open at once (D12b).
    @ViewBuilder private var repositoriesRow: some View {
        if !model.repositories.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.repositories, id: \.self) { repository in
                    let policy = model.supervisor.policy(for: repository)
                    let open = model.supervisor.openAgentBranches[repository]
                    HStack(spacing: 12) {
                        Label(
                            DisplayText.escaped((repository as NSString).lastPathComponent),
                            systemImage: "arrow.triangle.branch"
                        )
                        .font(.system(.body, design: .monospaced))
                        if let state = model.supervisor.branchStates[repository] {
                            Text(DisplayText.escaped(state.summary))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle((state.behind ?? 0) > 0 ? .orange : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(open.map { "\($0.count) of \(policy.maxOpenBranches) agent branches open" } ?? "")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Toggle(
                            "Push claude/* automatically and open a PR",
                            isOn: Binding(
                                get: { policy.autoPush },
                                set: { on in
                                    var changed = policy
                                    changed.autoPush = on
                                    model.setRepositoryPolicy(changed, for: repository)
                                }
                            )
                        )
                        Stepper(
                            "Max open: \(policy.maxOpenBranches)",
                            value: Binding(
                                get: { policy.maxOpenBranches },
                                set: { cap in
                                    var changed = policy
                                    changed.maxOpenBranches = cap
                                    model.setRepositoryPolicy(changed, for: repository)
                                }
                            ),
                            in: AgentBranches.capRange
                        )
                        .fixedSize()
                    }
                }
            }
        }
    }

    /// The serial ports open for Claude. Stop closes them all.
    @ViewBuilder private var serialRow: some View {
        let sessions = model.supervisor.serialSessions.values.sorted { $0.openedAt < $1.openedAt }
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sessions) { session in
                    Label(
                        "Serial open: \(DisplayText.escaped(session.port)) at \(session.settings.description)"
                            + (session.device.map { " · USB \($0.label)" } ?? "")
                            + (session.writesRefused ? " · writes refused (bootloader)" : ""),
                        systemImage: "cable.connector"
                    )
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                }
            }
        }
    }

    private func chooseSessionFolder() {
        guard let ceiling = model.ceiling else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: model.supervisor.scope?.root ?? ceiling, isDirectory: true)
        panel.message = "Choose the folder Claude may work in. It must be inside your Developer folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseSessionFolder(url.path)
    }

    private var modeRow: some View {
        HStack(spacing: 12) {
            Picker(
                "Mode",
                selection: Binding(get: { model.modeChoice }, set: { model.choose($0) })
            ) {
                ForEach(ModeChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)
            .disabled(model.supervisor.engine.isStopped)
            if case .allowUntil(let end) = model.supervisor.engine.mode, end > model.now {
                Text("\(Self.remaining(end.timeIntervalSince(model.now))) left")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rules & Settings…") { showingRules = true }
        }
    }

    /// The gatekeeper: whether agent processes have any network, and the hosts it refused, each one click from
    /// being allowed.
    @ViewBuilder private var networkRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let endpoint = model.proxyEndpoint {
                Label(
                    "Network: only through the gatekeeper on \(endpoint) to allowed hosts",
                    systemImage: "network.badge.shield.half.filled"
                )
                .foregroundStyle(.green)
            } else {
                Label(
                    model.proxyError ?? "Network off: agent processes reach nothing until Reset.",
                    systemImage: "network.slash"
                )
                .foregroundStyle(model.proxyError == nil ? Color.secondary : Color.red)
                .textSelection(.enabled)
            }
            ForEach(model.supervisor.deniedHosts.prefix(5)) { denied in
                HStack(spacing: 8) {
                    Text("Refused: \(denied.host)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("\(denied.count)× · last \(denied.lastSeen.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow for this session") { model.allowHost(denied.host, always: false) }
                    Button("Always allow") { model.allowHost(denied.host, always: true) }
                }
            }
        }
    }

    @ViewBuilder private var approvals: some View {
        Text("Waiting for approval (\(model.supervisor.pending.count))").font(.headline)
        if model.supervisor.pending.isEmpty {
            Text("Nothing is waiting.").foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.supervisor.pending) { ApprovalCard(approval: $0, model: model) }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity").font(.headline)
            Table(model.supervisor.feed) {
                TableColumn("Time") { Text($0.time, format: .dateTime.hour().minute().second()).monospacedDigit() }
                    .width(70)
                TableColumn("Tool", value: \.tool).width(110)
                TableColumn("Summary") { Text($0.summary).font(.system(.body, design: .monospaced)) }
                TableColumn("Decision") { entry in
                    Text(entry.outcome.label).foregroundStyle(Self.color(entry.outcome))
                }
                .width(110)
                TableColumn("Outcome") { entry in
                    if let result = entry.result {
                        Text(result.label).foregroundStyle(result.succeeded ? Color.green : Color.red)
                    }
                }
                .width(150)
                TableColumn("Rule", value: \.ruleID).width(150)
            }
        }
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func color(_ outcome: FeedOutcome) -> Color {
        switch outcome {
        case .allowed, .approved: return .green
        case .asked: return .orange
        case .denied, .ownerDenied, .timedOut, .failed: return .red
        }
    }
}

/// One waiting request. Shows exactly what would run, escaped so nothing is hidden.
struct ApprovalCard: View {
    let approval: PendingApproval
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(approval.tool).font(.headline)
                Text(Self.tierText(approval.tier))
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Self.tierColor(approval.tier).opacity(0.2)))
                Spacer()
                Text("Auto-deny in \(ContentView.remaining(approval.deadline.timeIntervalSince(model.now)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row(contentTitle, content, monospaced: true)
                if let device = approval.request.device {
                    row("Device", "USB \(device.label)", monospaced: true)
                    if approval.canAlwaysAllow, device.needsLocation {
                        row("Note", Self.locationNote(device))
                    }
                }
                row("Folder", approval.request.cwd.isEmpty ? "—" : DisplayText.escaped(approval.request.cwd))
                row("Reason", "\(approval.decision.reason) (\(approval.decision.ruleID))")
            }
            HStack {
                Button("Approve") { model.approve(approval.id) }
                Button("Deny", role: .destructive) { model.deny(approval.id) }
                if approval.canAlwaysAllow, approval.request.capability == .serial {
                    Button("Approve and always allow this device in this folder") {
                        model.approve(approval.id, alwaysAllow: true)
                    }
                    .help(
                        "Adds a device rule: this USB device (vendor, product and serial number"
                            + (approval.request.device?.needsLocation == true ? ", on this USB port" : "")
                            + ") may be opened, written and reset without asking while this is the session folder. "
                            + "Remove it in Rules."
                    )
                } else if approval.canAlwaysAllow {
                    Button("Approve and always allow this in this folder") {
                        model.approve(approval.id, alwaysAllow: true)
                    }
                    .help("Adds a project rule for exactly this command in this folder. Remove it in Rules.")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.5)))
    }

    /// Why a device rule for `device` also needs its USB port.
    static func locationNote(_ device: SerialDevice) -> String {
        let why =
            device.serialNumberShared
            ? "Another connected device reports the same serial number"
            : "This serial number is a common default, not unique to this board"
        return why + ", so \"always allow\" covers it only on this USB port."
    }

    private var contentTitle: String {
        switch approval.request.capability {
        case .command: return "Command"
        case .serial: return "Serial"
        case .file: return "File"
        default: return "Text"
        }
    }

    private var content: String {
        switch approval.request.capability {
        case .command: return DisplayText.argv(approval.request.argv)
        case .serial:
            return SerialOperation(argv: approval.request.argv)?.summary ?? DisplayText.argv(approval.request.argv)
        case .file:
            return FileRequest(argv: approval.request.argv)?.summary ?? DisplayText.argv(approval.request.argv)
        default: return DisplayText.escaped(approval.request.argv.joined())
        }
    }

    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }

    static func tierText(_ tier: RiskTier) -> String {
        switch tier {
        case .readOnly: return "read-only"
        case .changing: return "changing"
        case .privileged: return "privileged"
        case .blocked: return "blocked"
        }
    }

    static func tierColor(_ tier: RiskTier) -> Color {
        tier == .changing ? .orange : .red
    }
}

/// The approval timeout and the project rules.
struct RulesSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    static let timeouts: [TimeInterval] = [60, 120, 300, 600, 840]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rules & Settings").font(.title2.bold())
            Picker(
                "Deny unanswered requests after",
                selection: Binding(get: { model.supervisor.approvalTimeout }, set: { model.setApprovalTimeout($0) })
            ) {
                ForEach(Self.timeouts, id: \.self) { Text("\(Int($0) / 60) min").tag($0) }
            }
            .frame(maxWidth: 360)
            Divider()
            Text("Project rules").font(.headline)
            Text("Each rule allows exactly one command in one folder (and its subfolders) without asking.")
                .foregroundStyle(.secondary)
            if model.supervisor.rules.isEmpty {
                Text("No rules yet. Add one with “Approve and always allow” on a waiting request.")
                    .foregroundStyle(.secondary)
            } else {
                List(model.supervisor.rules, id: \.id) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(DisplayText.argv(rule.argv))
                                .font(.system(.body, design: .monospaced))
                            Text("in \(DisplayText.escaped(rule.folder)) · rule.\(rule.id)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { model.removeRule(rule.id) }
                    }
                }
                .frame(minHeight: 160)
            }
            Divider()
            Text("Device rules").font(.headline)
            Text(
                "Each rule lets one USB serial device be opened, written and reset without asking in one session folder."
            )
            .foregroundStyle(.secondary)
            if model.supervisor.deviceRules.isEmpty {
                Text("No device rules yet. Add one with “Approve and always allow this device” on a serial request.")
                    .foregroundStyle(.secondary)
            } else {
                List(model.supervisor.deviceRules, id: \.id) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("USB \(rule.label)").font(.system(.body, design: .monospaced))
                            Text("in \(DisplayText.escaped(rule.folder)) · rule.\(rule.id)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { model.removeRule(rule.id) }
                    }
                }
                .frame(minHeight: 100)
            }
            Divider()
            Text("Network hosts").font(.headline)
            Text(
                "Agent processes reach only these hosts, through the gatekeeper: HTTPS on port 443 and plain HTTP on "
                    + "port 80. Always allowed: \(NetworkPolicy.defaultHosts.joined(separator: ", "))."
            )
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            if model.supervisor.ownerHosts.isEmpty {
                Text("No hosts of your own. Allow one from a refused connection in the main window.")
                    .foregroundStyle(.secondary)
            } else {
                List(model.supervisor.ownerHosts, id: \.self) { host in
                    HStack {
                        Text(host).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove", role: .destructive) { model.removeHost(host) }
                    }
                }
                .frame(minHeight: 80)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
    }
}

/// The session report after Stop or End session, as saved: shown literally, never rendered, so nothing from the log
/// can become a link.
struct ReportSheet: View {
    let report: AppModel.ShownReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session report").font(.title2.bold())
            switch report.saved {
            case .path(let path):
                HStack {
                    Text("Saved next to the audit log: \((path as NSString).lastPathComponent)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            ScrollView {
                Text(verbatim: report.markdown)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 560)
    }
}

/// The owner enters the model relay's API key (D11). It goes to the owner's keychain; Claude Code inside gets only
/// the relay's address and a session token.
struct ModelKeySheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var problem: String?
    @State private var budget = ""
    @State private var budgetProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model key for Claude Code inside").font(.headline)
            Text(
                "Use a key from a dedicated Console workspace with a spend limit. It stays in your keychain; the app "
                    + "adds it to each request Claude Code makes through the relay. The agent never sees it."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            SecureField("sk-ant-…", text: $key)
                .font(.system(.body, design: .monospaced))
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
            Divider()
            Text("Monthly budget (US dollars)").font(.subheadline.bold())
            Text(
                "The relay adds up what each answer used at a conservative price table and refuses new requests once "
                    + "this month's spend reaches the budget. Keep the workspace's own spend limit too."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(model.relayBudget.limit.map { String(format: "%.2f", $0) } ?? "none", text: $budget)
                    .frame(width: 100)
                Button("Set budget") {
                    guard let value = Double(budget.replacingOccurrences(of: ",", with: ".")) else {
                        budgetProblem = "enter an amount such as 5"
                        return
                    }
                    budgetProblem = model.setRelayBudget(value)
                    if budgetProblem == nil { budget = "" }
                }
                if model.relayBudget.limit != nil {
                    Button("No budget") { budgetProblem = model.setRelayBudget(nil) }
                }
            }
            if let budgetProblem {
                Text(budgetProblem).foregroundStyle(.red)
            }
            HStack {
                if model.hasModelKey {
                    Button("Remove key", role: .destructive) {
                        model.removeModelKey()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    problem = model.saveModelKey(key)
                    if problem == nil {
                        key = ""
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// The owner's review of a branch the agent committed to (D11 phase 3): the commits the remote does not have, their
/// stat and diff (agent text, escaped). Push re-signs them with the owner's key and pushes the branch, as the owner.
struct ReviewSheet: View {
    let model: AppModel

    var body: some View {
        if let review = model.review {
            VStack(alignment: .leading, spacing: 10) {
                Text("Review \(DisplayText.escaped(review.branch))").font(.headline)
                Text(
                    "\(review.commits.count) commit(s) → \(DisplayText.escaped(review.remote))"
                        + (review.remoteTip == nil ? " (new branch)" : " (fast-forward)")
                )
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(DisplayText.escaped(review.log))
                        Text(DisplayText.escaped(review.stat))
                        Divider()
                        Text(DisplayText.escaped(review.diff) + (review.truncated ? "\n… (diff cut at 1 MiB)" : ""))
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 360)
                HStack {
                    Text("Push re-signs these commits with your key. Never the default branch, never forced.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.discardReview() }.keyboardShortcut(.cancelAction)
                    Button(model.isReviewBusy ? "Pushing…" : "Push as me") { model.pushReview() }
                        .disabled(model.isReviewBusy)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(minWidth: 760, minHeight: 560)
        }
    }
}
