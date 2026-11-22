#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlSandbox

    private let tmux = SetupCheck.homebrewTmux
    /// Skipped without tmux, except in CI, which sets DC_REQUIRE_TMUX so a missing tmux fails.
    private let tmuxAvailable =
        FileManager.default.isExecutableFile(atPath: tmux)
        || ProcessInfo.processInfo.environment["DC_REQUIRE_TMUX"] == "1"

    /// A session folder under a temporary ceiling; short, because tmux sockets must fit in 104 bytes.
    private final class Folder {
        let base: String
        let scope: SessionScope

        init() throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            for folder in [
                "/D/Developer/p", "/D/Developer/other", "/D/Developer/.dual-control/agent-home",
                "/D/Developer/.dual-control/tmp",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            scope = try ResolvedScope.make(choosing: base + "/D/Developer/p", ceiling: base + "/D/Developer")
        }

        deinit {
            try? FileManager.default.removeItem(atPath: base)
        }
    }

    /// Polls the pane until it shows `text`.
    private func waitFor(_ text: String, in session: TerminalSession) async throws -> String {
        var last = ""
        for _ in 0..<50 {
            last = try session.read(lines: 40)
            if last.contains(text) { return last }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("pane never showed \(text): \(last)")
        return last
    }

    @Test(.enabled(if: tmuxAvailable))
    func theSharedTerminalRunsSandboxedInTheSessionFolder() async throws {
        let folder = try Folder()
        let session = TerminalSession(sandbox: Sandbox(scope: folder.scope, toolchains: []), tmux: tmux)
        try session.start()
        defer { session.stop() }

        try session.send("echo DC-TEST $((40+2)) $PWD\n")
        _ = try await waitFor("DC-TEST 42 \(folder.scope.root)", in: session)

        // Waits for text only the output contains: the typed line itself already shows "echo ... done".
        try session.send("echo DC-TEST > inside.txt; echo DC-TEST > ../other/evil.txt; echo DC-TEST $((6*7)) done\n")
        let screen = try await waitFor("DC-TEST 42 done", in: session)
        #expect(screen.contains("operation not permitted"))
        #expect(FileManager.default.fileExists(atPath: folder.scope.root + "/inside.txt"))
        #expect(!FileManager.default.fileExists(atPath: folder.scope.ceiling + "/other/evil.txt"))

        // Text that looks like an option or a key name is typed literally.
        try session.send("echo DC-TEST -n Enter C-c\n")
        _ = try await waitFor("DC-TEST -n Enter C-c", in: session)
    }

    @Test(.enabled(if: tmuxAvailable))
    func theTwoTabsAreSeparateShellsAndStopEndsBoth() async throws {
        let folder = try Folder()
        let session = TerminalSession(sandbox: Sandbox(scope: folder.scope, toolchains: []), tmux: tmux)
        try session.start()
        defer { session.stop() }
        #expect(session.isRunning(tab: .agent) && session.isRunning(tab: .second))

        try session.send("echo DC-SECOND $((20+1))\n", tab: .second)
        var second = ""
        for _ in 0..<50 {
            second = try session.read(lines: 40, tab: .second)
            if second.contains("DC-SECOND 21") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(second.contains("DC-SECOND 21"))
        #expect(!(try session.read(lines: 40, tab: .agent)).contains("DC-SECOND 21"))
        // The program in a tab's pane, as tmux names it.
        #expect(["sh", "bash", "zsh", "-sh", "-zsh"].contains(session.currentCommand(tab: .second) ?? ""))
        #expect(try session.attachArgv(tab: .second).suffix(2) == ["-t", "=second"])

        session.stop()
        #expect(!session.isRunning(tab: .agent) && !session.isRunning(tab: .second))
    }

    @Test(.enabled(if: tmuxAvailable))
    func stoppingEndsTheSession() async throws {
        let folder = try Folder()
        let session = TerminalSession(sandbox: Sandbox(scope: folder.scope, toolchains: []), tmux: tmux)
        try session.start()
        #expect(session.isRunning())
        session.stop()
        #expect(!session.isRunning())
        #expect(throws: TerminalSession.Error.self) { try session.read(lines: 5) }
        #expect(throws: TerminalSession.Error.self) { try session.send("echo DC-TEST\n") }
    }

    @Test func theViewAttachesThroughTheSandbox() throws {
        let folder = try Folder()
        let session = TerminalSession(sandbox: Sandbox(scope: folder.scope, toolchains: []), tmux: tmux)
        let argv = try session.attachArgv()
        #expect(argv.first == "/usr/bin/sandbox-exec")
        #expect(argv.suffix(6) == [tmux, "-L", "dualcontrol", "attach-session", "-t", "=claude"])
    }

    @Test func anUntrustedTmuxIsRefused() throws {
        let folder = try Folder()
        let fake = folder.base + "/tmux"
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: fake))
        chmod(fake, 0o777)
        let session = TerminalSession(sandbox: Sandbox(scope: folder.scope, toolchains: []), tmux: fake)
        #expect(throws: TerminalSession.Error.untrustedTmux) { try session.start() }
    }
#endif
