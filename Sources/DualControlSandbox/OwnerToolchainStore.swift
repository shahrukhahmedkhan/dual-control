#if canImport(Darwin)
    import CryptoKit
    import Darwin
    import DualControlCore
    import Foundation

    /// What happened to a finished `esp_idf_install`: the install it was copied to, and its hash or why not.
    public struct ToolchainCopy: Sendable, Equatable {
        /// The install folder in the owner's toolchain folder.
        public let install: String
        /// SHA-256 (hex) of its manifest, if it was copied and checked.
        public let digest: String?
        /// Why it was not, otherwise.
        public let problem: String?
    }

    extension Sandbox {
        /// After an `esp_idf_install` job: if it ended well, copies the staging folder into the owner's toolchain
        /// folder as the owner (`OwnerToolchainStore.replace`), and says so in the outcome. Anything else is returned
        /// as it is, with no copy.
        public func finishToolchain(_ launch: Launch, _ outcome: CommandOutcome) -> (CommandOutcome, ToolchainCopy?) {
            guard let version = launch.toolchain, !launch.readOnly, outcome.status == 0, !outcome.killed else {
                return (outcome, nil)
            }
            let store = OwnerToolchainStore(scope: scope, denyACLUser: runAs.isEmpty ? nil : AgentEnvironment.user)
            let install = scope.toolchains + "/" + OwnerToolchain.installName(version: version)
            var finished = outcome
            let note: String
            let copy: ToolchainCopy
            switch store.replace(install, version: version, sandboxExec: sandboxExec) {
            case .success(let digest):
                note =
                    "\nDual Control: copied to \(install), which you can read but not write. Flashers are recognised "
                    + "only there. SHA-256 \(digest).\n"
                copy = ToolchainCopy(install: install, digest: digest, problem: nil)
            case .failure(let problem):
                if finished.status == 0 { finished.status = 1 }
                note = "\nDual Control: the install was not copied: \(problem.description).\n"
                copy = ToolchainCopy(install: install, digest: nil, problem: problem.description)
            }
            finished.output += note
            if finished.tail != nil { finished.tail? += note }
            return (finished, copy)
        }

        /// Why the install a flasher runs from cannot be trusted, or `nil`: it must be an install in the owner's
        /// toolchain folder that still matches its recorded hash (`OwnerToolchainStore.verify`).
        func toolchainProblem(for argv: [String]) -> String? {
            guard let install = FlasherCommand.install(of: argv, scope: scope, resolve: RealPath.resolve) else {
                return "it does not run from an install in the toolchain folder"
            }
            let store = OwnerToolchainStore(scope: scope, denyACLUser: nil)
            if case .failure(let problem) = store.verify(install) { return problem.description }
            return nil
        }
    }

    /// The owner's toolchain folder on disk (`OwnerToolchain`). Everything here runs as the owner, in the app.
    struct OwnerToolchainStore {
        /// Why an install cannot be copied or used.
        struct Problem: Error, Equatable, CustomStringConvertible {
            let description: String
        }

        /// The ACL entry that keeps the agent from changing anything in the toolchain folder, inherited by
        /// everything made in it. Unix permissions already leave the agent only reading.
        static let denyRights =
            "add_file,add_subdirectory,delete_child,write,append,delete,writeattr,writeextattr,writesecurity,chown,"
            + "file_inherit,directory_inherit"
        /// The largest file read whole to look for paths in it.
        static let maxScannedBytes = 1 << 30

        let scope: SessionScope
        /// The user the deny ACL names; `nil` (tests) adds none.
        let denyACLUser: String?

        // MARK: - Copying

        /// Copies the staging folder to `install`, replacing an earlier install there only once the new one passed
        /// its checks, and records its hash next to it. The digest, or why not; on failure nothing new is left
        /// behind and an earlier install is back in place.
        func replace(_ install: String, version: String, sandboxExec: String) -> Result<String, Problem> {
            if let problem = prepareRoot() { return .failure(problem) }
            let name = OwnerToolchain.installName(version: version)
            let old = scope.toolchains + "/.replaced-\(name)-\(UInt32.random(in: .min ... .max))"
            let hashFile = OwnerToolchain.hashFile(of: install)
            unlink(hashFile)
            Self.forget(install)
            var hadOld = false
            if exists(install) {
                guard rename(install, old) == 0 else {
                    return .failure(Problem(description: "the earlier install cannot be moved aside"))
                }
                hadOld = true
            }
            func undo(_ problem: Problem) -> Result<String, Problem> {
                _ = Subprocess.run(["/bin/rm", "-rf", "--", install])
                if hadOld { rename(old, install) }
                return .failure(problem)
            }
            guard mkdir(install, 0o755) == 0 else {
                return undo(Problem(description: "the install folder cannot be made"))
            }
            if let problem = copy(into: install, sandboxExec: sandboxExec) { return undo(problem) }
            if let problem = writeVersion(version, install: install) { return undo(problem) }
            if let problem = normalise(install) { return undo(problem) }
            switch digest(install) {
            case .failure(let problem):
                return undo(problem)
            case .success(let digest):
                guard write(digest + "\n", to: hashFile) else {
                    return undo(Problem(description: "its hash cannot be recorded"))
                }
                if hadOld { _ = Subprocess.run(["/bin/rm", "-rf", "--", old]) }
                return .success(digest)
            }
        }

        /// The toolchain folder: made if missing, a real folder of the owner's that only the owner may write, with
        /// no ACL but the agent's deny entry (an ACL inherited from the Developer folder would let the agent in).
        func prepareRoot() -> Problem? {
            Self.prepareOwnerFolder(scope.toolchains, name: "the toolchain folder", denyACLUser: denyACLUser)
        }

        /// `root` (called `name` in problems): made if missing, a real folder of the owner's that only the owner may
        /// write, with no ACL but `denyACLUser`'s deny entry. Also the `git_sync` folder (D13a).
        static func prepareOwnerFolder(_ root: String, name: String, denyACLUser: String?) -> Problem? {
            var info = stat()
            if lstat(root, &info) != 0, mkdir(root, 0o755) != 0 {
                return Problem(description: "\(name) cannot be made")
            }
            guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                return Problem(description: "\(name) is not a folder of the owner's")
            }
            guard chmod(root, 0o755) == 0, Subprocess.run(["/bin/chmod", "-N", root])?.status == 0 else {
                return Problem(description: "\(name)'s permissions cannot be set")
            }
            if let user = denyACLUser {
                guard Subprocess.run(["/bin/chmod", "+a", "\(user) deny \(Self.denyRights)", root])?.status == 0 else {
                    return Problem(description: "\(name)'s deny entry cannot be set")
                }
            }
            return nil
        }

        /// The staging folder's install folders, copied by bsdtar in `SandboxProfile.toolchainCopy`: links are
        /// copied as links, never followed, set-id bits are dropped, git's files, byte code and archives are left out.
        func copy(into install: String, sandboxExec: String) -> Problem? {
            let profile: String
            do {
                profile = try SandboxProfile.toolchainCopy(scope: scope, install: install)
            } catch {
                return Problem(description: "the copy's sandbox profile cannot be made")
            }
            let excludes = OwnerToolchain.excludedPatterns.map { "--exclude '\($0)'" }.joined(separator: " ")
            let script =
                #"cd "$1" && /usr/bin/tar -c -f - \#(excludes) "# + OwnerToolchain.copiedFolders.joined(separator: " ")
                + #" | /usr/bin/tar -x -f - -C "$2" --no-same-owner --no-acls --no-xattrs --no-fflags"#
            let argv = [sandboxExec, "-p", profile, "/bin/sh", "-c", script, "copy", scope.toolchainStaging, install]
            guard let run = Subprocess.run(argv), run.status == 0 else {
                return Problem(description: "the copy failed")
            }
            return nil
        }

        /// `idf/version.txt`: how ESP-IDF names its version without git, whose files are not copied.
        func writeVersion(_ version: String, install: String) -> Problem? {
            let path = install + "/" + OwnerToolchain.idfFolder + "/version.txt"
            unlink(path)
            return write(version + "\n", to: path) ? nil : Problem(description: "version.txt cannot be written")
        }

        /// Makes the copy the owner's alone and points it at itself: folders 0755, files 0755 or 0644; the staging
        /// folder's path in text files and links becomes the install's; links that lead nowhere are removed, and
        /// every other link must resolve into the install or `OwnerToolchain.linkRoots`. Anything else that still
        /// names the staging folder or the agent's HOME or TMPDIR, or that is not a folder, file or link, fails it.
        func normalise(_ install: String) -> Problem? {
            let staging = scope.toolchainStaging
            let agentPaths = [staging + "/", scope.agentHome + "/", scope.agentTmp + "/"]
            var problem: Problem?
            walk(install) { path, info in
                let shown = DisplayText.summary(String(path.dropFirst(install.count + 1)), limit: 160)
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    if chmod(path, 0o755) != 0 { problem = Problem(description: "\(shown) cannot be locked") }
                case S_IFREG:
                    guard chmod(path, info.st_mode & 0o111 == 0 ? 0o644 : 0o755) == 0 else {
                        problem = Problem(description: "\(shown) cannot be locked")
                        break
                    }
                    guard info.st_size <= Self.maxScannedBytes,
                        let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
                    else {
                        problem = Problem(description: "\(shown) cannot be read")
                        break
                    }
                    var bytes = data
                    if Self.contains(data, staging + "/"),
                        let moved = OwnerToolchain.relocated([UInt8](data), from: staging, to: install)
                    {
                        bytes = Data(moved)
                        guard replaceFile(path, with: bytes) else {
                            problem = Problem(description: "\(shown) cannot be rewritten")
                            break
                        }
                    }
                    if agentPaths.contains(where: { Self.contains(bytes, $0) }) {
                        problem = Problem(description: "\(shown) names the agent's folders")
                    }
                case S_IFLNK:
                    guard var target = Self.linkTarget(path) else {
                        problem = Problem(description: "\(shown) cannot be read")
                        break
                    }
                    if let moved = OwnerToolchain.relocatedLink(target, from: staging, to: install) {
                        guard unlink(path) == 0, symlink(moved, path) == 0 else {
                            problem = Problem(description: "\(shown) cannot be rewritten")
                            break
                        }
                        target = moved
                    }
                    guard let real = RealPath.resolve(path) else {
                        if unlink(path) != 0 { problem = Problem(description: "\(shown) leads nowhere") }
                        break
                    }
                    if !OwnerToolchain.mayLink(to: real, install: install) {
                        problem = Problem(description: "\(shown) leads out of the install")
                    }
                default:
                    problem = Problem(description: "\(shown) is not a file, folder or link")
                }
                return problem == nil
            }
            return problem
        }

        // MARK: - Checking

        /// SHA-256 (hex) of `install`'s manifest (`OwnerToolchain.manifestLine`, in walk order), after checking that
        /// every entry is the owner's, writable by nobody else, without set-id bits and without an ACL entry that
        /// allows anything.
        func digest(_ install: String) -> Result<String, Problem> {
            var manifest = SHA256()
            var problem: Problem?
            let owner = getuid()
            if let rootProblem = Self.lockProblem(scope.toolchains, owner: owner) { return .failure(rootProblem) }
            if let installProblem = Self.lockProblem(install, owner: owner) { return .failure(installProblem) }
            walk(install) { path, info in
                let relative = String(path.dropFirst(install.count + 1))
                if let found = Self.lockProblem(path, owner: owner, info: info) {
                    problem = found
                    return false
                }
                let mode = UInt16(info.st_mode & 0o7777)
                let line: String
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    line = OwnerToolchain.manifestLine(kind: "d", path: relative, mode: mode, value: "")
                case S_IFREG:
                    guard let hash = Self.fileHash(path) else {
                        problem = Problem(description: "\(DisplayText.summary(relative, limit: 160)) cannot be read")
                        return false
                    }
                    line = OwnerToolchain.manifestLine(kind: "f", path: relative, mode: mode, value: hash)
                case S_IFLNK:
                    line = OwnerToolchain.manifestLine(
                        kind: "l",
                        path: relative,
                        mode: 0,
                        value: Self.linkTarget(path) ?? ""
                    )
                default:
                    problem = Problem(
                        description: "\(DisplayText.summary(relative, limit: 160)) is not a file, folder or link"
                    )
                    return false
                }
                manifest.update(data: Data(line.utf8))
                return true
            }
            if let problem { return .failure(problem) }
            return .success(manifest.finalize().map { String(format: "%02x", $0) }.joined())
        }

        /// `.success` with the digest if `install` still matches the hash recorded next to it. Checked once per
        /// install while the app runs; a new copy forgets it.
        func verify(_ install: String) -> Result<String, Problem> {
            if let known = Self.verified(install) { return .success(known) }
            let hashFile = OwnerToolchain.hashFile(of: install)
            var info = stat()
            guard lstat(hashFile, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                info.st_mode & 0o022 == 0,
                let recorded = try? String(contentsOfFile: hashFile, encoding: .utf8)
            else {
                return .failure(
                    Problem(description: "\(install) has no recorded hash; install it with esp_idf_install")
                )
            }
            switch digest(install) {
            case .failure(let problem):
                return .failure(problem)
            case .success(let digest):
                guard digest == recorded.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return .failure(Problem(description: "\(install) no longer matches its recorded hash"))
                }
                Self.remember(install, digest)
                return .success(digest)
            }
        }

        /// Why `path` is not locked for the owner `owner`, or `nil`.
        static func lockProblem(_ path: String, owner: uid_t, info known: stat? = nil) -> Problem? {
            var info = known ?? stat()
            if known == nil, lstat(path, &info) != 0 { return Problem(description: "\(path) is missing") }
            let shown = DisplayText.summary(path, limit: 200)
            guard info.st_uid == owner else { return Problem(description: "\(shown) is not the owner's") }
            let type = info.st_mode & S_IFMT
            guard type == S_IFLNK || (info.st_mode & 0o022 == 0 && info.st_mode & 0o7000 == 0) else {
                return Problem(description: "\(shown) is writable by others or set-id")
            }
            if type != S_IFLNK, hasAllowingACL(path) {
                return Problem(description: "\(shown) has an ACL entry that allows access")
            }
            return nil
        }

        /// True if `path` has an ACL entry that allows anything (the agent's deny entry is the only kind expected).
        static func hasAllowingACL(_ path: String) -> Bool {
            guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            var which = ACL_FIRST_ENTRY.rawValue
            while acl_get_entry(acl, Int32(which), &entry) == 0, let current = entry {
                var tag = ACL_UNDEFINED_TAG
                if acl_get_tag_type(current, &tag) != 0 || tag != ACL_EXTENDED_DENY { return true }
                which = ACL_NEXT_ENTRY.rawValue
            }
            return false
        }

        // MARK: - Files

        /// Calls `visit` for everything under `folder`, sorted by name, folders before what is in them, never
        /// following links; stops when it returns false.
        @discardableResult
        func walk(_ folder: String, _ visit: (String, stat) -> Bool) -> Bool {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return false }
            for name in names.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                let path = folder + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0, visit(path, info) else { return false }
                if info.st_mode & S_IFMT == S_IFDIR, !walk(path, visit) { return false }
            }
            return true
        }

        static func contains(_ data: Data, _ text: String) -> Bool {
            let needle = Array(text.utf8)
            return data.withUnsafeBytes { buffer in
                needle.withUnsafeBytes { memmem(buffer.baseAddress, buffer.count, $0.baseAddress, $0.count) != nil }
            }
        }

        static func linkTarget(_ path: String) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(path, &buffer, Int(PATH_MAX))
            guard length > 0 else { return nil }
            return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        static func fileHash(_ path: String) -> String? {
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 { return nil }
                if count == 0 { break }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        /// Replaces `path`'s content, keeping its mode: a new file next to it, renamed over it.
        func replaceFile(_ path: String, with data: Data) -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            let temporary = path + ".dc-\(UInt32.random(in: .min ... .max))"
            guard write(data, to: temporary, mode: info.st_mode & 0o777) else { return false }
            guard rename(temporary, path) == 0 else {
                unlink(temporary)
                return false
            }
            return true
        }

        /// Writes a new file (never through a link, never over one), 0644 unless `mode` says otherwise.
        func write(_ text: String, to path: String) -> Bool {
            write(Data(text.utf8), to: path, mode: 0o644)
        }

        func write(_ data: Data, to path: String, mode: mode_t) -> Bool {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            return written == data.count && fchmod(fd, mode) == 0
        }

        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }

        // MARK: - Verified installs

        static func verified(_ install: String) -> String? { VerifiedToolchains.shared.digest(install) }
        static func remember(_ install: String, _ digest: String) { VerifiedToolchains.shared.set(install, digest) }
        static func forget(_ install: String) { VerifiedToolchains.shared.set(install, nil) }
    }

    /// Installs that matched their recorded hash while the app runs.
    final class VerifiedToolchains: @unchecked Sendable {
        static let shared = VerifiedToolchains()
        private let lock = NSLock()
        private var digests: [String: String] = [:]

        func digest(_ install: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return digests[install]
        }

        func set(_ install: String, _ digest: String?) {
            lock.lock()
            defer { lock.unlock() }
            digests[install] = digest
        }
    }
#endif
