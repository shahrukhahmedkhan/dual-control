import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func install(_ arguments: [String: JSONValue]) -> IPCRequest {
    IPCRequest(id: "1", tool: "esp_idf_install", arguments: arguments)
}

private func install(_ version: String, _ targets: [String]) -> IPCRequest {
    install(["version": .string(version), "targets": .array(targets.map(JSONValue.string))])
}

@Test func anInstallIsAFixedScriptWithTheVersionAndTargetsAsArguments() {
    let request = ActionRequest(
        capability: .command,
        argv: ["/bin/sh", "-c", ESPIDFInstall.script, "esp_idf_install", "v5.4", "esp32s3,esp32"],
        cwd: "",
        projectID: "",
        timeoutSeconds: ESPIDFInstall.timeoutSeconds
    )
    // Always a job: an install takes many minutes.
    #expect(ToolRouter.route(install("v5.4", ["esp32s3", "esp32"])) == .job(tool: "esp_idf_install", request))
    #expect(ESPIDFInstall.script.contains("https://github.com/espressif/esp-idf.git"))
    #expect(!ESPIDFInstall.script.contains("v5.4"))
}

@Test(arguments: ["5.4", "v5", "v5.4;rm -rf ~", "v5.4 ", "master", "-v5.4", "v5.4.1.2", "v5.4-rc1", ""])
func onlyReleaseVersionsCanBeInstalled(_ version: String) {
    guard case .invalid = ToolRouter.route(install(version, ["esp32"])) else {
        Issue.record("\(version) was routed")
        return
    }
}

@Test(arguments: [[], ["esp8266"], ["esp32", "ESP32S3"], ["esp32,esp32s3"], ["all", "esp32"]])
func onlyKnownTargetsCanBeInstalled(_ targets: [String]) {
    guard case .invalid = ToolRouter.route(install("v5.4", targets)) else {
        Issue.record("\(targets) was routed")
        return
    }
}

@Test func otherArgumentsAreInvalid() {
    guard
        case .invalid = ToolRouter.route(
            install(["version": .string("v5.4"), "targets": .array([.string("esp32")]), "path": .string("/x")])
        )
    else {
        Issue.record("routed")
        return
    }
}

private func supervisor(_ mode: ApprovalMode) throws -> Supervisor {
    var supervisor = Supervisor(
        scope: try SessionScope(ceiling: "/work", root: "/work/p"),
        sandboxProblem: nil,
        resolvePath: { $0.contains("//") ? nil : $0 }
    )
    supervisor.setMode(mode, now: start)
    return supervisor
}

@Test func anInstallRunsInTheSessionFolderAndFollowsTheApprovalMode() throws {
    var asking = try supervisor(.askEach)
    guard case .jobWaiting = asking.submit(install("v5.4", ["esp32s3"]), now: start) else {
        Issue.record("an install did not wait for approval")
        return
    }
    var allowing = try supervisor(.allowWhileOpen)
    guard case .jobStarted(let execution, _) = allowing.submit(install("v5.4", ["esp32s3"]), now: start) else {
        Issue.record("an install did not start")
        return
    }
    #expect(execution.request.cwd == "/work/p")
    guard
        case .launch(let launch) = allowing.begin(
            execution,
            callerConnected: true,
            now: start,
            persist: { _, _ in true }
        )
    else {
        Issue.record("an install did not launch")
        return
    }
    #expect(launch.request.argv.last == "esp32s3")
    #expect(allowing.feed.first?.tool == "esp_idf_install")
    // Only this tool's launch builds a toolchain (INSTALLING, then the app's copy).
    #expect(launch.toolchain == "v5.4" && launch.git == nil && launch.serialPort == nil)

    allowing.recordToolchain(
        launch,
        install: "/work/.dual-control/toolchains/esp-idf-v5.4",
        digest: "ab12",
        problem: nil,
        now: start
    )
    #expect(allowing.feed.first?.summary == "toolchain /work/.dual-control/toolchains/esp-idf-v5.4: checked")
    let line = try #require(allowing.drainAuditLines().last)
    #expect(line.contains(#""event":"toolchain""#) && line.contains("esp-idf-v5.4: sha256 ab12"))
    allowing.recordToolchain(launch, install: "/x", digest: nil, problem: "leads out\u{1B}[2J", now: start)
    #expect(allowing.feed.first?.outcome == .failed)
    #expect(try #require(allowing.drainAuditLines().last).contains("failed: leads out\\\\u{1B}[2J"))
}

@Test func theVersionIsReadBackOnlyFromTheFixedCommandLine() {
    #expect(ESPIDFInstall.version(of: ESPIDFInstall.argv(version: "v5.4.1", targets: ["esp32"])) == "v5.4.1")
    #expect(ESPIDFInstall.version(of: ["/bin/sh", "-c", "echo", "esp_idf_install", "v5.4", "esp32"]) == nil)
    #expect(ESPIDFInstall.version(of: ["/bin/sh", "-c", ESPIDFInstall.script, "esp_idf_install", "../x", "e"]) == nil)
}

/// ESP-IDF v5.4's build is not ready for cmake 4, which pip picks by default.
@Test func theInstallPinsCmakeBelowFour() {
    #expect(ESPIDFInstall.script.contains(#"python -m pip install "cmake>=3.24,<4" ninja"#))
    #expect(!ESPIDFInstall.script.contains("pip install cmake "))
}

@Test func theInstallSeesNoneOfTheAgentsConfiguration() throws {
    let scope = try SessionScope(ceiling: "/work", root: "/work/p")
    let environment = ESPIDFInstall.environment(scope: scope, git: "/Library/Developer/CommandLineTools/usr/bin/git")
    let staging = "/work/.dual-control/toolchain-staging"
    #expect(environment["HOME"] == staging + "/home" && environment["TMPDIR"] == staging + "/tmp/")
    #expect(environment["IDF_TOOLS_PATH"] == staging + "/tools" && environment["DC_TOOLCHAIN_STAGING"] == staging)
    #expect(environment["PYTHONNOUSERSITE"] == "1" && environment["PIP_CONFIG_FILE"] == "/dev/null")
    #expect(environment["GIT_CONFIG_GLOBAL"] == "/dev/null" && environment["GIT_CONFIG_NOSYSTEM"] == "1")
    #expect(!environment.values.contains { $0.contains("agent-home") })
}

@Test func theSameScriptThroughRunCommandIsCheckedLikeAnyOther() throws {
    // The script names paths outside the session (Homebrew's Python); only the app's own tool may.
    var allowing = try supervisor(.allowWhileOpen)
    let argv = ESPIDFInstall.argv(version: "v5.4", targets: ["esp32"])
    let request = IPCRequest(
        id: "1",
        tool: "run_command",
        arguments: ["argv": .array(argv.map(JSONValue.string)), "cwd": .string("/work/p")]
    )
    guard case .finished(let result) = allowing.submit(request, now: start) else {
        Issue.record("ran")
        return
    }
    #expect(result.text.contains("[scope.argument]"))
}
