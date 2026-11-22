#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlSandbox

    /// A session under a temporary ceiling, run as the test user (the kernel applies the profiles to any user).
    private final class Folder {
        let base: String
        let scope: SessionScope

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in ["/D/p", "/D/.dual-control/agent-home", "/D/.dual-control/tmp"] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            scope = try ResolvedScope.make(choosing: base + "/D/p", ceiling: base + "/D")
        }

        deinit {
            try? FileManager.default.removeItem(atPath: base)
        }
    }

    private func getconf(_ name: String) throws -> String {
        let run = try #require(Subprocess.run(["/usr/bin/getconf", name]))
        return try #require(RealPath.resolve(run.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func theAgentsOwnDarwinFoldersAreReadInsideTheSandbox() throws {
        let folder = try Folder()
        let found = Sandbox(scope: folder.scope, toolchains: []).agentSystemFolders()
        #expect(found == [try getconf("DARWIN_USER_TEMP_DIR"), try getconf("DARWIN_USER_CACHE_DIR")])
    }

    @Test func aDarwinFolderOfAnotherUserIsNotUsed() throws {
        let temp = try getconf("DARWIN_USER_TEMP_DIR")
        #expect(AgentSystemFolders.validated(temp, owner: getuid()) == temp)
        #expect(AgentSystemFolders.validated(temp, owner: getuid() + 1) == nil)
        #expect(AgentSystemFolders.validated("/private/var/folders", owner: getuid()) == nil)
        #expect(AgentSystemFolders.validated("/tmp", owner: getuid()) == nil)
    }

    @Test func changingWritesTheDarwinTempFolderOnlyWhenGiven() throws {
        let folder = try Folder()
        let temp = try getconf("DARWIN_USER_TEMP_DIR")
        let probe = temp + "/dc-test-\(UUID().uuidString)"
        defer { unlink(probe) }
        let without = Sandbox(scope: folder.scope, toolchains: [])
        _ = try without.run(["/usr/bin/touch", probe], kind: .changing, cwd: folder.scope.root)
        #expect(access(probe, F_OK) != 0)
        let with = Sandbox(scope: folder.scope, toolchains: [], systemFolders: without.agentSystemFolders())
        let run = try with.run(["/usr/bin/touch", probe], kind: .changing, cwd: folder.scope.root)
        #expect(run.status == 0, "\(run.output)")
        #expect(access(probe, F_OK) == 0)
    }

    @Test(.enabled(if: Toolchain.developerDirectory() != nil))
    func theDeveloperStubsRunWithoutCacheErrors() throws {
        let folder = try Folder()
        let sandbox = Sandbox(scope: folder.scope, toolchains: [])
        let with = Sandbox(scope: folder.scope, toolchains: [], systemFolders: sandbox.agentSystemFolders())
        let run = try with.run(["/usr/bin/python3", "-c", "print('dc-ok')"], kind: .changing, cwd: folder.scope.root)
        #expect(run.status == 0)
        #expect(run.output == "dc-ok\n", "\(run.output)")
    }
#endif
