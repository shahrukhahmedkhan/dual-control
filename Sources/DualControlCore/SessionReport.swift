import Foundation

/// One audit entry as the session report reads it. The event is kept as text, so entries this build does not know
/// (such as `network` from the gatekeeper) are still read.
public struct AuditRecord: Sendable, Equatable, Decodable {
    /// Sequence number in the chain.
    public let seq: Int
    /// When it was written.
    public let time: Date
    /// The `AuditEvent` raw value.
    public let event: String
    /// The entry's detail.
    public let detail: String?
    /// The request it is about, if any.
    public let request: ActionRequest?
    /// The decision it records, if any.
    public let decision: Decision?

    /// A record.
    public init(
        seq: Int,
        time: Date,
        event: String,
        detail: String? = nil,
        request: ActionRequest? = nil,
        decision: Decision? = nil
    ) {
        self.seq = seq
        self.time = time
        self.event = event
        self.detail = detail
        self.request = request
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey {
        case seq, ts, event, detail, request, decision
    }

    /// Decodes an audit line.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        let stamp = try container.decode(String.self, forKey: .ts)
        guard let time = Self.date(stamp) else {
            throw DecodingError.dataCorruptedError(forKey: .ts, in: container, debugDescription: "bad timestamp")
        }
        self.time = time
        event = try container.decode(String.self, forKey: .event)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        request = try container.decodeIfPresent(ActionRequest.self, forKey: .request)
        decision = try container.decodeIfPresent(Decision.self, forKey: .decision)
    }

    static func date(_ stamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: stamp)
    }
}

/// Traffic through the gatekeeper to one `host:port`.
public struct HostTraffic: Sendable, Equatable {
    /// `host:port`, escaped as in the log.
    public let host: String
    /// Connections allowed.
    public var allowed: Int
    /// Connections refused.
    public var denied: Int
    /// Allowed connections that could not reach the server.
    public var failed: Int
    /// Bytes from the agent.
    public var up: Int
    /// Bytes to the agent.
    public var down: Int
}

/// What was done on one serial port.
public struct SerialUse: Sendable, Equatable {
    /// The port path, escaped as in the log.
    public let port: String
    /// Times it was opened.
    public var opens: Int
    /// Writes to it.
    public var writes: Int
    /// Bytes written.
    public var bytesWritten: Int
    /// Resets.
    public var resets: Int
}

/// How long one ask waited for the owner, and how it ended.
public struct ApprovalTiming: Sendable, Equatable {
    /// How an ask ended.
    public enum Verdict: String, Sendable, Equatable {
        /// The owner approved it.
        case approved
        /// The owner denied it.
        case denied
        /// Nobody answered in time.
        case timedOut = "timed out"
        /// Stop, the caller leaving or a new session folder ended it.
        case withdrawn
    }

    /// The approval id.
    public let id: String
    /// What was asked, escaped and shortened.
    public let summary: String
    /// Seconds from the ask to the answer.
    public let seconds: TimeInterval
    /// How it ended.
    public let verdict: Verdict
}

/// Refusals under one rule.
public struct DenialCount: Sendable, Equatable {
    /// The deciding rule.
    public let rule: String
    /// How many.
    public var count: Int
    /// The first request refused, escaped and shortened.
    public let example: String
}

/// The end-of-session summary of an audit log (D8a): what ran and how it ended, what was refused, where the network
/// went, which serial ports were used and how fast the owner approved. A session is everything since the last
/// Reset, or since the log began. Computed only from the log, so it shows what was recorded, nothing more.
public struct SessionReport: Sendable, Equatable {
    /// Approvals faster than this are flagged as rubber-stamped.
    public static let rubberStampSeconds: TimeInterval = 2

    /// "verified, N entries", or where and why the chain is broken (over the whole file).
    public let chain: String
    /// Lines that are not audit entries.
    public let unreadable: Int
    /// The session's first and last entries.
    public let start: Date?
    /// The session's last entry.
    public let end: Date?
    /// Entries in the session.
    public let entries: Int
    /// Commands that ran, by outcome (`exit 0`, `exit 2`, `timed out`, `killed`…).
    public let commands: [String: Int]
    /// Text typed into the shared terminal.
    public let terminalTexts: Int
    /// Working directories of commands that started outside the session folder. Must be empty.
    public let ranOutside: [String]
    /// Requests refused because they reached outside the session folder.
    public let refusedOutside: Int
    /// Refusals by rule, rule names sorted.
    public let denials: [DenialCount]
    /// Network use per host, busiest first.
    public let network: [HostTraffic]
    /// Serial ports used, by path.
    public let serial: [SerialUse]
    /// Every ask and its answer, in the order asked.
    public let approvals: [ApprovalTiming]
    /// Times Stop was pressed.
    public let stops: Int
    /// Times the owner took over the terminal.
    public let takeovers: Int
    /// Files in the session folder that the owner's tools run and that changed during the session (gap 3), when the
    /// app scanned for them; shown first.
    public var ownerRunFiles: OwnerRunScan?
    /// Files in the session folder and the agent's home, changed this session, that look like credentials (D12d),
    /// when the app scanned for them; shown right after `ownerRunFiles`.
    public var credentialFiles: CredentialScan?

    /// Approvals given in under `rubberStampSeconds`.
    public var rubberStamped: [ApprovalTiming] {
        approvals.filter { $0.verdict == .approved && $0.seconds < Self.rubberStampSeconds }
    }

    /// The report for the JSONL `lines` of one audit log, oldest first.
    public static func make(lines: [String]) -> SessionReport {
        let chain: String
        switch AuditLog.verify(lines) {
        case .valid(let head): chain = "verified, \(head.count) entries"
        case .invalid(let line, let reason): chain = "BROKEN at line \(line + 1): \(reason)"
        }
        var records: [AuditRecord] = []
        var unreadable = 0
        for line in lines {
            if let record = try? JSONDecoder().decode(AuditRecord.self, from: Data(line.utf8)) {
                records.append(record)
            } else {
                unreadable += 1
            }
        }
        return make(records: records, chain: chain, unreadable: unreadable)
    }

    /// The report for `records`. One pass, so every count comes from the same entries; the session folder is
    /// followed from the start of the log, since a session after Reset may not repeat it.
    static func make(records: [AuditRecord], chain: String, unreadable: Int = 0) -> SessionReport {
        let first = records.lastIndex { $0.event == AuditEvent.reset.rawValue } ?? 0
        var root: String?
        var commands: [String: Int] = [:]
        var terminalTexts = 0
        var ranOutside: [String] = []
        var refusedOutside = 0
        var denials: [String: DenialCount] = [:]
        var hosts: [String: HostTraffic] = [:]
        var ports: [String: SerialUse] = [:]
        var openingPort: [String: String] = [:]
        var sessionPort: [String: String] = [:]
        var asks: [(id: String, time: Date, summary: String)] = []
        var answers: [String: (Date, ApprovalTiming.Verdict)] = [:]
        var stops = 0
        var takeovers = 0

        for (index, record) in records.enumerated() {
            if record.event == AuditEvent.scopeChanged.rawValue {
                root = record.detail == "none" ? nil : record.detail
            }
            guard index >= first else { continue }
            let detail = record.detail ?? ""
            switch record.event {
            case AuditEvent.starting.rawValue:
                guard let request = record.request else { break }
                if request.capability == .command, let root {
                    let cwd = DisplayText.escaped(request.cwd)
                    if cwd != root && !cwd.hasPrefix(root + "/") { ranOutside.append(cwd) }
                }
                if request.capability == .serial {
                    countSerial(request.argv, execution: detail, &ports, &openingPort, sessionPort)
                }
            case AuditEvent.executed.rawValue:
                guard let request = record.request else { break }
                if request.capability == .command { commands[outcome(detail), default: 0] += 1 }
                if request.capability == .terminal, detail.hasSuffix(" ok") { terminalTexts += 1 }
                if request.capability == .serial, let opened = detail.range(of: " ok: opened ") {
                    let execution = String(detail[..<opened.lowerBound])
                    if let port = openingPort[execution] { sessionPort[String(detail[opened.upperBound...])] = port }
                }
            case AuditEvent.serialClosed.rawValue:
                let words = detail.split(separator: " ", maxSplits: 1)
                if words.count == 2, let colon = words[1].range(of: ": ", options: .backwards) {
                    sessionPort[String(words[0])] = String(words[1][..<colon.lowerBound])
                }
            case "network":
                countNetwork(detail, &hosts)
            case AuditEvent.stopped.rawValue:
                stops += 1
            case AuditEvent.baton.rawValue where detail.contains("baton: owner"):
                takeovers += 1
            default:
                break
            }
            if let decision = record.decision, let request = record.request {
                let denied =
                    [
                        AuditEvent.decision.rawValue, AuditEvent.ownerDenied.rawValue,
                        AuditEvent.approvalTimedOut.rawValue,
                    ].contains(record.event) && decision.verdict == .deny
                if denied {
                    denials[
                        decision.ruleID,
                        default: DenialCount(
                            rule: decision.ruleID,
                            count: 0,
                            example: summary(request)
                        )
                    ].count += 1
                    if ["scope.outside", "scope.argument", "scope.unresolved"].contains(decision.ruleID) {
                        refusedOutside += 1
                    }
                }
                if record.event == AuditEvent.decision.rawValue, decision.verdict == .ask {
                    asks.append((detail, record.time, summary(request)))
                } else if answers[detail] == nil, asks.contains(where: { $0.id == detail }) {
                    switch record.event {
                    case AuditEvent.ownerApproved.rawValue: answers[detail] = (record.time, .approved)
                    case AuditEvent.ownerDenied.rawValue: answers[detail] = (record.time, .denied)
                    case AuditEvent.approvalTimedOut.rawValue: answers[detail] = (record.time, .timedOut)
                    case AuditEvent.decision.rawValue: answers[detail] = (record.time, .withdrawn)
                    default: break
                    }
                }
            }
        }

        let session = Array(records[min(first, records.count)...])
        return SessionReport(
            chain: chain,
            unreadable: unreadable,
            start: session.first?.time,
            end: session.last?.time,
            entries: session.count,
            commands: commands,
            terminalTexts: terminalTexts,
            ranOutside: ranOutside,
            refusedOutside: refusedOutside,
            denials: denials.values.sorted { $0.rule < $1.rule },
            network: hosts.values.sorted {
                ($0.up + $0.down, $0.denied, $1.host) > ($1.up + $1.down, $1.denied, $0.host)
            },
            serial: ports.values.sorted { $0.port < $1.port },
            approvals: asks.compactMap { ask in
                answers[ask.id].map { time, verdict in
                    ApprovalTiming(
                        id: ask.id,
                        summary: ask.summary,
                        seconds: time.timeIntervalSince(ask.time),
                        verdict: verdict
                    )
                }
            },
            stops: stops,
            takeovers: takeovers
        )
    }

    /// `exit N`, `timed out`, `killed: caller left`, `killed` or `could not start`, from an `executed` detail.
    static func outcome(_ detail: String) -> String {
        if detail.contains(" failed: ") { return "could not start" }
        if detail.contains("; timed out") { return "timed out" }
        if detail.contains("; caller left") { return "killed: caller left" }
        if detail.contains("; killed") { return "killed" }
        let words = detail.split(separator: " ")
        if let exit = words.firstIndex(of: "exit"), exit + 1 < words.count { return "exit \(words[exit + 1])" }
        return "other"
    }

    private static func countSerial(
        _ argv: [String],
        execution: String,
        _ ports: inout [String: SerialUse],
        _ openingPort: inout [String: String],
        _ sessionPort: [String: String]
    ) {
        guard argv.count >= 2 else { return }
        let operation = argv[0]
        let port = operation == "open" ? DisplayText.escaped(argv[1]) : sessionPort[argv[1]]
        guard let port else { return }
        var use = ports[port] ?? SerialUse(port: port, opens: 0, writes: 0, bytesWritten: 0, resets: 0)
        switch operation {
        case "open":
            use.opens += 1
            openingPort[execution] = port
        case "write":
            use.writes += 1
            use.bytesWritten += argv.count > 2 ? argv[2].count / 2 : 0
        case "reset":
            use.resets += 1
        default:
            break
        }
        ports[port] = use
    }

    /// Reads `nN METHOD host:port: allowed|denied [rule]` and `nN closed host:port: up X B, down Y B, Z s[, failed: …]`.
    private static func countNetwork(_ detail: String, _ hosts: inout [String: HostTraffic]) {
        let words = detail.split(separator: " ")
        guard words.count >= 4, words[2].hasSuffix(":") else { return }
        let host = String(words[2].dropLast())
        var traffic = hosts[host] ?? HostTraffic(host: host, allowed: 0, denied: 0, failed: 0, up: 0, down: 0)
        if words[1] == "closed" {
            func bytes(after label: String) -> Int {
                guard let index = words.firstIndex(of: Substring(label)), index + 1 < words.count else { return 0 }
                return Int(words[index + 1]) ?? 0
            }
            traffic.up += bytes(after: "up")
            traffic.down += bytes(after: "down")
            if detail.contains(", failed: ") { traffic.failed += 1 }
        } else if words[3] == "allowed" {
            traffic.allowed += 1
        } else {
            traffic.denied += 1
        }
        hosts[host] = traffic
    }

    static func summary(_ request: ActionRequest) -> String {
        DisplayText.summary(request.argv.joined(separator: " "), limit: 80)
    }

    // MARK: - Markdown

    /// The section on changed files that look like credentials: a loud warning and a table of where, which file and
    /// what kind (never the secret), or that there were none.
    static func credentialSection(_ scan: CredentialScan) -> [String] {
        let warn = !scan.files.isEmpty || !scan.unreadable.isEmpty || scan.incomplete
        var out = ["", "## Credentials" + (warn ? " ⚠️" : ""), ""]
        if scan.files.isEmpty {
            out.append(
                "No file changed this session looks like a credential (\(scan.scanned) entries checked in the "
                    + "session folder and the agent's home)."
            )
        } else {
            out.append(
                "**\(scan.files.count) changed file(s) look like credentials.** A key or token in the agent's reach "
                    + "can be used or sent anywhere the agent can reach. Revoke any that are real, then delete the "
                    + "files; never commit them."
            )
            out += ["", "| Where | File | Looks like |", "|---|---|---|"]
            for file in scan.files {
                let kinds = file.kinds.map(Self.md).joined(separator: ", ")
                out.append("| \(file.place.rawValue) | \(Self.md(file.path)) | \(kinds) |")
            }
        }
        if !scan.unreadable.isEmpty {
            out.append("")
            out.append(
                "⚠️ You could not read \(scan.unreadable.count) changed entr\(scan.unreadable.count == 1 ? "y" : "ies") "
                    + "the agent made private; check them as the agent:"
            )
            for entry in scan.unreadable { out.append("- \(entry.place.rawValue): \(Self.md(entry.path))") }
        }
        if scan.incomplete {
            out.append("")
            out.append("⚠️ The scan stopped after \(scan.scanned) entries; there may be more.")
        }
        out.append("")
        out.append("Claude Code's login folder in the agent's home (.claude) is not scanned: its token belongs there.")
        return out
    }

    /// The section on changed files the owner's tools run: a warning and a table, or that there were none.
    static func ownerRunSection(_ scan: OwnerRunScan) -> [String] {
        var out = ["", "## Files your tools run" + (scan.files.isEmpty ? "" : " ⚠️"), ""]
        if scan.files.isEmpty {
            out.append(
                "None of the files your editor, build or git run on their own changed in the session folder "
                    + "(\(scan.scanned) entries checked)."
            )
        } else {
            out.append(
                "**\(scan.files.count) changed file(s) in the session folder run code as you** when you open the "
                    + "folder in an editor, build, or commit there. Read each one before you do any of that, or "
                    + "outside Dual Control's sandbox the agent's code runs with your rights."
            )
            out += ["", "| File | Runs on | Change |", "|---|---|---|"]
            for file in scan.files {
                let change = file.createdByAgent ? "new, written by the agent" : "changed during the session"
                out.append("| \(Self.md(file.path)) | \(Self.md(file.kind)) | \(change) |")
            }
        }
        if scan.incomplete {
            out.append("")
            out.append(
                "⚠️ The scan stopped after \(scan.scanned) entries; there may be more. Check the folder yourself."
            )
        }
        return out
    }

    /// The report as Markdown. Every value from the log is escaped, so nothing the agent wrote can add structure,
    /// links or formatting.
    public var markdown: String {
        var out = ["# Dual Control session report", ""]
        if let start, let end {
            out.append(
                "- Period: \(Self.stamp(start)) to \(Self.stamp(end)) (\(Self.duration(end.timeIntervalSince(start))))"
            )
        }
        out.append("- Entries in this session: \(entries)")
        out.append("- Audit chain: \(Self.md(chain))" + (chain.hasPrefix("verified") ? "" : " ⚠️"))
        if unreadable > 0 { out.append("- Lines that are not audit entries: \(unreadable) ⚠️") }
        out.append("- Stops: \(stops) · takeovers: \(takeovers)")
        if let ownerRunFiles { out += Self.ownerRunSection(ownerRunFiles) }
        if let credentialFiles { out += Self.credentialSection(credentialFiles) }

        out += ["", "## Commands", ""]
        if commands.isEmpty {
            out.append("No commands ran.")
        } else {
            out += ["| Outcome | Count |", "|---|---|"]
            for key in commands.keys.sorted(by: Self.outcomeOrder) {
                out.append("| \(Self.md(key)) | \(commands[key] ?? 0) |")
            }
        }
        out.append("")
        out.append(
            "- Text typed into the shared terminal: \(terminalTexts) (the log has the text, not what the shell then ran)"
        )
        out.append(
            "- Commands that ran outside the session folder: **\(ranOutside.count)**" + (ranOutside.isEmpty ? "" : " ⚠️")
        )
        for cwd in ranOutside { out.append("  - \(Self.md(cwd))") }
        out.append("- Requests refused for reaching outside the session folder: \(refusedOutside)")

        out += ["", "## Denied and blocked", ""]
        if denials.isEmpty {
            out.append("Nothing was refused.")
        } else {
            out += ["| Rule | Count | First example |", "|---|---|---|"]
            for denial in denials {
                out.append("| \(Self.md(denial.rule)) | \(denial.count) | \(Self.md(denial.example)) |")
            }
        }

        out += ["", "## Network", ""]
        if network.isEmpty {
            out.append("No network use was recorded.")
        } else {
            out += ["| Host | Allowed | Denied | Up | Down |", "|---|---|---|---|---|"]
            for traffic in network {
                out.append(
                    "| \(Self.md(traffic.host)) | \(traffic.allowed) | \(traffic.denied) | "
                        + "\(Self.bytes(traffic.up)) | \(Self.bytes(traffic.down)) |"
                )
            }
            let unreachable = network.filter { $0.failed > 0 }
            if !unreachable.isEmpty {
                out.append("")
                out.append(
                    "Allowed but unreachable: "
                        + unreachable.map { "\(Self.md($0.host)) (\($0.failed))" }.joined(separator: ", ")
                )
            }
        }

        out += ["", "## Serial ports", ""]
        if serial.isEmpty {
            out.append("No serial port was used.")
        } else {
            out += ["| Port | Opens | Writes | Bytes written | Resets |", "|---|---|---|---|---|"]
            for use in serial {
                out.append(
                    "| \(Self.md(use.port)) | \(use.opens) | \(use.writes) | \(use.bytesWritten) | \(use.resets) |"
                )
            }
        }

        out += ["", "## Approvals", ""]
        func count(_ verdict: ApprovalTiming.Verdict) -> Int { approvals.filter { $0.verdict == verdict }.count }
        out.append(
            "- Asked: \(approvals.count) · approved \(count(.approved)) · denied \(count(.denied)) · "
                + "timed out \(count(.timedOut)) · withdrawn \(count(.withdrawn))"
        )
        let approved = approvals.filter { $0.verdict == .approved }.map(\.seconds).sorted()
        if let fastest = approved.first {
            out.append(
                "- Time to approve: median \(Self.seconds(approved[approved.count / 2])), fastest \(Self.seconds(fastest))"
            )
        }
        out.append("- Approvals under \(Int(Self.rubberStampSeconds)) s (rubber-stamped): **\(rubberStamped.count)**")
        for approval in rubberStamped {
            out.append("  - \(Self.md(approval.summary)) (\(Self.seconds(approval.seconds)))")
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// `exit 0` first, then other exits by status, then the rest by name.
    static func outcomeOrder(_ a: String, _ b: String) -> Bool {
        func key(_ text: String) -> (Int, Int, String) {
            if text.hasPrefix("exit "), let status = Int(text.dropFirst(5)) { return (status == 0 ? 0 : 1, status, "") }
            return (2, 0, text)
        }
        return key(a) < key(b)
    }

    /// `text` shown literally in a paragraph or a table cell: Markdown punctuation is backslash-escaped, and control,
    /// invisible and line-break characters are shown as `DisplayText` escapes (they are already, unless the log was
    /// edited), so nothing from the log can add structure, links or formatting.
    static func md(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if "`*_[]<>|#~!(){}".unicodeScalars.contains(scalar) {
                out += "\\" + String(scalar)
            } else {
                // Also turns a backslash into two, which Markdown shows as one.
                out += DisplayText.escape(scalar)
            }
        }
        return out
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func seconds(_ value: TimeInterval) -> String { String(format: "%.1f", value) + " s" }

    static func duration(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return total >= 3600
            ? "\(total / 3600) h \(total / 60 % 60) min"
            : total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    /// `bytes` in decimal units with one decimal: `999 B`, `1.2 KB`, `3.4 MB`.
    static func bytes(_ count: Int) -> String {
        guard count >= 1000 else { return "\(count) B" }
        var value = Double(count) / 1000
        for unit in ["KB", "MB", "GB"] {
            if value < 1000 || unit == "GB" { return String(format: "%.1f", value) + " " + unit }
            value /= 1000
        }
        return "\(count) B"
    }
}
