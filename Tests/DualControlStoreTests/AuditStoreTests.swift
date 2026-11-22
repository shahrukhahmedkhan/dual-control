#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlStore

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryBase() throws -> String {
        var template = Array("/tmp/dc-audit-XXXXXX".utf8CString)
        let root = try #require(mkdtemp(&template).map { String(cString: $0) })
        return root + "/DualControl"
    }

    private func mode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    /// A session that records `count` decisions, as the app would.
    @discardableResult
    private func runSession(base: String, at time: Date, entries count: Int = 3) throws -> AuditStore {
        let store = try AuditStore(base: base, sessionStart: time)
        var supervisor = Supervisor()
        for index in 0..<count {
            _ = supervisor.submit(
                IPCRequest(
                    id: "\(index)",
                    tool: "run_command",
                    arguments: ["argv": .array([.string("ls")]), "cwd": .string("/w")]
                ),
                now: time
            )
        }
        try store.append(supervisor.drainAuditLines(), head: supervisor.auditHead)
        return store
    }

    private func isBroken(_ check: PreviousSessionCheck) -> Bool {
        if case .broken = check { return true }
        return false
    }

    @Test func firstLaunchCreatesPrivateFiles() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        let store = try runSession(base: base, at: start)
        #expect(store.previous == .none)
        #expect(mode(base) == 0o700)
        #expect(mode(base + "/audit") == 0o700)
        #expect(mode(store.logPath) == 0o600)
        #expect(mode(base + "/audit-head.json") == 0o600)
        #expect(store.logPath.hasSuffix(".jsonl"))
        let lines = try String(contentsOfFile: store.logPath, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(AuditLog.verify(lines) == .valid(try #require(store.lastHead)))
    }

    @Test func nextLaunchVerifiesThePreviousSession() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        let first = try runSession(base: base, at: start)
        let second = try runSession(base: base, at: start.addingTimeInterval(60))
        #expect(second.previous == .verified(file: (first.logPath as NSString).lastPathComponent, entries: 3))
        #expect(second.logPath != first.logPath)
        let third = try AuditStore(base: base, sessionStart: start.addingTimeInterval(120))
        #expect(third.previous == .verified(file: (second.logPath as NSString).lastPathComponent, entries: 3))
    }

    @Test func sameSecondLaunchesGetSeparateFiles() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        let first = try runSession(base: base, at: start)
        let second = try runSession(base: base, at: start)
        #expect(first.logPath != second.logPath)
        #expect(second.previous == .verified(file: (first.logPath as NSString).lastPathComponent, entries: 3))
    }

    @Test func emptySessionVerifies() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        let first = try AuditStore(base: base, sessionStart: start)
        let second = try AuditStore(base: base, sessionStart: start.addingTimeInterval(1))
        #expect(second.previous == .verified(file: (first.logPath as NSString).lastPathComponent, entries: 0))
    }

    /// Tampering with the previous session's files, and whether the next launch must report it.
    @Test(
        arguments: [
            "truncate-tail", "edit-line", "drop-first", "partial-line", "delete-log", "delete-anchor",
            "anchor-garbage", "anchor-escapes", "symlink-log",
        ]
    )
    func tamperingIsReported(_ tamper: String) throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        let first = try runSession(base: base, at: start)
        let log = first.logPath
        let anchor = base + "/audit-head.json"
        var lines = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        func rewrite(_ text: String) throws { try text.write(toFile: log, atomically: false, encoding: .utf8) }
        switch tamper {
        case "truncate-tail":
            try rewrite(lines.dropLast().map { $0 + "\n" }.joined())
        case "edit-line":
            lines[1] = lines[1].replacingOccurrences(of: "\"ls\"", with: "\"rm\"")
            try rewrite(lines.map { $0 + "\n" }.joined())
        case "drop-first":
            try rewrite(lines.dropFirst().map { $0 + "\n" }.joined())
        case "partial-line":
            try rewrite(lines.map { $0 + "\n" }.joined() + "{\"seq\":")
        case "delete-log":
            try FileManager.default.removeItem(atPath: log)
        case "delete-anchor":
            try FileManager.default.removeItem(atPath: anchor)
        case "anchor-garbage":
            try "not json".write(toFile: anchor, atomically: false, encoding: .utf8)
        case "anchor-escapes":
            let escaping = #"{"count":0,"file":"../audit-head.json","hash":"\#(AuditHead.genesis.hash)"}"#
            try escaping.write(toFile: anchor, atomically: false, encoding: .utf8)
        case "symlink-log":
            let moved = log + ".real"
            try FileManager.default.moveItem(atPath: log, toPath: moved)
            try FileManager.default.createSymbolicLink(atPath: log, withDestinationPath: moved)
        default:
            Issue.record("unknown tamper \(tamper)")
        }
        let second = try AuditStore(base: base, sessionStart: start.addingTimeInterval(60))
        #expect(isBroken(second.previous), "\(tamper): \(second.previous)")
        // The new session still starts and gets a fresh anchor.
        let third = try AuditStore(base: base, sessionStart: start.addingTimeInterval(120))
        #expect(third.previous == .verified(file: (second.logPath as NSString).lastPathComponent, entries: 0))
    }

    @Test func extraValidLinesAfterTheAnchorAreAccepted() throws {
        // A crash between writing the log and the anchor leaves the anchor one write behind.
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        let store = try AuditStore(base: base, sessionStart: start)
        var supervisor = Supervisor()
        _ = supervisor.submit(IPCRequest(id: "s", tool: "status"), now: start)
        try store.append(supervisor.drainAuditLines(), head: supervisor.auditHead)
        _ = supervisor.submit(IPCRequest(id: "s", tool: "status"), now: start)
        let lines = supervisor.drainAuditLines()
        let handle = try #require(FileHandle(forWritingAtPath: store.logPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        let next = try AuditStore(base: base, sessionStart: start.addingTimeInterval(1))
        #expect(next.previous == .verified(file: (store.logPath as NSString).lastPathComponent, entries: 2))
    }

    @Test func logsWithoutAnyAnchorAreReported() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        try runSession(base: base, at: start)
        try FileManager.default.removeItem(atPath: base + "/audit-head.json")
        let next = try AuditStore(base: base, sessionStart: start.addingTimeInterval(1))
        #expect(isBroken(next.previous))
    }

    @Test(arguments: ["", "/audit"])
    func unsafeDirectoriesAreRefused(_ sub: String) throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        try runSession(base: base, at: start)
        #expect(chmod(base + sub, 0o755) == 0)
        #expect(throws: (any Error).self) { try AuditStore(base: base, sessionStart: start.addingTimeInterval(1)) }
    }

    @Test func appendWritesAnchorAfterTheLines() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        let store = try AuditStore(base: base, sessionStart: start)
        #expect(store.lastHead == .genesis)
        var supervisor = Supervisor()
        supervisor.recordSessionStart(detail: "test", now: start)
        try store.append(supervisor.drainAuditLines(), head: supervisor.auditHead)
        #expect(store.lastHead == supervisor.auditHead)
        let anchor = try JSONDecoder().decode(
            AuditAnchor.self,
            from: Data(contentsOf: URL(fileURLWithPath: base + "/audit-head.json"))
        )
        #expect(anchor.count == 1)
        #expect(anchor.hash == supervisor.auditHead.hash)
        try store.append([], head: supervisor.auditHead)
        #expect(store.lastHead == supervisor.auditHead)
    }

    @Test func theSessionReportIsReadFromTheLogAndSavedNextToIt() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        let store = try runSession(base: base, at: start, entries: 3)
        let lines = try store.lines()
        #expect(lines.count == 3)
        #expect(AuditLog.verify(lines) == .valid(store.lastHead))

        let path = try store.writeReport("# report\n", entries: 3)
        #expect(path == (store.logPath as NSString).deletingPathExtension + ".report-3.md")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# report\n")
        #expect(mode(path) == 0o600)
        // A second report for the same entries gets its own file; nothing is overwritten.
        let again = try store.writeReport("# again\n", entries: 3)
        #expect(again != path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# report\n")
        // Reports are not logs: the next launch still verifies the previous log.
        _ = try runSession(base: base, at: start.addingTimeInterval(60))
        let next = try AuditStore(base: base, sessionStart: start.addingTimeInterval(120))
        guard case .verified(let file, 3) = next.previous else {
            Issue.record("expected the previous log to verify, got \(next.previous)")
            return
        }
        #expect(file.hasSuffix(".jsonl"))
    }

    @Test func aReportNeverFollowsASymlink() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        let store = try runSession(base: base, at: start)
        let target = (base as NSString).deletingLastPathComponent + "/elsewhere.md"
        let planted = (store.logPath as NSString).deletingPathExtension + ".report-3.md"
        #expect(symlink(target, planted) == 0)
        let path = try store.writeReport("# report\n", entries: 3)
        #expect(path != planted)
        #expect(!FileManager.default.fileExists(atPath: target))
    }
#endif
