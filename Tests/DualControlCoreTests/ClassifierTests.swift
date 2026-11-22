import Testing

@testable import DualControlCore

private func command(_ argv: [String]) -> ActionRequest {
    ActionRequest(capability: .command, argv: argv, cwd: "/work/p", projectID: "p")
}

// Never runnable by Claude, in any mode. Includes wrapper, shell and interpreter evasions.
@Test(
    arguments: [
        // Plain, path-qualified and case-mangled program names.
        ["sudo", "ls"], ["/usr/bin/sudo", "-s"], ["SUDO", "x"], ["/usr/bin/../bin/Sudo"], ["sudoedit", "/etc/hosts"],
        ["su"], ["doas", "x"], ["security", "find-generic-password", "-s", "x"], ["login"],
        ["dscl", ".", "-list", "/Users"], ["launchctl", "list"], ["osascript", "-e", "x"],
        // Wrappers.
        ["env", "sudo", "ls"], ["env", "-i", "FOO=1", "sudo"], ["env", "-u", "X", "sudo"], ["env", "-S", "sudo ls"],
        ["xargs", "sudo"], ["xargs", "-n", "1", "sudo"], ["nohup", "sudo", "x"], ["time", "sudo"],
        ["time", "-p", "sudo"], ["nice", "-n", "10", "sudo"], ["nice", "-10", "sudo"], ["timeout", "5", "sudo"],
        ["timeout", "-s", "KILL", "5", "sudo"], ["timeout", "--signal=KILL", "5s", "sudo"],
        ["exec", "-a", "x", "sudo"], ["command", "sudo"], ["caffeinate", "-dims", "sudo"],
        ["caffeinate", "-t", "5", "sudo"], ["env", "nice", "timeout", "1", "nohup", "/usr/bin/sudo"],
        ["env", "--unknown-flag", "sudo"], ["timeout", "--frobnicate", "1", "sudo"],
        // Shell strings.
        ["sh", "-c", "sudo ls"], ["bash", "-c", "ls; sudo rm -rf /"], ["zsh", "-lc", "echo hi && sudo x"],
        ["dash", "-c", "ls|sudo tee f"], ["bash", "-c", "FOO=1 sudo x"], ["bash", "-c", "'sudo' x"],
        ["bash", "-c", "\"su\"do x"], ["bash", "-c", "s\\udo x"], ["bash", "-c", "echo $(sudo id)"],
        ["bash", "-c", "echo `sudo id`"], ["bash", "-c", "bash -c 'sudo id'"],
        ["sh", "-c", "if true; then sudo x; fi"],
        ["sh", "-c", "(sudo x)"], ["sh", "-c", "{ sudo x; }"], ["sh", "-c", "exec sudo x"],
        ["sh", "-c", "\"$0\" x", "sudo"], ["sh", "-c", "/usr/bin/su*"], ["sh", "-e", "-c", "sudo x"],
        ["bash", "-c", "ls\nlaunchctl list"], ["sh", "-c", "x=1;sudo y"], ["bash", "--norc", "-c", "sudo x"],
        ["fish", "-c", "sudo x"], ["sh", "-c", "ls 2>&1 | sudo tee x"],
        // eFuse writes.
        ["espefuse.py", "burn_efuse", "X"], ["espefuse", "--port", "/dev/x", "burn-key", "k"],
        ["espefuse.py", "summary", "burn_efuse", "X", "1"], ["esptool.py", "burn_efuse"], ["esptool", "write_efuse"],
        ["idf.py", "efuse-burn"], ["idf.py", "-p", "x", "efuse_burn_key"], ["ESPEFUSE.PY", "BURN_EFUSE"],
        ["python3", "-m", "espefuse", "burn_efuse"], ["python3", "/opt/esp/espefuse.py", "burn_key"],
        ["python", "-u", "-m", "esptool", "burn_efuse"], ["/usr/bin/python3.12", "-mespefuse", "burn_efuse"],
        ["sh", "-c", "idf.py efuse-burn-key"],
        // Interpreters and exec-ing tools.
        ["python3", "-c", "import os; os.system('espefuse.py burn_efuse X')"],
        ["python3", "-c", "import os;os.system('sudo id')"], ["perl", "-e", "system('sudo id')"],
        ["find", ".", "-exec", "sudo", "rm", "{}", ";"],
        // NUL truncates the C string exec sees.
        ["sudo\u{0}x"], ["ls", "a\u{0}b"],
    ]
)
func blocked(_ argv: [String]) {
    #expect(Classifier.classify(command(argv)).tier == .blocked)
}

@Test(
    arguments: [
        ["ls"], ["ls", "-la", "/tmp"], ["/bin/ls"], ["/usr/bin/head", "-n", "5", "f"], ["cat", "f"],
        ["tail", "-f", "log"], ["wc", "-l"], ["pwd"], ["which", "git"], ["git", "status"],
        ["git", "log", "--oneline"], ["git", "diff", "HEAD~1"], ["git", "show", "abc"], ["env", "ls"],
        ["nice", "cat", "f"], ["sh", "-c", "ls -la && git status"], ["bash", "-c", "cat f | head -n 5"],
        ["sh", "-c", "ls 2>&1"], ["sh", "-c", "cat < f"], ["sh", "-c", "# comment\nls"], ["LS"],
    ]
)
func readOnly(_ argv: [String]) {
    #expect(Classifier.classify(command(argv)).tier == .readOnly)
}

// Not confidently read-only, but not blocked either: no over-blocking of ordinary work.
@Test(
    arguments: [
        ["./ls"], ["/tmp/ls"], ["/usr/bin/../../tmp/ls"], ["make"], ["rm", "-rf", "x"], ["git", "commit"],
        ["git", "-c", "core.pager=x", "log"], ["git", "diff", "--output=x"], ["git", "diff", "--outp=x"],
        ["git", "log", "--ext-diff"], ["git", "push"], ["sh", "-c", "cat a > b"], ["sh", "-c", "ls >> f"],
        ["sh", "-c", "> f"], ["sh", "-c", "echo $(ls)"], ["sh", "-c", "$CMD"], ["sh", "-c", "cat $F"],
        ["sh", "-c", "eval ls"], ["bash", "script.sh"], ["bash"], ["sh", "-c", "PATH=/tmp ls"],
        ["sh", "-c", "PATH=/tmp; ls"], ["env", "PATH=/tmp", "ls"], ["xargs", "ls"], ["python3", "x.py"],
        ["sh", "-c", "'unterminated"], [], [""], ["FOO=1"], ["env"], ["timeout", "5"],
        ["sh", "-c", "cat <<EOF\nx\nEOF"], ["sh", "-c", "$'\\x73udo' id"], ["grep", "sudo", "f"],
        ["git", "commit", "-m", "drop sudo"], ["bash", "-c", "grep sudo f"], ["espefuse.py", "summary"],
        ["idf.py", "flash"], ["esptool.py", "write_flash", "0x0", "fw.bin"],
        Array(repeating: "env", count: 20) + ["ls"],
    ]
)
func changing(_ argv: [String]) {
    #expect(Classifier.classify(command(argv)).tier == .changing)
}

@Test func deepWrapperNestingStillBlocks() {
    #expect(Classifier.classify(command(Array(repeating: "env", count: 20) + ["sudo"])).tier == .blocked)
    let nested = (0..<6).reduce("sudo x") { inner, _ in "sh -c '\(inner.replacingQuotes)'" }
    #expect(Classifier.classify(command(["sh", "-c", nested])).tier == .blocked)
}

@Test(
    arguments: [
        (Capability.serial, ["list"], RiskTier.readOnly),
        (.serial, ["write", "s", "68656c6c6f"], .changing),
        // D7b: reaching a LAN device is a grant the owner always decides (stricter than changing).
        (.network, ["net_allow", "tcp", "192.168.1.50:80", "why"], .privileged),
        (.broker, ["wifi-password"], .privileged),
        // The shell runs terminal text under CHANGING, so it is never read-only.
        (.terminal, ["ls -la\n"], .changing),
        (.terminal, ["git status\n"], .changing),
        (.terminal, [""], .changing),
        (.terminal, ["sudo ls\n"], .blocked),
        (.terminal, ["su", "do x\n"], .blocked),
        (.terminal, ["make\n"], .changing),
        (.terminalRead, ["100"], .readOnly),
    ]
)
func capabilities(_ capability: Capability, _ argv: [String], _ tier: RiskTier) {
    let request = ActionRequest(capability: capability, argv: argv, cwd: "/work/p", projectID: "p")
    #expect(Classifier.classify(request).tier == tier)
}

@Test func blockedDecisionsNameTheRule() {
    let result = Classifier.classify(command(["env", "sudo", "ls"]))
    #expect(result.ruleID == "blocked.sudo")
    #expect(Classifier.classify(command(["idf.py", "efuse-burn"])).ruleID == "blocked.efuse")
}

extension String {
    /// Escapes single quotes for nesting inside a single-quoted shell string.
    fileprivate var replacingQuotes: String {
        var result = ""
        for character in self {
            result += character == "'" ? "'\\''" : String(character)
        }
        return result
    }
}

// MARK: - Persistence

/// Programs that schedule work to run later, outside the session and after Stop.
@Test(
    arguments: [
        ["crontab", "-l"], ["crontab", "jobs.txt"], ["/usr/bin/crontab", "-r"], ["at", "now", "+1", "minute"],
        ["/usr/bin/at", "-f", "x.sh", "now"], ["batch"], ["atq"], ["atrm", "3"], ["launchctl", "bootstrap", "gui/1"],
        ["env", "crontab", "x"], ["nohup", "at", "now"], ["sh", "-c", "echo 'make' | at now"],
        ["bash", "-c", "crontab -l | crontab -"], ["python3", "-c", "import os; os.system('crontab x')"],
        ["sfltool", "add-item", "x"],
        ["defaults", "write", "com.apple.loginwindow", "AutoLaunchedApplicationDictionary", "-array-add", "x"],
        ["defaults", "write", "loginwindow", "LoginHook", "/x"],
        ["defaults", "-currentHost", "write", "com.apple.loginitems", "k", "v"],
        ["/usr/bin/defaults", "import", "com.apple.backgroundtaskmanagementagent", "f.plist"],
        ["defaults", "write", "-g", "x", "1", "com.apple.loginwindow"], ["sh", "-c", "defaults write loginwindow x y"],
    ]
)
func persistenceProgramsAreBlocked(_ argv: [String]) {
    #expect(Classifier.classify(command(argv)).tier == .blocked, "\(argv)")
}

@Test func loginItemWritesNameTheirRule() {
    let result = Classifier.classify(command(["defaults", "write", "com.apple.loginwindow", "LoginHook", "/x"]))
    #expect(result.ruleID == "blocked.login-items")
    #expect(Classifier.classify(command(["crontab", "-l"])).ruleID == "blocked.crontab")
}

/// Ordinary preferences and everyday words stay usable.
@Test(
    arguments: [
        ["defaults", "write", "com.example.app", "Key", "1"], ["defaults", "read", "com.apple.loginwindow"],
        ["python3", "-c", "print('look at this batch')"], ["node", "-e", "console.log('at')"],
        ["echo", "at", "batch"], ["sh", "-c", "echo look at this"],
    ]
)
func everydayUsesAreNotBlocked(_ argv: [String]) {
    #expect(Classifier.classify(command(argv)).tier != .blocked, "\(argv)")
}
