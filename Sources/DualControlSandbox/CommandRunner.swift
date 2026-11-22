#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// The ESP-IDF environment for a flasher's launch: which install, the validated environment or why not, and
    /// whether the export ran for it now (`fresh`) or it came from the cache.
    public struct IDFDerivation: Sendable, Equatable {
        /// The ESP-IDF folder (IDF_PATH).
        public let install: String
        /// The environment, or why it cannot be used.
        public let result: Result<[String: String], IDFEnvironment.Problem>
        /// True if `idf_tools.py export` ran for this, false if it was cached.
        public let fresh: Bool
    }

    extension Sandbox {
        /// The ESP-IDF environment for `launch` (a flasher: `serialPort` set). Runs the export once per install;
        /// the caller records a fresh run.
        public func idfEnvironment(for launch: Launch) -> IDFDerivation {
            guard
                let install = IDFEnvironment.idfPath(for: launch.request.argv, scope: scope, resolve: RealPath.resolve)
            else {
                let problem = IDFEnvironment.Problem(
                    description: "it does not run from an install in the toolchain folder"
                )
                return IDFDerivation(install: scope.toolchains, result: .failure(problem), fresh: true)
            }
            let (result, fresh) = IDFEnvironmentCache.shared.environment(idfPath: install, sandbox: self)
            return IDFDerivation(install: install, result: result, fresh: fresh)
        }

        /// Starts `launch`'s command: the argument vector itself (no shell), in the matching profile, with only the
        /// command environment, stdin closed, and no descriptor of the app except stdout and stderr. It runs in a
        /// process group of its own, which the timeout, `kill()`, Stop and quitting kill as a whole. A flasher also
        /// gets the ESP-IDF environment: `idf` if given, otherwise `idfEnvironment(for:)`. A `git_sync` needs `sync`,
        /// the bundle the owner's side just wrote.
        public func start(
            _ launch: Launch,
            idf: IDFDerivation? = nil,
            sync: OwnerPush.SyncBundle? = nil
        ) throws -> RunningCommand {
            let request = launch.request
            // Checked again here, right before spawning: the folder must still resolve to itself, in the scope.
            guard launch.scope == scope, RealPath.resolve(request.cwd) == request.cwd, scope.contains(request.cwd)
            else { throw SandboxError.outsideScope }
            var command = request.argv
            if launch.readOnly, command.first?.split(separator: "/").last == "git" {
                guard let git = Toolchain.git(), let hardened = ReadOnlyGit.hardened(command, git: git) else {
                    throw SandboxError.noGit
                }
                command = hardened
            }
            var environment = AgentEnvironment.commandVariables(scope: scope)
            var kind: SandboxKind = launch.readOnly ? .readOnly : .changing
            var cwd = request.cwd
            if let git = launch.git, !launch.readOnly {
                // The fixed command line from `GitSetup`, run by the real git, not the xcrun stub.
                if let problem = gitTargetProblem(git) { throw SandboxError.gitTarget(problem) }
                guard let binary = Toolchain.git(), command.first == "git" else { throw SandboxError.noGit }
                command[0] = binary
                environment.merge(GitSetup.environment) { $1 }
                kind = .cloning(target: git.target)
            } else if launch.gitCommit || launch.gitSync != nil, !launch.readOnly {
                // `git_commit`'s or `git_sync`'s fixed script with the real git, in the repository's top folder only.
                var info = stat()
                guard lstat(request.cwd + "/.git", &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                    throw SandboxError.gitTarget("the folder is not a repository's top folder")
                }
                guard let git = Toolchain.git() else { throw SandboxError.noGit }
                environment.merge(GitCommit.environment) { $1 }
                environment["DC_GIT"] = git
                if launch.gitSync != nil {
                    // Only a bundle in its own folder of the sync folder, for a plain default branch.
                    guard let sync, (sync.folder as NSString).deletingLastPathComponent == scope.gitSync,
                        (sync.folder as NSString).lastPathComponent.hasPrefix("sync-"),
                        !sync.folder.contains("/../"), sync.bundle == sync.folder + "/" + GitSync.bundleName,
                        GitSync.isDefaultBranch(sync.defaultBranch)
                    else { throw SandboxError.gitTarget("the remote's bundle is missing") }
                    environment["DC_BUNDLE"] = sync.bundle
                    environment["DC_DEFAULT"] = sync.defaultBranch
                }
            } else if launch.toolchain != nil, !launch.readOnly {
                // `esp_idf_install`'s fixed script, which alone may write the staging folder.
                guard let git = Toolchain.git() else { throw SandboxError.noGit }
                environment = ESPIDFInstall.environment(scope: scope, git: git)
                kind = .installing
                // INSTALLING cannot read the session folder, so a shell started there cannot find its working
                // directory; the script uses only absolute paths.
                cwd = "/"
            } else if let port = launch.serialPort, !launch.readOnly {
                // Only from an install in the owner's toolchain folder that still matches its recorded hash.
                if let problem = toolchainProblem(for: command) { throw SandboxError.toolchain(problem) }
                kind = .flashing(port: port)
                switch (idf ?? idfEnvironment(for: launch)).result {
                case .success(let idf): environment = AgentEnvironment.commandVariables(scope: scope, idf: idf)
                case .failure(let problem):
                    // esptool runs from its Python environment's own bin; idf.py cannot run without it.
                    if IDFEnvironment.needed(for: command) { throw SandboxError.idfEnvironment(problem.description) }
                }
            }
            let full = try argv(command, kind: kind, environment: environment)
            return try RunningCommand(argv: full, cwd: cwd, timeout: launch.timeoutSeconds, killer: killer())
        }

        /// Runs the install's `idf_tools.py export` as the agent, in CHANGING without serial ports, for at most a
        /// minute, and validates what it prints.
        func deriveIDFEnvironment(idfPath: String) -> Result<[String: String], IDFEnvironment.Problem> {
            let failed = { (why: String) in
                Result<[String: String], IDFEnvironment.Problem>.failure(
                    IDFEnvironment.Problem(description: "the ESP-IDF environment could not be read: " + why)
                )
            }
            var variables = AgentEnvironment.commandVariables(scope: scope)
            variables["IDF_PATH"] = idfPath
            variables["IDF_TOOLS_PATH"] = IDFEnvironment.toolsPath(idfPath: idfPath)
            let outcome: CommandOutcome
            do {
                let full = try argv(
                    IDFEnvironment.exportCommand(idfPath: idfPath),
                    kind: .changing,
                    environment: variables
                )
                outcome = try RunningCommand(argv: full, cwd: scope.root, timeout: 60, killer: killer()).wait()
            } catch {
                return failed("\(error)")
            }
            guard outcome.status == 0, !outcome.killed else {
                return failed("idf_tools.py export ended with status \(outcome.status)")
            }
            guard outcome.totalBytes <= IDFEnvironment.maxOutputBytes else { return failed("it printed too much") }
            return IDFEnvironment.validated(outcome.output, idfPath: idfPath, scope: scope)
        }

        /// How to kill a process group of the agent's. As another user the app may not signal it, so it runs kill as
        /// the agent through the same sudoers rule, in a sandbox that restricts nothing.
        func killer() -> @Sendable (pid_t) -> Void {
            guard !runAs.isEmpty else { return { _ = killpg($0, SIGKILL) } }
            let prefix = runAs + [sandboxExec, "-p", "(version 1)(allow default)", "/bin/kill", "-KILL", "--"]
            return { group in _ = Subprocess.run(prefix + ["-\(group)"]) }
        }
    }

    /// Validated ESP-IDF environments, derived once per install for the app's lifetime. Failures are not kept, so
    /// fixing the install and trying again works.
    final class IDFEnvironmentCache: @unchecked Sendable {
        static let shared = IDFEnvironmentCache()
        private let lock = NSLock()
        private var environments: [String: [String: String]] = [:]

        /// The environment, and true if it was derived now rather than cached.
        func environment(idfPath: String, sandbox: Sandbox) -> (Result<[String: String], IDFEnvironment.Problem>, Bool)
        {
            lock.lock()
            defer { lock.unlock() }
            let key = sandbox.scope.agentHome + "\0" + idfPath
            if let known = environments[key] { return (.success(known), false) }
            let derived = sandbox.deriveIDFEnvironment(idfPath: idfPath)
            if case .success(let environment) = derived { environments[key] = environment }
            return (derived, true)
        }
    }

    /// A command started by `Sandbox.start`. `wait()` returns once it has ended, its output is read and its
    /// descriptors are closed; `kill()` may be called from any thread, any number of times.
    public final class RunningCommand: @unchecked Sendable {
        private let pid: pid_t
        private let timeout: Int
        private let killer: @Sendable (pid_t) -> Void
        private let started = Date()
        private let exited = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var status: Int32 = 0
        private var killed = false
        private var hasExited = false
        private let reader: OutputReader

        init(argv: [String], cwd: String, timeout: Int, killer: @escaping @Sendable (pid_t) -> Void) throws {
            self.timeout = timeout
            self.killer = killer
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw SandboxError.notStarted }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer {
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attributes)
            }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
            posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
            // A new process group; default signal handling; and close every descriptor not named above.
            var everySignal = sigset_t()
            sigfillset(&everySignal)
            var noSignals = sigset_t()
            sigemptyset(&noSignals)
            posix_spawnattr_setsigdefault(&attributes, &everySignal)
            posix_spawnattr_setsigmask(&attributes, &noSignals)
            posix_spawnattr_setpgroup(&attributes, 0)
            posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
                )
            )
            var arguments = argv.map { strdup($0) } + [nil]
            defer { arguments.forEach { free($0) } }
            var environment: [UnsafeMutablePointer<CChar>?] = [nil]
            var child: pid_t = 0
            let result = posix_spawn(&child, argv[0], &actions, &attributes, &arguments, &environment)
            close(fds[1])
            guard result == 0 else {
                close(fds[0])
                throw SandboxError.notStarted
            }
            pid = child
            reader = OutputReader(fd: fds[0], cap: CommandLimits.maxOutputBytes)
            let thread = Thread { [self] in reap() }
            thread.name = "DualControl.command"
            thread.start()
        }

        /// Waits for the exit without reaping first: while the child is a zombie its pid, and so the group id,
        /// cannot be reused, so a `kill()` that holds the lock can never hit someone else's group.
        private func reap() {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
            lock.withLock { hasExited = true }
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
            let signal = raw & 0x7F
            lock.withLock { status = signal == 0 ? (raw >> 8) & 0xFF : 128 + signal }
            exited.signal()
        }

        /// Kills the command's whole process group now. Does nothing once it has exited.
        public func kill() {
            lock.withLock {
                guard !hasExited else { return }
                killed = true
                killer(pid)
            }
        }

        /// The end of the output so far and the bytes written in all, while it runs (for background jobs).
        public func peek() -> (tail: String, totalBytes: Int) {
            let (tail, total) = reader.snapshot()
            return (String(decoding: tail, as: UTF8.self), total)
        }

        /// Waits for the command to end, killing its process group at the timeout.
        public func wait() -> CommandOutcome {
            var timedOut = false
            if exited.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
                timedOut = lock.withLock { !hasExited }
                kill()
                exited.wait()
            }
            // A process that left the group may still hold the pipe: read for a moment more, then stop.
            let output = reader.finish(grace: 2)
            let (status, killed) = lock.withLock { (self.status, self.killed) }
            return CommandOutcome(
                status: status,
                timedOut: timedOut,
                killed: killed,
                duration: Date().timeIntervalSince(started),
                output: String(decoding: output.kept, as: UTF8.self),
                totalBytes: output.total,
                shownBytes: output.kept.count,
                tail: output.total > output.kept.count ? String(decoding: output.tail, as: UTF8.self) : nil
            )
        }
    }

    /// Reads a pipe on its own thread until EOF or `finish`, keeping the first `cap` bytes and the last
    /// `Supervisor.jobOutputLimit`, and counting the rest. It owns the descriptor and closes it once, after its
    /// thread has stopped reading.
    private final class OutputReader: @unchecked Sendable {
        private let fd: Int32
        private let cap: Int
        private let tailCap = Supervisor.jobOutputLimit
        private let lock = NSLock()
        private var kept: [UInt8] = []
        private var tail: [UInt8] = []
        private var total = 0
        private var stopRequested = false
        private let done = DispatchSemaphore(value: 0)

        init(fd: Int32, cap: Int) {
            self.fd = fd
            self.cap = cap
            let thread = Thread { [self] in readUntilDone() }
            thread.name = "DualControl.command-output"
            thread.start()
        }

        private func readUntilDone() {
            defer {
                close(fd)
                done.signal()
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while !lock.withLock({ stopRequested }) {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 100)
                if ready < 0 && errno != EINTR { return }
                guard ready > 0 else { continue }
                let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count == 0 { return }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                lock.withLock {
                    total += count
                    let room = cap - kept.count
                    if room > 0 { kept.append(contentsOf: chunk[..<min(room, count)]) }
                    tail.append(contentsOf: chunk[..<count])
                    if tail.count > 2 * tailCap { tail.removeFirst(tail.count - tailCap) }
                }
            }
        }

        /// The last bytes read so far and the total.
        func snapshot() -> (tail: [UInt8], total: Int) {
            lock.withLock { (Array(tail.suffix(tailCap)), total) }
        }

        /// Waits up to `grace` seconds for EOF, then stops reading, and returns what was kept and the total.
        func finish(grace: TimeInterval) -> (kept: [UInt8], tail: [UInt8], total: Int) {
            if done.wait(timeout: .now() + grace) == .timedOut {
                lock.withLock { stopRequested = true }
                done.wait()
            }
            return lock.withLock { (kept, Array(tail.suffix(tailCap)), total) }
        }
    }
#endif
