#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// The owner's review and push of a branch the agent committed to (D11 phase 3, `GitReview`). Everything here
    /// runs as the owner, with the owner's git, SSH and signing key, and never inside the agent's repository: its
    /// config could name programs to run (`core.sshCommand`, `credential.helper`, `gpg.program`). Instead:
    ///
    /// 1. The remote is read from the repository's config file as data (`git config --file`) and must be a plain
    ///    https or ssh URL.
    /// 2. A fresh bare repository of the app's fetches the branch from the agent's over `file://`, every object
    ///    checked (`transfer.fsckObjects`), and the remote's default branch and the branch itself from the remote.
    /// 3. The review is what the remote does not have: the commits, their stat and diff (escaped when shown).
    /// 4. On the owner's click each commit is re-created there with its tree, message and author and signed with the
    ///    owner's key (`commit-tree -S`), and the result pushed to `refs/heads/<branch>`: never the default branch,
    ///    never forced. Which signed commit stands for which agent commit is kept, so later pushes fast-forward.
    public struct OwnerPush: Sendable {
        /// A review waiting for the owner's decision. Its scratch repository is removed by `push` or `discard`.
        public struct Review: Sendable, Equatable, Identifiable {
            /// The scratch repository.
            public let id: String
            /// The agent's repository.
            public let repository: String
            /// The branch.
            public let branch: String
            /// Where it would be pushed.
            public let remote: String
            /// The agent's commits to push, oldest first.
            public let commits: [String]
            /// One line per commit: short hash, author, subject (untrusted text).
            public let log: String
            /// `git diff --stat` of all of them.
            public let stat: String
            /// Their diff, at most `maxDiffBytes`.
            public let diff: String
            /// True if the diff was cut.
            public let truncated: Bool
            /// The remote branch's tip, if it exists; the push must fast-forward it.
            public let remoteTip: String?
            /// The remote's default branch, if it says: the base of a pull request.
            public var defaultBranch: String? = nil
            /// The newest commit's whole message (untrusted text).
            public var tipMessage: String = ""
        }

        /// Why a review or push failed.
        public struct Problem: Error, Equatable, CustomStringConvertible {
            /// Why, for the owner and the audit log.
            public let description: String
        }

        /// The longest diff shown.
        public static let maxDiffBytes = 1 << 20
        /// The most commits pushed at once.
        public static let maxCommits = 500

        let git: String
        /// Where scratch repositories are made (the owner's).
        let scratch: String
        /// The file that maps agent commits to the signed ones pushed for them (the owner's).
        let mapFile: String
        /// Extra variables for the owner's git (tests point it at their own config).
        let extraEnvironment: [String: String]
        /// Tests push to a local bare repository.
        let allowFileRemotes: Bool

        /// The owner's push with `git` (the real binary), scratch repositories in `scratch` and the commit map in
        /// `mapFile`.
        public init(git: String, scratch: String, mapFile: String) {
            self.init(git: git, scratch: scratch, mapFile: mapFile, extraEnvironment: [:], allowFileRemotes: false)
        }

        init(git: String, scratch: String, mapFile: String, extraEnvironment: [String: String], allowFileRemotes: Bool)
        {
            self.git = git
            self.scratch = scratch
            self.mapFile = mapFile
            self.extraEnvironment = extraEnvironment
            self.allowFileRemotes = allowFileRemotes
        }

        /// The owner's git name and email from the owner's global config, for `git_commit`.
        public func identity() -> (name: String, email: String)? {
            guard let name = run(["config", "--global", "--get", "user.name"]), name.status == 0,
                let email = run(["config", "--global", "--get", "user.email"]), email.status == 0
            else { return nil }
            return (
                name.out.trimmingCharacters(in: .whitespacesAndNewlines),
                email.out.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // MARK: - Review

        /// Prepares the review of `branch` in `repository`.
        public func review(repository: String, branch: String) -> Result<Review, Problem> {
            if let problem = GitReview.branchProblem(branch, defaultBranch: nil) {
                return .failure(Problem(description: problem))
            }
            let remote: String
            switch origin(of: repository) {
            case .failure(let problem): return .failure(problem)
            case .success(let url): remote = url
            }
            guard
                let listed = run(protocols + ["ls-remote", "--symref", "--", remote, "HEAD", "refs/heads/" + branch]),
                listed.status == 0
            else { return .failure(Problem(description: "the remote could not be reached")) }
            let state = GitReview.parseLsRemote(listed.out, branch: branch)
            if let problem = GitReview.branchProblem(branch, defaultBranch: state.defaultBranch) {
                return .failure(Problem(description: problem))
            }

            var template = Array((scratch + "/review-XXXXXX").utf8CString)
            guard let made = mkdtemp(&template).map({ String(cString: $0) }) else {
                return .failure(Problem(description: "the scratch repository cannot be made"))
            }
            func failed(_ why: String) -> Result<Review, Problem> {
                _ = try? FileManager.default.removeItem(atPath: made)
                return .failure(Problem(description: why))
            }
            guard run(["init", "--bare", "--quiet", "--template=", made])?.status == 0 else {
                return failed("the scratch repository cannot be made")
            }
            let local = ["-C", made]
            // Alternates (which the agent can write) would let the agent's branch take in objects from the owner's
            // other repositories.
            var info = stat()
            guard lstat(repository + "/.git/objects/info/alternates", &info) != 0 else {
                return failed("the repository borrows objects from elsewhere (objects/info/alternates)")
            }
            // safe.directory as command-line config, which the upload-pack git runs in the agent's repository
            // inherits: its .git may belong to the agent.
            let fromAgent = run(
                local + [
                    "-c", "transfer.fsckObjects=true", "-c", "protocol.allow=never", "-c", "protocol.file.allow=always",
                ]
                    + ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--", "file://" + repository]
                    + ["+refs/heads/\(branch):refs/agent/tip"],
                environment: [
                    "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": repository,
                ]
            )
            guard fromAgent?.status == 0 else { return failed("the branch could not be read from the repository") }
            var remoteRefs: [String] = []
            for (name, tip) in [("branch", state.branchTip), ("default", state.defaultTip)] {
                guard tip != nil else { continue }
                let source = name == "branch" ? "refs/heads/" + branch : "refs/heads/" + (state.defaultBranch ?? "")
                guard name == "branch" || state.defaultBranch != nil else { continue }
                let fetched = run(
                    local + protocols + ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--", remote]
                        + ["+\(source):refs/remote/\(name)"]
                )
                guard fetched?.status == 0 else { return failed("the remote's \(name) branch could not be fetched") }
                remoteRefs.append("refs/remote/\(name)")
            }

            // Agent commits whose signed stand-ins the remote branch already has. After a rebase (D13a) the earlier
            // ones are no longer on the branch, so not here either; naming them would fail rev-list.
            let map = loadMap()[repository] ?? [:]
            var pushed: [String] = []
            if remoteRefs.contains("refs/remote/branch") {
                for (unsigned, signed) in map
                where GitReview.isObjectName(unsigned)
                    && run(local + ["cat-file", "-e", unsigned + "^{commit}"])?.status == 0
                    && run(local + ["merge-base", "--is-ancestor", signed, "refs/remote/branch"])?.status == 0
                {
                    pushed.append(unsigned)
                }
            }
            let range = ["refs/agent/tip", "--not"] + remoteRefs + pushed.filter(GitReview.isObjectName)
            guard let listing = run(local + ["rev-list", "--reverse", "--topo-order"] + range), listing.status == 0
            else { return failed("the commits could not be listed") }
            let commits = listing.out.split(separator: "\n").map(String.init)
            guard !commits.isEmpty else { return failed("the remote already has everything on \(branch)") }
            guard commits.count <= Self.maxCommits else { return failed("more than \(Self.maxCommits) commits") }
            if let merges = run(local + ["rev-list", "--min-parents=2"] + range), !merges.out.isEmpty {
                return failed("the branch has merge commits, which are not re-signed here; rebase it first")
            }
            let base = commits[0] + "^"
            let hasBase = run(local + ["rev-parse", "--verify", "--quiet", base])?.status == 0
            let from = hasBase ? [base] : [emptyTree(local)]
            let noDrivers = ["--no-color", "--no-ext-diff", "--no-textconv"]
            let log = run(local + ["log", "--no-color", "--format=%h %an: %s"] + range)?.out ?? ""
            let stat = run(local + ["diff", "--stat"] + noDrivers + from + ["refs/agent/tip"])?.out ?? ""
            let diff = run(local + ["diff"] + noDrivers + from + ["refs/agent/tip"])?.out ?? ""
            let tipMessage = run(local + ["log", "-1", "--no-color", "--format=%B", "refs/agent/tip"])?.out ?? ""
            let truncated = diff.utf8.count > Self.maxDiffBytes
            return .success(
                Review(
                    id: made,
                    repository: repository,
                    branch: branch,
                    remote: remote,
                    commits: commits,
                    log: log,
                    stat: stat,
                    diff: truncated ? String(decoding: diff.utf8.prefix(Self.maxDiffBytes), as: UTF8.self) : diff,
                    truncated: truncated,
                    remoteTip: state.branchTip,
                    defaultBranch: state.defaultBranch,
                    tipMessage: tipMessage
                )
            )
        }

        /// The repository's `remote.origin.url`, read from its config file as data, if it is a remote the owner's
        /// git may use.
        public func origin(of repository: String) -> Result<String, Problem> {
            guard
                let remote = run(["config", "--file", repository + "/.git/config", "--get", "remote.origin.url"])
                    .flatMap({ $0.status == 0 ? $0.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil })
            else { return .failure(Problem(description: "the repository has no remote origin")) }
            if let problem = remoteProblem(remote) { return .failure(Problem(description: problem)) }
            return .success(remote)
        }

        // MARK: - Agent branches (D12b)

        /// The agent branches (`claude/*`) on `remote`.
        public func agentBranches(on remote: String) -> Result<[String], Problem> {
            guard let listed = run(protocols + ["ls-remote", "--heads", "--", remote, "refs/heads/claude/*"]),
                listed.status == 0
            else { return .failure(Problem(description: "the remote could not be reached")) }
            return .success(AgentBranches.parseHeads(listed.out))
        }

        /// Deletes the agent branch `branch` on `remote`, as the owner; nothing else is ever deleted.
        public func deleteAgentBranch(_ branch: String, on remote: String) -> Problem? {
            guard AgentBranches.isAgentBranch(branch) else { return Problem(description: "not an agent branch") }
            // git push needs a repository to run in; an empty one of the app's own.
            var template = Array((scratch + "/delete-XXXXXX").utf8CString)
            guard let made = mkdtemp(&template).map({ String(cString: $0) }) else {
                return Problem(description: "the scratch repository cannot be made")
            }
            defer { _ = try? FileManager.default.removeItem(atPath: made) }
            guard run(["init", "--bare", "--quiet", "--template=", made])?.status == 0,
                let pushed = run(
                    ["-C", made] + protocols + ["push", "--porcelain", "--", remote, ":refs/heads/\(branch)"]
                ), pushed.status == 0
            else { return Problem(description: "the remote did not delete \(branch)") }
            return nil
        }

        /// Removes a review's scratch repository.
        public func discard(_ review: Review) {
            guard review.id.hasPrefix(scratch + "/review-") else { return }
            _ = try? FileManager.default.removeItem(atPath: review.id)
        }

        // MARK: - Push

        /// Re-signs the reviewed commits with the owner's key and pushes them to the branch (fast-forward only).
        /// With `lease` (D13a: the agent rebased it with `git_sync update`) an agent branch (`claude/*`) may be
        /// replaced instead, but only if the remote branch is still where the review found it
        /// (`--force-with-lease`); any other branch is never forced. The signed tip, or why not. The scratch
        /// repository is removed either way.
        public func push(_ review: Review, lease: Bool = false) -> Result<String, Problem> {
            defer { discard(review) }
            let forced = lease && AgentBranches.isAgentBranch(review.branch)
            let signing: [String]
            switch signingOptions(for: review.repository) {
            case .failure(let problem): return .failure(problem)
            case .success(let options): signing = options
            }
            let local = ["-C", review.id] + signing
            var map = loadMap()
            var mapped = map[review.repository] ?? [:]
            var signedTip = ""
            for commit in review.commits {
                guard let raw = run(local + ["cat-file", "commit", commit]), raw.status == 0,
                    let parsed = Self.parse(commit: raw.out)
                else { return .failure(Problem(description: "commit \(commit.prefix(12)) cannot be read")) }
                var argv = local + ["commit-tree", parsed.tree]
                if let parent = parsed.parent { argv += ["-p", mapped[parent] ?? parent] }
                argv += ["-S", "-F", "-"]
                var environment = [
                    "GIT_AUTHOR_NAME": parsed.authorName, "GIT_AUTHOR_EMAIL": parsed.authorEmail,
                    "GIT_AUTHOR_DATE": parsed.authorDate,
                ]
                environment.merge(extraEnvironment) { $1 }
                let signed = run(argv, input: parsed.message, environment: environment)
                guard let signed, signed.status == 0,
                    GitReview.isObjectName(signed.out.trimmingCharacters(in: .whitespacesAndNewlines))
                else {
                    return .failure(
                        Problem(
                            description: "commit \(commit.prefix(12)) could not be signed with your key"
                                + Self.because(signed?.err)
                        )
                    )
                }
                signedTip = signed.out.trimmingCharacters(in: .whitespacesAndNewlines)
                mapped[commit] = signedTip
            }
            let ref = "refs/heads/\(review.branch)"
            let leaseOption = forced ? ["--force-with-lease=\(ref):\(review.remoteTip ?? "")"] : []
            let pushed = run(
                local + protocols + ["push", "--porcelain"] + leaseOption
                    + ["--", review.remote, "\(signedTip):\(ref)"]
            )
            guard let pushed, pushed.status == 0 else {
                let rule = forced ? "the remote branch moved since the review" : "it must fast-forward"
                let why = "the remote refused the push (\(rule))" + Self.because(pushed?.err)
                return .failure(Problem(description: why))
            }
            map[review.repository] = mapped
            saveMap(map)
            return .success(signedTip)
        }

        /// A commit object's tree, single parent, author and message, or `nil` if it is not one this push handles.
        static func parse(commit text: String) -> (
            tree: String, parent: String?, authorName: String, authorEmail: String, authorDate: String, message: String
        )? {
            guard let split = text.range(of: "\n\n") else { return nil }
            let headers = text[..<split.lowerBound].split(separator: "\n")
            let message = String(text[split.upperBound...])
            var tree: String?
            var parents: [String] = []
            var author: Substring?
            for header in headers {
                if header.hasPrefix("tree ") { tree = String(header.dropFirst(5)) }
                if header.hasPrefix("parent ") { parents.append(String(header.dropFirst(7))) }
                if header.hasPrefix("author ") { author = header.dropFirst(7) }
            }
            // author Name <email> 1700000000 +0100
            guard let tree, GitReview.isObjectName(tree), parents.count <= 1, let author,
                let open = author.lastIndex(of: "<"), let close = author.lastIndex(of: ">"), open < close
            else { return nil }
            let name = author[..<open].trimmingCharacters(in: .whitespaces)
            let email = String(author[author.index(after: open)..<close])
            let date = author[author.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let dateParts = date.split(separator: " ")
            guard dateParts.count == 2, let seconds = Int(dateParts[0]) else { return nil }
            return (tree, parents.first, name, email, "@\(seconds) \(dateParts[1])", message)
        }

        // MARK: - Signing

        /// The longest part of git's own error shown with a problem.
        static let maxErrorCharacters = 400

        /// Options that make `commit-tree -S` sign as the owner's git does in `repository`. The owner's global config
        /// wins if it names a key. Otherwise the repository's `gpg.format` and `user.signingkey`, read from its config
        /// file as data like the remote: only SSH signing with a key file of the owner's in `~/.ssh`. Programs
        /// (`gpg.program`, `gpg.ssh.program`) are never taken from the repository, whose config the agent may write.
        func signingOptions(for repository: String) -> Result<[String], Problem> {
            if let global = run(["config", "--global", "--get", "user.signingkey"]), global.status == 0 {
                return .success([])
            }
            func value(_ name: String) -> String? {
                run(["config", "--file", repository + "/.git/config", "--get", name])
                    .flatMap { $0.status == 0 ? $0.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            }
            guard let key = value("user.signingkey") else {
                return .failure(
                    Problem(
                        description: "no SSH signing key is set for you or the repository; set one with "
                            + "git config --global gpg.format ssh and git config --global user.signingkey "
                            + "~/.ssh/<key>.pub"
                    )
                )
            }
            guard value("gpg.format") == "ssh", let path = ownerSSHKey(key) else {
                return .failure(
                    Problem(
                        description: "the repository's signing key `\(DisplayText.summary(key, limit: 120))` is not "
                            + "an SSH key file of yours in ~/.ssh (gpg.format ssh)"
                    )
                )
            }
            return .success(["-c", "gpg.format=ssh", "-c", "user.signingkey=" + path])
        }

        /// `value` as the path of a regular file the owner owns in their `~/.ssh` (`~/` expanded), reached without
        /// links or `..`, or `nil`.
        func ownerSSHKey(_ value: String) -> String? {
            let owner = extraEnvironment["HOME"] ?? ProcessInfo.processInfo.environment["HOME"]
            guard let home = owner.flatMap(RealPath.resolve) else { return nil }
            let path = value.hasPrefix("~/") ? home + value.dropFirst(1) : value
            var info = stat()
            guard path.hasPrefix(home + "/.ssh/"), RealPath.resolve(path) == path, lstat(path, &info) == 0,
                info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid()
            else { return nil }
            return path
        }

        /// `": "` and git's error as one escaped line, or nothing if it said nothing.
        static func because(_ error: String?) -> String {
            let text = (error ?? "").split(whereSeparator: \.isNewline).joined(separator: " | ")
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "" : ": " + DisplayText.summary(text, limit: maxErrorCharacters)
        }

        // MARK: - Helpers

        /// Git options every remote operation uses: only https and ssh (and `file` in tests).
        var protocols: [String] {
            ["-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c", "protocol.ssh.allow=always"]
                + (allowFileRemotes ? ["-c", "protocol.file.allow=always"] : [])
        }

        private func remoteProblem(_ remote: String) -> String? {
            if allowFileRemotes, remote.hasPrefix("/"), RealPath.resolve(remote) == remote { return nil }
            return GitReview.remoteProblem(remote)
        }

        private func emptyTree(_ local: [String]) -> String {
            run(local + ["hash-object", "-t", "tree", "/dev/null"])?.out.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        }

        private func loadMap() -> [String: [String: String]] {
            guard let data = FileManager.default.contents(atPath: mapFile),
                let map = try? JSONDecoder().decode([String: [String: String]].self, from: data)
            else { return [:] }
            return map
        }

        private func saveMap(_ map: [String: [String: String]]) {
            guard let data = try? JSONEncoder().encode(map) else { return }
            let temporary = mapFile + ".new"
            unlink(temporary)
            guard
                FileManager.default.createFile(
                    atPath: temporary,
                    contents: data,
                    attributes: [.posixPermissions: 0o600]
                )
            else { return }
            rename(temporary, mapFile)
        }

        /// The owner's git with hooks, fsmonitor and the pager off, never prompting; stdout and stderr apart (stderr
        /// through a file of the owner's in `scratch`, so a full pipe cannot stall git). With `output`, stdout goes
        /// there instead and `out` is empty.
        func run(
            _ arguments: [String],
            input: String? = nil,
            environment extra: [String: String] = [:],
            output: FileHandle? = nil
        ) -> (status: Int32, out: String, err: String)? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments =
                ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.pager=cat", "--no-pager"]
                + arguments
            let owner = ProcessInfo.processInfo.environment
            var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "LANG": "en_US.UTF-8"]
            for name in ["HOME", "USER", "LOGNAME", "SSH_AUTH_SOCK"] { environment[name] = owner[name] }
            environment.merge(["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "GIT_ASKPASS": "/usr/bin/false"]) { $1 }
            environment.merge(extraEnvironment) { $1 }
            environment.merge(extra) { $1 }
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: scratch, isDirectory: true)
            let out = Pipe()
            let inputPipe = Pipe()
            var template = Array((scratch + "/stderr-XXXXXX").utf8CString)
            let descriptor = mkstemp(&template)
            guard descriptor >= 0 else { return nil }
            unlink(String(cString: template))
            let errors = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            process.standardOutput = output ?? out
            process.standardError = errors
            process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
            guard (try? process.run()) != nil else { return nil }
            if let input {
                inputPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inputPipe.fileHandleForWriting.close()
            }
            if output != nil { try? out.fileHandleForWriting.close() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            lseek(descriptor, 0, SEEK_SET)
            let error = (try? errors.read(upToCount: 64 << 10)) ?? nil
            return (
                process.terminationStatus, String(decoding: data, as: UTF8.self),
                String(decoding: error ?? Data(), as: UTF8.self)
            )
        }
    }
#endif
