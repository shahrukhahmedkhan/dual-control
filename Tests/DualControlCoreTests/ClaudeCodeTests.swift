import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let start2 = IPCRequest(id: "1", tool: "claude_code_start", arguments: [:])

private func supervisor(_ mode: ApprovalMode, installs: [String] = ["2.1.311"]) throws -> Supervisor {
    var supervisor = Supervisor(
        scope: try SessionScope(ceiling: "/work", root: "/work/p"),
        sandboxProblem: nil,
        resolvePath: { $0 }
    )
    supervisor.setMode(mode, now: start)
    supervisor.setClaudeCodeVersions(installs)
    return supervisor
}

// MARK: - Versions and layout

@Test(arguments: ["2.1.311", "1.0.0", "10.20.3000"])
func releaseVersionsAreAccepted(_ version: String) {
    #expect(ClaudeCode.versionProblem(version) == nil)
}

@Test(arguments: ["", "v2.1.3", "2.1", "2.1.3.4", "2.1.3-beta", "latest", "stable", "../2.1.3", "2.1.3 ", "02.1.x"])
func otherVersionsAreRefused(_ version: String) {
    #expect(ClaudeCode.versionProblem(version) != nil)
}

@Test func anInstallLivesInTheOwnersToolchainFolder() throws {
    let scope = try SessionScope(ceiling: "/work", root: "/work/p")
    #expect(
        ClaudeCode.install(version: "2.1.311", scope: scope) == "/work/.dual-control/toolchains/claude-code-2.1.311"
    )
    #expect(ClaudeCode.binary(of: "/x/claude-code-2.1.311") == "/x/claude-code-2.1.311/claude")
    #expect(ClaudeCode.version(ofInstallName: "claude-code-2.1.311") == "2.1.311")
    for name in ["claude-code-latest", "esp-idf-v5.4", "claude-code-", ".new-claude-code-2.1.311-1", "claude-code-2.1"]
    {
        #expect(ClaudeCode.version(ofInstallName: name) == nil, "\(name)")
    }
    // A Claude Code install is never taken for an ESP-IDF one (flashers are recognised only there).
    #expect(
        OwnerToolchain.install(of: "/work/.dual-control/toolchains/claude-code-2.1.311/claude", scope: scope) == nil
    )
}

@Test func theNewestVersionIsComparedNumerically() {
    #expect(ClaudeCode.newest(["2.1.9", "2.1.311", "2.0.999"]) == "2.1.311")
    #expect(ClaudeCode.newest(["1.10.0", "1.9.9"]) == "1.10.0")
    #expect(ClaudeCode.newest([]) == nil)
    #expect(ClaudeCode.newest(["x", "2.1.3"]) == "2.1.3")
}

@Test func downloadsComeFromTheOfficialReleaseHost() {
    #expect(
        ClaudeCode.manifestURL(version: "2.1.311")
            == "https://downloads.claude.ai/claude-code-releases/2.1.311/manifest.json"
    )
    #expect(
        ClaudeCode.binaryURL(version: "2.1.311", platform: "darwin-arm64")
            == "https://downloads.claude.ai/claude-code-releases/2.1.311/darwin-arm64/claude"
    )
}

@Test func theChecksumIsReadFromTheManifestForThePlatformOnly() {
    let sum = String(repeating: "ab", count: 32)
    let other = String(repeating: "cd", count: 32)
    let manifest = """
        {"version":"2.1.311","platforms":{"darwin-x64":{"checksum":"\(other)","size":1},\
        "darwin-arm64":{"checksum":"\(sum)","size":2}}}
        """
    #expect(ClaudeCode.checksum(manifest: Data(manifest.utf8), platform: "darwin-arm64") == sum)
    #expect(ClaudeCode.checksum(manifest: Data(manifest.utf8), platform: "darwin-x64") == other)
    #expect(ClaudeCode.checksum(manifest: Data(manifest.utf8), platform: "linux-x64") == nil)
    for bad in [
        #"{"platforms":{"darwin-arm64":{"checksum":"ABAB"}}}"#,
        #"{"platforms":{"darwin-arm64":{"checksum":"\#(String(repeating: "AB", count: 32))"}}}"#,
        #"{"platforms":{"darwin-arm64":{"checksum":42}}}"#,
        "<html>not found</html>", "",
    ] {
        #expect(ClaudeCode.checksum(manifest: Data(bad.utf8), platform: "darwin-arm64") == nil, "\(bad)")
    }
}

@Test func theSigningRequirementNamesAnthropicsDeveloperID() {
    let requirement = ClaudeCode.codeRequirement
    // Anthropic's designated requirement: a Developer ID Application certificate of team Q6L2SF6YDW.
    #expect(
        requirement
            == #"identifier "com.anthropic.claude-code" and anchor apple generic and "#
            + #"certificate 1[field.1.2.840.113635.100.6.2.6] exists and "#
            + #"certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "Q6L2SF6YDW""#
    )
}

// MARK: - The launch line

@Test func theLaunchLineRunsThePinnedBinaryInTheSessionFolderWithUpdatesAndTelemetryOff() throws {
    let scope = try SessionScope(ceiling: "/work", root: "/work/p")
    let line = try #require(ClaudeCode.launchLine(version: "2.1.311", scope: scope))
    #expect(
        line
            == "cd '/work/p' && DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "
            + "'/work/.dual-control/toolchains/claude-code-2.1.311/claude'\n"
    )
    #expect(ClaudeCode.version(ofLaunchLine: line, scope: scope) == "2.1.311")
    #expect(ClaudeCode.version(ofLaunchLine: line + "rm -rf ~\n", scope: scope) == nil)
    #expect(ClaudeCode.version(ofLaunchLine: "echo hi\n", scope: scope) == nil)
    #expect(ClaudeCode.launchLine(version: "latest", scope: scope) == nil)
}

@Test func pathsThatCannotBeQuotedGiveNoLaunchLine() throws {
    let scope = try SessionScope(ceiling: "/work", root: "/work/it's")
    #expect(ClaudeCode.launchLine(version: "2.1.311", scope: scope) == nil)
    let control = try SessionScope(ceiling: "/work", root: "/work/a\u{1B}b")
    #expect(ClaudeCode.launchLine(version: "2.1.311", scope: control) == nil)
}

// MARK: - claude_code_start

@Test func startTakesNoArguments() {
    let request = IPCRequest(id: "1", tool: "claude_code_start", arguments: ["version": .string("2.1.311")])
    guard case .invalid = ToolRouter.route(request) else {
        Issue.record("routed with arguments")
        return
    }
}

@Test func startTypesTheFixedLineForTheNewestInstallAndFollowsTheApprovalMode() throws {
    var asking = try supervisor(.askEach, installs: ["2.1.300", "2.1.311"])
    guard case .pending = asking.submit(start2, now: start) else {
        Issue.record("did not wait for approval")
        return
    }
    #expect(asking.pending.first?.request.argv == [ClaudeCode.launchLine(version: "2.1.311", scope: asking.scope!)!])
    var allowing = try supervisor(.allowWhileOpen)
    guard case .execute(let execution) = allowing.submit(start2, now: start) else {
        Issue.record("did not run")
        return
    }
    #expect(execution.tool == "claude_code_start" && execution.request.capability == .terminal)
    guard
        case .launch(let launch) = allowing.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    else {
        Issue.record("did not launch")
        return
    }
    #expect(launch.claudeCode == "2.1.311")
}

@Test func startWithoutAnInstallIsRefusedAndSaysWhatToDo() throws {
    var allowing = try supervisor(.allowWhileOpen, installs: [])
    guard case .finished(let result) = allowing.submit(start2, now: start) else {
        Issue.record("ran")
        return
    }
    #expect(result.isError && result.text.contains("[claude-code.none]") && result.text.contains("owner"))
}

@Test func startIsDeniedWhileTheOwnerHoldsTheBaton() throws {
    var allowing = try supervisor(.allowWhileOpen)
    _ = allowing.apply(.ownerTakesOver, now: start)
    guard case .finished(let result) = allowing.submit(start2, now: start) else {
        Issue.record("ran")
        return
    }
    #expect(result.isError)
}

@Test func plainTerminalTextNamingTheBinaryIsNoStart() throws {
    var allowing = try supervisor(.allowWhileOpen)
    let line = ClaudeCode.launchLine(version: "2.1.311", scope: allowing.scope!)!
    let typed = IPCRequest(id: "1", tool: "terminal_send", arguments: ["text": .string(line)])
    if case .execute(let execution) = allowing.submit(typed, now: start),
        case .launch(let launch) = allowing.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    {
        #expect(launch.claudeCode == nil)
    }
}

@Test func installsAndOwnerStartsAreAudited() throws {
    var allowing = try supervisor(.allowWhileOpen)
    _ = allowing.drainAuditLines()
    allowing.recordClaudeCodeInstall(version: "2.1.311", install: "/i", digest: "ab12", problem: nil, now: start)
    allowing.recordClaudeCodeInstall(version: "2.1.312", install: "/j", digest: nil, problem: "bad\u{1B}", now: start)
    allowing.recordOwnerClaudeCodeStart(version: "2.1.311", now: start)
    let lines = allowing.drainAuditLines()
    #expect(lines.count == 3)
    #expect(lines[0].contains("claude code 2.1.311 installed in /i: sha256 ab12"))
    #expect(lines[1].contains("failed: bad\\\\u{1B}"))
    #expect(lines[2].contains("owner started claude code 2.1.311"))
    #expect(allowing.feed.first?.tool == "claude_code_start")
}
