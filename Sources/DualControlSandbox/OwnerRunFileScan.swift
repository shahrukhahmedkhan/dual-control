#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// Finds the files in the session folder that the owner's tools run (`OwnerRunFiles`) and that changed during
    /// the session (gap 3): files the agent owns (it created them), and files whose status changed since `since`
    /// (the agent edited one of the owner's, which keeps the owner as its owner). Read as the owner, in the app.
    public enum OwnerRunFileScan {
        /// Folders not entered: package caches, large and not where anyone works. In `.git` only `hooks` is looked
        /// at; the sandbox keeps the agent out of the rest.
        static let skipped: Set<String> = ["node_modules"]

        /// Scans `root`, never following links, looking at no more than `limit` entries. `agentUID` is
        /// `claude-agent`'s uid, if it exists.
        public static func scan(root: String, since: Date?, agentUID: uid_t?, limit: Int = 50_000) -> OwnerRunScan {
            var files: [OwnerRunFile] = []
            var scanned = 0
            var incomplete = false
            let cutoff = since.map { $0.timeIntervalSince1970 } ?? .infinity

            func visit(_ folder: String, _ relative: String) {
                guard !incomplete, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                    return
                }
                for name in names.sorted() {
                    scanned += 1
                    if scanned > limit {
                        incomplete = true
                        return
                    }
                    let path = folder + "/" + name
                    let inside = relative.isEmpty ? name : relative + "/" + name
                    var info = stat()
                    guard lstat(path, &info) == 0 else { continue }
                    let lowered = name.lowercased()
                    if info.st_mode & S_IFMT == S_IFDIR {
                        if skipped.contains(lowered) { continue }
                        if lowered == ".git" {
                            visit(path + "/hooks", inside + "/hooks")
                            continue
                        }
                        visit(path, inside)
                        continue
                    }
                    guard let kind = OwnerRunFiles.kind(of: inside) else { continue }
                    let byAgent = agentUID.map { info.st_uid == $0 } ?? false
                    let changed = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9
                    if byAgent || changed >= cutoff {
                        files.append(OwnerRunFile(path: inside, kind: kind, createdByAgent: byAgent))
                    }
                }
            }
            visit(root, "")
            return OwnerRunScan(folder: root, files: files, scanned: scanned, incomplete: incomplete)
        }

        /// `claude-agent`'s uid, if the user exists.
        public static func agentUID() -> uid_t? {
            getpwnam(AgentEnvironment.user).map { $0.pointee.pw_uid }
        }
    }
#endif
