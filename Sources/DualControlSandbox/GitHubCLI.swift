#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// The owner's `gh`, for the pull requests of auto-pushed agent branches (D12b). It runs as the owner, with the
    /// owner's login, always with `--repo`, in the app's own folder, never in the agent's repository. It only lists and
    /// opens pull requests; it never merges.
    public struct GitHubCLI: Sendable {
        /// Why a call failed.
        public struct Problem: Error, Equatable, CustomStringConvertible {
            /// Why, for the owner and the audit log.
            public let description: String
        }

        let gh: String
        /// The folder `gh` runs in (the owner's).
        let folder: String

        /// `gh` at `path`, run in `folder`.
        public init(gh: String, folder: String) {
            self.gh = gh
            self.folder = folder
        }

        /// The owner's `gh` from Homebrew, if installed.
        public static func find() -> String? {
            ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        /// The host an SSH host alias stands for, from the owner's ssh configuration (`ssh -G`); nothing connects.
        public static func resolveSSHHost(_ alias: String) -> String? {
            guard !alias.hasPrefix("-"), alias.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
                let result = Subprocess.run(["/usr/bin/ssh", "-G", "--", alias]), result.status == 0
            else { return nil }
            for line in result.output.split(separator: "\n") where line.hasPrefix("hostname ") {
                return String(line.dropFirst("hostname ".count)).trimmingCharacters(in: .whitespaces).lowercased()
            }
            return nil
        }

        /// The state of `branch`'s pull requests in `slug` (`owner/name`); `nil` if it has none or `gh` failed.
        public func state(slug: String, branch: String) -> Result<AgentBranches.PullRequestState?, Problem> {
            guard
                let listed = run([
                    "pr", "list", "--repo", slug, "--head", branch, "--state", "all", "--limit", "20", "--json",
                    "state,headRefName,isCrossRepository",
                ]), listed.status == 0
            else { return .failure(Problem(description: "gh could not list pull requests")) }
            return .success(AgentBranches.pullRequestState(listJSON: listed.out, branch: branch))
        }

        /// Opens a pull request from `branch` into `base`, or finds the one already open. Its URL, or why not.
        public func openPullRequest(
            slug: String,
            branch: String,
            base: String,
            title: String,
            body: String
        ) -> Result<String, Problem> {
            guard AgentBranches.isAgentBranch(branch),
                GitReview.branchProblem(base, defaultBranch: nil) == nil
                    || GitReview.protectedBranches.contains(base)
            else { return .failure(Problem(description: "not an agent branch into a plain base")) }
            if let open = run([
                "pr", "list", "--repo", slug, "--head", branch, "--state", "open", "--json", "url", "--jq", ".[0].url",
            ]), open.status == 0 {
                let url = open.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if url.hasPrefix("https://") { return .success(url) }
            }
            guard
                let made = run(
                    [
                        "pr", "create", "--repo", slug, "--head", branch, "--base", base, "--title", title,
                        "--body-file",
                        "-",
                    ],
                    input: body
                ), made.status == 0
            else { return .failure(Problem(description: "gh could not open the pull request")) }
            let url = made.out.split(separator: "\n").last.map(String.init) ?? ""
            return url.hasPrefix("https://") ? .success(url) : .failure(Problem(description: "gh printed no URL"))
        }

        /// `gh` as the owner: no prompts, no update check, no colour; stdout only.
        func run(_ arguments: [String], input: String? = nil) -> (status: Int32, out: String)? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = arguments
            let owner = ProcessInfo.processInfo.environment
            var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "LANG": "en_US.UTF-8"]
            for name in ["HOME", "USER", "LOGNAME", "SSH_AUTH_SOCK"] { environment[name] = owner[name] }
            environment.merge([
                "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1", "GH_PAGER": "cat",
                "GIT_TERMINAL_PROMPT": "0",
            ]) { $1 }
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
            let out = Pipe()
            let inputPipe = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
            guard (try? process.run()) != nil else { return nil }
            if let input {
                inputPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inputPipe.fileHandleForWriting.close()
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }

    extension Sandbox {
        /// Deletes the merged agent branch `branch` in `repository` (a repository's top folder in the session folder)
        /// as the agent, in CHANGING, with the fixed `AgentBranches.deleteScript`. True if it is gone.
        public func deleteAgentBranch(_ branch: String, in repository: String) -> Bool {
            var info = stat()
            guard AgentBranches.isAgentBranch(branch), RealPath.resolve(repository) == repository,
                scope.contains(repository), lstat(repository + "/.git", &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                let git = Toolchain.git()
            else { return false }
            var environment = AgentEnvironment.commandVariables(scope: scope)
            environment.merge(GitCommit.environment) { $1 }
            environment["DC_GIT"] = git
            guard
                let full = try? argv(
                    AgentBranches.deleteArgv(branch: branch),
                    kind: .changing,
                    environment: environment
                ),
                let outcome = try? RunningCommand(argv: full, cwd: repository, timeout: 60, killer: killer()).wait()
            else { return false }
            return outcome.status == 0 && !outcome.killed
        }

        /// Where `repository` stands (D13c): `BranchState`'s fixed script, as the agent, in READ-ONLY. `nil` if it
        /// is not a repository's top folder in the session or the script failed.
        public func branchState(in repository: String) -> BranchState? {
            var info = stat()
            guard RealPath.resolve(repository) == repository, scope.contains(repository),
                lstat(repository + "/.git", &info) == 0, info.st_mode & S_IFMT == S_IFDIR, let git = Toolchain.git()
            else { return nil }
            var environment = AgentEnvironment.commandVariables(scope: scope)
            environment.merge(GitCommit.environment) { $1 }
            environment["DC_GIT"] = git
            guard let full = try? argv(BranchState.argv(), kind: .readOnly, environment: environment),
                let outcome = try? RunningCommand(
                    argv: full,
                    cwd: repository,
                    timeout: BranchState.timeoutSeconds,
                    killer: killer()
                ).wait(),
                outcome.status == 0, !outcome.killed
            else { return nil }
            return BranchState.parse(outcome.output)
        }
    }
#endif
