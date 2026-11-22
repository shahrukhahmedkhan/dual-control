#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import DualControlIPC
    import Foundation

    /// What the app found when it checked the previous session's audit log at launch.
    public enum PreviousSessionCheck: Sendable, Equatable {
        /// No earlier session.
        case none
        /// The log the anchor names is intact and at least as long as the anchor says.
        case verified(file: String, entries: Int)
        /// Something is missing, edited or truncated; shown as a warning.
        case broken(String)
    }

    /// The latest head of the current session's log, kept next to the logs so tail truncation can be detected.
    struct AuditAnchor: Codable, Equatable {
        /// Log file name inside `audit/`.
        var file: String
        /// Entries written so far.
        var count: Int
        /// Hash of the last entry.
        var hash: String
    }

    /// Why the audit store could not be used.
    public enum AuditStoreError: Error, Equatable, Sendable {
        /// A system call failed with this errno.
        case system(String, Int32)
        /// A file could not be read safely, and why.
        case unreadable(String)
    }

    /// Persists the audit chain: one append-only JSONL file per app session in `<base>/audit/` (directory 0700, file
    /// 0600), and the latest head in `<base>/audit-head.json` (0600), rewritten atomically after every append.
    ///
    /// At launch, before starting a new file, the log named by the anchor is verified against it. A broken log is
    /// reported, never repaired, and does not stop the new session. Not thread-safe: one owner.
    public final class AuditStore {
        /// Largest log verified at launch; anything bigger is reported instead of read.
        static let maxVerifiedBytes = 256 << 20

        /// `~/Library/Application Support/DualControl` for the current user.
        public static var defaultBase: String { (RunDirectory.defaultPath as NSString).deletingLastPathComponent }

        /// Result of checking the previous session.
        public let previous: PreviousSessionCheck
        /// This session's log file.
        public let logPath: String
        /// Head after the last successful append.
        public private(set) var lastHead: AuditHead = .genesis

        private let base: String
        private let fileName: String
        private let fd: Int32

        /// Checks the previous session, then starts this session's log and anchor. Throws if the directories are
        /// not private (wrong owner, mode or a symlink) or the files cannot be created.
        public init(base: String, sessionStart: Date) throws {
            _ = try RunDirectory.prepare(base)
            let directory = base + "/audit"
            _ = try RunDirectory.prepare(directory)
            previous = Self.checkPrevious(base: base, directory: directory)

            let stamp = Self.stamp(sessionStart)
            var attempt = 0
            while true {
                let name = attempt == 0 ? "\(stamp).jsonl" : "\(stamp)-\(attempt).jsonl"
                let fd = open(
                    directory + "/" + name,
                    O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                if fd >= 0 {
                    self.fd = fd
                    fileName = name
                    logPath = directory + "/" + name
                    break
                }
                guard errno == EEXIST, attempt < 100 else { throw AuditStoreError.system("open log", errno) }
                attempt += 1
            }
            self.base = base
            // open applies the umask; make the mode exact. Every stored property is set, so a throw from here on
            // runs deinit, which closes fd; closing it here too could close a number already reused elsewhere.
            guard fchmod(fd, 0o600) == 0 else { throw AuditStoreError.system("fchmod log", errno) }
            try writeAnchor(.genesis)
        }

        deinit { close(fd) }

        /// Appends lines from `Supervisor.drainAuditLines()`, syncs them, then records `head` as the new anchor.
        public func append(_ lines: [String], head: AuditHead) throws {
            guard !lines.isEmpty else { return }
            try Self.writeAll(fd, Data((lines.joined(separator: "\n") + "\n").utf8), what: "write log")
            guard fsync(fd) == 0 else { throw AuditStoreError.system("fsync log", errno) }
            try writeAnchor(head)
            lastHead = head
        }

        /// This session's log as written so far, one entry per line, for the session report.
        public func lines() throws -> [String] {
            switch Self.readPrivateFile(logPath, maxBytes: Self.maxVerifiedBytes) {
            case .missing: throw AuditStoreError.system("read log", ENOENT)
            case .failed(let reason): throw AuditStoreError.unreadable(reason)
            case .data(let data):
                let text = String(decoding: data, as: UTF8.self)
                guard !text.isEmpty else { return [] }
                return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            }
        }

        /// Saves a session report next to this session's log as `<log>.report-<entries>.md` (0600), or with a
        /// number added if that name exists, and returns its path. Never follows or replaces an existing file.
        public func writeReport(_ markdown: String, entries: Int) throws -> String {
            let stem = (logPath as NSString).deletingPathExtension + ".report-\(entries)"
            for attempt in 0..<100 {
                let path = stem + (attempt == 0 ? "" : "-\(attempt)") + ".md"
                let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                if fd < 0 {
                    guard errno == EEXIST else { throw AuditStoreError.system("open report", errno) }
                    continue
                }
                defer { close(fd) }
                guard fchmod(fd, 0o600) == 0 else { throw AuditStoreError.system("fchmod report", errno) }
                try Self.writeAll(fd, Data(markdown.utf8), what: "write report")
                guard fsync(fd) == 0 else { throw AuditStoreError.system("fsync report", errno) }
                return path
            }
            throw AuditStoreError.system("open report", EEXIST)
        }

        private func writeAnchor(_ head: AuditHead) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(AuditAnchor(file: fileName, count: head.count, hash: head.hash))
            let path = base + "/audit-head.json"
            let temporary = path + ".tmp"
            unlink(temporary)
            let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw AuditStoreError.system("open anchor", errno) }
            defer { close(fd) }
            guard fchmod(fd, 0o600) == 0 else { throw AuditStoreError.system("fchmod anchor", errno) }
            try Self.writeAll(fd, data, what: "write anchor")
            guard fsync(fd) == 0 else { throw AuditStoreError.system("fsync anchor", errno) }
            guard rename(temporary, path) == 0 else { throw AuditStoreError.system("rename anchor", errno) }
        }

        static func checkPrevious(base: String, directory: String) -> PreviousSessionCheck {
            let anchorData: Data
            switch readPrivateFile(base + "/audit-head.json", maxBytes: 4096) {
            case .missing:
                let logs = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                return logs.contains { $0.hasSuffix(".jsonl") }
                    ? .broken("The audit anchor is missing, but earlier audit logs exist.") : .none
            case .failed(let reason):
                return .broken("The audit anchor could not be read: \(reason).")
            case .data(let data):
                anchorData = data
            }
            guard let anchor = try? JSONDecoder().decode(AuditAnchor.self, from: anchorData), anchor.count >= 0
            else { return .broken("The audit anchor is not valid.") }
            let name = anchor.file
            guard name.hasSuffix(".jsonl"), !name.hasPrefix("."), !name.contains("/"), !name.contains("\0") else {
                return .broken("The audit anchor names an invalid file.")
            }
            let shown = DisplayText.escaped(name)

            let data: Data
            switch readPrivateFile(directory + "/" + name, maxBytes: maxVerifiedBytes) {
            case .missing: return .broken("The previous audit log \(shown) is missing.")
            case .failed(let reason): return .broken("The previous audit log \(shown) could not be read: \(reason).")
            case .data(let contents): data = contents
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .broken("The previous audit log \(shown) is not valid text.")
            }
            guard text.isEmpty || text.hasSuffix("\n") else {
                return .broken("The previous audit log \(shown) ends with an incomplete line.")
            }
            let lines =
                text.isEmpty
                ? [] : text.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if case .invalid(let line, let reason) = AuditLog.verify(lines) {
                return .broken("The previous audit log \(shown) is broken at line \(line + 1): \(reason).")
            }
            guard lines.count >= anchor.count,
                AuditLog.verify(Array(lines.prefix(anchor.count)))
                    == .valid(AuditHead(count: anchor.count, hash: anchor.hash))
            else {
                return .broken(
                    "The previous audit log \(shown) does not match its anchor (entries: \(lines.count), "
                        + "anchor: \(anchor.count)): entries were removed or replaced."
                )
            }
            return .verified(file: name, entries: lines.count)
        }

        enum ReadResult {
            case missing
            case failed(String)
            case data(Data)
        }

        /// Reads a regular file owned by this user, refusing symlinks and files over `maxBytes`.
        static func readPrivateFile(_ path: String, maxBytes: Int) -> ReadResult {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                if errno == ENOENT { return .missing }
                return errno == ELOOP ? .failed("it is a symlink") : .failed(String(cString: strerror(errno)))
            }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { return .failed(String(cString: strerror(errno))) }
            guard info.st_mode & S_IFMT == S_IFREG else { return .failed("not a regular file") }
            guard info.st_uid == getuid() else { return .failed("owned by another user") }
            guard info.st_size <= maxBytes else { return .failed("larger than \(maxBytes) bytes") }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return .failed(String(cString: strerror(errno)))
                }
                if count == 0 { break }
                data.append(contentsOf: buffer[0..<count])
                guard data.count <= maxBytes else { return .failed("larger than \(maxBytes) bytes") }
            }
            return .data(data)
        }

        static func writeAll(_ fd: Int32, _ data: Data, what: String) throws {
            try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < bytes.count {
                    let written = write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw AuditStoreError.system(what, errno)
                    }
                    offset += written
                }
            }
        }

        /// File-name-safe UTC timestamp, e.g. `2027-01-15T08-00-00Z`.
        static func stamp(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
            return formatter.string(from: date)
        }
    }
#endif
