#if canImport(Darwin)
    import DualControlCore
    import Foundation

    /// The agent's shared tmux sessions, one per tab (`TerminalTab`). Every tmux process (server and clients) runs as
    /// the agent inside the CHANGING sandbox, so everything typed into a pane inherits it.
    public struct TerminalSession: Sendable {
        /// Why the terminal cannot be used.
        public enum Error: Swift.Error, Equatable {
            /// tmux is missing or could be changed by someone other than root or the owner.
            case untrustedTmux
            /// The session is not running, or tmux failed.
            case tmux(String)
        }

        /// The sandbox the session runs in.
        public let sandbox: Sandbox
        let tmux: String

        /// A session for `sandbox`, using Homebrew's tmux.
        public init(sandbox: Sandbox) {
            self.init(sandbox: sandbox, tmux: SetupCheck.homebrewTmux)
        }

        init(sandbox: Sandbox, tmux: String) {
            self.sandbox = sandbox
            self.tmux = tmux
        }

        /// Starts every tab's session in the session folder. Sessions left over from before are ended first.
        public func start() throws {
            guard SetupCheck.isTrustedExecutable(tmux) else { throw Error.untrustedTmux }
            stop()
            for tab in TerminalTab.allCases {
                try run(SharedTerminal.newSession(tmux: tmux, root: sandbox.scope.root, tab: tab))
            }
        }

        /// Types `text` into a tab's pane.
        public func send(_ text: String, tab: TerminalTab = .agent) throws {
            try run(SharedTerminal.sendKeys(tmux: tmux, text: text, tab: tab))
        }

        /// A tab's last `lines` lines.
        public func read(lines: Int, tab: TerminalTab = .agent) throws -> String {
            SharedTerminal.lastLines(try run(SharedTerminal.capture(tmux: tmux, lines: lines, tab: tab)), lines)
        }

        /// The program running in a tab's pane, as tmux names it; `nil` if tmux cannot say.
        public func currentCommand(tab: TerminalTab) -> String? {
            (try? run(SharedTerminal.currentCommand(tmux: tmux, tab: tab)))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// True if a tab's session exists.
        public func isRunning(tab: TerminalTab = .agent) -> Bool {
            (try? run([tmux, "-L", SharedTerminal.socketName, "has-session", "-t", "=" + tab.sessionName])) != nil
        }

        /// Ends the session. Never fails: there may be nothing to end.
        public func stop() {
            _ = try? sandbox.run(SharedTerminal.killServer(tmux: tmux), kind: .changing, cwd: sandbox.scope.root)
        }

        /// The full argument vector for a tab's view in the window: a tmux client, sandboxed, as the agent.
        public func attachArgv(tab: TerminalTab = .agent) throws -> [String] {
            try sandbox.argv(SharedTerminal.attach(tmux: tmux, tab: tab), kind: .changing)
        }

        @discardableResult
        private func run(_ argv: [String]) throws -> String {
            let result = try sandbox.run(argv, kind: .changing, cwd: sandbox.scope.root)
            guard result.status == 0 else {
                throw Error.tmux(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return result.output
        }
    }
#endif
