#if os(macOS)
    import AppKit
    import SwiftTerm

    /// What the owner's view of the agent's terminal does with escape sequences in agent output. The agent owns the
    /// tmux server, so it controls every byte the view gets, including tmux's `set-clipboard` and passthrough.
    public enum ViewOnlyTerminal {
        /// Every OSC code SwiftTerm 1.10.1 acts on (`EscapeSequenceParser.dispatchOsc`); re-read it when SwiftTerm is
        /// updated. The view shows text, and nothing else: 52 would write the owner's clipboard (one paste from
        /// running as them), 8 makes links that open on a click, 4/10/11/12/104/112 recolour text (it could be made
        /// invisible), 777 posts notifications, 1337 is iTerm2's file and image transfer, 0-2/6/7/9 set titles,
        /// documents, folders and progress. Codes SwiftTerm doesn't know already do nothing.
        public static let neutralisedOSC = [0, 1, 2, 4, 6, 7, 8, 9, 10, 11, 12, 52, 104, 112, 777, 1337]

        /// Makes `terminal` ignore every OSC code in `neutralisedOSC`. Registered handlers come first in SwiftTerm's
        /// dispatch, whichever way the sequence arrived (7-bit, 8-bit C1, split across reads), and the parser is never
        /// replaced, so they stay after a reset.
        public static func harden(_ terminal: Terminal) {
            for code in neutralisedOSC {
                terminal.registerOscHandler(code: code) { _ in }
            }
        }
    }

    /// The owner's view of the agent's tmux client: shows its output with `ViewOnlyTerminal.harden` applied and drops
    /// every keystroke, so the owner types only in their own pane. A tab the owner chose to type in (D12c) passes
    /// keystrokes on (`acceptsInput`); the hardening stays.
    public final class ViewOnlyTerminalView: LocalProcessTerminalView {
        /// True while the owner types into the agent's pane; keystrokes are dropped otherwise.
        public var acceptsInput = false
        /// Called on the main thread whenever output arrives, for the hidden tab's activity dot.
        public var onOutput: (@MainActor () -> Void)?

        /// A hardened view; start the tmux client with `startProcess`.
        public override init(frame: CGRect) {
            super.init(frame: frame)
            ViewOnlyTerminal.harden(terminal)
        }

        /// A hardened view, from an archive.
        public required init?(coder: NSCoder) {
            super.init(coder: coder)
            ViewOnlyTerminal.harden(terminal)
        }

        public override func send(source: TerminalView, data: ArraySlice<UInt8>) {
            if acceptsInput { super.send(source: source, data: data) }
        }

        public override func dataReceived(slice: ArraySlice<UInt8>) {
            super.dataReceived(slice: slice)
            if let onOutput { MainActor.assumeIsolated { onOutput() } }
        }
    }
#endif
