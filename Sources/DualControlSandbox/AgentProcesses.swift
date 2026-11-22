#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// A process found by `AgentProcesses.list`.
    public struct AgentProcess: Sendable, Equatable {
        /// Process id.
        public let pid: pid_t
        /// Short command name, as the kernel keeps it.
        public let name: String
    }

    /// The off switch: Stop, quitting and the next launch after a crash end every process the agent user owns,
    /// whoever started it and whichever process group or session it is in (setsid, daemons, the shared terminal).
    public enum AgentProcesses {
        /// Every live process whose real or effective uid is `uid`, from the kernel's process table.
        public static func list(uid: uid_t) -> [AgentProcess] {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            let stride = MemoryLayout<kinfo_proc>.stride
            for _ in 0..<5 {
                var size = 0
                guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
                // Room for processes started between the two calls.
                var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
                size = table.count * stride
                guard sysctl(&mib, 3, &table, &size, nil, 0) == 0 else {
                    if errno == ENOMEM { continue }
                    return []
                }
                return table.prefix(size / stride).compactMap { entry in
                    let process = entry.kp_proc
                    guard process.p_stat != SZOMB,
                        entry.kp_eproc.e_pcred.p_ruid == uid || entry.kp_eproc.e_ucred.cr_uid == uid
                    else { return nil }
                    let name = withUnsafeBytes(of: process.p_comm) { raw in
                        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    return AgentProcess(pid: process.p_pid, name: name)
                }
            }
            return []
        }

        /// `kill -KILL -1` as the agent: every process the agent may signal, except the kill itself. Run through the
        /// owner's one sudoers rule, in a sandbox that restricts nothing, since the owner may not signal the agent.
        static func killArgv(runAs: [String]) -> [String] {
            runAs + [Sandbox.systemSandboxExec, "-p", "(version 1)(allow default)", "/bin/kill", "-KILL", "-1"]
        }

        /// Ends every process of `user` and returns the ones still alive afterwards (empty when the user does not
        /// exist). Blocks for at most about a second.
        public static func endAll(
            user: String = AgentEnvironment.user,
            runAs: [String] = SetupGuide.runAsAgent
        ) -> [AgentProcess] {
            guard let entry = getpwnam(user) else { return [] }
            let uid = entry.pointee.pw_uid
            return end(
                kill: { _ = Subprocess.run(killArgv(runAs: runAs)) },
                list: { list(uid: uid) },
                rounds: 3,
                settle: 0.3
            )
        }

        /// Kills and re-lists until nothing is left or `rounds` kills have been tried; `settle` is the wait for the
        /// kernel to reap after each kill.
        static func end(
            kill: () -> Void,
            list: () -> [AgentProcess],
            rounds: Int,
            settle: TimeInterval
        ) -> [AgentProcess] {
            var alive = list()
            var round = 0
            while !alive.isEmpty, round < rounds {
                kill()
                round += 1
                // Poll, so the usual case returns as soon as the table is clear.
                let deadline = Date().addingTimeInterval(settle)
                repeat {
                    alive = list()
                    if alive.isEmpty || settle <= 0 { break }
                    usleep(20_000)
                } while Date() < deadline
            }
            return alive
        }
    }
#endif
