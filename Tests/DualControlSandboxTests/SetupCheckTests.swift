#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlSandbox

    private func temporaryFolder() throws -> String {
        var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
        let made = try #require(mkdtemp(&template).map { String(cString: $0) })
        return try #require(RealPath.resolve(made))
    }

    private func chmod(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func groupMembershipIsChecked() {
        #expect(SetupCheck.isMember("root", of: "admin") == true)
        #expect(SetupCheck.isMember("root", of: "wheel") == true)
        #expect(SetupCheck.isMember("nobody", of: "admin") == false)
        #expect(SetupCheck.isMember("dc-test-no-such-user", of: "admin") == nil)
        #expect(SetupCheck.isMember("nobody", of: "dc-test-no-such-group") == nil)
    }

    /// admin and wheel give sudo and system rights, tty lets a user write to other users' terminals, and
    /// _developer lets a user debug other processes.
    @Test func theAgentMayBeInNoPrivilegedGroup() {
        #expect(SetupCheck.privilegedGroups == ["admin", "wheel", "tty", "_developer"])
        #expect(SetupCheck.privilegedMemberships("nobody") == [])
        #expect(SetupCheck.privilegedMemberships("root")?.contains("admin") == true)
        #expect(SetupCheck.privilegedMemberships("root")?.contains("wheel") == true)
        #expect(SetupCheck.privilegedMemberships("dc-test-no-such-user") == nil)
    }

    @Test func theACLMustGrantTheAgentWithInheritance() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        #expect(SetupCheck.aclGrants(user: "_www", on: base) == false)
        #expect(try chmod(["+a", "_www allow list,search,read", base]) == 0)
        // Without inheritance, delete and write, new files would not be shared.
        #expect(SetupCheck.aclGrants(user: "_www", on: base) == false)
        #expect(try chmod(["+a", "_www allow \(SetupGuide.aclRights)", base]) == 0)
        #expect(SetupCheck.aclGrants(user: "_www", on: base) == true)
        #expect(SetupCheck.aclGrants(user: "nobody", on: base) == false)
        #expect(SetupCheck.aclGrants(user: "_www", on: base + "/missing") == false)
    }

    @Test func aDenyEntryForTheAgentFailsTheACLCheck() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        #expect(try chmod(["+a", "_www allow \(SetupGuide.aclRights)", base]) == 0)
        #expect(try chmod(["+a#", "0", "_www deny write", base]) == 0)
        #expect(SetupCheck.aclGrants(user: "_www", on: base) == false)
    }

    @Test func theProtectedFolderMustDenyTheAgentFirst() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        #expect(SetupCheck.aclDenies(user: "_www", on: base) == false)
        #expect(try chmod(["+a", "_www allow \(SetupGuide.aclRights)", base]) == 0)
        #expect(SetupCheck.aclDenies(user: "_www", on: base) == false)
        // A deny that comes after the allow is never reached.
        #expect(try chmod(["+a#", "1", "_www deny \(SetupGuide.aclRights)", base]) == 0)
        #expect(SetupCheck.aclDenies(user: "_www", on: base) == false)
        #expect(try chmod(["-a#", "1", base]) == 0)
        // A partial deny is not enough.
        #expect(try chmod(["+a", "_www deny write", base]) == 0)
        #expect(SetupCheck.aclDenies(user: "_www", on: base) == false)
        #expect(try chmod(["-a", "_www deny write", base]) == 0)
        // What the setup step adds: chmod puts the deny before the allow.
        #expect(try chmod(["+a", "_www deny \(SetupGuide.aclRights)", base]) == 0)
        #expect(SetupCheck.aclDenies(user: "_www", on: base) == true)
        #expect(SetupCheck.aclDenies(user: "nobody", on: base) == false)
        #expect(SetupCheck.aclDenies(user: "_www", on: base + "/missing") == false)
    }

    @Test(
        arguments: [
            (1, "Sorry, user claude-agent may not run sudo on host.\n", true),
            // Seen on a real setup: the sandbox will not even start the setuid sudo. The strongest pass.
            (1, "sandbox-exec: execvp() of '/usr/bin/sudo' failed: Operation not permitted\n", true),
            (0, "User claude-agent may run the following commands on host:\n    (ALL) ALL\n", false),
            (1, "sandbox-exec: execvp() of '/usr/bin/sudo' failed: Operation not permitted\nUser x may run\n", false),
            (0, "sandbox-exec: execvp() of '/usr/bin/sudo' failed: Operation not permitted\n", false),
            (1, "sudo: a password is required\n", false),
            (1, "", false),
        ]
    )
    func sudoListOutputs(_ status: Int32, _ output: String, _ passes: Bool) {
        let (passed, detail) = SetupCheck.sudoVerdict(agent: "claude-agent", SandboxRun(status: status, output: output))
        #expect(passed == passes)
        #expect(!detail.isEmpty)
    }

    @Test func tmuxMustBeAnExecutableNobodyElseCanChange() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let tool = base + "/tmux"
        #expect(!SetupCheck.isTrustedExecutable(tool))
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: tool))
        Darwin.chmod(tool, 0o755)
        #expect(SetupCheck.isTrustedExecutable(tool))
        Darwin.chmod(tool, 0o775)
        #expect(!SetupCheck.isTrustedExecutable(tool))
        Darwin.chmod(tool, 0o757)
        #expect(!SetupCheck.isTrustedExecutable(tool))
        Darwin.chmod(tool, 0o644)
        #expect(!SetupCheck.isTrustedExecutable(tool))
    }

    @Test func aMissingAgentFailsEveryCheckWithoutRunningAnything() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base + "/Developer/p", withIntermediateDirectories: true)
        let scope = try ResolvedScope.make(choosing: base + "/Developer/p", ceiling: base + "/Developer")
        let items = SetupCheck(agent: "dc-test-no-such-user", tmux: base + "/no-tmux").run(scope: scope)
        #expect(items.map(\.id) == ["user", "home", "groups", "sudo", "acl", "acl-deny", "folders", "tmux", "sandbox"])
        #expect(items.allSatisfy { !$0.passed })
        #expect(items.allSatisfy { !$0.detail.isEmpty })
        #expect(SetupCheck().runAs == SetupGuide.runAsAgent)
    }

    @Test func withoutASessionFolderTheSandboxIsNotChecked() {
        let items = SetupCheck(agent: "dc-test-no-such-user").run(scope: nil)
        let sandbox = items.first { $0.id == "sandbox" }
        #expect(sandbox?.passed == false)
        #expect(sandbox?.detail.contains("session folder") == true)
    }
#endif
