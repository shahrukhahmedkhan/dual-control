import Testing

@testable import DualControlCore

private let scope = try? SessionScope(ceiling: "/Users/o/Developer", root: "/Users/o/Developer/team/p")

private func lines(_ profile: String?) -> [String] {
    (profile ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
}

/// Index of the first line equal to `line`, so tests can check order (later Seatbelt rules win).
private func position(_ line: String, in profile: [String]) -> Int? {
    profile.firstIndex(of: line)
}

// MARK: - CHANGING

@Test func changingDeniesWritesThenAllowsOnlyTheScopeAndWorkArea() throws {
    let profile = lines(try SandboxProfile.changing(scope: #require(scope)))
    #expect(profile.first == "(version 1)")
    let denyWrites = try #require(position("(deny file-write*)", in: profile))
    let allowWrites = try #require(
        position(
            #"(allow file-write* (subpath "/Users/o/Developer/team/p") "#
                + #"(subpath "/Users/o/Developer/.dual-control/agent-home") "#
                + #"(subpath "/Users/o/Developer/.dual-control/tmp"))"#,
            in: profile
        )
    )
    #expect(denyWrites < allowWrites)
    // The only other write rule: data (never create or unlink) on a few devices.
    let devices = try #require(
        position(
            #"(allow file-write-data (literal "/dev/null") (literal "/dev/tty") "#
                + #"(literal "/dev/ptmx") (regex #"^/dev/ttys[0-9]+$"))"#,
            in: profile
        )
    )
    #expect(devices > denyWrites)
    // Plus the work area again after the git rule, which is a subset of the first allow.
    #expect(profile.filter { $0.hasPrefix("(allow file-write") }.count == 3)
}

@Test func changingNeverOpensSerialDevices() throws {
    let plain = lines(try SandboxProfile.changing(scope: #require(scope)))
    let serial = try #require(
        position(#"(deny file-read* file-write* (regex #"^/dev/cu\.") (regex #"^/dev/tty\."))"#, in: plain)
    )
    // Nothing after the deny reaches /dev.
    #expect(!plain[(serial + 1)...].contains { $0.hasPrefix("(allow") && $0.contains("/dev") })
    #expect(!plain.contains { $0.hasPrefix("(allow") && $0.contains("cu\\.") })

}

@Test func changingHidesTheRestOfTheOwnersHome() throws {
    let profile = lines(try SandboxProfile.changing(scope: #require(scope)))
    let denyHome = try #require(position(#"(deny file-read* (subpath "/Users/o"))"#, in: profile))
    let allowScope = try #require(
        position(
            #"(allow file-read* (subpath "/Users/o/Developer/team/p") (subpath "/Users/o/Developer/.dual-control"))"#,
            in: profile
        )
    )
    // Path lookups need the folders above the scope, but only their metadata, never their listings.
    let ancestors = try #require(
        position(
            #"(allow file-read-metadata (literal "/Users/o") (literal "/Users/o/Developer") "#
                + #"(literal "/Users/o/Developer/team"))"#,
            in: profile
        )
    )
    #expect(denyHome < allowScope && denyHome < ancestors)
    // Without a proxy, no network at all (fail closed): only the agent's own Unix sockets (tmux).
    #expect(
        profile.filter { $0.contains("network") } == [
            "(deny network*)",
            #"(allow network* (local unix-socket (subpath "/Users/o/Developer/.dual-control/agent-home")) "#
                + #"(local unix-socket (subpath "/Users/o/Developer/.dual-control/tmp")) "#
                + #"(remote unix-socket (subpath "/Users/o/Developer/.dual-control/agent-home")) "#
                + #"(remote unix-socket (subpath "/Users/o/Developer/.dual-control/tmp")))"#,
        ]
    )
}

@Test func changingReadsOnlyAnAllowlistOutsideTheHome() throws {
    let xcode = "/Applications/Xcode.app/Contents/Developer"
    let text = try SandboxProfile.changing(scope: #require(scope), toolchains: [xcode])
    let profile = lines(text)
    let denyAll = try #require(position("(deny file-read*)", in: profile))
    let allow = try #require(profile.firstIndex { $0.hasPrefix("(allow file-read* (literal \"/\")") })
    let denyHome = try #require(position(#"(deny file-read* (subpath "/Users/o"))"#, in: profile))
    #expect(denyAll < allow && allow < denyHome)
    let reads = profile[allow]
    for folder in [
        "/usr", "/System", "/opt/homebrew", "/Library/Developer", "/Library/Apple", "/Applications/Xcode.app",
    ] {
        #expect(reads.contains("(subpath \"\(folder)\")"), "\(folder)")
    }
    // Gap 10: none of these, nor anything else outside the list.
    for folder in [
        "/Volumes", "/Users/Shared", "/private/tmp", "/Library\")", "/Applications\")", "/private/var/folders",
    ] {
        #expect(!reads.contains(folder), "\(folder)")
    }
    // Above the allowed folders and the ceiling: metadata only.
    let metadata = try #require(profile.first { $0.hasPrefix("(allow file-read-metadata (literal \"/etc\")") })
    for folder in ["/opt", "/Applications", "/Library", "/Users"] {
        #expect(metadata.contains("(literal \"\(folder)\")"), "\(folder)")
    }
    #expect(throws: SandboxProfile.Error.self) {
        try SandboxProfile.changing(scope: #require(scope), toolchains: ["/"])
    }
}

@Test func changingReachesTheNetworkOnlyThroughTheProxyPort() throws {
    let profile = lines(try SandboxProfile.changing(scope: #require(scope), proxyPort: 50123))
    let deny = try #require(position("(deny network*)", in: profile))
    // IPv4 only: nobody else can squat [::1] on the same port.
    let allow = try #require(position(#"(allow network-outbound (remote tcp4 "localhost:50123"))"#, in: profile))
    #expect(deny < allow)
    #expect(profile.filter { $0.contains("network") }.count == 3)
    #expect(!profile.contains { $0.contains("network-bind") || $0.contains("network-inbound") })
    let flashing = lines(
        try SandboxProfile.changing(scope: #require(scope), serialPort: "/dev/cu.usbserial-1", proxyPort: 50123)
    )
    #expect(flashing.contains(#"(allow network-outbound (remote tcp4 "localhost:50123"))"#))
}

@Test func readOnlyNeverReachesTheNetworkEvenWithAProxy() throws {
    let profile = lines(try SandboxProfile.readOnly(scope: #require(scope)))
    #expect(profile.filter { $0.contains("network") } == ["(deny network*)"])
}

@Test func aFlasherNamingAPortMayOpenOnlyThatPort() throws {
    let profile = lines(try SandboxProfile.changing(scope: #require(scope), serialPort: "/dev/cu.usbserial-1"))
    let denySerial = try #require(
        position(#"(deny file-read* file-write* (regex #"^/dev/cu\.") (regex #"^/dev/tty\."))"#, in: profile)
    )
    let allowPort = try #require(
        position(#"(allow file-read* file-write-data (literal "/dev/cu.usbserial-1"))"#, in: profile)
    )
    #expect(denySerial < allowPort)
    #expect(!profile.contains { $0.contains(#"(regex #"^/dev/cu\.")"#) && $0.hasPrefix("(allow") })
    #expect(throws: SandboxProfile.Error.self) {
        try SandboxProfile.changing(scope: #require(scope), serialPort: "/dev/cu.a\"b")
    }
    #expect(throws: SandboxProfile.Error.self) {
        try SandboxProfile.changing(scope: #require(scope), serialPort: "/dev/disk0")
    }
}

// MARK: - READ-ONLY

@Test func readOnlyAllowsNoWritesAndNoNetwork() throws {
    let profile = lines(try SandboxProfile.readOnly(scope: #require(scope)))
    #expect(profile.first == "(version 1)")
    let denyWrites = try #require(position("(deny file-write*)", in: profile))
    let devices = try #require(
        position(#"(allow file-write-data (literal "/dev/null") (literal "/dev/tty"))"#, in: profile)
    )
    #expect(denyWrites < devices)
    #expect(profile.filter { $0.hasPrefix("(allow file-write") }.count == 1)
    #expect(profile.contains("(deny network*)"))
    #expect(!profile.contains { $0.hasPrefix("(allow network") })
}

@Test func readOnlyReadsOnlyTheScopeAndSystemPaths() throws {
    let profile = lines(try SandboxProfile.readOnly(scope: #require(scope), toolchains: ["/Applications/Xcode.app"]))
    let denyReads = try #require(position("(deny file-read*)", in: profile))
    let allowReads = try #require(profile.firstIndex { $0.hasPrefix("(allow file-read* ") })
    #expect(denyReads < allowReads)
    let allowed = profile[allowReads]
    for path in SandboxProfile.systemReadPaths + ["/Applications/Xcode.app", "/Users/o/Developer/team/p"] {
        #expect(allowed.contains(#"(subpath "\#(path)")"#), "\(path)")
    }
    #expect(allowed.contains(#"(literal "/")"#))
    #expect(!allowed.contains(#""/Users/o/Developer/.dual-control"#))
    #expect(!allowed.contains(#"(subpath "/Users/o")"#))
    #expect(!allowed.contains(#"(subpath "/dev")"#))
}

@Test func readOnlyNeverOpensSerialDevicesAndNoAllowFollows() throws {
    let profile = lines(try SandboxProfile.readOnly(scope: #require(scope)))
    let serial = try #require(
        position(#"(deny file-read* file-write* (regex #"^/dev/cu\.") (regex #"^/dev/tty\."))"#, in: profile)
    )
    #expect(!profile[(serial + 1)...].contains { $0.hasPrefix("(allow") })
}

// MARK: - Paths that cannot be quoted safely

@Test(arguments: [
    "/Users/o/Developer/a\"b", "/Users/o/Developer/a\\b", "/Users/o/Developer/a\nb", "/Users/o/Developer/a\u{7F}",
])
func unquotablePathsAreRefused(_ root: String) throws {
    let odd = try SessionScope(ceiling: "/Users/o/Developer", root: root)
    #expect(throws: SandboxProfile.Error.self) { try SandboxProfile.changing(scope: odd) }
    #expect(throws: SandboxProfile.Error.self) { try SandboxProfile.readOnly(scope: odd) }
}

@Test(arguments: ["relative", "/Applications/../x", "/a\"b", ""])
func oddToolchainsAreRefused(_ toolchain: String) throws {
    #expect(throws: SandboxProfile.Error.self) {
        try SandboxProfile.readOnly(scope: #require(scope), toolchains: [toolchain])
    }
}

@Test func unicodePathsAreQuotedAsIs() throws {
    let odd = try SessionScope(ceiling: "/Users/o/Developer", root: "/Users/o/Developer/caf\u{E9} x")
    #expect(try SandboxProfile.changing(scope: odd).contains(#"(subpath "/Users/o/Developer/caf\#u{E9} x")"#))
}

// MARK: - Agent environment

@Test func agentEnvironmentKeepsHomeAndTempInTheWorkArea() throws {
    let environment = try AgentEnvironment.variables(scope: #require(scope))
    #expect(environment["HOME"] == "/Users/o/Developer/.dual-control/agent-home")
    #expect(environment["TMPDIR"] == "/Users/o/Developer/.dual-control/tmp/")
    #expect(environment["TMUX_TMPDIR"] == "/Users/o/Developer/.dual-control/tmp")
    #expect(environment["XDG_CACHE_HOME"] == "/Users/o/Developer/.dual-control/agent-home/.cache")
    #expect(environment["PWD"] == "/Users/o/Developer/team/p")
    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
    #expect(environment["USER"] == "claude-agent")
    #expect(environment["LOGNAME"] == "claude-agent")
    #expect(environment["SHELL"] == "/bin/zsh")
    #expect(environment["TERM"] == "xterm-256color")
}

// MARK: - Read-only git

@Test(
    arguments: [
        (["git", "status"], ["status"]),
        (["git", "status", "--short"], ["status", "--short"]),
        (["/usr/bin/git", "log", "-p", "--", "a"], ["log", "--no-ext-diff", "--no-textconv", "-p", "--", "a"]),
        (["git", "diff"], ["diff", "--no-ext-diff", "--no-textconv"]),
        (["git", "show", "HEAD"], ["show", "--no-ext-diff", "--no-textconv", "HEAD"]),
    ]
)
func readOnlyGitIsHardened(_ argv: [String], _ rest: [String]) {
    let git = "/Library/Developer/CommandLineTools/usr/bin/git"
    let prefix = [git, "-c", "core.fsmonitor=", "-c", "core.pager=cat", "-c", "diff.external=", "--no-pager"]
    #expect(ReadOnlyGit.hardened(argv, git: git) == prefix + rest)
}

@Test(arguments: [["git"], ["git", "commit"], ["git", "-C", "x", "status"], ["gitk", "log"], ["ls"], []])
func onlyReadOnlyGitIsHardened(_ argv: [String]) {
    #expect(ReadOnlyGit.hardened(argv, git: "/usr/bin/git") == nil)
}

@Test func readOnlyGitEnvironmentIgnoresSystemAndGlobalConfig() {
    #expect(
        ReadOnlyGit.environment == [
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "PAGER": "cat", "GIT_PAGER": "cat",
        ]
    )
}

@Test(arguments: ["--textconv", "--textc", "--text"])
func gitTextconvIsNotReadOnly(_ option: String) {
    let request = ActionRequest(capability: .command, argv: ["git", "log", option], cwd: "/w", projectID: "/w")
    #expect(Classifier.classify(request).tier != .readOnly)
}

// MARK: - Self-protection and git

private let protectedScope = try? SessionScope(
    ceiling: "/Users/o/Developer",
    root: "/Users/o/Developer/team",
    protected: ["/Users/o/Developer/team/dc"]
)

@Test func changingAlwaysDeniesTheProtectedPathsLast() throws {
    let profile = lines(try SandboxProfile.changing(scope: #require(protectedScope)))
    let deny =
        #"(deny file-read* file-write* (subpath "/Users/o/Developer/dual-control") "#
        + #"(subpath "/Users/o/Developer/team/dc"))"#
    let index = try #require(position(deny, in: profile))
    // Later rules win in Seatbelt: nothing after it may allow anything.
    #expect(!profile[(index + 1)...].contains { $0.hasPrefix("(allow") })
    // Renaming a folder above a protected path would move it out from under the deny.
    let above = #"(deny file-write* (literal "/Users/o/Developer") (literal "/Users/o/Developer/team"))"#
    #expect(profile.contains(above))
}

@Test func readOnlyAlwaysDeniesWritesToTheProtectedPathsLast() throws {
    let profile = lines(try SandboxProfile.readOnly(scope: #require(protectedScope)))
    let deny = #"(deny file-write* (subpath "/Users/o/Developer/dual-control") (subpath "/Users/o/Developer/team/dc"))"#
    let index = try #require(position(deny, in: profile))
    #expect(!profile[(index + 1)...].contains { $0.hasPrefix("(allow") })
}

@Test func changingDeniesGitAutoExecutorsAfterTheAllows() throws {
    let profile = lines(try SandboxProfile.changing(scope: #require(scope)))
    let allowWrites = try #require(profile.firstIndex { $0.hasPrefix("(allow file-write* (subpath") })
    let git = try #require(profile.firstIndex { $0.hasPrefix("(deny file-write*") && $0.contains("hooks") })
    #expect(git > allowWrites)
    // The one allow after it gives the agent's own HOME and TMPDIR back: toolchain installs clone repos there.
    let workArea =
        #"(allow file-write* (subpath "/Users/o/Developer/.dual-control/agent-home") "#
        + #"(subpath "/Users/o/Developer/.dual-control/tmp"))"#
    #expect(profile[(git + 1)...].filter { $0.hasPrefix("(allow") } == [workArea])
    for pattern in [
        #"/\.git$"#, #"/\.git/(.+/)?hooks(/|$)"#, #"/\.git/(.+/)?config(\.worktree)?$"#,
        #"/\.git/(.+/)?info/attributes$"#, #"/\.git/(.+/)?(commondir|gitdir)$"#,
    ] {
        #expect(profile[git].contains("(regex #\"\(pattern)\")"))
    }
}

@Test func changingDeniesPersistenceLocationsAfterEveryAllow() throws {
    let profile = lines(try SandboxProfile.changing(scope: #require(scope)))
    let deny = try #require(profile.firstIndex { $0.hasPrefix("(deny file-write*") && $0.contains("LaunchAgents") })
    #expect(!profile[(deny + 1)...].contains { $0.hasPrefix("(allow") })
    for part in [
        #"(regex #"/Library/LaunchAgents(/|$)")"#, #"(regex #"/Library/LaunchDaemons(/|$)")"#,
        #"(subpath "/Library/StartupItems")"#, #"(subpath "/usr/lib/cron")"#, #"(subpath "/private/var/at")"#,
    ] {
        #expect(profile[deny].contains(part), "\(part)")
    }
}

// MARK: - The agent's own Darwin temp and cache folders (D9c)

private let darwinTemp = "/private/var/folders/qq/abc123_0000gp/T"
private let darwinCache = "/private/var/folders/qq/abc123_0000gp/C"

@Test func changingLetsTheAgentWriteItsOwnDarwinTempAndCacheFolders() throws {
    // The /usr/bin developer stubs (git, python3) write xcrun's cache there whatever TMPDIR says (live).
    let profile = lines(
        try SandboxProfile.changing(scope: #require(scope), systemFolders: [darwinTemp, darwinCache])
    )
    let git = try #require(profile.firstIndex { $0.hasPrefix("(deny file-write*") && $0.contains("hooks") })
    let own =
        #"(allow file-write* (subpath "/Users/o/Developer/.dual-control/agent-home") "#
        + #"(subpath "/Users/o/Developer/.dual-control/tmp") "#
        + #"(subpath "/private/var/folders/qq/abc123_0000gp/T") "#
        + #"(subpath "/private/var/folders/qq/abc123_0000gp/C"))"#
    #expect(profile[(git + 1)...].filter { $0.hasPrefix("(allow") } == [own])
    let persistence = try #require(profile.firstIndex { $0.contains("LaunchAgents") })
    #expect(try #require(position(own, in: profile)) < persistence)
}

@Test(
    arguments: [
        "/var/folders/qq/abc123_0000gp/T", "/private/var/folders/qq/abc123_0000gp", "/private/var/folders/qq/T",
        "/private/var/folders/qq/abc123_0000gp/T/sub", "/private/var/folders/qq/abc123_0000gp/X",
        "/private/var/folders/../tmp/x/T", "/tmp/a/b/T", "/private/var/folders/qq/a\"b/T", "",
    ]
)
func onlyDarwinTempAndCacheFoldersCanBeOpened(_ folder: String) throws {
    let scope = try #require(scope)
    #expect(throws: SandboxProfile.Error.self) {
        try SandboxProfile.changing(scope: scope, systemFolders: [folder])
    }
}
