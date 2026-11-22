#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// The owner's side of `git_sync` (D13a, `GitSync`): the remote is fetched with the owner's git, SSH and
    /// credentials, never inside the agent's repository, and handed to the agent as a git bundle in the sync folder.
    extension OwnerPush {
        /// A bundle of the remote's branches, waiting for the agent's script. `discard` removes it.
        public struct SyncBundle: Sendable, Equatable {
            /// The bundle's own folder in the sync folder.
            public let folder: String
            /// The bundle file.
            public let bundle: String
            /// The remote's default branch.
            public let defaultBranch: String
            /// The remote it came from.
            public let remote: String
        }

        /// The largest bundle handed to the agent.
        public static let maxBundleBytes: off_t = 2 << 30

        /// Makes `root` (`SessionScope.gitSync`) a folder only the owner may write, which the agent can read.
        public static func prepareSyncFolder(_ root: String, denyACLUser: String?) -> Problem? {
            OwnerToolchainStore.prepareOwnerFolder(root, name: "the git_sync folder", denyACLUser: denyACLUser)
                .map { Problem(description: $0.description) }
        }

        /// Fetches `repository`'s remote into a fresh scratch repository (every object checked) and writes all its
        /// branches as a bundle into a new folder in `root`, which `prepareSyncFolder` made. The folder and the file
        /// are made through descriptors (no links followed, the file new), so nothing the agent placed is written to.
        public func syncBundle(repository: String, root: String) -> Result<SyncBundle, Problem> {
            let remote: String
            switch origin(of: repository) {
            case .failure(let problem): return .failure(problem)
            case .success(let url): remote = url
            }
            let listing = run(protocols + ["ls-remote", "--symref", "--", remote, "HEAD"])
            guard let listed = listing, listed.status == 0 else {
                return .failure(Problem(description: "the remote could not be reached" + Self.because(listing?.err)))
            }
            guard let defaultBranch = GitReview.parseLsRemote(listed.out, branch: "").defaultBranch,
                GitSync.isDefaultBranch(defaultBranch)
            else { return .failure(Problem(description: "the remote names no default branch")) }

            var template = Array((scratch + "/sync-XXXXXX").utf8CString)
            guard let made = mkdtemp(&template).map({ String(cString: $0) }) else {
                return .failure(Problem(description: "the scratch repository cannot be made"))
            }
            defer { _ = try? FileManager.default.removeItem(atPath: made) }
            let local = ["-C", made]
            guard run(["init", "--bare", "--quiet", "--template=", made])?.status == 0 else {
                return .failure(Problem(description: "the scratch repository cannot be made"))
            }
            let fetched = run(
                local + protocols + ["-c", "transfer.fsckObjects=true"]
                    + [
                        "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--", remote,
                        "+refs/heads/*:refs/heads/*",
                    ]
            )
            guard let fetched, fetched.status == 0 else {
                return .failure(Problem(description: "the remote could not be fetched" + Self.because(fetched?.err)))
            }
            guard run(local + ["rev-parse", "--verify", "--quiet", "refs/heads/" + defaultBranch])?.status == 0 else {
                return .failure(Problem(description: "the remote has no branch \(defaultBranch)"))
            }

            let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { return .failure(Problem(description: "the git_sync folder cannot be opened")) }
            defer { close(rootFD) }
            var info = stat()
            guard fstat(rootFD, &info) == 0, info.st_uid == getuid() else {
                return .failure(Problem(description: "the git_sync folder is not the owner's"))
            }
            let name = "sync-" + String(UInt64.random(in: .min ... .max), radix: 16)
            guard mkdirat(rootFD, name, 0o700) == 0 else {
                return .failure(Problem(description: "the bundle's folder cannot be made"))
            }
            let folder = root + "/" + name
            let bundle = folder + "/" + GitSync.bundleName
            func failed(_ why: String) -> Result<SyncBundle, Problem> {
                discard(folder: folder)
                return .failure(Problem(description: why))
            }
            let folderFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folderFD >= 0 else { return failed("the bundle's folder cannot be opened") }
            defer { close(folderFD) }
            guard fstat(folderFD, &info) == 0, info.st_uid == getuid(), fchmod(folderFD, 0o755) == 0 else {
                return failed("the bundle's folder cannot be prepared")
            }
            let fileFD = openat(
                folderFD,
                GitSync.bundleName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            guard fileFD >= 0 else { return failed("the bundle cannot be made") }
            let file = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
            let written = run(local + ["bundle", "create", "--quiet", "-", "--branches"], output: file)
            guard let written, written.status == 0, fstat(fileFD, &info) == 0, info.st_size > 0,
                info.st_size <= Self.maxBundleBytes, fchmod(fileFD, 0o644) == 0
            else { return failed("the bundle could not be written" + Self.because(written?.err)) }
            return .success(SyncBundle(folder: folder, bundle: bundle, defaultBranch: defaultBranch, remote: remote))
        }

        /// Removes a bundle and its folder.
        public func discard(_ bundle: SyncBundle) {
            discard(folder: bundle.folder)
        }

        private func discard(folder: String) {
            let parent = (folder as NSString).deletingLastPathComponent
            let name = (folder as NSString).lastPathComponent
            guard name.hasPrefix("sync-") else { return }
            let rootFD = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { return }
            defer { close(rootFD) }
            let folderFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if folderFD >= 0 {
                unlinkat(folderFD, GitSync.bundleName, 0)
                close(folderFD)
            }
            unlinkat(rootFD, name, AT_REMOVEDIR)
        }
    }
#endif
