#if canImport(Darwin)
    import CryptoKit
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlSandbox

    /// D11 phase 1: the owner's pinned Claude Code. A fake owner home as in `OwnerToolchainTests`; the kernel enforces
    /// the profiles for any user, so the tests run as the test user.
    private final class Fixture {
        let base: String
        let scope: SessionScope
        let store: ClaudeCodeStore
        let sandbox: Sandbox

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in [
                "/home/Developer/p", "/home/Developer/.dual-control/agent-home", "/home/Developer/.dual-control/tmp",
                "/downloads",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            scope = try ResolvedScope.make(choosing: base + "/home/Developer/p", ceiling: base + "/home/Developer")
            store = ClaudeCodeStore(scope: scope, denyACLUser: nil)
            sandbox = Sandbox(scope: scope, toolchains: Toolchain.readPaths())
        }

        deinit {
            try? FileManager.default.removeItem(atPath: base)
        }

        /// A copy of `source` in the downloads folder, as the app's download leaves it.
        func download(_ source: String) throws -> String {
            let path = base + "/downloads/claude-\(UInt32.random(in: .min ... .max))"
            try FileManager.default.copyItem(atPath: source, toPath: path)
            return path
        }

        func write(_ text: String) throws -> String {
            let path = base + "/downloads/fake-\(UInt32.random(in: .min ... .max))"
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            return path
        }

        func sh(_ script: String) throws -> SandboxRun {
            try sandbox.run(["/bin/sh", "-c", script], kind: .changing, cwd: scope.root)
        }
    }

    extension Result {
        fileprivate var success: Success? { try? get() }
        fileprivate var failure: Failure? {
            guard case .failure(let failure) = self else { return nil }
            return failure
        }
    }

    private func sha256(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A Claude Code binary signed by Anthropic on this Mac, if there is one; on CI there is none and the tests that
    /// need it end early.
    private let realClaude: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates =
            ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + path.split(separator: ":").map {
                String($0) + "/claude"
            }
        return candidates.lazy.compactMap(RealPath.resolve).first {
            ClaudeCodeStore.signatureProblem($0) == nil
        }
    }()

    @Test func aBinaryNotSignedByAnthropicIsRefused() throws {
        let f = try Fixture()
        // Apple's own signature, and none at all.
        for file in [try f.download("/bin/ls"), try f.write("#!/bin/sh\necho hi\n")] {
            let result = f.store.install(version: "2.1.311", from: file, sha256: try sha256(file))
            #expect(result.failure?.description.contains("not signed by Anthropic") == true, "\(result)")
        }
        #expect(f.store.versions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ClaudeCode.install(version: "2.1.311", scope: f.scope)))
    }

    @Test func aBinaryThatDoesNotMatchTheManifestIsRefused() throws {
        let f = try Fixture()
        let file = try f.write("x")
        let result = f.store.install(version: "2.1.311", from: file, sha256: String(repeating: "0", count: 64))
        #expect(result.failure?.description.contains("does not match the release manifest") == true, "\(result)")
        #expect(f.store.versions().isEmpty)
    }

    @Test func anInvalidVersionOrALinkIsRefused() throws {
        let f = try Fixture()
        let file = try f.write("x")
        let sum = try sha256(file)
        #expect(f.store.install(version: "../x", from: file, sha256: sum).failure != nil)
        let target = try f.write("x")
        let link = f.base + "/downloads/link"
        symlink(target, link)
        #expect(f.store.install(version: "2.1.311", from: link, sha256: sum).failure != nil)
        #expect(f.store.versions().isEmpty)
    }

    @Test func noInstallMeansNothingToVerify() throws {
        let f = try Fixture()
        #expect(f.store.verify(version: "2.1.311").failure?.description.contains("not installed") == true)
    }

    @Test func aSignedBinaryIsInstalledLockedVerifiedAndRunsAsTheAgentWhoCannotChangeIt() throws {
        guard let realClaude else { return }
        let f = try Fixture()
        let file = try f.download(realClaude)
        let digest = try #require(f.store.install(version: "2.1.311", from: file, sha256: try sha256(file)).success)
        let install = ClaudeCode.install(version: "2.1.311", scope: f.scope)
        let binary = ClaudeCode.binary(of: install)
        var info = stat()
        #expect(lstat(binary, &info) == 0 && info.st_mode & 0o7777 == 0o755 && info.st_uid == getuid())
        #expect(f.store.versions() == ["2.1.311"])
        #expect(f.store.verify(version: "2.1.311").success == digest)
        #expect(!FileManager.default.fileExists(atPath: file), "the download is removed")

        // The agent runs it in CHANGING, with HOME in its own work area, and cannot change it.
        let version = try f.sh("DISABLE_AUTOUPDATER=1 '\(binary)' --version")
        #expect(version.status == 0 && version.output.contains("Claude Code"), "\(version.output)")
        for script in ["echo x >> '\(binary)'", "rm -f '\(binary)'", "mv '\(install)' '\(install).x'"] {
            let run = try f.sh(script)
            #expect(run.status != 0 && run.output.contains("Operation not permitted"), "\(script): \(run.output)")
        }

        // Changed afterwards (as the owner could), it no longer verifies.
        chmod(binary, 0o775)
        ClaudeCodeStore.forget(install)
        #expect(f.store.verify(version: "2.1.311").failure != nil)
    }

    @Test func aNewInstallOfTheSameVersionReplacesTheEarlierOne() throws {
        guard let realClaude else { return }
        let f = try Fixture()
        for _ in 0..<2 {
            let file = try f.download(realClaude)
            #expect(f.store.install(version: "2.1.311", from: file, sha256: try sha256(file)).success != nil)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: f.scope.toolchains).sorted()
        #expect(names == ["claude-code-2.1.311", "claude-code-2.1.311.sha256"])
    }
#endif
