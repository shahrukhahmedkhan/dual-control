#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlSandbox

    /// A fake owner home in a temporary folder, used as the ceiling (tests only; production uses
    /// `DeveloperCeiling`). The kernel enforces these profiles for any user, so the tests run as the test user:
    /// everything denied here is something that user could otherwise do.
    ///
    ///     <base>/home/Developer/p          the session folder
    ///     <base>/home/Developer/other      another project
    ///     <base>/home/Developer/.dual-control/{agent-home,tmp}
    ///     <base>/home/Documents/secret.txt
    ///     <base>/outside                   outside the home
    ///     <base>/home/Developer/dual-control      the Dual Control repo (protected by name)
    ///     <base>/home/Developer/p/vendor/dc       a DualControl clone inside the session (protected)
    ///     <base>/home/Developer/p/repo/.git       a git repository inside the session
    private final class Fixture {
        let base: String
        let scope: SessionScope
        let sandbox: Sandbox

        var home: String { base + "/home" }
        var root: String { scope.root }
        var other: String { scope.ceiling + "/other" }
        var outside: String { base + "/outside" }

        init() throws {
            // Short and labelled: tmux sockets must fit in 104 bytes.
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in [
                "/home/Developer/p/sub", "/home/Developer/other", "/home/Developer/.dual-control/agent-home",
                "/home/Developer/.dual-control/tmp", "/home/Documents", "/outside", "/home/Developer/dual-control",
                "/home/Developer/p/vendor/dc", "/home/Developer/p/repo/.git/hooks", "/home/Developer/p/repo/.git/info",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            for file in [
                "/home/Developer/p/a.txt", "/home/Developer/other/o.txt", "/home/Documents/secret.txt",
                "/outside/x.txt", "/home/Developer/.dual-control/agent-home/h.txt",
                "/home/Developer/dual-control/r.txt", "/home/Developer/p/repo/.git/config",
                "/home/Developer/p/repo/.git/HEAD",
            ] {
                try Data("DC-TEST\n".utf8).write(to: URL(fileURLWithPath: base + file))
            }
            try Data("let package = Package(name: \"DualControl\")\n".utf8)
                .write(to: URL(fileURLWithPath: base + "/home/Developer/p/vendor/dc/Package.swift"))
            scope = try ResolvedScope.make(choosing: base + "/home/Developer/p", ceiling: base + "/home/Developer")
            sandbox = Sandbox(scope: scope, toolchains: Toolchain.readPaths())
        }

        deinit {
            try? FileManager.default.removeItem(atPath: base)
        }

        func run(_ kind: SandboxKind, _ argv: [String]) throws -> SandboxRun {
            try sandbox.run(argv, kind: kind, cwd: root)
        }

        func sh(_ kind: SandboxKind, _ script: String) throws -> SandboxRun {
            try run(kind, ["/bin/sh", "-c", script])
        }

        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }

        func contents(_ path: String) -> String? {
            try? String(contentsOfFile: path, encoding: .utf8)
        }
    }

    private func notPermitted(_ run: SandboxRun) -> Bool {
        run.status != 0 && run.output.contains("Operation not permitted")
    }

    // MARK: - CHANGING

    @Test func changingWorksInsideTheScopeAndWorkArea() throws {
        let f = try Fixture()
        let script = """
            set -e
            echo DC-TEST > b.txt; mv b.txt c.txt; ln c.txt d.txt; ln -s c.txt e.txt; echo more >> e.txt
            chmod 600 c.txt; mkdir -p deep/er; rm -rf sub deep; echo DC-TEST > "$HOME/new.txt"; echo t > "$TMPDIR/t"
            echo ok > /dev/null
            """
        let result = try f.sh(.changing, script)
        #expect(result.status == 0, "\(result.output)")
        #expect(f.contents(f.root + "/c.txt") == "DC-TEST\nmore\n")
        #expect(!f.exists(f.root + "/sub"))
        #expect(f.exists(f.scope.agentHome + "/new.txt"))
        #expect(f.exists(f.scope.agentTmp + "/t"))
    }

    @Test func changingCannotWriteOutsideTheScope() throws {
        let f = try Fixture()
        for target in [
            f.other + "/new.txt", f.home + "/Documents/new.txt", f.outside + "/new.txt",
            f.scope.ceiling + "/new.txt", f.scope.workArea + "/new.txt", f.base + "/new.txt",
        ] {
            #expect(notPermitted(try f.sh(.changing, "echo DC-TEST > '\(target)'")), "\(target)")
            #expect(!f.exists(target), "\(target)")
        }
    }

    @Test func changingCannotDeleteRenameOrChangeOutsideTheScope() throws {
        let f = try Fixture()
        // rm -f hides the error, so check what is left, not only the exit status.
        _ = try f.sh(.changing, "rm -rf '\(f.other)' '\(f.outside)' '\(f.home)/Documents'")
        #expect(f.contents(f.other + "/o.txt") == "DC-TEST\n")
        #expect(f.contents(f.outside + "/x.txt") == "DC-TEST\n")
        #expect(f.contents(f.home + "/Documents/secret.txt") == "DC-TEST\n")
        #expect(notPermitted(try f.sh(.changing, "mv '\(f.outside)/x.txt' a2.txt")))
        #expect(notPermitted(try f.sh(.changing, "mv a.txt '\(f.outside)/a.txt'")))
        #expect(notPermitted(try f.sh(.changing, "chmod 777 '\(f.outside)/x.txt'")))
        #expect(notPermitted(try f.sh(.changing, "xattr -w dc.test 1 '\(f.outside)/x.txt'")))
        #expect(notPermitted(try f.sh(.changing, "touch -t 200001010000 '\(f.outside)/x.txt'")))
        #expect(f.exists(f.outside + "/x.txt") && f.exists(f.root + "/a.txt"))
    }

    @Test func changingCannotReachOutsideThroughLinks() throws {
        let f = try Fixture()
        // A symlink inside the scope that points out: following it to write is denied.
        #expect(symlink(f.outside + "/x.txt", f.root + "/out-link") == 0)
        #expect(symlink(f.other, f.root + "/other-link") == 0)
        #expect(notPermitted(try f.sh(.changing, "echo pwn > out-link")))
        #expect(notPermitted(try f.sh(.changing, "echo pwn > other-link/o.txt")))
        _ = try f.sh(.changing, "rm -rf other-link/")
        #expect(f.contents(f.outside + "/x.txt") == "DC-TEST\n")
        #expect(f.contents(f.other + "/o.txt") == "DC-TEST\n")
        // Hard links: neither pulling an outside file in nor pushing one out.
        #expect(notPermitted(try f.sh(.changing, "ln '\(f.other)/o.txt' pulled.txt")))
        #expect(notPermitted(try f.sh(.changing, "ln a.txt '\(f.other)/pushed.txt'")))
        #expect(!f.exists(f.root + "/pulled.txt") && !f.exists(f.other + "/pushed.txt"))
    }

    @Test func changingCannotReadTheRestOfTheOwnersHome() throws {
        let f = try Fixture()
        #expect(notPermitted(try f.sh(.changing, "cat '\(f.other)/o.txt'")))
        #expect(notPermitted(try f.sh(.changing, "cat '\(f.home)/Documents/secret.txt'")))
        #expect(notPermitted(try f.sh(.changing, "ls '\(f.home)'")))
        #expect(notPermitted(try f.sh(.changing, "ls '\(f.scope.ceiling)'")))
        let reads = try f.sh(.changing, "cat a.txt \"$HOME/h.txt\" && ls /usr/bin >/dev/null && pwd")
        #expect(reads.status == 0, "\(reads.output)")
        #expect(reads.output == "DC-TEST\nDC-TEST\n\(f.root)\n")
    }

    @Test func protectedFoldersStayUnreachableEvenInsideTheScope() throws {
        let f = try Fixture()
        let clone = f.root + "/vendor/dc"
        #expect(f.scope.protectedPaths == [f.scope.ceiling + "/dual-control", clone])
        for kind in [SandboxKind.changing, .readOnly] {
            #expect(notPermitted(try f.sh(kind, "echo DC-TEST > vendor/dc/new.txt")), "\(kind)")
        }
        #expect(notPermitted(try f.sh(.changing, "cat vendor/dc/Package.swift")))
        #expect(notPermitted(try f.sh(.changing, "ls vendor/dc")))
        #expect(notPermitted(try f.sh(.changing, "cat '\(f.scope.ceiling)/dual-control/r.txt'")))
        #expect(notPermitted(try f.sh(.changing, "echo x > '\(f.scope.ceiling)/dual-control/r.txt'")))
        // Moving the clone, or a folder above it, would take it out from under the deny rule.
        #expect(notPermitted(try f.sh(.changing, "mv vendor/dc dc2")))
        #expect(notPermitted(try f.sh(.changing, "mv vendor vendor2")))
        _ = try f.sh(.changing, "rm -rf vendor")
        #expect(f.exists(clone + "/Package.swift") && !f.exists(f.root + "/dc2") && !f.exists(f.root + "/vendor2"))
        // Other files next to the clone are still the agent's to change.
        #expect(try f.sh(.changing, "echo DC-TEST > vendor/ok.txt && rm vendor/ok.txt").status == 0)
        #expect(f.contents(f.scope.ceiling + "/dual-control/r.txt") == "DC-TEST\n")
    }

    @Test func changingCannotPlantGitAutoExecutors() throws {
        let f = try Fixture()
        for script in [
            "echo DC-TEST > repo/.git/hooks/pre-commit",
            "echo '[core] hooksPath = /x' >> repo/.git/config",
            "echo '* filter=x' > repo/.git/info/attributes",
            "mv repo/.git repo/.git-old",
            "rm -rf repo/.git",
            "mkdir -p fake/hooks && mv fake repo2.git && mkdir -p r3 && mv repo2.git r3/.git",
            "mkdir -p new/.git",
            "echo 'gitdir: ../fake' > sub/.git",
            "mkdir -p repo/.git/modules/s && echo DC-TEST > repo/.git/modules/s/config",
            "mkdir -p repo/.git/modules/s/hooks",
            "mkdir -p repo/.git/worktrees/w && echo /x > repo/.git/worktrees/w/commondir",
            "echo DC-TEST > repo/.git/config.worktree",
        ] {
            #expect(notPermitted(try f.sh(.changing, script)), "\(script)")
        }
        #expect(f.contents(f.root + "/repo/.git/config") == "DC-TEST\n")
        #expect(!f.exists(f.root + "/repo/.git/hooks/pre-commit") && !f.exists(f.root + "/r3/.git"))
        // Ordinary git data (objects, refs, HEAD) stays writable, so commits in existing repos work.
        let ordinary =
            "mkdir -p repo/.git/objects/ab && echo DC-TEST > repo/.git/objects/ab/cd && echo x > repo/.git/HEAD"
        #expect(try f.sh(.changing, ordinary).status == 0)
    }

    /// Toolchain installs (ESP-IDF and others) clone repositories into the agent's own HOME or TMPDIR, so git
    /// works normally there; the protection stays for every project.
    @Test func gitWorksNormallyInTheAgentsWorkArea() throws {
        let f = try Fixture()
        for folder in ["$HOME", "$TMPDIR"] {
            let script = """
                set -e
                mkdir -p "\(folder)/r/.git/hooks" "\(folder)/r/.git/info"
                echo DC-TEST > "\(folder)/r/.git/hooks/post-checkout"
                echo DC-TEST > "\(folder)/r/.git/config"
                echo DC-TEST > "\(folder)/r/.git/info/attributes"
                mv "\(folder)/r/.git" "\(folder)/r/.git-moved" && mv "\(folder)/r/.git-moved" "\(folder)/r/.git"
                rm -rf "\(folder)/r"
                """
            let result = try f.sh(.changing, script)
            #expect(result.status == 0, "\(folder): \(result.output)")
        }
        if let git = Toolchain.git() {
            let result = try f.run(.changing, [git, "init", "-q", f.scope.agentTmp + "/clone"])
            #expect(result.status == 0, "\(result.output)")
            #expect(f.exists(f.scope.agentTmp + "/clone/.git/config"))
            // The same git init in the session folder is still denied.
            #expect(try f.run(.changing, [git, "init", "-q", f.root + "/new"]).status != 0)
            #expect(!f.exists(f.root + "/new/.git"))
        }
    }

    /// Work scheduled outside the session would run after Stop: cron and at spools, launchd agents and daemons of
    /// any user (the agent's own home included), and startup items. Files the test user could otherwise create
    /// must be refused by the sandbox itself (EPERM).
    @Test func changingCannotPlantScheduledWork() throws {
        let f = try Fixture()
        let token = "dc-test-\(UInt32.random(in: 0...UInt32.max))"
        let ownHome = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) })
        var targets = [
            ownHome + "/Library/LaunchAgents", f.scope.agentHome + "/Library/LaunchAgents",
            f.scope.agentHome + "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/LaunchDaemons",
            "/Library/StartupItems", "/usr/lib/cron/tabs", "/private/var/at/jobs", "/private/var/at/tabs",
        ]
        let users = (try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? []
        targets += users.map { "/Users/\($0)/Library/LaunchAgents" }
        for folder in Set(targets) {
            let file = folder + "/" + token + ".plist"
            defer { unlink(file) }
            let result = try f.sh(.changing, "mkdir -p '\(folder)' && echo DC-TEST > '\(file)'")
            #expect(result.status != 0, "\(folder)")
            #expect(!f.exists(file), "\(folder)")
        }
        // Places the test user may write without a sandbox: the denial must come from the sandbox.
        let ownAgents = ownHome + "/Library/LaunchAgents"
        if access(ownAgents, W_OK) == 0 {
            #expect(notPermitted(try f.sh(.changing, "echo DC-TEST > '\(ownAgents)/\(token).plist'")))
        }
        #expect(notPermitted(try f.sh(.changing, "mkdir -p \"$HOME/Library/LaunchAgents\"")))
        #expect(!f.exists(f.scope.agentHome + "/Library/LaunchAgents"))
        // The rest of the agent's Library stays writable.
        #expect(try f.sh(.changing, "mkdir -p \"$HOME/Library/Caches/dc\" && rm -r \"$HOME/Library\"").status == 0)
    }

    @Test func changingCannotCreateOrDeleteDevices() throws {
        let f = try Fixture()
        #expect(try f.sh(.changing, "rm -f /dev/null; echo x > /dev/null").status == 0)
        #expect(f.exists("/dev/null"))
        #expect(try f.sh(.changing, "mkfifo /dev/dc-test-fifo").status != 0)
        #expect(!f.exists("/dev/dc-test-fifo"))
    }

    @Test func changingCanOpenAPty() throws {
        let f = try Fixture()
        let result = try f.run(.changing, ["/usr/bin/script", "-q", "/dev/null", "/bin/echo", "DC-TEST pty"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("DC-TEST pty"))
    }

    @Test func theEnvironmentIsTheAgentsOnly() throws {
        let f = try Fixture()
        setenv("DC_TEST_LEAK", "leaked", 1)
        defer { unsetenv("DC_TEST_LEAK") }
        let result = try f.run(.changing, ["/usr/bin/env"])
        let lines = Set(result.output.split(separator: "\n").map(String.init))
        #expect(lines.contains("HOME=\(f.scope.agentHome)"))
        #expect(lines.contains("TMPDIR=\(f.scope.agentTmp)/"))
        #expect(!result.output.contains("DC_TEST_LEAK"))
    }

    // MARK: - READ-ONLY

    @Test func readOnlyReadsTheScope() throws {
        let f = try Fixture()
        let result = try f.sh(.readOnly, "cat a.txt && ls && wc -l a.txt && head -1 a.txt")
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.hasPrefix("DC-TEST\na.txt\nrepo\nsub\nvendor\n"))
    }

    @Test func readOnlyCannotWriteAnywhere() throws {
        let f = try Fixture()
        for script in [
            "echo x > b.txt", "echo x >> a.txt", "rm a.txt", "mv a.txt b.txt", "mkdir new", "ln a.txt h",
            "ln -s a.txt s", "chmod 600 a.txt", "touch a.txt", "echo x > \"$HOME/n\"", "echo x > \"$TMPDIR/n\"",
            "rm -rf sub",
        ] {
            #expect(notPermitted(try f.sh(.readOnly, script)), "\(script)")
        }
        #expect(f.contents(f.root + "/a.txt") == "DC-TEST\n")
        #expect(f.exists(f.root + "/sub"))
        #expect(!f.exists(f.root + "/b.txt") && !f.exists(f.root + "/new"))
        #expect(try f.sh(.readOnly, "echo x > /dev/null").status == 0)
    }

    @Test func readOnlyCannotReadOutsideTheScope() throws {
        let f = try Fixture()
        for path in [
            f.other + "/o.txt", f.home + "/Documents/secret.txt", f.outside + "/x.txt",
            f.scope.agentHome + "/h.txt",
        ] {
            #expect(notPermitted(try f.sh(.readOnly, "cat '\(path)'")), "\(path)")
        }
        #expect(notPermitted(try f.sh(.readOnly, "ls /Users")))
    }

    @Test func readOnlyHasNoNetwork() throws {
        let f = try Fixture()
        let listener = try LoopbackListener()
        defer { listener.close() }
        let probe = ["/usr/bin/nc", "-z", "-w", "2", "127.0.0.1", String(listener.port)]
        // The control shows the probe works when the network is allowed: CHANGING with the listener as its proxy.
        let endpoint = try #require(ProxyEndpoint(port: listener.port, token: ProxyEndpoint.newToken()))
        let withProxy = Sandbox(scope: f.scope, toolchains: Toolchain.readPaths(), proxy: endpoint)
        #expect(try withProxy.run(probe, kind: .changing, cwd: f.root).status == 0)
        #expect(try withProxy.run(probe, kind: .readOnly, cwd: f.root).status != 0)
        #expect(try f.run(.readOnly, probe).status != 0)
        #expect(try f.run(.readOnly, ["/usr/bin/nc", "-z", "-w", "2", "1.1.1.1", "443"]).status != 0)
    }

    @Test func readOnlyCannotOpenSerialDevices() throws {
        let f = try Fixture()
        let devices = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let serial = devices.filter { $0.hasPrefix("cu.") || $0.hasPrefix("tty.") }.map { "/dev/" + $0 }
        // CI runners may have none; the profile text test covers the rule then.
        for device in serial.prefix(4) {
            #expect(notPermitted(try f.sh(.readOnly, ": < '\(device)'")), "\(device)")
        }
    }

    @Test func changingCannotOpenSerialDevices() throws {
        let f = try Fixture()
        let devices = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let serial = devices.filter { $0.hasPrefix("cu.") || $0.hasPrefix("tty.") }.map { "/dev/" + $0 }
        // CI runners may have none; the profile text test covers the rule then, and the FLASHING side (a real open
        // raises DTR and RTS, which could reset a board on the desk).
        for device in serial.prefix(4) {
            #expect(notPermitted(try f.sh(.changing, ": < '\(device)'")), "\(device)")
            #expect(notPermitted(try f.sh(.changing, ": <> '\(device)'")), "\(device)")
        }
    }

    @Test func poisonedGitConfigCannotRunAnythingThatWrites() throws {
        let f = try Fixture()
        let git = try #require(Toolchain.git())
        let setup = Process()
        setup.executableURL = URL(fileURLWithPath: git)
        setup.arguments = ["init", "-q", f.root]
        try setup.run()
        setup.waitUntilExit()
        #expect(setup.terminationStatus == 0)
        // Written directly: running git outside the sandbox after this would run the payloads.
        let payload = { (name: String) in "/usr/bin/touch \(f.root)/PWNED-\(name)" }
        let config = """
            [core]
            \tfsmonitor = \(payload("fsmonitor"))
            \tpager = \(payload("pager"))
            \thooksPath = \(f.root)
            [diff]
            \texternal = \(payload("external"))
            [diff "dc"]
            \ttextconv = \(payload("textconv"))
            [pager]
            \tlog = \(payload("pagerlog"))
            """
        try Data(config.utf8).write(to: URL(fileURLWithPath: f.root + "/.git/config"), options: .atomic)
        try Data("*.txt diff=dc\n".utf8).write(to: URL(fileURLWithPath: f.root + "/.gitattributes"))
        try Data("DC-TEST change\n".utf8).write(to: URL(fileURLWithPath: f.root + "/a.txt"))

        for argv in [["git", "status"], ["git", "diff"], ["git", "log", "-p"], ["git", "show"]] {
            let hardened = try #require(ReadOnlyGit.hardened(argv, git: git))
            _ = try f.run(.readOnly, hardened)
            // Even unhardened, the read-only sandbox stops the payload from writing.
            _ = try f.run(.readOnly, [git] + argv.dropFirst())
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: f.root)
        #expect(!left.contains { $0.hasPrefix("PWNED") }, "\(left)")
        #expect(!FileManager.default.fileExists(atPath: f.root + "/.git/index.lock"))
    }

    // MARK: - Wrapper

    @Test(arguments: [[], ["X=1"], ["-i"], ["relative\0"]])
    func oddCommandsAreRefused(_ argv: [String]) throws {
        let f = try Fixture()
        #expect(throws: SandboxError.self) { try f.sandbox.argv(argv, kind: .changing) }
    }

    @Test func theWrapperStartsWithSandboxExec() throws {
        let f = try Fixture()
        let argv = try f.sandbox.argv(["/bin/ls"], kind: .readOnly)
        #expect(argv.prefix(2) == ["/usr/bin/sandbox-exec", "-p"])
        #expect(argv[3] == "/usr/bin/env" && argv[4] == "-i")
        #expect(argv.last == "/bin/ls")
        #expect(argv.contains("GIT_CONFIG_NOSYSTEM=1"))
        #expect(!(try f.sandbox.argv(["/bin/ls"], kind: .changing)).contains("GIT_CONFIG_NOSYSTEM=1"))
    }

    // MARK: - Self-test

    @Test func theSelfTestPasses() throws {
        let f = try Fixture()
        #expect(f.sandbox.selfTest() == .passed)
        // It leaves nothing behind.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: f.scope.ceiling).sorted() == [
                ".dual-control", "dual-control", "other", "p",
            ]
        )
    }

    @Test func theSelfTestFailsClosedWithoutTheSandbox() throws {
        let f = try Fixture()
        let missing = Sandbox(scope: f.scope, toolchains: [], sandboxExec: "/nonexistent/sandbox-exec")
        guard case .failed = missing.selfTest() else {
            Issue.record("a missing sandbox-exec must fail the self-test")
            return
        }
        // A "sandbox" that applies nothing lets the probe write outside the scope: the self-test catches it.
        let script = f.base + "/fake-sandbox-exec"
        try Data("#!/bin/sh\nshift 2\nexec \"$@\"\n".utf8).write(to: URL(fileURLWithPath: script))
        chmod(script, 0o755)
        let fake = Sandbox(scope: f.scope, toolchains: [], sandboxExec: script)
        guard case .failed(let reason) = fake.selfTest() else {
            Issue.record("a sandbox that does not apply must fail the self-test")
            return
        }
        #expect(reason.contains("outside"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: f.scope.ceiling).sorted() == [
                ".dual-control", "dual-control", "other", "p",
            ]
        )
    }

    /// Accepts TCP connections on 127.0.0.1 so the network probe has something to reach.
    private final class LoopbackListener {
        let socket: Int32
        let port: UInt16

        init() throws {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
                }
            }
            try #require(bound && listen(socket, 4) == 0)
            self.socket = socket
            port = UInt16(bigEndian: address.sin_port)
        }

        func close() {
            Darwin.close(socket)
        }
    }
#endif
