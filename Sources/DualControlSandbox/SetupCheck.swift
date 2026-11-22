#if canImport(Darwin)
    import CMembership
    import Darwin
    import DualControlCore
    import Foundation

    /// "Check setup": verifies each part of the agent setup and reports green or red. Read-only; it never changes
    /// anything, and it runs nothing as the agent unless the agent user exists.
    public struct SetupCheck: Sendable {
        /// One checked item.
        public struct Item: Sendable, Equatable, Identifiable {
            /// Stable identifier.
            public let id: String
            /// What is checked.
            public let title: String
            /// Whether it is set up correctly.
            public let passed: Bool
            /// What was found.
            public let detail: String
        }

        /// The Homebrew tmux the shared terminal uses.
        public static let homebrewTmux = "/opt/homebrew/bin/tmux"

        let agent: String
        let tmux: String
        var runAs: [String] { ["/usr/bin/sudo", "-n", "-u", agent, "--"] }

        /// A check for the production agent user.
        public init() {
            self.init(agent: AgentEnvironment.user)
        }

        init(agent: String, tmux: String = homebrewTmux) {
            self.agent = agent
            self.tmux = tmux
        }

        /// Runs every check. The sandbox self-test needs a session folder.
        public func run(scope: SessionScope?) -> [Item] {
            let entry = getpwnam(agent)
            let exists = entry != nil
            let missing = "the user \(agent) does not exist"
            var items: [Item] = []
            func add(_ id: String, _ title: String, _ passed: Bool, _ detail: String) {
                items.append(Item(id: id, title: title, passed: passed, detail: detail))
            }

            add("user", "Agent user exists", exists, exists ? "\(agent) exists" : missing)

            let home = entry.map { String(cString: $0.pointee.pw_dir) }
            if let home, let scope {
                let matches = RealPath.resolve(home) == scope.agentHome
                add("home", "Agent home is in the work area", matches, matches ? home : "home is \(home)")
            } else {
                add("home", "Agent home is in the work area", false, exists ? "choose a session folder first" : missing)
            }

            let groupsTitle = "Agent is in no privileged group"
            switch Self.privilegedMemberships(agent) {
            case []?: add("groups", groupsTitle, true, "\(agent) is a standard user in none of \(groupList)")
            case let found?: add("groups", groupsTitle, false, "\(agent) is in \(found.joined(separator: ", "))")
            case nil: add("groups", groupsTitle, false, exists ? "group membership could not be checked" : missing)
            }

            let sudo = exists ? sudoRights() : (false, missing)
            add("sudo", "Agent has no sudo rights", sudo.0, sudo.1)

            if let scope {
                let shared = Self.aclGrants(user: agent, on: scope.ceiling)
                add(
                    "acl",
                    "Developer folder is shared with the agent",
                    shared,
                    shared ? "inheriting ACL present" : "no inheriting ACL for \(agent) on the Developer folder"
                )
                let denyTitle = "Dual Control folder is denied to the agent"
                if !exists {
                    add("acl-deny", denyTitle, false, missing)
                } else if let repo = RealPath.resolve(scope.ceiling + "/" + SessionScope.protectedFolderName) {
                    let denied = Self.aclDenies(user: agent, on: repo)
                    add(
                        "acl-deny",
                        denyTitle,
                        denied,
                        denied ? "deny entry comes first" : "no deny entry for \(agent) ahead of its allow on \(repo)"
                    )
                } else {
                    add("acl-deny", denyTitle, true, "there is no Dual Control folder in the Developer folder")
                }
                let folders = [scope.agentHome, scope.agentTmp].allSatisfy(Self.isOwnedDirectory)
                add(
                    "folders",
                    "Work area folders exist",
                    folders,
                    folders ? "agent-home and tmp exist" : "agent-home or tmp is missing or not yours"
                )
            } else {
                add("acl", "Developer folder is shared with the agent", false, "choose a session folder first")
                add("acl-deny", "Dual Control folder is denied to the agent", false, "choose a session folder first")
                add("folders", "Work area folders exist", false, "choose a session folder first")
            }

            let trusted = Self.isTrustedExecutable(tmux)
            add("tmux", "tmux is installed", trusted, trusted ? tmux : "\(tmux) is missing or writable by others")

            if let scope, exists {
                switch Sandbox(scope: scope, runAs: runAs).selfTest() {
                case .passed: add("sandbox", "Sandbox self-test as the agent", true, "both profiles enforced")
                case .failed(let reason): add("sandbox", "Sandbox self-test as the agent", false, reason)
                }
            } else {
                add(
                    "sandbox",
                    "Sandbox self-test as the agent",
                    false,
                    scope == nil ? "choose a session folder first" : missing
                )
            }
            return items
        }

        /// Asks sudo, as the agent, what the agent may run. Started through the owner's one sudoers rule, in a
        /// sandbox that restricts nothing, since sudo must read its own state.
        private func sudoRights() -> (Bool, String) {
            let prefix = runAs + [Sandbox.systemSandboxExec, "-p", "(version 1)(allow default)"]
            guard let probe = Subprocess.run(prefix + ["/usr/bin/true"]), probe.status == 0 else {
                return (false, "the sudoers rule for Dual Control is missing or not valid")
            }
            guard let list = Subprocess.run(prefix + ["/usr/bin/sudo", "-n", "-l"]) else {
                return (false, "sudo could not be started")
            }
            return Self.sudoVerdict(agent: agent, list)
        }

        /// What `sudo -n -l`, run as the agent inside the sandbox, says about its rights. Passes when sudo refuses,
        /// or when the sandbox will not even start it; anything else, above all output listing commands, fails.
        static func sudoVerdict(agent: String, _ list: SandboxRun) -> (Bool, String) {
            let blocked = "sandbox-exec: execvp() of '/usr/bin/sudo' failed: Operation not permitted"
            if list.status != 0, list.output.trimmingCharacters(in: .whitespacesAndNewlines) == blocked {
                return (true, "sudo can't even start inside the sandbox")
            }
            if list.status != 0, list.output.contains("may not run sudo"), !list.output.contains("may run") {
                return (true, "\(agent) may not run sudo")
            }
            return (false, "\(agent) may have sudo rights: \(list.output.prefix(200))")
        }

        /// Groups the agent must not be in: admin and wheel (sudo and system rights), tty (writing to other users'
        /// terminals) and _developer (debugging other processes).
        static let privilegedGroups = ["admin", "wheel", "tty", "_developer"]
        private var groupList: String { Self.privilegedGroups.joined(separator: ", ") }

        /// The privileged groups `user` is in, directly or nested, or `nil` if any of them cannot be checked.
        static func privilegedMemberships(_ user: String) -> [String]? {
            var found: [String] = []
            for group in privilegedGroups {
                guard let member = isMember(user, of: group) else { return nil }
                if member { found.append(group) }
            }
            return found
        }

        /// Whether `user` is in `group`, or `nil` if either does not exist.
        static func isMember(_ user: String, of group: String) -> Bool? {
            var groupID = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            guard var userID = uuid(ofUser: user), let entry = getgrnam(group),
                mbr_gid_to_uuid(entry.pointee.gr_gid, &groupID) == 0
            else { return nil }
            var member: Int32 = 0
            guard mbr_check_membership(&userID, &groupID, &member) == 0 else { return nil }
            return member != 0
        }

        /// True if `path` has an inheriting allow entry giving `user` read, write and delete rights, without the
        /// right to change permissions or owners, and no deny entry for `user`.
        static func aclGrants(user: String, on path: String) -> Bool {
            guard var userID = uuid(ofUser: user), let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
                return false
            }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            let required: [acl_perm_t] = [
                ACL_LIST_DIRECTORY, ACL_ADD_FILE, ACL_SEARCH, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD, ACL_DELETE,
                ACL_READ_ATTRIBUTES, ACL_WRITE_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
            ]
            var granted = false
            var entry: acl_entry_t?
            var which = ACL_FIRST_ENTRY.rawValue
            while acl_get_entry(acl, Int32(which), &entry) == 0, let current = entry {
                which = ACL_NEXT_ENTRY.rawValue
                guard let qualifier = acl_get_qualifier(current) else { continue }
                let isUser = withUnsafeBytes(of: &userID) { wanted in
                    memcmp(qualifier, wanted.baseAddress, MemoryLayout<uuid_t>.size) == 0
                }
                acl_free(qualifier)
                guard isUser else { continue }
                var tag = ACL_UNDEFINED_TAG
                guard acl_get_tag_type(current, &tag) == 0 else { return false }
                if tag == ACL_EXTENDED_DENY { return false }
                guard tag == ACL_EXTENDED_ALLOW else { continue }
                var permissions: acl_permset_t?
                var flags: acl_flagset_t?
                guard acl_get_permset(current, &permissions) == 0, let permissions,
                    acl_get_flagset_np(UnsafeMutableRawPointer(current), &flags) == 0, let flags
                else { return false }
                if acl_get_perm_np(permissions, ACL_WRITE_SECURITY) == 1
                    || acl_get_perm_np(permissions, ACL_CHANGE_OWNER) == 1
                {
                    return false
                }
                if required.allSatisfy({ acl_get_perm_np(permissions, $0) == 1 }),
                    acl_get_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 1,
                    acl_get_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 1
                {
                    granted = true
                }
            }
            return granted
        }

        /// True if the first ACL entry for `user` on `path` is an inheriting deny of everything the setup step
        /// allows (read, write, delete, listing), so it wins over any allow that follows.
        static func aclDenies(user: String, on path: String) -> Bool {
            guard var userID = uuid(ofUser: user), let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
                return false
            }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            let required: [acl_perm_t] = [
                ACL_READ_DATA, ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_EXECUTE, ACL_DELETE, ACL_DELETE_CHILD,
                ACL_READ_ATTRIBUTES, ACL_WRITE_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
            ]
            var entry: acl_entry_t?
            var which = ACL_FIRST_ENTRY.rawValue
            while acl_get_entry(acl, Int32(which), &entry) == 0, let current = entry {
                which = ACL_NEXT_ENTRY.rawValue
                guard let qualifier = acl_get_qualifier(current) else { continue }
                let isUser = withUnsafeBytes(of: &userID) { wanted in
                    memcmp(qualifier, wanted.baseAddress, MemoryLayout<uuid_t>.size) == 0
                }
                acl_free(qualifier)
                guard isUser else { continue }
                // Only the first entry for the user counts: macOS stops at the first entry that decides a right.
                var tag = ACL_UNDEFINED_TAG
                var permissions: acl_permset_t?
                var flags: acl_flagset_t?
                guard acl_get_tag_type(current, &tag) == 0, tag == ACL_EXTENDED_DENY,
                    acl_get_permset(current, &permissions) == 0, let permissions,
                    acl_get_flagset_np(UnsafeMutableRawPointer(current), &flags) == 0, let flags
                else { return false }
                return required.allSatisfy { acl_get_perm_np(permissions, $0) == 1 }
                    && acl_get_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 1
                    && acl_get_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 1
            }
            return false
        }

        /// The directory UUID of `user`, or `nil` if there is no such user.
        static func uuid(ofUser user: String) -> uuid_t? {
            var id = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            guard let entry = getpwnam(user), mbr_uid_to_uuid(entry.pointee.pw_uid, &id) == 0 else { return nil }
            return id
        }

        /// A real directory (not a symlink) owned by the user running the app.
        static func isOwnedDirectory(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
        }

        /// A regular executable file, after symlinks, owned by root or the user running the app and writable by
        /// nobody else.
        static func isTrustedExecutable(_ path: String) -> Bool {
            var info = stat()
            guard let resolved = RealPath.resolve(path), stat(resolved, &info) == 0 else { return false }
            return info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o111 == 0o111 && info.st_mode & 0o022 == 0
                && (info.st_uid == 0 || info.st_uid == getuid())
        }
    }

    /// Runs a short, bounded program with an empty environment and waits for it.
    enum Subprocess {
        static func run(_ argv: [String], cwd: String? = nil) -> SandboxRun? {
            guard let program = argv.first else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = Array(argv.dropFirst())
            process.environment = [:]
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let status =
                process.terminationReason == .uncaughtSignal
                ? 128 + process.terminationStatus : process.terminationStatus
            return SandboxRun(status: status, output: String(decoding: data, as: UTF8.self))
        }
    }
#endif
