#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlSandbox

    /// Gap 8: a fake owner home with a session folder, the agent's work area, a staging folder and an installed
    /// toolchain. The kernel enforces the profiles for any user, so the tests run as the test user.
    ///
    ///     <base>/home/Developer/p                                    the session folder
    ///     <base>/home/Developer/.dual-control/{agent-home,tmp}
    ///     <base>/home/Developer/.dual-control/toolchain-staging      what esp_idf_install builds
    ///     <base>/home/Developer/.dual-control/toolchains/esp-idf-v5.4    an installed toolchain
    ///     <base>/home/Documents/secret.txt
    ///     <base>/outside
    private final class Fixture {
        let base: String
        let scope: SessionScope
        let sandbox: Sandbox

        var home: String { base + "/home" }
        var staging: String { scope.toolchainStaging }
        var installed: String { scope.toolchains + "/esp-idf-v5.4" }

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            let work = "/home/Developer/.dual-control"
            for folder in [
                "/home/Developer/p", work + "/agent-home", work + "/tmp", work + "/toolchain-staging/idf/tools",
                work + "/toolchains/esp-idf-v5.4/idf/tools", "/home/Documents", "/outside",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            for file in [
                "/home/Developer/p/a.txt", work + "/agent-home/h.txt", work + "/tmp/t.txt",
                work + "/toolchain-staging/idf/tools/s.py", work + "/toolchains/esp-idf-v5.4/idf/tools/idf.py",
                "/home/Documents/secret.txt", "/outside/x.txt",
            ] {
                try Data("DC-TEST\n".utf8).write(to: URL(fileURLWithPath: base + file))
            }
            chmod(base + "/outside/x.txt", 0o644)
            scope = try ResolvedScope.make(choosing: base + "/home/Developer/p", ceiling: base + "/home/Developer")
            sandbox = Sandbox(scope: scope, toolchains: Toolchain.readPaths())
        }

        deinit {
            try? FileManager.default.removeItem(atPath: base)
        }

        func sh(_ kind: SandboxKind, _ script: String) throws -> SandboxRun {
            try sandbox.run(["/bin/sh", "-c", script], kind: kind, cwd: scope.root)
        }

        func contents(_ path: String) -> String? {
            try? String(contentsOfFile: path, encoding: .utf8)
        }

        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }

        func write(_ text: String, _ path: String, mode: mode_t = 0o644) throws {
            try FileManager.default.createDirectory(
                atPath: SandboxProfile.parent(of: path),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            chmod(path, mode)
        }

        /// An `esp_idf_install` launch for `version`, as `Supervisor.begin` makes it.
        func installLaunch(_ version: String = "v5.4") -> Launch {
            let request = ActionRequest(
                capability: .command,
                argv: ESPIDFInstall.argv(version: version, targets: ["esp32s3"]),
                cwd: scope.root,
                projectID: scope.root,
                timeoutSeconds: 60
            )
            let decision = Decision(verdict: .allow, reason: "test", ruleID: "test")
            let execution = Execution(
                id: "x1",
                tool: "esp_idf_install",
                request: request,
                decision: decision,
                scope: scope
            )
            return Launch(
                execution: execution,
                scope: scope,
                readOnly: false,
                serialPort: nil,
                timeoutSeconds: 60,
                toolchain: version
            )
        }

        /// A finished install job's outcome.
        func outcome(status: Int32 = 0) -> CommandOutcome {
            CommandOutcome(
                status: status,
                timedOut: false,
                killed: false,
                duration: 1,
                output: "built\n",
                totalBytes: 6,
                shownBytes: 6
            )
        }
    }

    private func notPermitted(_ run: SandboxRun) -> Bool {
        run.status != 0 && run.output.contains("Operation not permitted")
    }

    // MARK: - The kernel

    @Test func nothingTheAgentRunsCanWriteTheToolchainFolder() throws {
        let f = try Fixture()
        let idfPy = f.installed + "/idf/tools/idf.py"
        for kind in [SandboxKind.changing, .flashing(port: "/dev/cu.dc-test"), .installing, .readOnly] {
            #expect(notPermitted(try f.sh(kind, "echo efuse >> '\(idfPy)'")), "\(kind)")
            #expect(notPermitted(try f.sh(kind, "touch '\(f.installed)/idf/tools/new.py'")), "\(kind)")
            #expect(notPermitted(try f.sh(kind, "rm -f '\(idfPy)'")), "\(kind)")
            #expect(notPermitted(try f.sh(kind, "mv '\(f.installed)' '\(f.scope.toolchains)/moved'")), "\(kind)")
            #expect(notPermitted(try f.sh(kind, "mv '\(f.scope.toolchains)' '\(f.scope.workArea)/moved'")), "\(kind)")
            #expect(notPermitted(try f.sh(kind, "mkdir '\(f.scope.toolchains)/esp-idf-v9.9'")), "\(kind)")
            #expect(notPermitted(try f.sh(kind, "ln -s '\(f.scope.agentHome)' '\(f.scope.toolchains)/esp-idf-v9.8'")))
        }
        #expect(f.contents(idfPy) == "DC-TEST\n")
        // It can still be read and run from: flashers run there.
        let read = try f.sh(.changing, "cat '\(idfPy)'")
        #expect(read.status == 0 && read.output == "DC-TEST\n", "\(read.output)")
    }

    @Test func onlyTheInstallCanWriteTheStagingFolder() throws {
        let f = try Fixture()
        let staged = f.staging + "/idf/tools/s.py"
        for kind in [SandboxKind.changing, .flashing(port: "/dev/cu.dc-test"), .readOnly] {
            #expect(notPermitted(try f.sh(kind, "echo efuse >> '\(staged)'")), "\(kind)")
            #expect(notPermitted(try f.sh(kind, "touch '\(f.staging)/idf/new.py'")), "\(kind)")
            #expect(notPermitted(try f.sh(kind, "mv '\(f.staging)' '\(f.scope.workArea)/moved'")), "\(kind)")
        }
        // Not through a hard link in the agent's own home either: Seatbelt would check only the link's path.
        let linked = try f.sh(.changing, "ln '\(staged)' \"$HOME/s.py\" && echo efuse >> \"$HOME/s.py\"")
        #expect(linked.status != 0, "\(linked.output)")
        #expect(f.contents(staged) == "DC-TEST\n")
        let written = try f.sh(.installing, "echo built >> '\(staged)' && mkdir -p '\(f.staging)/tools/x'")
        #expect(written.status == 0, "\(written.output)")
        #expect(f.contents(staged) == "DC-TEST\nbuilt\n")
    }

    @Test func theInstallReadsNothingTheAgentCouldPlant() throws {
        let f = try Fixture()
        for path in [f.scope.agentHome + "/h.txt", f.scope.agentTmp + "/t.txt", f.scope.root + "/a.txt"] {
            #expect(notPermitted(try f.sh(.installing, "cat '\(path)'")), "\(path)")
        }
        #expect(notPermitted(try f.sh(.installing, "cat '\(f.home)/Documents/secret.txt'")))
        #expect(notPermitted(try f.sh(.installing, "touch '\(f.scope.agentHome)/new.txt'")))
        #expect(notPermitted(try f.sh(.installing, "touch '\(f.scope.root)/new.txt'")))
        // It starts in the session folder, which it cannot read, and moves on to its own.
        let moved = try f.sh(.installing, "cd '\(f.staging)' && cat idf/tools/s.py && /bin/pwd")
        #expect(moved.status == 0 && moved.output == "DC-TEST\n\(f.staging)\n", "\(moved.output)")
    }

    @Test func theOwnersCopyCannotReadTheOwnersFiles() throws {
        let f = try Fixture()
        let profile = try SandboxProfile.toolchainCopy(scope: f.scope, install: f.installed)
        func copying(_ script: String) throws -> SandboxRun {
            try #require(Subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c", script]))
        }
        #expect(notPermitted(try copying("cat '\(f.home)/Documents/secret.txt'")))
        #expect(notPermitted(try copying("cat '\(f.scope.agentHome)/h.txt'")))
        #expect(notPermitted(try copying("touch '\(f.scope.toolchains)/esp-idf-v9.9'")))
        #expect(notPermitted(try copying("touch '\(f.staging)/x'")))
        let allowed = try copying("cat '\(f.staging)/idf/tools/s.py' && touch '\(f.installed)/x'")
        #expect(allowed.status == 0, "\(allowed.output)")
    }

    /// Gap 10: outside the owner's home, the install and the owner's copy read only CHANGING's allowlist.
    @Test func theInstallAndTheCopyReadOnlyTheAllowlistOutsideTheHome() throws {
        let f = try Fixture()
        let profile = try SandboxProfile.toolchainCopy(scope: f.scope, install: f.installed)
        func copying(_ script: String) throws -> SandboxRun {
            try #require(Subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c", script]))
        }
        let denied = [
            "cat '\(f.base)/outside/x.txt'", "cat '/System/Volumes/Data\(f.base)/outside/x.txt'", "ls /Volumes",
            "ls /Users/Shared", "ls /Library/Preferences", "ls /private/tmp", "ls /Applications",
        ]
        for script in denied {
            let installing = try f.sh(.installing, script)
            #expect(notPermitted(installing), "installing \(script): \(installing.output)")
            let copy = try copying(script)
            #expect(notPermitted(copy), "copy \(script): \(copy.output)")
        }
        // What the install runs, from the staging folder as the script does, still works: the developer stubs, git
        // and Python.
        for script in [
            "/usr/bin/git --version", "/usr/bin/python3 -c 'import ssl, venv; print(1)'", "ls /usr/bin >/dev/null",
            "cat /etc/hosts >/dev/null", "/bin/pwd",
        ] {
            let run = try f.sh(.installing, "cd '\(f.staging)' && " + script)
            #expect(run.status == 0, "installing \(script): \(run.output)")
        }
        let tar = try copying("/usr/bin/tar --version && cd '\(f.staging)' && /bin/pwd")
        #expect(tar.status == 0, "\(tar.output)")
    }

    // MARK: - Copying a finished install

    /// A staging folder as `esp_idf_install` leaves it: ESP-IDF with git's files, a Python environment whose
    /// scripts name the staging folder, byte code, downloaded archives and a dangling link.
    private func stage(_ f: Fixture) throws {
        let s = f.staging
        try f.write("[core]\n\thooksPath = /tmp/x\n", s + "/idf/.git/config")
        try f.write("#!/bin/sh\necho pwn\n", s + "/idf/.git/hooks/post-checkout", mode: 0o755)
        try f.write("gitdir: ../../.git/modules/x\n", s + "/idf/components/x/.git")
        try f.write("import sys\n", s + "/idf/tools/idf.py", mode: 0o755)
        try f.write("archive", s + "/tools/dist/xtensa.tar.xz")
        let env = s + "/tools/python_env/idf5.4_py3.12_env"
        try f.write("#!\(env)/bin/python\nimport esptool\n", env + "/bin/esptool.py", mode: 0o775)
        try f.write("home = /opt/homebrew/bin\ncommand = python3 -m venv \(env)\n", env + "/pyvenv.cfg")
        try f.write("\u{0}compiled \(s)/idf/tools/idf.py", env + "/lib/__pycache__/m.cpython-312.pyc")
        try FileManager.default.createDirectory(atPath: s + "/python-bin", withIntermediateDirectories: true)
        #expect(symlink("/usr/bin/python3", s + "/python-bin/python3") == 0)
        #expect(symlink(env + "/bin/esptool.py", env + "/bin/esptool") == 0)
        #expect(symlink("python3", env + "/bin/python") == 0)
        #expect(symlink("/usr/bin/python3", env + "/bin/python3") == 0)
        #expect(symlink(s + "/missing", env + "/bin/gone") == 0)
        try f.write("staged home", s + "/home/.gitconfig")
    }

    @Test func aFinishedInstallIsCopiedLockedAndPointedAtItself() throws {
        let f = try Fixture()
        try FileManager.default.removeItem(atPath: f.installed)
        try stage(f)
        let (outcome, copy) = f.sandbox.finishToolchain(f.installLaunch(), f.outcome())
        let digest = try #require(copy?.digest, "\(String(describing: copy?.problem))")
        #expect(copy?.install == f.installed && outcome.status == 0)
        #expect(outcome.output.contains("copied to \(f.installed)") && outcome.output.contains(digest))
        let i = f.installed
        let env = i + "/tools/python_env/idf5.4_py3.12_env"
        // Git's files, byte code, archives and the staging home are not copied; links that lead nowhere go.
        for gone in [
            "/idf/.git", "/idf/components/x/.git", "/tools/dist", "/home",
            "/tools/python_env/idf5.4_py3.12_env/lib/__pycache__",
            "/tools/python_env/idf5.4_py3.12_env/bin/gone",
        ] {
            #expect(!f.exists(i + gone), "\(gone)")
        }
        // Paths to the staging folder now name the install, in text and in links.
        #expect(f.contents(env + "/bin/esptool.py") == "#!\(env)/bin/python\nimport esptool\n")
        #expect(f.contents(env + "/pyvenv.cfg")?.contains("venv \(env)\n") == true)
        #expect(OwnerToolchainStore.linkTarget(env + "/bin/esptool") == env + "/bin/esptool.py")
        #expect(OwnerToolchainStore.linkTarget(env + "/bin/python") == "python3")
        #expect(f.contents(i + "/idf/version.txt") == "v5.4\n")
        // The owner's alone: nobody else may write, no set-id bits.
        var info = stat()
        #expect(lstat(env + "/bin/esptool.py", &info) == 0 && info.st_mode & 0o7777 == 0o755)
        #expect(lstat(i + "/idf/tools", &info) == 0 && info.st_mode & 0o7777 == 0o755 && info.st_uid == getuid())
        #expect(f.contents(OwnerToolchain.hashFile(of: i)) == digest + "\n")
        let store = OwnerToolchainStore(scope: f.scope, denyACLUser: nil)
        #expect(try store.verify(i).get() == digest)
        // The staging folder is left as it was.
        #expect(f.exists(f.staging + "/idf/.git/config"))
    }

    @Test func aRealPythonEnvironmentStillWorksOnceMoved() throws {
        guard access("/opt/homebrew/bin/python3.12", X_OK) == 0 else { return }
        let f = try Fixture()
        try FileManager.default.removeItem(atPath: f.installed)
        try FileManager.default.createDirectory(atPath: f.staging + "/python-bin", withIntermediateDirectories: true)
        #expect(symlink("/opt/homebrew/bin/python3.12", f.staging + "/python-bin/python3") == 0)
        let env = "/tools/python_env/idf5.4_py3.12_env"
        let made = try #require(Subprocess.run([f.staging + "/python-bin/python3", "-m", "venv", f.staging + env]))
        #expect(made.status == 0, "\(made.output)")
        let (_, copy) = f.sandbox.finishToolchain(f.installLaunch(), f.outcome())
        #expect(copy?.digest != nil, "\(String(describing: copy?.problem))")
        let prefix = try #require(
            Subprocess.run([f.installed + env + "/bin/python", "-c", "import sys; print(sys.prefix)"])
        )
        #expect(prefix.output == f.installed + env + "\n", "\(prefix.output)")
        let pip = try #require(Subprocess.run([f.installed + env + "/bin/pip", "--version"]))
        #expect(pip.status == 0 && pip.output.contains(f.installed + env), "\(pip.output)")
    }

    @Test(arguments: ["agent-home", "outside", "secret"])
    func aLinkOutOfTheInstallFailsItAndKeepsTheEarlierOne(_ target: String) throws {
        let f = try Fixture()
        try stage(f)
        let path = [
            "agent-home": f.scope.agentHome + "/h.txt", "outside": f.base + "/outside",
            "secret": f.home + "/Documents/secret.txt",
        ][target]!
        #expect(symlink(path, f.staging + "/idf/tools/esptool.py") == 0)
        try f.write("earlier\n", OwnerToolchain.hashFile(of: f.installed))
        let (outcome, copy) = f.sandbox.finishToolchain(f.installLaunch(), f.outcome())
        #expect(copy?.digest == nil && copy?.problem?.contains("leads out of the install") == true)
        #expect(outcome.status == 1 && outcome.output.contains("the install was not copied"))
        // The earlier install is back, unchanged; nothing of the new one is left.
        #expect(f.contents(f.installed + "/idf/tools/idf.py") == "DC-TEST\n")
        #expect(!f.exists(f.installed + "/idf/tools/esptool.py"))
        let left = try FileManager.default.contentsOfDirectory(atPath: f.scope.toolchains)
        #expect(left == ["esp-idf-v5.4"], "\(left)")
    }

    @Test func aBinaryThatNamesTheAgentsHomeFailsTheCopy() throws {
        let f = try Fixture()
        try stage(f)
        try f.write(
            "\u{0}\u{1}\(f.scope.agentHome)/lib/evil.dylib",
            f.staging + "/tools/tools/gcc/bin/gcc",
            mode: 0o755
        )
        let (_, copy) = f.sandbox.finishToolchain(f.installLaunch(), f.outcome())
        #expect(copy?.problem?.contains("names the agent's folders") == true, "\(String(describing: copy))")
    }

    @Test func setIDBitsAndGroupWritesAreDropped() throws {
        let f = try Fixture()
        try FileManager.default.removeItem(atPath: f.installed)
        try stage(f)
        try f.write("#!/bin/sh\n", f.staging + "/idf/tools/suid", mode: 0o6777)
        let (_, copy) = f.sandbox.finishToolchain(f.installLaunch(), f.outcome())
        #expect(copy?.digest != nil, "\(String(describing: copy?.problem))")
        var info = stat()
        #expect(lstat(f.installed + "/idf/tools/suid", &info) == 0 && info.st_mode & 0o7777 == 0o755)
    }

    @Test func aNewInstallReplacesTheEarlierOne() throws {
        let f = try Fixture()
        try stage(f)
        let (_, first) = f.sandbox.finishToolchain(f.installLaunch(), f.outcome())
        #expect(first?.digest != nil, "\(String(describing: first?.problem))")
        try f.write("import sys  # newer\n", f.staging + "/idf/tools/idf.py", mode: 0o755)
        let (_, second) = f.sandbox.finishToolchain(f.installLaunch(), f.outcome())
        let digest = try #require(second?.digest, "\(String(describing: second?.problem))")
        #expect(digest != first?.digest)
        #expect(f.contents(f.installed + "/idf/tools/idf.py") == "import sys  # newer\n")
        let left = try FileManager.default.contentsOfDirectory(atPath: f.scope.toolchains).sorted()
        #expect(left == ["esp-idf-v5.4", "esp-idf-v5.4.sha256"], "\(left)")
    }

    @Test func aFailedOrForeignJobCopiesNothing() throws {
        let f = try Fixture()
        try FileManager.default.removeItem(atPath: f.installed)
        try stage(f)
        let (failed, none) = f.sandbox.finishToolchain(f.installLaunch(), f.outcome(status: 2))
        #expect(none == nil && failed.status == 2 && !f.exists(f.installed))
        // The same command line through run_command carries no toolchain.
        let plain = Launch(
            execution: f.installLaunch().execution,
            scope: f.scope,
            readOnly: false,
            serialPort: nil,
            timeoutSeconds: 60
        )
        #expect(f.sandbox.finishToolchain(plain, f.outcome()).1 == nil && !f.exists(f.installed))
    }

    // MARK: - The install script

    /// The job starts in `/`, not the session folder: INSTALLING cannot read the session folder, so a shell started
    /// there cannot find its own working directory (`getcwd: cannot access parent directories`).
    @Test func theInstallJobFindsItsWorkingDirectory() throws {
        let f = try Fixture()
        let outcome = try f.sandbox.start(f.installLaunch()).wait()
        #expect(!outcome.output.contains("getcwd"), "\(outcome.output)")
        #expect(!outcome.output.contains("shell-init"), "\(outcome.output)")
    }

    @Test func theInstallScriptParses() throws {
        let run = try #require(Subprocess.run(["/bin/sh", "-n", "-c", ESPIDFInstall.script]))
        #expect(run.status == 0, "\(run.output)")
    }

    /// The real script in INSTALLING, with a git that prints what it sees and fails: the staging folder starts
    /// empty except the archives, and git sees none of the agent's configuration.
    @Test func theInstallStartsFreshAndSeesNoConfigurationOfTheAgents() throws {
        let f = try Fixture()
        try stage(f)
        let git = f.base + "/outside/git"
        try f.write("#!/bin/sh\n/usr/bin/env\necho \"ARGS $*\"\nexit 7\n", git, mode: 0o755)
        let environment = ESPIDFInstall.environment(scope: f.scope, git: git)
        // The real git is in a toolchain folder (gap 10: nothing else outside the home can be read).
        let sandbox = Sandbox(scope: f.scope, toolchains: Toolchain.readPaths() + [f.base + "/outside"])
        let argv = try sandbox.argv(
            ESPIDFInstall.argv(version: "v5.4", targets: ["esp32s3"]),
            kind: .installing,
            environment: environment
        )
        let run = try #require(Subprocess.run(argv, cwd: f.scope.root))
        let hasPython = (10...13).contains { access("/opt/homebrew/bin/python3.\($0)", X_OK) == 0 }
        guard hasPython else {
            #expect(run.status == 2 && run.output.contains("no Python 3.10 or newer"), "\(run.output)")
            return
        }
        #expect(run.status == 7, "\(run.output)")
        let lines = Set(run.output.split(separator: "\n").map(String.init))
        #expect(lines.contains("HOME=\(f.staging)/home"))
        #expect(lines.contains("GIT_CONFIG_GLOBAL=/dev/null") && lines.contains("PYTHONNOUSERSITE=1"))
        #expect(
            lines.contains { $0.hasPrefix("ARGS -c core.hooksPath=/dev/null") && $0.hasSuffix(" \(f.staging)/idf") }
        )
        #expect(f.exists(f.staging + "/tools/dist/xtensa.tar.xz"))
        for gone in ["/idf", "/tools/python_env", "/home/.gitconfig"] {
            #expect(!f.exists(f.staging + gone), "\(gone)")
        }
        #expect(
            OwnerToolchainStore.linkTarget(f.staging + "/python-bin/python3")?.hasPrefix("/opt/homebrew/bin/") == true
        )
        #expect(!f.exists(f.scope.agentHome + "/esp") && !f.exists(f.scope.agentHome + "/.espressif"))
    }
#endif
