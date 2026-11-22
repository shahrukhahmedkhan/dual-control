/// Seatbelt profiles for every `claude-agent` process (SAFE-004), as text; the macOS layer applies them with
/// sandbox-exec, and children inherit them. In Seatbelt the last matching rule wins, so each profile denies broadly
/// first and then allows a few paths.
///
/// - CHANGING: writes only inside the session folder and the agent's HOME and TMPDIR; device writes are data only
///   (never create or unlink) on /dev/null, /dev/tty and ptys (the shared terminal needs ptys). Serial devices
///   cannot be opened at all, except by a recognised flasher or monitor (`FlasherCommand`), whose profile allows
///   only the one port it names with `-p`/`--port`. The rest of the owner's home cannot be read. Git's silent auto-executors cannot be written in any repo: hooks,
///   config (core.hooksPath, filters, aliases, fsmonitor…), info/attributes, and the `.git` entry itself (else a
///   ready-made folder could be renamed into place). Code there would later run unsandboxed as whoever runs git.
///   The agent's own HOME and TMPDIR are exempt, so toolchain installs can clone repositories there. So are the
///   agent's own Darwin temp and cache folders, if given: the /usr/bin developer stubs write xcrun's cache there.
///   Network: none, except TCP to the gatekeeper proxy on 127.0.0.1 (D7a), which decides by host name, and Unix
///   sockets in the agent's own HOME and TMPDIR. No proxy, no network.
/// - READ-ONLY (the auto-allowed tier): no writes except /dev/null and /dev/tty, no network, no serial devices
///   (opening a port can reset a board), and reads only in the session folder and system paths.
/// - INSTALLING (`esp_idf_install` only): writes only the toolchain staging folder, which no other profile may
///   write. The owner's toolchain folder is writable in none of them.
///
/// Both end by denying the scope's protected paths (the Dual Control repo), so no earlier allow can reach them.
public enum SandboxProfile {
    /// Why a profile cannot be made.
    public enum Error: Swift.Error, Equatable {
        /// The path cannot be quoted safely or is not absolute and canonical.
        case unquotable(String)
    }

    /// Read-only folders a read-only command may need in order to run.
    public static let systemReadPaths = [
        "/usr", "/bin", "/sbin", "/System", "/opt/homebrew", "/Library/Developer/CommandLineTools",
        "/private/etc", "/private/var/select", "/private/var/db/timezone",
    ]

    /// Single files and symlinks read-only commands look up.
    static let systemReadLiterals = [
        "/", "/private/var/db/xcode_select_link", "/dev/null", "/dev/zero", "/dev/random", "/dev/urandom", "/dev/tty",
    ]

    /// Folders and symlinks whose metadata path lookups need.
    static let systemMetadataLiterals = ["/etc", "/tmp", "/var", "/private", "/private/var", "/private/var/db", "/dev"]

    /// What else CHANGING may read outside the owner's home (gap 10): every developer tool folder (Command Line
    /// Tools, custom Swift toolchains), Apple's own components outside /System (xcodebuild loads MobileDevice from
    /// /Library/Apple), and the devices the shared terminal and runtimes open.
    static let changingReadPaths = ["/Library/Developer", "/Library/Apple"]
    static let changingReadLiterals = [
        "/dev/ptmx", "/dev/dtracehelper",
        // Where the /usr/bin developer stubs find that the Xcode licence was accepted.
        "/Library/Preferences/com.apple.dt.Xcode.plist",
    ]

    /// Paths git runs code from, as Seatbelt regexes on absolute paths; `(.+/)?` covers submodules and worktrees
    /// kept under `.git/`.
    static let gitAutoExecutorPatterns = [
        #"/\.git$"#, #"/\.git/(.+/)?hooks(/|$)"#, #"/\.git/(.+/)?config(\.worktree)?$"#,
        #"/\.git/(.+/)?info/attributes$"#, #"/\.git/(.+/)?(commondir|gitdir)$"#,
    ]

    /// The profile for `changing` actions and the shared terminal; with `serialPort`, for a recognised flasher or
    /// monitor that may open only that `/dev/cu.*` port. With `proxyPort`, the only network it reaches is the
    /// gatekeeper proxy on 127.0.0.1; without one, none. `systemFolders` are the agent's own Darwin temp and cache
    /// folders (`isDarwinUserFolder`), readable and writable like its HOME. `toolchains` are extra read-only folders,
    /// such as the selected Xcode. Nothing else outside the owner's home can be read (gap 10): not `/Volumes`,
    /// `/Users/Shared`, other users' homes, `/private/tmp` or the rest of `/Library`.
    public static func changing(
        scope: SessionScope,
        serialPort: String? = nil,
        proxyPort: UInt16? = nil,
        systemFolders: [String] = [],
        toolchains: [String] = [],
        lanForwards: [LANForward] = [],
        gitTarget: String? = nil,
        relayPort: UInt16? = nil
    ) throws(Error) -> String {
        for folder in systemFolders where !isDarwinUserFolder(folder) { throw .unquotable(folder) }
        let outsideHome = try allowlistedReads(scope: scope, systemFolders: systemFolders, toolchains: toolchains)
        // D7b: each approved LAN endpoint only through its forwarder's port on 127.0.0.1; Seatbelt cannot name
        // another remote address, so the device itself stays unreachable.
        let lan = lanForwards.map {
            "(allow network-outbound (remote \($0.endpoint.transport.rawValue)4 \"localhost:\($0.localPort)\"))"
        }
        var newRepository: String?
        if let gitTarget {
            // CLONING (`GitSetup`): the one new repository may get its `.git`, strictly inside the session.
            guard SessionScope.isCanonical(gitTarget), SessionScope.isStrictlyInside(gitTarget, scope.root),
                !scope.protectedPaths.contains(where: { SessionScope.isSameOrInsideIgnoringCase(gitTarget, $0) })
            else { throw .unquotable(gitTarget) }
            newRepository = "(allow file-write* (subpath \(try quoted(gitTarget))))"
        }
        let home = try quoted(parent(of: scope.ceiling))
        var onlyPort: String?
        if let serialPort {
            guard SerialPorts.isListed(serialPort) else { throw .unquotable(serialPort) }
            onlyPort = "(allow file-read* file-write-data (literal \(try quoted(serialPort))))"
        }
        let own = [scope.agentHome, scope.agentTmp]
        var sockets: [String] = []
        for side in ["local", "remote"] {
            for path in own { sockets.append("(\(side) unix-socket (subpath \(try quoted(path))))") }
        }
        return try lines([
            "(version 1)",
            "(allow default)",
            // No sockets, DNS (mDNSResponder's socket), binds or UDP; only the agent's own Unix sockets (tmux)
            // and, when it runs, the proxy. IPv4 only, so nobody can squat [::1] on the proxy's port.
            "(deny network*)",
            "(allow network* \(sockets.joined(separator: " ")))",
            proxyPort.map { #"(allow network-outbound (remote tcp4 "localhost:\#($0)"))"# },
            // D11: the app's model relay, which holds the owner's key; the agent gets only a session token.
            relayPort.map { #"(allow network-outbound (remote tcp4 "localhost:\#($0)"))"# },
            lan.isEmpty ? nil : lan.joined(separator: "\n"),
            // Reads: an allowlist. System and developer folders, then, in the owner's home, only the session and
            // the agent's work area.
            outsideHome,
            "(deny file-read* (subpath \(home)))",
            "(allow file-read* \(subpaths([scope.root, scope.workArea])))",
            "(allow file-read-metadata \(literals(ancestors(of: scope.root, below: parent(of: scope.ceiling)))))",
            "(deny file-write*)",
            "(allow file-write* \(subpaths([scope.root, scope.agentHome, scope.agentTmp])))",
            #"(allow file-write-data (literal "/dev/null") (literal "/dev/tty") "#
                + #"(literal "/dev/ptmx") (regex #"^/dev/ttys[0-9]+$"))"#,
            #"(deny file-read* file-write* (regex #"^/dev/cu\.") (regex #"^/dev/tty\."))"#,
            onlyPort,
            "(deny file-write* \(gitAutoExecutorPatterns.map { "(regex #\"\($0)\")" }.joined(separator: " ")))",
            newRepository,
            // The agent's own HOME and TMPDIR are not projects: git works normally there (toolchain installs).
            "(allow file-write* \(try subpaths([scope.agentHome, scope.agentTmp] + systemFolders)))",
            // Work scheduled for later runs outside the session, after Stop. Even in the agent's own home.
            #"(deny file-write* (regex #"/Library/LaunchAgents(/|$)") (regex #"/Library/LaunchDaemons(/|$)") "#
                + #"(subpath "/Library/StartupItems") (subpath "/usr/lib/cron") (subpath "/private/var/at"))"#,
            "(deny file-read* file-write* \(try subpaths(scope.protectedPaths)))",
            "(deny file-write* \(try literals(foldersAbove(scope.protectedPaths, within: scope.ceiling))))",
        ])
    }

    /// INSTALLING, for `esp_idf_install` only (`ESPIDFInstall`): writes only in the toolchain staging folder (and the
    /// agent's Darwin folders), which every other profile denies, so nothing else the agent runs can change what the
    /// app later copies into the owner's toolchain folder. It cannot read the agent's HOME and TMPDIR or the session
    /// folder: configuration planted there (pip.conf, .gitconfig, usercustomize.py) never reaches the install.
    /// Outside the owner's home it reads only CHANGING's allowlist (gap 10). No serial devices; network only through
    /// the proxy.
    public static func installing(
        scope: SessionScope,
        proxyPort: UInt16? = nil,
        systemFolders: [String] = [],
        toolchains: [String] = []
    ) throws(Error) -> String {
        for folder in systemFolders where !isDarwinUserFolder(folder) { throw .unquotable(folder) }
        let outsideHome = try allowlistedReads(scope: scope, systemFolders: systemFolders, toolchains: toolchains)
        let home = try quoted(parent(of: scope.ceiling))
        // Metadata only: the job starts in the session folder, and getcwd must not fail there.
        let metadata = foldersAbove([scope.toolchainStaging, scope.root], within: parent(of: scope.ceiling))
        return try lines([
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            proxyPort.map { #"(allow network-outbound (remote tcp4 "localhost:\#($0)"))"# },
            outsideHome,
            "(deny file-read* (subpath \(home)))",
            "(allow file-read* \(try subpaths([scope.toolchainStaging])))",
            "(allow file-read-metadata \(try literals(metadata + [scope.root])))",
            "(deny file-write*)",
            "(allow file-write* \(try subpaths([scope.toolchainStaging] + systemFolders)))",
            #"(allow file-write-data (literal "/dev/null") (literal "/dev/tty"))"#,
            #"(deny file-read* file-write* (regex #"^/dev/cu\.") (regex #"^/dev/tty\."))"#,
            "(deny file-read* file-write* \(try subpaths(scope.protectedPaths)))",
        ])
    }

    /// The profile the app's own copy of a finished install runs in, as the owner (`Sandbox.finishToolchain`): it
    /// reads only the staging folder in the owner's home, and outside it only CHANGING's system folders (gap 10), and
    /// writes only `install`. A link the agent left in the staging folder, or swapped in while the copy runs, cannot
    /// make the owner's copy read the owner's files.
    public static func toolchainCopy(scope: SessionScope, install: String) throws(Error) -> String {
        guard OwnerToolchain.install(of: install + "/x", scope: scope) == install else { throw .unquotable(install) }
        let outsideHome = try allowlistedReads(scope: scope, systemFolders: [], toolchains: [])
        let home = try quoted(parent(of: scope.ceiling))
        let metadata = ancestors(of: scope.toolchainStaging, below: parent(of: scope.ceiling)) + [scope.toolchains]
        return try lines([
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            outsideHome,
            "(deny file-read* (subpath \(home)))",
            "(allow file-read* \(try subpaths([scope.toolchainStaging, install])))",
            "(allow file-read-metadata \(try literals(metadata)))",
            "(deny file-write*)",
            "(allow file-write* \(try subpaths([install])))",
            #"(allow file-write-data (literal "/dev/null"))"#,
        ])
    }

    /// What CHANGING, INSTALLING and the owner's toolchain copy may read outside the owner's home (gap 10), as profile
    /// lines: deny every read, then allow the system and developer folders, `toolchains` (an Xcode as its whole
    /// bundle: its tools look at Contents/Info.plist) and `systemFolders`, and the metadata of the folders above them
    /// and above the ceiling, so realpath and getcwd work (`/opt` above `/opt/homebrew`).
    static func allowlistedReads(
        scope: SessionScope,
        systemFolders: [String],
        toolchains: [String]
    ) throws(Error) -> String {
        for toolchain in toolchains where !SessionScope.isCanonical(toolchain) || toolchain == "/" {
            throw .unquotable(toolchain)
        }
        let bundles = toolchains.map { $0.hasSuffix(".app/Contents/Developer") ? parent(of: parent(of: $0)) : $0 }
        let readFolders = systemReadPaths + changingReadPaths + bundles + systemFolders
        let reads =
            try literals(systemReadLiterals + changingReadLiterals) + #" (regex #"^/dev/ttys[0-9]+$") "#
            + #"(subpath "/dev/fd") "# + subpaths(readFolders)
        let above = try literals(systemMetadataLiterals + foldersAbove(readFolders + [scope.ceiling], within: "/"))
        return ["(deny file-read*)", "(allow file-read* \(reads))", "(allow file-read-metadata \(above))"]
            .joined(separator: "\n")
    }

    /// A per-user Darwin temp or cache folder: `/private/var/folders/<xx>/<id>/T` or `…/C`, canonical. Which user it
    /// belongs to is checked on disk by whoever finds it.
    public static func isDarwinUserFolder(_ path: String) -> Bool {
        let base = "/private/var/folders/"
        guard SessionScope.isCanonical(path), path.hasPrefix(base) else { return false }
        let parts = path.dropFirst(base.count).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && !parts[0].isEmpty && !parts[1].isEmpty && ["T", "C"].contains(parts[2])
    }

    /// The folders from `ceiling` down to just above each of `paths`, without duplicates. Renaming any of them
    /// would move a protected path out from under its `subpath` rule; creating files inside them stays allowed.
    static func foldersAbove(_ paths: [String], within ceiling: String) -> [String] {
        var seen = Set<String>()
        return paths.flatMap { ancestors(of: $0, below: ceiling) }.filter { seen.insert($0).inserted }
    }

    /// The profile for `readOnly` actions. `toolchains` are extra read-only folders, such as the selected Xcode.
    public static func readOnly(scope: SessionScope, toolchains: [String] = []) throws(Error) -> String {
        for toolchain in toolchains where !SessionScope.isCanonical(toolchain) || toolchain == "/" {
            throw .unquotable(toolchain)
        }
        let reads =
            try literals(systemReadLiterals) + " (subpath \"/dev/fd\") "
            + subpaths(systemReadPaths + toolchains + [scope.root])
        let metadata = try literals(systemMetadataLiterals + ancestors(of: scope.root, below: "/"))
        return try lines([
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            "(deny file-write*)",
            #"(allow file-write-data (literal "/dev/null") (literal "/dev/tty"))"#,
            "(deny file-read*)",
            "(allow file-read* \(reads))",
            "(allow file-read-metadata \(metadata))",
            #"(deny file-read* file-write* (regex #"^/dev/cu\.") (regex #"^/dev/tty\."))"#,
            "(deny file-write* \(try subpaths(scope.protectedPaths)))",
        ])
    }

    private static func lines(_ lines: [String?]) throws(Error) -> String {
        lines.compactMap { $0 }.joined(separator: "\n") + "\n"
    }

    /// `path` in double quotes. Only canonical absolute paths without quotes, backslashes or control characters.
    static func quoted(_ path: String) throws(Error) -> String {
        guard SessionScope.isCanonical(path),
            !path.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F })
        else { throw .unquotable(path) }
        return "\"" + path + "\""
    }

    private static func subpaths(_ paths: [String]) throws(Error) -> String {
        var parts: [String] = []
        for path in paths { parts.append("(subpath \(try quoted(path)))") }
        return parts.joined(separator: " ")
    }

    private static func literals(_ paths: [String]) throws(Error) -> String {
        var parts: [String] = []
        for path in paths { parts.append("(literal \(try quoted(path)))") }
        return parts.joined(separator: " ")
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    /// The folders above `path`, from `top` (included unless it is `/`) down, `path` itself excluded.
    static func ancestors(of path: String, below top: String) -> [String] {
        var result: [String] = []
        var current = parent(of: path)
        while current != "/" {
            result.append(current)
            if current == top { break }
            current = parent(of: current)
        }
        return result.reversed()
    }
}

/// The environment every agent process starts with; nothing is inherited from the app.
public enum AgentEnvironment {
    /// The agent user's name.
    public static let user = "claude-agent"
    /// System folders first, so bare names such as `ls` are the system's.
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

    /// The allowlist for `run_command`: nothing else, and nothing from the owner's environment.
    public static func commandVariables(scope: SessionScope) -> [String: String] {
        ["PATH": path, "HOME": scope.agentHome, "TMPDIR": scope.agentTmp + "/", "LANG": "en_US.UTF-8", "TERM": "dumb"]
    }

    /// Variables for the shared terminal in `scope`'s session folder.
    public static func variables(scope: SessionScope) -> [String: String] {
        [
            "HOME": scope.agentHome,
            "TMPDIR": scope.agentTmp + "/",
            "TMUX_TMPDIR": scope.agentTmp,
            "XDG_CACHE_HOME": scope.agentHome + "/.cache",
            "PWD": scope.root,
            "PATH": path,
            "USER": user,
            "LOGNAME": user,
            "LANG": "en_US.UTF-8",
            "SHELL": "/bin/zsh",
            "TERM": "xterm-256color",
        ]
    }
}

/// Read-only git that cannot run programs from repository or user configuration. The read-only sandbox catches
/// anything that slips through: no writes, no network.
public enum ReadOnlyGit {
    /// Ignore system and global config; never page.
    public static let environment = [
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "PAGER": "cat", "GIT_PAGER": "cat",
    ]

    /// `argv` run by `git` (a resolved binary, not the xcrun stub) with fsmonitor, pager and external diff off,
    /// or `nil` unless it is a read-only git command.
    public static func hardened(_ argv: [String], git: String) -> [String]? {
        guard argv.count >= 2, argv[0].split(separator: "/").last == "git",
            Classifier.readOnlyGitCommands.contains(argv[1])
        else { return nil }
        let subcommand = argv[1]
        let noDrivers = subcommand == "status" ? [] : ["--no-ext-diff", "--no-textconv"]
        return [git, "-c", "core.fsmonitor=", "-c", "core.pager=cat", "-c", "diff.external=", "--no-pager", subcommand]
            + noDrivers + argv.dropFirst(2)
    }
}
