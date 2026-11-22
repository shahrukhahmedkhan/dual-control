import Foundation

/// A tab of the shared terminal (D12c): its own tmux session on the agent's server, in the session folder.
public enum TerminalTab: String, Sendable, Codable, CaseIterable {
    /// The agent's shell, where `terminal_send` types unless told otherwise.
    case agent
    /// A second shell, where `claude_code_start` starts Claude Code.
    case second

    /// The tmux session.
    public var sessionName: String {
        switch self {
        case .agent: return SharedTerminal.sessionName
        case .second: return "second"
        }
    }

    /// The tab's name in the window: the second tab is "Claude Code" while the pinned binary (`claude`) runs in it.
    /// `currentCommand` is tmux's `pane_current_command`; agent output cannot set it, only the program that runs.
    public func label(currentCommand: String?) -> String {
        switch self {
        case .agent: return "Agent"
        case .second: return currentCommand == "claude" ? "Claude Code" : "Second"
        }
    }
}

/// The shared terminal: tmux sessions run by the agent inside the CHANGING sandbox, in the session folder, one per
/// tab. These are the tmux command lines; the app runs each one as the agent, sandboxed.
public enum SharedTerminal {
    /// tmux server name (`-L`), so the agent's other tmux servers are never touched.
    public static let socketName = "dualcontrol"
    /// The session's name.
    public static let sessionName = "claude"
    /// Typed into the owner's own pane on Hand back: cancel the line, forget cached sudo credentials, close it.
    public static let handBackText = "\u{3}sudo -k; exit\n"

    /// Starts a tab's session detached, ignoring any tmux configuration.
    public static func newSession(tmux: String, root: String, tab: TerminalTab = .agent) -> [String] {
        [
            tmux, "-L", socketName, "-f", "/dev/null", "new-session", "-d", "-s", tab.sessionName, "-c", root, "-x",
            "160", "-y", "48",
        ]
    }

    /// Attaches a client to a tab, for the window's view.
    public static func attach(tmux: String, tab: TerminalTab = .agent) -> [String] {
        [tmux, "-L", socketName, "attach-session", "-t", "=" + tab.sessionName]
    }

    /// Types `text` literally (no key names) into a tab, even if it starts with `-`.
    public static func sendKeys(tmux: String, text: String, tab: TerminalTab = .agent) -> [String] {
        [tmux, "-L", socketName, "send-keys", "-t", "=\(tab.sessionName):", "-l", "--", text]
    }

    /// Prints a tab's pane with `lines` lines of history, wrapped lines joined.
    public static func capture(tmux: String, lines: Int, tab: TerminalTab = .agent) -> [String] {
        [tmux, "-L", socketName, "capture-pane", "-p", "-J", "-t", "=\(tab.sessionName):", "-S", "-\(lines)"]
    }

    /// Prints the name of the program running in a tab's pane.
    public static func currentCommand(tmux: String, tab: TerminalTab) -> [String] {
        [tmux, "-L", socketName, "display-message", "-p", "-t", "=\(tab.sessionName):", "#{pane_current_command}"]
    }

    /// Ends the session and its server.
    public static func killServer(tmux: String) -> [String] {
        [tmux, "-L", socketName, "kill-server"]
    }

    /// The line the owner can run in their own pane to enter the session folder. Their pane starts in their home, not
    /// there, so no shell hook acts on agent-written files until they choose to go in.
    public static func enterSessionFolder(_ root: String) -> String {
        "cd '" + root.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Files that common shell hooks run, load or act on when a shell enters their folder: direnv, mise, asdf, nvm,
    /// pyenv, rbenv, autoenv, dotenv plugins and virtualenv auto-activation. Lowercase: the usual macOS volume
    /// ignores case, so `.ENVRC` is `.envrc` to direnv.
    public static let shellHookFileNames: Set<String> = [
        ".envrc", ".env", ".env.leave", ".autoenv.zsh", ".autoenv_leave.zsh", ".tool-versions", ".mise.toml",
        "mise.toml", ".mise.local.toml", "mise.local.toml", ".rtx.toml", ".nvmrc", ".node-version", ".python-version",
        ".ruby-version", ".venv",
    ]

    /// Whether a shell hook acts on a file with this name.
    public static func isShellHookFile(_ name: String) -> Bool {
        shellHookFileNames.contains(name.lowercased())
    }

    /// The last `count` lines of `captured`, without the blank lines below the cursor; each line ends in `\n`.
    public static func lastLines(_ captured: String, _ count: Int) -> String {
        var lines = captured.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(count).map { $0 + "\n" }.joined()
    }
}
