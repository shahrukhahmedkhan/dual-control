#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlSandbox

    /// Gap 10: what CHANGING may read outside the owner's home. A fake owner home in a temporary folder, as in
    /// `EnforcementTests`; the kernel enforces the profile for any user, so the tests run as the test user. The
    /// sandbox gets the test user's own Darwin folders, as production gets the agent's.
    ///
    ///     <base>/home/Developer/p                     the session folder
    ///     <base>/home/Developer/.dual-control/{agent-home,tmp}
    ///     <base>/outside/x.txt                        outside the home, world-readable
    private final class Fixture {
        let base: String
        let scope: SessionScope
        let sandbox: Sandbox

        var outside: String { base + "/outside" }

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in [
                "/home/Developer/p", "/home/Developer/.dual-control/agent-home", "/home/Developer/.dual-control/tmp",
                "/outside",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            for file in ["/outside/x.txt", "/home/Developer/p/a.txt", "/home/Developer/.dual-control/agent-home/h.txt"]
            {
                try Data("DC-TEST\n".utf8).write(to: URL(fileURLWithPath: base + file))
            }
            chmod(base + "/outside/x.txt", 0o644)
            scope = try ResolvedScope.make(choosing: base + "/home/Developer/p", ceiling: base + "/home/Developer")
            let plain = Sandbox(scope: scope, toolchains: Toolchain.readPaths())
            sandbox = Sandbox(
                scope: scope,
                toolchains: Toolchain.readPaths(),
                systemFolders: plain.agentSystemFolders()
            )
        }

        deinit {
            try? FileManager.default.removeItem(atPath: base)
        }

        func sh(_ script: String, kind: SandboxKind = .changing) throws -> SandboxRun {
            let environment = AgentEnvironment.commandVariables(scope: scope)
            let argv = try sandbox.argv(["/bin/sh", "-c", script], kind: kind, environment: environment)
            return try #require(Subprocess.run(argv, cwd: scope.root))
        }

        func write(_ text: String, _ relative: String) throws {
            let path = scope.root + "/" + relative
            try FileManager.default.createDirectory(
                atPath: SandboxProfile.parent(of: path),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    private func notPermitted(_ run: SandboxRun) -> Bool {
        run.status != 0 && run.output.contains("Operation not permitted")
    }

    /// The Swift compiles saturate a CI runner and slow the timing tests that run alongside them, so on CI they run
    /// only with `DC_BUILD_TESTS=1`. Locally (the pre-commit gate) they always run.
    private let runsSwiftBuilds: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] == nil || environment["DC_BUILD_TESTS"] == "1"
    }()

    @Suite(.serialized) struct ReadScope {
        @Test func nothingOutsideTheAllowlistCanBeRead() throws {
            let f = try Fixture()
            var denied = [
                "cat '\(f.outside)/x.txt'",
                // The same file through the data volume's firmlinked path.
                "cat '/System/Volumes/Data\(f.outside)/x.txt'",
                "ls /Volumes", "ls /Users", "ls /Users/Shared", "ls /Library/Preferences", "ls /private/var/log",
                "ls /private/tmp", "ls /Applications",
            ]
            for kind in [SandboxKind.flashing(port: "/dev/cu.dc-test"), .cloning(target: f.scope.root + "/new")] {
                #expect(notPermitted(try f.sh("cat '\(f.outside)/x.txt'", kind: kind)), "\(kind)")
            }
            if let volume = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes").first {
                denied.append("ls '/Volumes/\(volume)'")
            }
            for script in denied {
                let run = try f.sh(script)
                #expect(notPermitted(run), "\(script): \(run.output)")
            }
        }

        @Test func whatCommandsNeedCanStillBeRead() throws {
            let f = try Fixture()
            var allowed = [
                "ls /usr/bin >/dev/null", "cat /etc/hosts >/dev/null", "ls /Library/Developer >/dev/null",
                "head -c 8 /dev/urandom >/dev/null", "cat a.txt", "cat \"$HOME/h.txt\"", "/bin/pwd", "ls / >/dev/null",
            ]
            if let developer = Toolchain.developerDirectory() { allowed.append("ls '\(developer)/usr/bin' >/dev/null") }
            for script in allowed {
                let run = try f.sh(script)
                #expect(run.status == 0, "\(script): \(run.output)")
            }
        }

        @Test func cBuildsAndRuns() throws {
            let f = try Fixture()
            try f.write("#include <stdio.h>\nint main(void) { puts(\"DC-TEST-c\"); return 0; }\n", "hello.c")
            let run = try f.sh("/usr/bin/clang hello.c -o hello-c && ./hello-c")
            #expect(run.status == 0 && run.output.contains("DC-TEST-c"), "\(run.output)")
            #expect(!run.output.contains("Operation not permitted"), "\(run.output)")
        }

        @Test(.enabled(if: runsSwiftBuilds)) func swiftBuildsAndRuns() throws {
            let f = try Fixture()
            try f.write("print(\"DC-TEST-swift\")\n", "hello.swift")
            let run = try f.sh("/usr/bin/swiftc hello.swift -o hello-swift && ./hello-swift")
            #expect(run.status == 0 && run.output.contains("DC-TEST-swift"), "\(run.output)")
        }

        /// SwiftPM sandboxes its manifest with sandbox-exec, which cannot nest, so it runs with that off.
        @Test(.enabled(if: runsSwiftBuilds)) func aSwiftPackageBuilds() throws {
            let f = try Fixture()
            try f.write(
                "// swift-tools-version:5.9\nimport PackageDescription\n"
                    + "let package = Package(name: \"dctest\", targets: [.executableTarget(name: \"dctest\")])\n",
                "pkg/Package.swift"
            )
            try f.write("print(\"DC-TEST-package\")\n", "pkg/Sources/dctest/main.swift")
            let run = try f.sh("cd pkg && /usr/bin/swift run --disable-sandbox -q dctest 2>&1")
            #expect(run.status == 0 && run.output.contains("DC-TEST-package"), "\(run.output)")
        }

        @Test func pythonEnvironmentsWork() throws {
            let f = try Fixture()
            let system = try f.sh("/usr/bin/python3 -c 'import ssl, json, sqlite3; print(\"DC-TEST-py\")'")
            #expect(system.status == 0 && system.output.contains("DC-TEST-py"), "\(system.output)")
            guard access("/opt/homebrew/bin/python3.12", X_OK) == 0 else { return }
            let venv = try f.sh(
                "/opt/homebrew/bin/python3.12 -m venv v && v/bin/python -c 'import ssl; print(\"DC-TEST-venv\")'"
                    + " && v/bin/pip --version"
            )
            #expect(venv.status == 0 && venv.output.contains("DC-TEST-venv"), "\(venv.output)")
        }

        @Test func uvMakesAnEnvironment() throws {
            guard access("/opt/homebrew/bin/uv", X_OK) == 0 else { return }
            let f = try Fixture()
            let run = try f.sh(
                "/opt/homebrew/bin/uv venv --offline -q uvenv && uvenv/bin/python -c 'print(\"DC-TEST-uv\")'"
            )
            #expect(run.status == 0 && run.output.contains("DC-TEST-uv"), "\(run.output)")
        }

        @Test func gitAndMakeWork() throws {
            let f = try Fixture()
            try f.write("all:\n\t@echo DC-TEST-make\n", "Makefile")
            let make = try f.sh("/usr/bin/make")
            #expect(make.status == 0 && make.output.contains("DC-TEST-make"), "\(make.output)")
            let git = try f.sh(
                "cd \"$HOME\" && /usr/bin/git init -q r && cd r && echo x > x && /usr/bin/git add x"
                    + " && /usr/bin/git -c user.name=t -c user.email=t@t commit -qm x && /usr/bin/git log --oneline"
            )
            #expect(git.status == 0, "\(git.output)")
        }
    }
#endif
