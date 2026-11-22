import Foundation
import Testing

@testable import DualControlCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let tmux = "/opt/homebrew/bin/tmux"

private func send(_ text: String, tab: String? = nil) -> IPCRequest {
    var arguments: [String: JSONValue] = ["text": .string(text)]
    if let tab { arguments["tab"] = .string(tab) }
    return IPCRequest(id: "1", tool: "terminal_send", arguments: arguments)
}

private func supervisor() throws -> Supervisor {
    var supervisor = Supervisor(
        scope: try SessionScope(ceiling: "/work", root: "/work/p"),
        sandboxProblem: nil,
        resolvePath: { $0 }
    )
    supervisor.setMode(.allowWhileOpen, now: start)
    supervisor.setClaudeCodeVersions(["2.1.311"])
    return supervisor
}

// MARK: - tmux

@Test func theSecondTabIsItsOwnSessionOnTheSameServer() {
    #expect(
        SharedTerminal.newSession(tmux: tmux, root: "/w/p", tab: .second)
            == [
                tmux, "-L", "dualcontrol", "-f", "/dev/null", "new-session", "-d", "-s", "second", "-c", "/w/p", "-x",
                "160", "-y", "48",
            ]
    )
    #expect(
        SharedTerminal.attach(tmux: tmux, tab: .second) == [
            tmux, "-L", "dualcontrol", "attach-session", "-t", "=second",
        ]
    )
    #expect(
        SharedTerminal.sendKeys(tmux: tmux, text: "x", tab: .second)
            == [tmux, "-L", "dualcontrol", "send-keys", "-t", "=second:", "-l", "--", "x"]
    )
    #expect(
        SharedTerminal.capture(tmux: tmux, lines: 5, tab: .second)
            == [tmux, "-L", "dualcontrol", "capture-pane", "-p", "-J", "-t", "=second:", "-S", "-5"]
    )
    #expect(
        SharedTerminal.currentCommand(tmux: tmux, tab: .second)
            == [tmux, "-L", "dualcontrol", "display-message", "-p", "-t", "=second:", "#{pane_current_command}"]
    )
    // The agent tab keeps the session it always had.
    #expect(TerminalTab.agent.sessionName == SharedTerminal.sessionName)
}

@Test func onlyThePinnedBinaryNamesTheTabClaudeCode() {
    #expect(TerminalTab.second.label(currentCommand: "claude") == "Claude Code")
    #expect(TerminalTab.second.label(currentCommand: "zsh") == "Second")
    #expect(TerminalTab.second.label(currentCommand: nil) == "Second")
    #expect(TerminalTab.agent.label(currentCommand: "claude") == "Agent")
}

// MARK: - Routing

@Test func terminalToolsTakeAnOptionalTab() {
    guard case .action(_, let agent) = ToolRouter.route(send("ls\n")),
        case .action(_, let second) = ToolRouter.route(send("ls\n", tab: "second")),
        case .action(_, let read) = ToolRouter.route(
            IPCRequest(id: "1", tool: "terminal_read", arguments: ["lines": .int(5), "tab": .string("second")])
        )
    else {
        Issue.record("not routed")
        return
    }
    #expect(agent.tab == nil && second.tab == .second && read.tab == .second)
    #expect(second.argv == ["ls\n"])
    guard case .invalid = ToolRouter.route(send("ls\n", tab: "third")) else {
        Issue.record("a third tab")
        return
    }
}

@Test func claudeCodeStartsInTheSecondTab() throws {
    var s = try supervisor()
    guard
        case .execute(let execution) = s.submit(
            IPCRequest(id: "1", tool: "claude_code_start", arguments: [:]),
            now: start
        )
    else {
        Issue.record("did not run")
        return
    }
    #expect(execution.request.tab == .second)
}

// MARK: - The owner typing in a tab

@Test func whileTheOwnerTypesInTheSecondTabClaudeCannotTypeThereButCanElsewhere() throws {
    var s = try supervisor()
    s.setOwnerTyping(in: .second, true, now: start)
    #expect(s.ownerTypingTabs == [.second])
    guard case .finished(let refused) = s.submit(send("x", tab: "second"), now: start) else {
        Issue.record("typed into the owner's tab")
        return
    }
    #expect(refused.isError && refused.text.contains("baton.tab"))
    guard case .finished = s.submit(IPCRequest(id: "2", tool: "claude_code_start", arguments: [:]), now: start) else {
        Issue.record("started Claude Code in the owner's tab")
        return
    }
    guard case .execute = s.submit(send("ls\n"), now: start) else {
        Issue.record("the agent tab was locked too")
        return
    }
    guard
        case .execute = s.submit(
            IPCRequest(id: "3", tool: "terminal_read", arguments: ["tab": .string("second")]),
            now: start
        )
    else {
        Issue.record("reading was locked")
        return
    }
    s.setOwnerTyping(in: .second, false, now: start)
    guard case .execute = s.submit(send("x", tab: "second"), now: start) else {
        Issue.record("still locked after handing back")
        return
    }
    let lines = s.drainAuditLines()
    #expect(lines.contains { $0.contains("owner types in the second tab") })
    #expect(lines.contains { $0.contains("owner handed the second tab back") })
    #expect(lines.contains { $0.contains(#""tab":"second""#) })
}

@Test func aTabTheOwnerTakesWhileTypingWasWaitingIsRefusedAtTheStart() throws {
    var s = try supervisor()
    guard case .execute(let execution) = s.submit(send("x", tab: "second"), now: start) else {
        Issue.record("did not run")
        return
    }
    s.setOwnerTyping(in: .second, true, now: start)
    guard case .refused = s.begin(execution, callerConnected: true, now: start, persist: { _, _ in true }) else {
        Issue.record("typed after the owner took the tab")
        return
    }
}

@Test func stopAndANewSessionFolderEndTheOwnersTyping() throws {
    var s = try supervisor()
    s.setOwnerTyping(in: .second, true, now: start)
    _ = s.stop(now: start)
    #expect(s.ownerTypingTabs.isEmpty)
    s.resetAfterStop(now: start)
    s.setOwnerTyping(in: .second, true, now: start)
    _ = s.setScope(try SessionScope(ceiling: "/work", root: "/work/q"), now: start)
    #expect(s.ownerTypingTabs.isEmpty)
}

@Test func theAuditRecordsTheTab() throws {
    var s = try supervisor()
    _ = s.submit(send("echo DC-TEST\n", tab: "second"), now: start)
    #expect(s.drainAuditLines().contains { $0.contains(#""tab":"second""#) })
    // The request's own encoding carries the tab both ways, wherever it is written.
    guard case .action(_, let request) = ToolRouter.route(send("ls\n", tab: "second")) else {
        Issue.record("not routed")
        return
    }
    let encoded = try JSONEncoder().encode(request)
    #expect(String(decoding: encoded, as: UTF8.self).contains(#""tab":"second""#))
    #expect(try JSONDecoder().decode(ActionRequest.self, from: encoded).tab == .second)
}
