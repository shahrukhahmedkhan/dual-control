#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    extension Sandbox {
        /// What `.git` may hold right after a clone or init with no templates: git's own files and folders. `hooks`
        /// must be empty and `info` may hold only `exclude`.
        static let gitEntries: Set<String> = [
            "HEAD", "config", "description", "objects", "refs", "packed-refs", "index", "logs", "FETCH_HEAD",
            "ORIG_HEAD", "shallow", "info", "hooks", "branches",
        ]

        /// Why `git` cannot start, or `nil`: a clone needs a folder that does not exist yet; an init a real folder
        /// (or none yet) without `.git`. Checked right before it starts, so nothing that was there is ever removed.
        func gitTargetProblem(_ git: GitLaunch) -> String? {
            var info = stat()
            let exists = lstat(git.target, &info) == 0
            switch git.kind {
            case .clone:
                if exists { return "the folder already exists; clone into a new one" }
            case .initialize:
                if exists, info.st_mode & S_IFMT != S_IFDIR { return "the folder is not a folder" }
                if lstat(git.target + "/.git", &info) == 0 { return "the folder already has a .git" }
            }
            return nil
        }

        /// Checks the repository a `git_clone` or `git_init` made, after it ended. If it failed, or `.git` holds
        /// anything a plain clone or init does not write, what it made is removed (the clone's folder, or the new
        /// `.git` alone) and the outcome says why. Otherwise `outcome` is returned as it is.
        public func finishGit(_ launch: Launch, _ outcome: CommandOutcome) -> CommandOutcome {
            guard let git = launch.git else { return outcome }
            let problem: String?
            if outcome.status != 0 || outcome.killed {
                problem = "git ended with status \(outcome.status)"
            } else {
                problem = repositoryProblem(git)
            }
            guard let problem else { return outcome }
            let made = git.kind == .clone ? git.target : git.target + "/.git"
            var info = stat()
            var note = "\nDual Control: \(problem)."
            if lstat(made, &info) == 0 {
                let removed = try? run(
                    ["/bin/rm", "-rf", "--", made],
                    kind: .cloning(target: git.target),
                    cwd: scope.root
                )
                note +=
                    lstat(made, &info) == 0 ? " It could not be removed: \(removed?.output ?? "")" : " It was removed."
            }
            var failed = outcome
            if failed.status == 0 { failed.status = 1 }
            failed.output += note + "\n"
            return failed
        }

        /// Why the new repository is not what a plain clone or init makes, or `nil`.
        func repositoryProblem(_ git: GitLaunch) -> String? {
            let dotGit = git.target + "/.git"
            var info = stat()
            guard lstat(dotGit, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return ".git is not a folder" }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dotGit) else {
                return ".git cannot be read"
            }
            if let extra = entries.sorted().first(where: { !Self.gitEntries.contains($0) }) {
                return ".git holds `\(DisplayText.summary(extra, limit: 80))`, which git does not write there"
            }
            for (folder, allowed) in [("hooks", Set<String>()), ("info", Set(["exclude"]))] {
                let path = dotGit + "/" + folder
                guard lstat(path, &info) == 0 else { continue }
                guard info.st_mode & S_IFMT == S_IFDIR,
                    let inside = try? FileManager.default.contentsOfDirectory(atPath: path)
                else { return ".git/\(folder) is not a folder" }
                if let extra = inside.sorted().first(where: { !allowed.contains($0) }) {
                    return ".git/\(folder) holds `\(DisplayText.summary(extra, limit: 80))`"
                }
            }
            guard lstat(dotGit + "/config", &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                return ".git/config is not a file"
            }
            guard let entries = gitConfig(dotGit + "/config") else { return ".git/config cannot be read" }
            return GitSetup.configProblem(entries, kind: git.kind, url: git.url)
        }

        /// The config file's entries as git reads it (includes not followed), listed by the real git in READ-ONLY;
        /// `nil` if it cannot be read.
        func gitConfig(_ path: String) -> [(String, String)]? {
            guard let binary = Toolchain.git() else { return nil }
            let command = [binary, "config", "--file", path, "--no-includes", "--null", "--list"]
            guard let listed = try? run(command, kind: .readOnly, cwd: scope.root), listed.status == 0 else {
                return nil
            }
            var entries: [(String, String)] = []
            for item in listed.output.split(separator: "\0") {
                let parts = item.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                entries.append((String(parts[0]), parts.count > 1 ? String(parts[1]) : ""))
            }
            return entries
        }
    }
#endif
