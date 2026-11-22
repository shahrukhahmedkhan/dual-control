#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlSandbox

    /// A temporary ceiling with a session folder `p` and the agent's work area. The tests run commands as the test
    /// user (production adds sudo to the agent in front); the kernel sandbox is the same.
    private final class Session {
        let base: String
        let scope: SessionScope
        let sandbox: Sandbox

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in ["/Developer/p/sub", "/Developer/.dual-control/agent-home", "/Developer/.dual-control/tmp"] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            scope = try ResolvedScope.make(choosing: base + "/Developer/p", ceiling: base + "/Developer")
            sandbox = Sandbox(scope: scope, toolchains: Toolchain.readPaths())
        }

        deinit { try? FileManager.default.removeItem(atPath: base) }

        func launch(
            _ argv: [String],
            cwd: String? = nil,
            readOnly: Bool = false,
            serialPort: String? = nil,
            timeout: Int = 30
        ) -> Launch {
            let request = ActionRequest(
                capability: .command,
                argv: argv,
                cwd: cwd ?? scope.root,
                projectID: scope.root,
                timeoutSeconds: timeout
            )
            let decision = Decision(verdict: .allow, reason: "test", ruleID: "test")
            let execution = Execution(id: "x1", tool: "run_command", request: request, decision: decision, scope: scope)
            return Launch(
                execution: execution,
                scope: scope,
                readOnly: readOnly,
                serialPort: serialPort,
                timeoutSeconds: timeout
            )
        }

        func run(_ argv: [String], cwd: String? = nil, readOnly: Bool = false, timeout: Int = 30) throws
            -> CommandOutcome
        {
            try sandbox.start(launch(argv, cwd: cwd, readOnly: readOnly, timeout: timeout)).wait()
        }
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// The outcome of a `wait()` on another thread, once it has returned.
    private final class Ended: @unchecked Sendable {
        private let lock = NSLock()
        private let returned = DispatchSemaphore(value: 0)
        private var stored: CommandOutcome?

        var outcome: CommandOutcome? {
            get { lock.withLock { stored } }
            set {
                lock.withLock { stored = newValue }
                returned.signal()
            }
        }

        func waitForOutcome() -> CommandOutcome? {
            returned.wait()
            return outcome
        }
    }

    @Test func aCommandRunsAndReturnsItsOutput() throws {
        let session = try Session()
        let outcome = try session.run(["/bin/echo", "DC-TEST"])
        #expect(outcome.status == 0 && !outcome.timedOut && !outcome.killed)
        #expect(outcome.output == "DC-TEST\n")
        #expect(outcome.totalBytes == 8 && outcome.shownBytes == 8)
    }

    /// A background job's output can be read while it runs, for job_status.
    @Test func outputCanBeReadWhileItRuns() throws {
        let session = try Session()
        let command = try session.sandbox.start(
            session.launch(["/bin/sh", "-c", "echo DC-TEST-early; sleep 30"], timeout: 30)
        )
        var snapshot = command.peek()
        for _ in 0..<100 where !snapshot.tail.contains("DC-TEST-early") {
            usleep(50_000)
            snapshot = command.peek()
        }
        #expect(snapshot.tail == "DC-TEST-early\n")
        #expect(snapshot.totalBytes == 14)
        command.kill()
        #expect(command.wait().killed)
    }

    /// Past the 1 MiB that is returned, the end of the output (where a build's result is) is still kept.
    @Test func theEndOfLongOutputIsKept() throws {
        let session = try Session()
        let outcome = try session.run(
            ["/bin/sh", "-c", "i=0; while [ $i -lt 60000 ]; do echo line-$i-padding-padding; i=$((i+1)); done"]
        )
        #expect(outcome.totalBytes > CommandLimits.maxOutputBytes)
        let tail = try #require(outcome.tail)
        #expect(tail.hasSuffix("line-59999-padding-padding\n"))
        #expect(tail.utf8.count <= Supervisor.jobOutputLimit)
        #expect(try session.run(["/bin/echo", "short"]).tail == nil)
    }

    @Test func statusAndBothStreamsAreReturned() throws {
        let session = try Session()
        let outcome = try session.run(["/bin/sh", "-c", "echo DC-TEST-out; echo DC-TEST-err >&2; exit 3"])
        #expect(outcome.status == 3)
        #expect(outcome.output.contains("DC-TEST-out\n") && outcome.output.contains("DC-TEST-err\n"))
    }

    @Test func bareNamesAreFoundOnTheAgentsPath() throws {
        let session = try Session()
        try Data("DC-TEST\n".utf8).write(to: URL(fileURLWithPath: session.scope.root + "/a.txt"))
        let outcome = try session.run(["cat", "a.txt"], readOnly: true)
        #expect(outcome.status == 0, "\(outcome.output)")
        #expect(outcome.output == "DC-TEST\n")
    }

    @Test func theEnvironmentIsTheAllowlistOnly() throws {
        setenv("DC_TEST_SECRET", "leak", 1)
        defer { unsetenv("DC_TEST_SECRET") }
        let session = try Session()
        let outcome = try session.run(["/usr/bin/env"])
        let names = Set(
            outcome.output.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) }
        )
        #expect(names == ["PATH", "HOME", "TMPDIR", "LANG", "TERM"])
        #expect(outcome.output.contains("HOME=\(session.scope.agentHome)\n"))
    }

    @Test func theWorkingDirectoryIsTheRequestedFolder() throws {
        let session = try Session()
        let outcome = try session.run(["/bin/pwd"], cwd: session.scope.root + "/sub")
        #expect(outcome.output == session.scope.root + "/sub\n")
    }

    @Test func standardInputIsClosed() throws {
        let session = try Session()
        let begun = Date()
        let outcome = try session.run(["/bin/cat"], timeout: 10)
        #expect(outcome.status == 0 && outcome.output.isEmpty)
        #expect(Date().timeIntervalSince(begun) < 5)
    }

    @Test func theReadOnlyTierRunsReadOnly() throws {
        let session = try Session()
        #expect(try session.run(["/usr/bin/touch", "DC-TEST-ro"], readOnly: true).status != 0)
        #expect(!FileManager.default.fileExists(atPath: session.scope.root + "/DC-TEST-ro"))
        #expect(try session.run(["/usr/bin/touch", "DC-TEST-rw"]).status == 0)
        #expect(FileManager.default.fileExists(atPath: session.scope.root + "/DC-TEST-rw"))
    }

    @Test func theTimeoutKillsTheWholeProcessGroup() throws {
        let session = try Session()
        let begun = Date()
        let script = "sleep 30 & echo $! > child.pid; sleep 30"
        let outcome = try session.run(["/bin/sh", "-c", script], timeout: 1)
        #expect(Date().timeIntervalSince(begun) < 10)
        #expect(outcome.timedOut && outcome.killed && outcome.status != 0)
        let text = try String(contentsOfFile: session.scope.root + "/child.pid", encoding: .utf8)
        let child = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Give the kernel a moment to reap it.
        for _ in 0..<50 where isAlive(child) { usleep(20_000) }
        #expect(!isAlive(child))
    }

    @Test func outputIsCappedAndCounted() throws {
        let session = try Session()
        let outcome = try session.run(["/bin/sh", "-c", "head -c 3000000 /dev/zero | tr '\\0' a"])
        #expect(outcome.status == 0)
        #expect(outcome.totalBytes == 3_000_000)
        #expect(outcome.shownBytes == CommandLimits.maxOutputBytes)
        #expect(outcome.output.utf8.count == CommandLimits.maxOutputBytes)
    }

    @Test func killStopsARunningCommandAtOnce() throws {
        let session = try Session()
        let running = try session.sandbox.start(session.launch(["/bin/sh", "-c", "sleep 30 & sleep 30"]))
        // Waits on a thread of its own and kills from this one: a dispatch queue that other tests keep busy may run
        // a scheduled kill seconds late, so the clock starts at the kill itself.
        let ended = Ended()
        Thread { ended.outcome = running.wait() }.start()
        usleep(300_000)
        let begun = Date()
        running.kill()
        let outcome = try #require(ended.waitForOutcome())
        #expect(outcome.killed && !outcome.timedOut)
        #expect(Date().timeIntervalSince(begun) < 5)
        running.kill()  // Harmless once it has ended.
    }

    @Test func aWorkingDirectoryOutsideTheScopeIsRefused() throws {
        let session = try Session()
        for cwd in [session.base, session.scope.ceiling, session.base + "/missing", "/tmp"] {
            #expect(throws: SandboxError.self, "\(cwd)") {
                try session.sandbox.start(session.launch(["/bin/pwd"], cwd: cwd))
            }
        }
    }

    @Test func noDescriptorOfTheAppLeaksIntoTheCommand() throws {
        let session = try Session()
        let fd = open(session.base + "/DC-TEST-open", O_CREAT | O_RDWR, 0o600)
        #expect(fd > 2)
        defer { close(fd) }
        let outcome = try session.run(["/bin/sh", "-c", "[ -e /dev/fd/\(fd) ] && echo LEAK || echo DC-TEST-ok"])
        #expect(outcome.output == "DC-TEST-ok\n")
    }

    // MARK: - Flashers

    /// The fake install's folder in the owner's toolchain folder.
    private func installFolder(_ session: Session) -> String {
        session.scope.toolchains + "/esp-idf-v5.3"
    }

    /// Records `install`'s hash next to it, as the app does after copying it.
    private func lock(_ session: Session, _ install: String) throws {
        let digest = try OwnerToolchainStore(scope: session.scope, denyACLUser: nil).digest(install).get()
        let hashFile = OwnerToolchain.hashFile(of: install)
        unlink(hashFile)
        try Data((digest + "\n").utf8).write(to: URL(fileURLWithPath: hashFile))
    }

    /// A fake ESP-IDF install in the owner's toolchain folder, with its hash recorded: `idf_tools.py export` prints
    /// `export`, `idf.py` prints its environment.
    private func install(_ session: Session, export: String) throws -> (idf: String, env: String) {
        let root = installFolder(session)
        let idf = root + "/idf"
        let env = root + "/tools/python_env/idf5.3_py3.9_env"
        for folder in [idf + "/tools", env + "/bin", root + "/python-bin"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        symlink("/usr/bin/python3", root + "/python-bin/python3")
        defer { try? lock(session, root) }
        let tools = """
            import os, sys
            assert sys.argv[1:] == ["export", "--format", "key-value"], sys.argv
            idf = os.environ["IDF_PATH"]
            print(\"\"\"\(export)\"\"\".replace("@IDF@", idf))
            """
        try Data(tools.utf8).write(to: URL(fileURLWithPath: idf + "/tools/idf_tools.py"))
        try Data("#!/bin/sh\n/usr/bin/env\n".utf8).write(to: URL(fileURLWithPath: idf + "/tools/idf.py"))
        chmod(idf + "/tools/idf.py", 0o755)
        return (idf, env)
    }

    @Test func aFlasherRunsWithTheESPIDFEnvironmentFromTheInstall() throws {
        let session = try Session()
        let env = installFolder(session) + "/tools/python_env/idf5.3_py3.9_env"
        let (idf, _) = try install(
            session,
            export: "ESP_IDF_VERSION=5.3\nIDF_PYTHON_ENV_PATH=\(env)\nPATH=\(env)/bin:@IDF@/tools:$PATH"
        )
        setenv("DC_TEST_LEAK", "leaked", 1)
        defer { unsetenv("DC_TEST_LEAK") }
        let outcome = try session.sandbox.start(
            session.launch([idf + "/tools/idf.py", "flash"], serialPort: "/dev/cu.dc-test")
        )
        .wait()
        #expect(outcome.status == 0, "\(outcome.output)")
        let lines = Set(outcome.output.split(separator: "\n").map(String.init))
        #expect(lines.contains("IDF_PATH=\(idf)"))
        #expect(lines.contains("IDF_PYTHON_ENV_PATH=\(env)"))
        #expect(lines.contains("ESP_IDF_VERSION=5.3"))
        #expect(lines.contains("PATH=\(env)/bin:\(idf)/tools:\(AgentEnvironment.path)"))
        #expect(lines.contains("HOME=\(session.scope.agentHome)"))
        #expect(!outcome.output.contains("DC_TEST_LEAK"))
        // A command that is not a recognised flasher gets the plain environment.
        let plain = try session.run([idf + "/tools/idf.py", "flash"])
        #expect(!plain.output.contains("IDF_PATH="))
    }

    @Test func theEnvironmentIsDerivedOncePerInstallAndSaysSo() throws {
        let session = try Session()
        let env = installFolder(session) + "/tools/python_env/idf5.3_py3.9_env"
        let (idf, _) = try install(session, export: "PATH=\(env)/bin:$PATH")
        let launch = session.launch(
            [idf + "/tools/idf.py", "-p", "/dev/cu.dc-test", "flash"],
            serialPort: "/dev/cu.dc-test"
        )
        let first = session.sandbox.idfEnvironment(for: launch)
        #expect(first.install == idf && first.fresh)
        #expect(try first.result.get()["PATH"] == "\(env)/bin:\(AgentEnvironment.path)")
        // Cached: the export does not run again, even once the install is gone.
        try FileManager.default.removeItem(atPath: idf + "/tools/idf_tools.py")
        try lock(session, installFolder(session))
        let second = session.sandbox.idfEnvironment(for: launch)
        #expect(!second.fresh && second.result == first.result)
        // A derivation passed to start is used as it is.
        let outcome = try session.sandbox.start(launch, idf: second).wait()
        #expect(outcome.output.contains("IDF_PATH=\(idf)"))
    }

    @Test func aFailedDerivationIsNotKept() throws {
        let session = try Session()
        let (idf, _) = try install(session, export: "PATH=/usr/local/bin:$PATH")
        let launch = session.launch([idf + "/tools/idf.py", "flash"], serialPort: "/dev/cu.dc-test")
        let first = session.sandbox.idfEnvironment(for: launch)
        #expect(first.fresh)
        #expect(throws: IDFEnvironment.Problem.self) { try first.result.get() }
        #expect(session.sandbox.idfEnvironment(for: launch).fresh)
    }

    @Test func anIdfPyWithoutAUsableEnvironmentDoesNotStart() throws {
        let session = try Session()
        let (idf, _) = try install(session, export: "PATH=/usr/local/bin:$PATH")
        #expect(throws: SandboxError.self) {
            try session.sandbox.start(session.launch([idf + "/tools/idf.py", "flash"], serialPort: "/dev/cu.dc-test"))
        }
    }

    @Test func esptoolRunsWithoutAnInstallEnvironment() throws {
        let session = try Session()
        let bin = installFolder(session) + "/tools/python_env/idf_env/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n/usr/bin/env\n".utf8).write(to: URL(fileURLWithPath: bin + "/esptool.py"))
        chmod(bin + "/esptool.py", 0o755)
        try lock(session, installFolder(session))
        let outcome = try session.sandbox.start(
            session.launch([bin + "/esptool.py", "chip_id"], serialPort: "/dev/cu.dc-test")
        )
        .wait()
        #expect(outcome.status == 0, "\(outcome.output)")
        #expect(!outcome.output.contains("IDF_PATH="))
    }

    // MARK: - Gap 8: only the owner's toolchain, unchanged

    private func refusedFlash(_ session: Session, _ argv: [String]) -> String? {
        do {
            _ = try session.sandbox.start(session.launch(argv, serialPort: "/dev/cu.dc-test"))
            return nil
        } catch let error as SandboxError {
            guard case .toolchain(let why) = error else { return "another error: \(error)" }
            return why
        } catch {
            return "another error: \(error)"
        }
    }

    @Test func aFlasherFromAnInstallThatChangedSinceItWasRecordedDoesNotStart() throws {
        let session = try Session()
        let (idf, _) = try install(session, export: "PATH=@IDF@/tools:$PATH")
        let idfPy = idf + "/tools/idf.py"
        // Edited (as the owner here; the agent cannot write there at all).
        try Data("#!/bin/sh\necho efuse\n".utf8).write(to: URL(fileURLWithPath: idfPy))
        #expect(refusedFlash(session, [idfPy, "flash"])?.contains("no longer matches its recorded hash") == true)
        // A file added next to it.
        try lock(session, installFolder(session))
        try Data("x".utf8).write(to: URL(fileURLWithPath: idf + "/tools/sitecustomize.py"))
        #expect(refusedFlash(session, [idfPy, "flash"])?.contains("no longer matches") == true)
        // Made writable by the group, which the agent is in.
        try FileManager.default.removeItem(atPath: idf + "/tools/sitecustomize.py")
        try lock(session, installFolder(session))
        chmod(idfPy, 0o775)
        #expect(refusedFlash(session, [idfPy, "flash"])?.contains("writable by others") == true)
        chmod(idfPy, 0o755)
        #expect(refusedFlash(session, [idfPy, "flash"]) == nil)
    }

    @Test func aFlasherFromAnInstallWithoutARecordedHashDoesNotStart() throws {
        let session = try Session()
        let (idf, _) = try install(session, export: "PATH=@IDF@/tools:$PATH")
        unlink(OwnerToolchain.hashFile(of: installFolder(session)))
        #expect(refusedFlash(session, [idf + "/tools/idf.py", "flash"])?.contains("no recorded hash") == true)
    }

    @Test func aCopyOfTheInstallInTheAgentsHomeIsNotTrusted() throws {
        let session = try Session()
        _ = try install(session, export: "PATH=@IDF@/tools:$PATH")
        let copy = session.scope.agentHome + "/esp"
        try FileManager.default.copyItem(atPath: installFolder(session), toPath: copy)
        let refused = refusedFlash(session, [copy + "/idf/tools/idf.py", "-p", "/dev/cu.dc-test", "flash"])
        #expect(refused?.contains("does not run from an install in the toolchain folder") == true)
    }
#endif
