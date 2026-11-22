#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// Finds the files in the session folder and the agent's home that changed this session and look like credentials
    /// (D12d, `CredentialFiles`). Read as the owner, in the app: never following links, only regular files, only
    /// their first bytes. An entry changed this session that the owner cannot read is listed as such.
    public enum CredentialFileScan {
        /// Folders not entered: package caches, and git's object store (compressed, and the agent's commits are
        /// reviewed anyway).
        static let skipped: Set<String> = ["node_modules", ".git"]

        /// Scans `scope`'s session folder and agent home for entries changed at or after `since` (everything if
        /// `nil`), looking at no more than `limit` entries in all.
        public static func scan(scope: SessionScope, since: Date?, limit: Int = 100_000) -> CredentialScan {
            var files: [CredentialFile] = []
            var unreadable: [CredentialFile] = []
            var scanned = 0
            var incomplete = false
            let cutoff = since.map { $0.timeIntervalSince1970 } ?? -.infinity

            func changed(_ info: stat) -> Bool {
                Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9 >= cutoff
            }

            func visit(_ folder: String, _ relative: String, _ place: CredentialFile.Place) {
                guard !incomplete else { return }
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                    var info = stat()
                    if !relative.isEmpty, lstat(folder, &info) == 0, changed(info) {
                        unreadable.append(CredentialFile(place: place, path: relative, kinds: []))
                    }
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
                    if CredentialFiles.isExcluded(inside, inAgentHome: place == .agentHome) { continue }
                    var info = stat()
                    guard lstat(path, &info) == 0 else { continue }
                    switch info.st_mode & S_IFMT {
                    case S_IFDIR:
                        if !skipped.contains(name.lowercased()) { visit(path, inside, place) }
                    case S_IFREG where changed(info):
                        let head = readHead(path)
                        let kinds = CredentialFiles.kinds(path: inside, head: head ?? [])
                        if !kinds.isEmpty {
                            files.append(CredentialFile(place: place, path: inside, kinds: kinds))
                        } else if head == nil {
                            unreadable.append(CredentialFile(place: place, path: inside, kinds: []))
                        }
                    default:
                        continue
                    }
                }
            }
            visit(scope.root, "", .sessionFolder)
            visit(scope.agentHome, "", .agentHome)
            return CredentialScan(files: files, unreadable: unreadable, scanned: scanned, incomplete: incomplete)
        }

        /// The first `CredentialFiles.headBytes` of a regular file, or `nil` if the owner cannot read it. Opened
        /// without following a link and without blocking, in case it was swapped since `lstat`.
        static func readHead(_ path: String) -> [UInt8]? {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            var buffer = [UInt8](repeating: 0, count: CredentialFiles.headBytes)
            var total = 0
            while total < buffer.count {
                let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let start = bytes.baseAddress else { return 0 }
                    return read(fd, start + total, bytes.count - total)
                }
                if count <= 0 { break }
                total += count
            }
            return Array(buffer.prefix(total))
        }
    }
#endif
