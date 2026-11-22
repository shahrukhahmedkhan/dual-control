/// How much an action could change, from harmless to never allowed.
public enum RiskTier: Int, Sendable, Codable, Comparable {
    /// Only reads; always allowed.
    case readOnly
    /// May change files or devices; follows the approval mode.
    case changing
    /// Needs owner authority; always asks.
    case privileged
    /// Never allowed, in any mode.
    case blocked

    /// Orders tiers from least to most risky.
    public static func < (lhs: RiskTier, rhs: RiskTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A tier plus the rule that produced it.
public struct Classification: Sendable, Equatable {
    /// The risk tier.
    public var tier: RiskTier
    /// Stable rule identifier, e.g. `blocked.sudo`.
    public var ruleID: String
    /// Human-readable explanation.
    public var reason: String

    /// Creates a classification.
    public init(tier: RiskTier, ruleID: String, reason: String) {
        self.tier = tier
        self.ruleID = ruleID
        self.reason = reason
    }

    func atLeast(_ minimum: RiskTier, _ ruleID: String, _ reason: String) -> Classification {
        tier >= minimum ? self : Classification(tier: minimum, ruleID: ruleID, reason: reason)
    }

    /// The riskier of the two; on a tie, the first.
    static func max(_ a: Classification?, _ b: Classification) -> Classification {
        guard let a, a.tier >= b.tier else { return b }
        return a
    }
}

/// Assigns a risk tier to a request.
///
/// These string rules are the second wall. The first wall is the operating system: Claude's commands run as the
/// unprivileged `claude-agent` user (ISO-001), which cannot read the owner's home, keychain or SSH keys and has no
/// sudo rights, whatever a command line manages to hide from this classifier. The rules aim to catch the obvious
/// and the commonly obfuscated; anything they cannot parse confidently is at least `changing`, never `readOnly`.
/// Known gaps the first wall covers: expansions whose values are unknown here (`$X`, `$'\x73udo'`), symlinks and
/// `PATH` contents, and code that read-only tools run from configuration the agent user can write (shell rc
/// files, git pagers and diff drivers).
public enum Classifier {
    /// Classifies a request.
    public static func classify(_ request: ActionRequest) -> Classification {
        switch request.capability {
        case .command:
            return classify(argv: request.argv, depth: 0)
        case .terminal:
            // The pane's shell runs typed text under CHANGING, not READ-ONLY, and the agent can write its rc
            // files, so terminal text is never read-only: it always follows the approval mode.
            let script = classify(script: request.argv.joined(), extraArgs: [], depth: 0)
            guard script.tier == .readOnly else { return script }
            return Classification(
                tier: .changing,
                ruleID: "changing.terminal",
                reason: "types into the shared terminal"
            )
        case .terminalRead:
            return Classification(
                tier: .readOnly,
                ruleID: "readonly.terminal-read",
                reason: "reads the shared terminal"
            )
        case .serial:
            switch SerialOperation(argv: request.argv) {
            case .list:
                return Classification(tier: .readOnly, ruleID: "readonly.serial-list", reason: "lists serial ports")
            case .read:
                return Classification(
                    tier: .readOnly,
                    ruleID: "readonly.serial-read",
                    reason: "reads what a serial device sent"
                )
            case .open:
                return changing("changing.serial-open", "opens a serial port")
            case .write:
                return changing("changing.serial-write", "sends bytes to a serial device")
            case .reset:
                return changing("changing.serial-reset", "resets a serial device")
            case nil:
                return changing("changing.serial", "talks to a serial device")
            }
        case .network:
            // A grant, not an action: the owner decides in every mode, and no rule covers it.
            return Classification(
                tier: .privileged,
                ruleID: "privileged.lan-endpoint",
                reason: "lets your programs reach a device on your network"
            )
        case .broker:
            return Classification(tier: .privileged, ruleID: "privileged.broker", reason: "uses owner authority")
        case .file:
            return changing("changing.file", "writes a file in the session folder")
        }
    }

    static let maxDepth = 8

    /// Program basenames that are never available to Claude.
    static let blockedPrograms: [String: String] = [
        "sudo": "runs commands as another user",
        "sudoedit": "edits files as another user",
        "su": "switches user",
        "doas": "runs commands as another user",
        "login": "switches user",
        "security": "reads keychains and credentials",
        "dscl": "changes users and groups",
        "launchctl": "manages system and user services",
        "osascript": "scripts other apps as their user",
        // Work scheduled for later runs outside the session and survives Stop.
        "crontab": "schedules work outside the session",
        "at": "schedules work outside the session",
        "batch": "schedules work outside the session",
        "atq": "manages scheduled work",
        "atrm": "manages scheduled work",
        "sfltool": "changes login items",
    ]

    /// Blocked names that are everyday words, so the word scan of interpreter code skips them; as programs they
    /// are still blocked, and the sandbox denies the spools they write.
    static let unscannedPrograms: Set<String> = ["at", "batch"]

    /// Preference domains that start programs at login.
    static let loginItemDomains = ["loginwindow", "loginitems", "backgroundtaskmanagement"]

    static let readOnlyPrograms: Set<String> = ["ls", "cat", "head", "tail", "wc", "pwd", "which"]
    static let readOnlyGitCommands: Set<String> = ["status", "log", "diff", "show"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]
    /// Run their arguments as code; never read-only, and their arguments are scanned for blocked words.
    static let interpreters: Set<String> = ["perl", "ruby", "node", "php", "lua", "tclsh", "awk", "gawk", "nawk"]
    static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!",
        "{", "}",
    ]
    static let unmodelledShellWords: Set<String> = [
        "for", "case", "select", "function", "eval", "source", ".",
        "alias", "trap", "coproc",
    ]

    /// Options of programs that run their remaining arguments as a command.
    struct Wrapper {
        var flags: Set<String> = []
        var valued: Set<String> = []
        /// Positional operands before the command, e.g. the duration of `timeout`.
        var operands = 0
        var assignments = false
        var numericFlag = false
        var minimum = RiskTier.readOnly
    }

    static let wrappers: [String: Wrapper] = [
        "env": Wrapper(
            flags: ["-", "-i", "-0", "-v", "--ignore-environment", "--null"],
            valued: ["-u", "-C", "-P", "--unset", "--chdir"],
            assignments: true
        ),
        "xargs": Wrapper(
            flags: ["-0", "-o", "-p", "-r", "-t", "-x", "--null", "--no-run-if-empty", "--verbose"],
            valued: [
                "-a", "-d", "-E", "-I", "-J", "-L", "-n", "-P", "-R", "-s", "-S", "--arg-file", "--delimiter",
                "--max-args", "--max-procs", "--replace",
            ],
            minimum: .changing
        ),
        "nohup": Wrapper(),
        "time": Wrapper(
            flags: ["-a", "-l", "-p", "-v", "--append", "--portability", "--verbose"],
            valued: ["-f", "-o", "--format", "--output"]
        ),
        "nice": Wrapper(valued: ["-n", "--adjustment"], numericFlag: true),
        "timeout": Wrapper(
            flags: ["-v", "--foreground", "--preserve-status", "--verbose"],
            valued: ["-k", "-s", "--kill-after", "--signal"],
            operands: 1
        ),
        "exec": Wrapper(flags: ["-c", "-l"], valued: ["-a"]),
        "command": Wrapper(flags: ["-p", "-v", "-V"]),
        "builtin": Wrapper(),
        "caffeinate": Wrapper(flags: ["-d", "-i", "-m", "-s", "-u"], valued: ["-t", "-w"]),
    ]

    static func blocked(_ ruleID: String, _ reason: String) -> Classification {
        Classification(tier: .blocked, ruleID: ruleID, reason: reason)
    }

    static func changing(_ ruleID: String, _ reason: String) -> Classification {
        Classification(tier: .changing, ruleID: ruleID, reason: reason)
    }

    /// Path-stripped, lowercased program name, as macOS resolves it on a case-insensitive volume.
    static func programName(_ argv0: String) -> String {
        String(argv0.split(separator: "/", omittingEmptySubsequences: false).last ?? "").lowercased()
    }

    static func classify(argv: [String], depth: Int) -> Classification {
        if argv.contains(where: { $0.contains("\0") }) {
            return blocked("blocked.nul", "arguments contain a NUL byte, which hides the real program name")
        }
        guard depth <= maxDepth else {
            return unparsed(argv, "changing.depth", "nested too deeply to inspect")
        }
        guard let program = argv.first, !program.isEmpty else {
            return changing("changing.empty", "no program given")
        }
        let name = programName(program)
        let args = Array(argv.dropFirst())
        if let reason = blockedPrograms[name] {
            return blocked("blocked.\(name)", "`\(name)` is always blocked: it \(reason)")
        }
        if isEfuseWrite(name, args) {
            return blocked("blocked.efuse", "eFuse writes are irreversible and always blocked")
        }
        if isLoginItemWrite(name, args) {
            return blocked("blocked.login-items", "changing login items schedules work outside the session")
        }
        if let wrapper = wrappers[name] {
            return unwrap(wrapper, name, args, depth: depth)
        }
        if shells.contains(name) {
            return classify(shellArgs: args, depth: depth)
        }
        if interpreters.contains(name) || isPython(name) {
            return scan(args) ?? changing("changing.interpreter", "`\(name)` runs code")
        }
        if name == "find" {
            return classify(find: args, depth: depth)
        }
        if isReadOnly(program, name, args) {
            return Classification(tier: .readOnly, ruleID: "readonly.\(name)", reason: "`\(name)` only reads")
        }
        if program.contains("=") {
            return changing("changing.assignment", "`\(program)` is not a program")
        }
        return changing("changing.default", "`\(name)` may change files or devices")
    }

    static func isPython(_ name: String) -> Bool {
        name.hasPrefix("python") && name.dropFirst(6).allSatisfy { $0.isNumber || $0 == "." }
    }

    /// espefuse `burn_*`, esptool `burn_*` / `write_efuse`, idf.py `efuse-*`. These tools chain several commands
    /// in one invocation, so every argument counts; `-` and `_` are interchangeable.
    static func isEfuseWrite(_ name: String, _ args: [String]) -> Bool {
        let tool = name.hasSuffix(".py") ? String(name.dropLast(3)) : name
        let ops = args.map(normalizedOperation)
        switch tool {
        case "espefuse": return ops.contains { $0.hasPrefix("burn_") }
        case "esptool": return ops.contains { $0.hasPrefix("burn_") || $0 == "write_efuse" }
        case "idf": return ops.contains { $0.hasPrefix("efuse_") }
        default: return false
        }
    }

    /// `defaults write|import|rename` anywhere near a login item domain. Errs towards blocking: any such
    /// argument counts, wherever it is.
    static func isLoginItemWrite(_ name: String, _ args: [String]) -> Bool {
        guard name == "defaults", args.contains(where: { ["write", "import", "rename"].contains($0.lowercased()) })
        else { return false }
        return args.contains { arg in loginItemDomains.contains { arg.lowercased().contains($0) } }
    }

    static func normalizedOperation(_ arg: String) -> String {
        String(arg.lowercased().map { $0 == "-" ? "_" : $0 })
    }

    static func isReadOnly(_ program: String, _ name: String, _ args: [String]) -> Bool {
        // A path-qualified name could be a program the agent wrote; trust only system directories.
        if program.contains("/") {
            guard program.hasPrefix("/bin/") || program.hasPrefix("/usr/bin/"), !program.contains("..") else {
                return false
            }
        }
        if readOnlyPrograms.contains(name) { return true }
        guard name == "git", let subcommand = args.first, readOnlyGitCommands.contains(subcommand) else {
            return false
        }
        // `--output` writes a file, `--ext-diff` and `--textconv` run programs; git accepts unambiguous abbreviations.
        return !args.contains { arg in
            guard arg.hasPrefix("--"), arg != "--" else { return false }
            let option = String(arg.dropFirst(2).prefix { $0 != "=" })
            return ["output", "ext-diff", "textconv"].contains { $0.hasPrefix(option) || option.hasPrefix($0) }
        }
    }

    /// Conservative fallback for text that could not be parsed: blocks if any word looks like a blocked program or
    /// an eFuse write, otherwise `nil`.
    static func scan(_ texts: [String]) -> Classification? {
        for text in texts {
            let words = text.lowercased().split { !($0.isLetter || $0.isNumber || "._-".contains($0)) }
            for word in words.map(String.init) where !unscannedPrograms.contains(word) {
                if let reason = blockedPrograms[word] {
                    return blocked("blocked.\(word)", "mentions `\(word)`, which is always blocked: it \(reason)")
                }
                let op = normalizedOperation(word)
                if op.hasPrefix("burn_") || op == "write_efuse" || op.hasPrefix("efuse_") {
                    return blocked("blocked.efuse", "mentions an eFuse write, which is always blocked")
                }
            }
        }
        return nil
    }

    static func unparsed(_ texts: [String], _ ruleID: String, _ reason: String) -> Classification {
        scan(texts) ?? changing(ruleID, reason)
    }

    static func unwrap(_ wrapper: Wrapper, _ name: String, _ args: [String], depth: Int) -> Classification {
        var i = 0
        var assigned = false
        options: while i < args.count {
            let arg = args[i]
            if arg == "--" {
                i += 1
                break
            }
            if wrapper.assignments, !arg.hasPrefix("-"), arg.contains("=") {
                assigned = true
                i += 1
                continue
            }
            guard arg.hasPrefix("-"), arg != "-" || wrapper.flags.contains("-") else { break }
            if wrapper.flags.contains(arg) {
                i += 1
                continue
            }
            if wrapper.valued.contains(arg) {
                i += 2
                continue
            }
            if arg.hasPrefix("--") {
                guard let equals = arg.firstIndex(of: "="), wrapper.valued.contains(String(arg[..<equals])) else {
                    return unparsed(args, "changing.wrapper", "unknown `\(name)` option \(arg)")
                }
                i += 1
                continue
            }
            // Short option clusters: `-dims`, `-n10`, `-10`.
            if wrapper.numericFlag, arg.dropFirst().allSatisfy(\.isNumber) {
                i += 1
                continue
            }
            for (offset, flag) in arg.dropFirst().enumerated() {
                if wrapper.flags.contains("-\(flag)") { continue }
                guard wrapper.valued.contains("-\(flag)") else {
                    return unparsed(args, "changing.wrapper", "unknown `\(name)` option \(arg)")
                }
                i += offset == arg.count - 2 ? 2 : 1  // value is the next argument unless attached
                continue options
            }
            i += 1
        }
        i += wrapper.operands
        guard i < args.count else {
            return changing("changing.wrapper", "`\(name)` without a command")
        }
        var result = classify(argv: Array(args[i...]), depth: depth + 1)
        result = result.atLeast(wrapper.minimum, "changing.\(name)", "`\(name)` builds its command at run time")
        if assigned {
            result = result.atLeast(.changing, "changing.assignment", "environment changes can redirect programs")
        }
        return result
    }

    static func classify(shellArgs args: [String], depth: Int) -> Classification {
        var i = 0
        var hasCommandString = false
        while i < args.count {
            let arg = args[i]
            if arg == "--" || arg == "-" {
                i += 1
                break
            }
            if arg.hasPrefix("--") {
                if ["--rcfile", "--init-file"].contains(arg) {
                    i += 2
                    continue
                }
                guard ["--norc", "--noprofile", "--login", "--posix", "--noediting", "--verbose"].contains(arg) else {
                    return unparsed(args, "changing.shell", "unknown shell option \(arg)")
                }
                i += 1
                continue
            }
            guard arg.count > 1, arg.hasPrefix("-") || arg.hasPrefix("+") else { break }
            if arg.contains("c") { hasCommandString = true }
            i += arg.contains("o") || arg.contains("O") ? 2 : 1  // `-o name` takes a value
        }
        guard i < args.count else {
            return changing("changing.shell", "interactive shell or script from standard input")
        }
        guard hasCommandString else {
            return changing("changing.script", "runs a shell script")
        }
        return classify(script: args[i], extraArgs: Array(args[(i + 1)...]), depth: depth + 1)
    }

    static func classify(script source: String, extraArgs: [String], depth: Int) -> Classification {
        guard depth <= maxDepth else {
            return unparsed([source] + extraArgs, "changing.depth", "nested too deeply to inspect")
        }
        let script = ShellScript(parsing: source)
        var confident = script.isConfident
        var result: Classification?
        for command in script.commands {
            var words = command.words[...]
            var assigned = false
            while let first = words.first, !first.isDynamic {
                if shellKeywords.contains(first.text) {
                    words.removeFirst()
                } else if isAssignment(first.text) {
                    assigned = true
                    words.removeFirst()
                } else {
                    break
                }
            }
            if words.contains(where: \.isDynamic) { confident = false }
            guard let first = words.first else {
                if assigned { confident = false }  // e.g. `PATH=/tmp; ls`
                if command.redirectsOutput {
                    result = Classification.max(result, changing("changing.redirect", "writes a file"))
                }
                continue
            }
            if unmodelledShellWords.contains(first.text) { confident = false }
            var classification = classify(argv: words.map(\.text), depth: depth + 1)
            if command.redirectsOutput {
                classification = classification.atLeast(.changing, "changing.redirect", "writes a file")
            }
            if assigned {
                classification = classification.atLeast(
                    .changing,
                    "changing.assignment",
                    "environment changes can redirect programs"
                )
            }
            result = Classification.max(result, classification)
        }
        if !confident {
            let fallback = unparsed([source] + extraArgs, "changing.shell", "shell constructs that cannot be inspected")
            result = Classification.max(result, fallback)
        }
        return result ?? Classification(tier: .readOnly, ruleID: "readonly.empty", reason: "no command")
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber } && !(name.first?.isNumber ?? true)
    }

    /// `find` runs whatever follows `-exec`, `-execdir`, `-ok` or `-okdir`, up to `;` or `+`.
    static func classify(find args: [String], depth: Int) -> Classification {
        var result = changing("changing.find", "`find` can delete files or run commands")
        var i = 0
        while i < args.count {
            if ["-exec", "-execdir", "-ok", "-okdir"].contains(args[i]) {
                let start = i + 1
                var end = start
                while end < args.count, args[end] != ";", args[end] != "+" { end += 1 }
                result = Classification.max(result, classify(argv: Array(args[start..<end]), depth: depth + 1))
                i = end
            }
            i += 1
        }
        return result
    }
}
