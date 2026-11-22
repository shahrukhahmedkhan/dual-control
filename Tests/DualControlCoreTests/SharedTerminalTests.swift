import Testing

@testable import DualControlCore

private let tmux = "/opt/homebrew/bin/tmux"

@Test func theSessionStartsDetachedInTheSessionFolderWithNoConfig() {
    #expect(
        SharedTerminal.newSession(tmux: tmux, root: "/Users/o/Developer/p")
            == [
                tmux, "-L", "dualcontrol", "-f", "/dev/null", "new-session", "-d", "-s", "claude", "-c",
                "/Users/o/Developer/p", "-x", "160", "-y", "48",
            ]
    )
}

@Test func clientsTargetTheSessionExactly() {
    #expect(SharedTerminal.attach(tmux: tmux) == [tmux, "-L", "dualcontrol", "attach-session", "-t", "=claude"])
    #expect(SharedTerminal.killServer(tmux: tmux) == [tmux, "-L", "dualcontrol", "kill-server"])
}

@Test(arguments: ["ls\n", "-n", "--", "a;b", "\u{3}", ""])
func textIsTypedLiterally(_ text: String) {
    #expect(
        SharedTerminal.sendKeys(tmux: tmux, text: text)
            == [tmux, "-L", "dualcontrol", "send-keys", "-t", "=claude:", "-l", "--", text]
    )
}

@Test func readingCapturesTheLastLinesJoined() {
    #expect(
        SharedTerminal.capture(tmux: tmux, lines: 50)
            == [tmux, "-L", "dualcontrol", "capture-pane", "-p", "-J", "-t", "=claude:", "-S", "-50"]
    )
}

@Test func handingBackForgetsTheOwnersSudoAndClosesTheirPane() {
    #expect(SharedTerminal.handBackText == "\u{3}sudo -k; exit\n")
}

@Test(
    arguments: [
        ("a\nb\nc\n", 2, "b\nc\n"),
        ("a\nb\nc\n\n\n", 2, "b\nc\n"),
        ("a\nb", 5, "a\nb\n"),
        ("\n\n", 3, ""),
        ("", 3, ""),
    ]
)
func onlyTheLastLinesAreReturned(_ captured: String, _ lines: Int, _ expected: String) {
    #expect(SharedTerminal.lastLines(captured, lines) == expected)
}

@Test func theOwnerIsGivenAQuotedLineToEnterTheSessionFolder() {
    #expect(SharedTerminal.enterSessionFolder("/Users/o/Developer/p") == "cd '/Users/o/Developer/p'")
    #expect(SharedTerminal.enterSessionFolder("/Users/o/My Folder") == "cd '/Users/o/My Folder'")
    #expect(SharedTerminal.enterSessionFolder("/Users/o/it's $(x)") == #"cd '/Users/o/it'\''s $(x)'"#)
}

@Test(
    arguments: [
        ".envrc", ".env", ".tool-versions", ".mise.toml", "mise.toml", ".mise.local.toml", "mise.local.toml",
        ".rtx.toml", ".nvmrc", ".node-version", ".python-version", ".ruby-version", ".autoenv.zsh", ".env.leave",
        ".venv", ".ENVRC",
    ]
)
func filesThatShellHooksActOnAreRecognised(_ name: String) {
    #expect(SharedTerminal.isShellHookFile(name))
}

@Test(arguments: ["README.md", "envrc", "x.envrc", ".envrc.bak", "Makefile", ".gitignore", ""])
func otherFilesAreNotShellHookFiles(_ name: String) {
    #expect(!SharedTerminal.isShellHookFile(name))
}
