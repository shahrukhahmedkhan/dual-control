#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlSandbox

    /// D12a with the real scripts in the real CHANGING profile. The kernel enforces the profile for any user, so the
    /// tests run as the test user.
    private final class Fixture {
        let base: String
        let scope: SessionScope
        let sandbox: Sandbox

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in [
                "/home/Developer/p/src", "/home/Developer/p/repo/.git/hooks",
                "/home/Developer/.dual-control/agent-home",
                "/home/Developer/.dual-control/tmp", "/outside",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            scope = try ResolvedScope.make(choosing: base + "/home/Developer/p", ceiling: base + "/home/Developer")
            sandbox = Sandbox(scope: scope, toolchains: Toolchain.readPaths())
        }

        deinit {
            try? FileManager.default.removeItem(atPath: base)
        }

        /// A launch as `Supervisor.begin` makes one, after the supervisor resolved the folder.
        func launch(_ request: ActionRequest) -> Launch {
            var request = request
            request.cwd = RealPath.resolve(request.cwd) ?? request.cwd
            request.projectID = request.cwd
            let decision = Decision(verdict: .allow, reason: "test", ruleID: "test")
            let execution = Execution(id: "f1", tool: "write_file", request: request, decision: decision, scope: scope)
            return Launch(execution: execution, scope: scope, readOnly: false, serialPort: nil, timeoutSeconds: 30)
        }

        func write(_ path: String, _ content: [UInt8]) -> Result<FileWritten, FileWrite.Problem> {
            sandbox.writeFile(launch(FileWrite.writeRequest(path: path, content: content)))
        }

        func patch(_ path: String, _ text: String) throws -> Result<FileWritten, FileWrite.Problem> {
            let parsed = try UnifiedPatch.parse(text).get()
            return sandbox.writeFile(launch(FileWrite.patchRequest(path: path, text: text, patch: parsed)))
        }

        func contents(_ path: String) -> [UInt8]? {
            FileManager.default.contents(atPath: path).map(Array.init)
        }

        func mode(_ path: String) -> mode_t {
            var info = stat()
            _ = lstat(path, &info)
            return info.st_mode & 0o7777
        }

        func leftovers(_ folder: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter {
                $0.hasPrefix(".dual-control-write")
            }
        }
    }

    @Test func aNewFileIsWrittenWholeWithNoTemporaryFileLeft() throws {
        let f = try Fixture()
        let path = f.scope.root + "/src/main.c"
        let content = Array("int main(void) { return 0; }\n".utf8)
        let written = try f.write(path, content).get()
        #expect(written == FileWritten(bytes: content.count, sha256: FileWrite.sha256(content)))
        #expect(f.contents(path) == content)
        #expect(f.mode(path) & 0o600 == 0o600 && f.mode(path) & 0o022 == 0)
        #expect(f.leftovers(f.scope.root + "/src").isEmpty)
    }

    @Test func anyBytesCanBeWrittenAndAnExistingFileKeepsItsMode() throws {
        let f = try Fixture()
        let path = f.scope.root + "/run.sh"
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0o755)
        let bytes: [UInt8] = [0x00, 0xFF, 0x0A, 0x27, 0x22, 0x24]
        _ = try f.write(path, bytes).get()
        #expect(f.contents(path) == bytes)
        #expect(f.mode(path) == 0o755)
    }

    @Test func aPatchIsAppliedToTheFileAsTheAgentReadsIt() throws {
        let f = try Fixture()
        let path = f.scope.root + "/src/list.txt"
        try Data("one\ntwo\nthree\n".utf8).write(to: URL(fileURLWithPath: path))
        let written = try f.patch(path, "--- a/list.txt\n+++ b/list.txt\n@@ -2 +2 @@\n-two\n+TWO\n").get()
        #expect(f.contents(path) == Array("one\nTWO\nthree\n".utf8))
        #expect(written.sha256 == FileWrite.sha256(Array("one\nTWO\nthree\n".utf8)))
    }

    @Test func aPatchThatDoesNotMatchWritesNothing() throws {
        let f = try Fixture()
        let path = f.scope.root + "/src/list.txt"
        try Data("one\ntwo\n".utf8).write(to: URL(fileURLWithPath: path))
        guard case .failure(let problem) = try f.patch(path, "@@ -1 +1 @@\n-uno\n+one\n") else {
            Issue.record("patched")
            return
        }
        #expect(problem.description.contains("does not match"))
        #expect(f.contents(path) == Array("one\ntwo\n".utf8))
        guard case .failure = try f.patch(f.scope.root + "/src/missing.txt", "@@ -1 +1 @@\n-a\n+b\n") else {
            Issue.record("patched a missing file")
            return
        }
    }

    @Test func aSymbolicLinkIsNotWrittenThrough() throws {
        let f = try Fixture()
        let outside = f.base + "/outside/target.txt"
        try Data("keep\n".utf8).write(to: URL(fileURLWithPath: outside))
        let link = f.scope.root + "/link.txt"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        guard case .failure(let problem) = f.write(link, Array("x".utf8)) else {
            Issue.record("wrote through a link")
            return
        }
        #expect(problem.description.contains("symbolic link"))
        #expect(f.contents(outside) == Array("keep\n".utf8))
        guard case .failure = try f.patch(link, "@@ -1 +1 @@\n-keep\n+x\n") else {
            Issue.record("patched through a link")
            return
        }
        #expect(f.contents(outside) == Array("keep\n".utf8))
    }

    @Test func theKernelRefusesGitHooksEvenIfTheChecksAboveWereSkipped() throws {
        let f = try Fixture()
        // The router and supervisor refuse this path; the kernel profile is the floor under them.
        let hook = f.scope.root + "/repo/.git/hooks/pre-commit"
        guard case .failure(let problem) = f.write(hook, Array("#!/bin/sh\ntouch /tmp/pwned\n".utf8)) else {
            Issue.record("wrote a hook")
            return
        }
        #expect(problem.description.contains("sandbox refused"), "\(problem)")
        #expect(!FileManager.default.fileExists(atPath: hook))
    }

    @Test func aStepForAnotherPathIsNotStarted() throws {
        let f = try Fixture()
        let launch = f.launch(FileWrite.writeRequest(path: f.scope.root + "/a.txt", content: [0x61]))
        #expect(throws: (any Error).self) {
            try f.sandbox.startFileStep(
                launch,
                FileWrite.writeArgv(path: f.scope.root + "/b.txt", expected: .absentOrAny, content: [0x61])
            )
        }
        #expect(throws: (any Error).self) {
            try f.sandbox.startFileStep(launch, ["/bin/sh", "-c", "echo", "write_file", f.scope.root + "/a.txt"])
        }
    }
#endif
