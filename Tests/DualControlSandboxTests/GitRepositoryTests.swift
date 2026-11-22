#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlSandbox

    /// A temporary session, run as the test user with the real kernel sandbox and the real git.
    private final class Session {
        let base: String
        let scope: SessionScope
        let sandbox: Sandbox

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in [
                "/Developer/p/existing", "/Developer/.dual-control/agent-home", "/Developer/.dual-control/tmp",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            try Data("DC-TEST\n".utf8).write(to: URL(fileURLWithPath: base + "/Developer/p/existing/notes.txt"))
            scope = try ResolvedScope.make(choosing: base + "/Developer/p", ceiling: base + "/Developer")
            sandbox = Sandbox(scope: scope, toolchains: Toolchain.readPaths())
        }

        deinit {
            // The test user may delete what the sandboxed agent may not.
            try? FileManager.default.removeItem(atPath: base)
        }

        var root: String { scope.root }

        func launch(_ tool: String, _ argv: [String]) -> Launch {
            let request = ActionRequest(
                capability: .command,
                argv: argv,
                cwd: SandboxProfile.parent(of: argv.last ?? scope.root),
                projectID: scope.root,
                timeoutSeconds: 60
            )
            let decision = Decision(verdict: .allow, reason: "test", ruleID: "test")
            let execution = Execution(id: "g1", tool: tool, request: request, decision: decision, scope: scope)
            return Launch(
                execution: execution,
                scope: scope,
                readOnly: false,
                serialPort: nil,
                timeoutSeconds: 60,
                git: Supervisor.gitLaunch(execution)
            )
        }

        func initialize(_ folder: String) throws -> CommandOutcome {
            let launch = launch("git_init", GitSetup.initArgv(folder: folder))
            return sandbox.finishGit(launch, try sandbox.start(launch).wait())
        }

        func sh(_ script: String, cwd: String? = nil) throws -> SandboxRun {
            try sandbox.run(["/bin/sh", "-c", script], kind: .changing, cwd: cwd ?? root)
        }

        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }
    }

    private let gitAvailable = Toolchain.git() != nil

    @Test(.enabled(if: gitAvailable)) func plainGitInitStaysImpossibleInTheSession() throws {
        let s = try Session()
        let git = try #require(Toolchain.git())
        let run = try s.sandbox.run([git, "init", s.root + "/plain"], kind: .changing, cwd: s.root)
        #expect(run.status != 0)
        #expect(!s.exists(s.root + "/plain/.git/config"))
    }

    @Test(.enabled(if: gitAvailable)) func gitInitMakesACheckedRepositoryThatThenStaysLocked() throws {
        let s = try Session()
        let outcome = try s.initialize(s.root + "/fresh")
        #expect(outcome.status == 0, "\(outcome.output)")
        #expect(s.exists(s.root + "/fresh/.git/config"))
        #expect(!s.exists(s.root + "/fresh/.git/hooks"))
        // From now on the agent works in it, but its hooks and config cannot change.
        let git = try #require(Toolchain.git())
        let commit = try s.sandbox.run(
            [
                "/usr/bin/env", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", git, "-c", "user.name=t", "-c",
                "user.email=t@example.com", "commit", "--allow-empty", "-m", "first",
            ],
            kind: .changing,
            cwd: s.root + "/fresh"
        )
        #expect(commit.status == 0, "\(commit.output)")
        #expect(try s.sh("mkdir .git/hooks", cwd: s.root + "/fresh").status != 0)
        #expect(try s.sh("echo '[core]' >> .git/config", cwd: s.root + "/fresh").status != 0)
    }

    @Test(.enabled(if: gitAvailable)) func gitInitWorksInAnExistingFolderAndKeepsItsFiles() throws {
        let s = try Session()
        #expect(try s.initialize(s.root + "/existing").status == 0)
        #expect(s.exists(s.root + "/existing/.git/HEAD"))
        #expect(s.exists(s.root + "/existing/notes.txt"))
    }

    @Test(.enabled(if: gitAvailable)) func anExistingRepositoryIsNeverReinitialised() throws {
        let s = try Session()
        #expect(try s.initialize(s.root + "/existing").status == 0)
        let launch = s.launch("git_init", GitSetup.initArgv(folder: s.root + "/existing"))
        #expect(throws: SandboxError.self) { try s.sandbox.start(launch) }
    }

    @Test(.enabled(if: gitAvailable)) func aCloneNeedsAFolderThatDoesNotExistYet() throws {
        let s = try Session()
        let launch = s.launch(
            "git_clone",
            GitSetup.cloneArgv(url: "https://github.com/a/b.git", folder: s.root + "/existing")
        )
        #expect(throws: SandboxError.self) { try s.sandbox.start(launch) }
    }

    @Test(.enabled(if: gitAvailable)) func aRepositoryWithAnythingElseIsRemoved() throws {
        let s = try Session()
        let launch = s.launch("git_init", GitSetup.initArgv(folder: s.root + "/existing"))
        let outcome = try s.sandbox.start(launch).wait()
        #expect(outcome.status == 0)
        // As if git had written more than it does: a hooks path, then a hook.
        let config = s.root + "/existing/.git/config"
        let handle = try #require(FileHandle(forWritingAtPath: config))
        handle.seekToEndOfFile()
        handle.write(Data("\thooksPath = /tmp/x\n".utf8))
        try handle.close()
        let finished = s.sandbox.finishGit(launch, outcome)
        #expect(finished.status != 0)
        #expect(finished.output.contains("core.hookspath"), "\(finished.output)")
        // Only what git_init made goes: the folder and its files stay.
        #expect(!s.exists(s.root + "/existing/.git"))
        #expect(s.exists(s.root + "/existing/notes.txt"))
    }

    @Test(.enabled(if: gitAvailable)) func aHookOrAttributesFileFailsTheCheck() throws {
        let s = try Session()
        for extra in ["hooks/post-checkout", "info/attributes", "commondir"] {
            let folder = s.root + "/r-" + extra.replacingOccurrences(of: "/", with: "-")
            let launch = s.launch("git_init", GitSetup.initArgv(folder: folder))
            let outcome = try s.sandbox.start(launch).wait()
            let path = folder + "/.git/" + extra
            try FileManager.default.createDirectory(
                atPath: SandboxProfile.parent(of: path),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
            #expect(s.sandbox.finishGit(launch, outcome).status != 0, "\(extra)")
            #expect(!s.exists(folder + "/.git"), "\(extra)")
        }
    }

    @Test(.enabled(if: gitAvailable)) func aFailedCloneLeavesNothing() throws {
        let s = try Session()
        // No proxy: the sandbox has no network, so the clone fails after git made the folder.
        let target = s.root + "/blink"
        let launch = s.launch("git_clone", GitSetup.cloneArgv(url: "https://github.com/a/b.git", folder: target))
        let finished = s.sandbox.finishGit(launch, try s.sandbox.start(launch).wait())
        #expect(finished.status != 0)
        #expect(!s.exists(target))
    }
#endif
