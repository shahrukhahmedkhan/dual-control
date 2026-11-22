#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// Which profile a process runs in.
    public enum SandboxKind: Sendable, Equatable {
        /// `SandboxProfile.changing`.
        case changing
        /// `SandboxProfile.changing` with the one serial port a recognised flasher or monitor names.
        case flashing(port: String)
        /// `SandboxProfile.readOnly`.
        case readOnly
        /// CLONING: `SandboxProfile.changing` where only `target`, the repository a `git_clone` or `git_init` makes,
        /// may get its `.git` (`GitSetup`).
        case cloning(target: String)
        /// INSTALLING: `SandboxProfile.installing`, for `esp_idf_install` only.
        case installing
    }

    /// Why a command cannot be wrapped.
    public enum SandboxError: Error, Equatable, CustomStringConvertible {
        /// The profile cannot be made for this scope.
        case profile(SandboxProfile.Error)
        /// The program is empty, contains NUL, starts with `-` or contains `=` (env(1) would read it as an option
        /// or a variable).
        case badProgram
        /// The process could not be started.
        case notStarted
        /// The working directory is not inside the session folder (after realpath).
        case outsideScope
        /// A read-only git command, but no real git binary was found.
        case noGit
        /// idf.py cannot run: the install's ESP-IDF environment cannot be read or used.
        case idfEnvironment(String)
        /// A `git_clone` or `git_init` cannot make its repository there.
        case gitTarget(String)
        /// A flasher's install is not one the owner's toolchain folder vouches for.
        case toolchain(String)

        /// Why, for the caller's result.
        public var description: String {
            switch self {
            case .profile(let error): return "the sandbox profile cannot be made: \(error)"
            case .badProgram: return "the program name is not valid"
            case .notStarted: return "the process could not be started"
            case .outsideScope: return "the working directory is not inside the session folder"
            case .noGit: return "no git binary was found"
            case .idfEnvironment(let why): return "idf.py cannot run: \(why)"
            case .gitTarget(let why): return "the repository cannot be made: \(why)"
            case .toolchain(let why): return "the flasher's toolchain cannot be trusted: \(why)"
            }
        }
    }

    /// The outcome of a sandboxed run.
    public struct SandboxRun: Sendable, Equatable {
        /// Exit status, or 128 + signal.
        public let status: Int32
        /// Standard output and standard error, interleaved.
        public let output: String
    }

    /// The sandbox self-test: if it does not pass, no command runs.
    public enum SelfTest: Sendable, Equatable {
        /// The kernel applied both profiles and denied what they deny.
        case passed
        /// Why the sandbox cannot be trusted.
        case failed(String)
    }

    /// Runs agent processes inside the kernel sandbox for one session scope (SAFE-004):
    /// `[runAs…] /usr/bin/sandbox-exec -p <profile> /usr/bin/env -i <agent environment> <command…>`.
    /// The sandbox is applied before the command starts and is inherited by all its children.
    public struct Sandbox: Sendable {
        /// The system's sandbox-exec.
        public static let systemSandboxExec = "/usr/bin/sandbox-exec"

        /// The session scope.
        public let scope: SessionScope
        /// The gatekeeper proxy, the only network CHANGING processes reach; `nil`: no network at all.
        public let proxy: ProxyEndpoint?
        /// The agent's own Darwin temp and cache folders, writable in CHANGING (`agentSystemFolders()`).
        public let systemFolders: [String]
        /// Approved LAN endpoints (D7b): CHANGING processes may reach their forwarders' local ports.
        public let lanForwards: [LANForward]
        /// The model relay (D11): CHANGING processes may reach its port and get its URL and session token.
        public let relay: ModelRelayEndpoint?
        let toolchains: [String]
        let sandboxExec: String
        let runAs: [String]

        /// A sandbox for `scope`. `runAs` goes in front, e.g. sudo to `claude-agent`.
        public init(
            scope: SessionScope,
            runAs: [String] = [],
            proxy: ProxyEndpoint? = nil,
            systemFolders: [String] = [],
            lanForwards: [LANForward] = [],
            relay: ModelRelayEndpoint? = nil
        ) {
            self.init(
                scope: scope,
                toolchains: Toolchain.readPaths(),
                runAs: runAs,
                proxy: proxy,
                systemFolders: systemFolders,
                lanForwards: lanForwards,
                relay: relay
            )
        }

        init(
            scope: SessionScope,
            toolchains: [String],
            sandboxExec: String = systemSandboxExec,
            runAs: [String] = [],
            proxy: ProxyEndpoint? = nil,
            systemFolders: [String] = [],
            lanForwards: [LANForward] = [],
            relay: ModelRelayEndpoint? = nil
        ) {
            self.scope = scope
            self.toolchains = toolchains
            self.sandboxExec = sandboxExec
            self.runAs = runAs
            self.proxy = proxy
            self.systemFolders = systemFolders
            self.lanForwards = lanForwards
            self.relay = relay
        }

        /// The agent's own Darwin temp and cache folders, as the agent's `getconf` names them inside CHANGING, each
        /// checked on disk (`AgentSystemFolders.validated`). Empty if they cannot be read or checked; then the
        /// developer stubs just print cache warnings.
        public func agentSystemFolders() -> [String] {
            let owner: uid_t
            if runAs.isEmpty {
                owner = getuid()
            } else {
                guard let entry = getpwnam(AgentEnvironment.user) else { return [] }
                owner = entry.pointee.pw_uid
            }
            return ["DARWIN_USER_TEMP_DIR", "DARWIN_USER_CACHE_DIR"].compactMap { name in
                guard let run = try? self.run(["/usr/bin/getconf", name], kind: .changing, cwd: scope.root),
                    run.status == 0
                else { return nil }
                return AgentSystemFolders.validated(
                    run.output.trimmingCharacters(in: .whitespacesAndNewlines),
                    owner: owner
                )
            }
        }

        /// The profile text for `kind`.
        public func profile(_ kind: SandboxKind) throws(SandboxError) -> String {
            do {
                switch kind {
                case .changing:
                    return try SandboxProfile.changing(
                        scope: scope,
                        proxyPort: proxy?.port,
                        systemFolders: systemFolders,
                        toolchains: toolchains,
                        lanForwards: lanForwards,
                        relayPort: relay?.port
                    )
                case .flashing(let port):
                    return try SandboxProfile.changing(
                        scope: scope,
                        serialPort: port,
                        proxyPort: proxy?.port,
                        systemFolders: systemFolders,
                        toolchains: toolchains,
                        lanForwards: lanForwards,
                        relayPort: relay?.port
                    )
                case .readOnly: return try SandboxProfile.readOnly(scope: scope, toolchains: toolchains)
                case .cloning(let target):
                    return try SandboxProfile.changing(
                        scope: scope,
                        proxyPort: proxy?.port,
                        systemFolders: systemFolders,
                        toolchains: toolchains,
                        gitTarget: target,
                        relayPort: relay?.port
                    )
                case .installing:
                    return try SandboxProfile.installing(
                        scope: scope,
                        proxyPort: proxy?.port,
                        systemFolders: systemFolders,
                        toolchains: toolchains
                    )
                }
            } catch {
                throw .profile(error)
            }
        }

        /// The full argument vector that runs `command` sandboxed, with the shared terminal's environment.
        public func argv(_ command: [String], kind: SandboxKind) throws(SandboxError) -> [String] {
            try argv(command, kind: kind, environment: AgentEnvironment.variables(scope: scope))
        }

        /// The full argument vector that runs `command` sandboxed with exactly `environment`, plus the read-only
        /// git variables in READ-ONLY or the proxy variables (with the session token) otherwise.
        func argv(_ command: [String], kind: SandboxKind, environment: [String: String]) throws(SandboxError)
            -> [String]
        {
            guard let program = command.first, !program.isEmpty, !program.hasPrefix("-"), !program.contains("="),
                !command.contains(where: { $0.utf8.contains(0) })
            else { throw .badProgram }
            var environment = environment
            if kind == .readOnly {
                environment.merge(ReadOnlyGit.environment) { $1 }
            } else if let proxy {
                environment.merge(proxy.variables) { $1 }
            }
            if let relay, kind != .readOnly, kind != .installing {
                environment.merge(relay.variables) { $1 }
            }
            let variables = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return runAs + [sandboxExec, "-p", try profile(kind), "/usr/bin/env", "-i"] + variables + command
        }

        /// Runs `command` sandboxed in `cwd` and waits. For short, bounded commands (the self-test, tests); D5 adds
        /// timeouts and output caps for Claude's commands.
        public func run(_ command: [String], kind: SandboxKind, cwd: String) throws -> SandboxRun {
            guard let result = Subprocess.run(try argv(command, kind: kind), cwd: cwd) else {
                throw SandboxError.notStarted
            }
            return result
        }

        /// Checks that the kernel applies both profiles: CHANGING may write in the agent's TMPDIR but not next to
        /// the session folder; READ-ONLY may not write even in TMPDIR. Anything unexpected fails closed.
        public func selfTest() -> SelfTest {
            let token = String(UInt64.random(in: .min ... .max), radix: 16)
            let inside = scope.agentTmp + "/.dc-selftest-\(token)"
            let outside = scope.ceiling + "/.dc-selftest-\(token)"
            defer {
                unlink(inside)
                unlink(outside)
            }
            func touch(_ path: String, _ kind: SandboxKind) -> SandboxRun? {
                try? run(["/usr/bin/touch", path], kind: kind, cwd: scope.root)
            }
            guard let allowed = touch(inside, .changing) else { return .failed("sandbox-exec could not be started") }
            guard allowed.status == 0, exists(inside) else {
                return .failed("the sandbox could not be applied: \(allowed.output.prefix(300))")
            }
            unlink(inside)
            _ = touch(outside, .changing)
            if exists(outside) { return .failed("a probe write outside the session folder succeeded") }
            _ = touch(inside, .readOnly)
            if exists(inside) { return .failed("a probe write in read-only mode succeeded") }
            // The network: a loopback port that is not the proxy's must be out of reach. Decided by whether the
            // listener got a connection, not by what the probe prints.
            guard let probe = LoopbackProbe() else { return .failed("the network probe could not listen") }
            defer { probe.close() }
            let netcat = ["/usr/bin/nc", "-z", "-G", "2", "127.0.0.1", String(probe.port)]
            _ = try? run(netcat, kind: .changing, cwd: scope.root)
            if probe.wasReached() { return .failed("a probe connection that bypasses the proxy succeeded") }
            return .passed
        }

        private func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }
    }

    /// A listener on 127.0.0.1 that only records whether anything connected, for the self-test.
    struct LoopbackProbe {
        let fd: Int32
        let port: UInt16

        init?() {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
                }
            }
            guard bound, listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                Darwin.close(fd)
                return nil
            }
            self.fd = fd
            port = UInt16(bigEndian: address.sin_port)
        }

        /// True if a connection completed (it waits in the backlog until accepted).
        func wasReached() -> Bool {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return false }
            Darwin.close(client)
            return true
        }

        func close() { Darwin.close(fd) }
    }

    /// The agent's per-user Darwin folders, checked before CHANGING may write them.
    public enum AgentSystemFolders {
        /// `path` resolved, if it is a Darwin temp or cache folder (`SandboxProfile.isDarwinUserFolder`) that is a
        /// real folder owned by `owner` that nobody else may write; otherwise `nil`.
        public static func validated(_ path: String, owner: uid_t) -> String? {
            guard let real = RealPath.resolve(path), SandboxProfile.isDarwinUserFolder(real) else { return nil }
            var info = stat()
            guard lstat(real, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner,
                info.st_mode & 0o022 == 0
            else { return nil }
            return real
        }
    }

    /// The developer tools the read-only profile must be able to read, found once at launch.
    public enum Toolchain {
        /// The selected developer folder (Xcode or the Command Line Tools), resolved.
        public static func developerDirectory() -> String? {
            guard let result = Subprocess.run(["/usr/bin/xcode-select", "-p"]), result.status == 0 else { return nil }
            return RealPath.resolve(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// Extra read-only folders for the read-only profile: the developer folder, if any.
        public static func readPaths() -> [String] {
            developerDirectory().map { [$0] } ?? []
        }

        /// The real git binary, not the `/usr/bin/git` stub (which needs files outside the read-only profile).
        public static func git() -> String? {
            let candidates =
                (developerDirectory().map { [$0 + "/usr/bin/git"] } ?? [])
                + ["/Library/Developer/CommandLineTools/usr/bin/git"]
            return candidates.first { access($0, X_OK) == 0 }.flatMap(RealPath.resolve)
        }
    }
#endif
