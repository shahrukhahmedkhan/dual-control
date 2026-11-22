/// Checks the paths a command or terminal text names against the session folder (SAFE-003), before the policy
/// engine and before anything runs. The kernel sandbox refuses the same access; this check makes the decision say so,
/// so the feed never shows "Allowed" for something only the sandbox stops.
///
/// An argument is a path if it starts with `/` or `~`, has a `..` component, or is an option or assignment whose
/// value is one (`--file=/x`, `if=/x`). It is resolved against the working directory: with realpath where it exists,
/// otherwise the longest existing prefix with the rest applied lexically. Any other argument that exists on disk is
/// resolved too, so a symlink out of the session counts. `~` always names a home folder, never the session, so it is
/// refused unresolved. The program name is not an argument. Shell strings (behind a shell anywhere in an argument
/// vector, and terminal text) are parsed: their words and redirection targets are checked the same way, and a bare
/// `cd`, which goes to the agent's home, is refused. The only system path allowed is `/dev/null`, plus one serial
/// port for a recognised flasher (`FlasherCommand`), which must name exactly one: the value of its `-p`/`--port`,
/// if `isFreePort` says serial_list shows it as a USB serial device and no Dual Control serial session holds it.
///
/// Known gaps the kernel covers: expansions (`$HOME/x`), paths inside interpreter code (`python -c`), option values
/// attached without `=` (`-I/x`), and for terminal text, relative paths after the pane changed folder (they are
/// resolved against the session folder).
enum ArgumentScope {
    static let ruleID = "scope.argument"
    /// System paths that tools legitimately take as arguments or redirection targets.
    static let allowedSystemPaths: Set<String> = ["/dev/null"]

    /// Why `request` may not run, or `nil`. `request.cwd` must already be resolved and inside `scope` for commands;
    /// terminal text is resolved against the session folder, where the pane starts.
    static func violation(
        _ request: ActionRequest,
        scope: SessionScope,
        resolvePath: @escaping (String) -> String?,
        isFreePort: (String) -> String? = { _ in "no serial port may be named" }
    ) -> Decision? {
        let checker = Checker(scope: scope, resolvePath: resolvePath)
        let problem: String?
        switch request.capability {
        case .command:
            switch port(request.argv, scope: scope, resolvePath: resolvePath, isFreePort: isFreePort) {
            case .failure(let refusal): return Decision(verdict: .deny, reason: refusal.text, ruleID: refusal.ruleID)
            case .success(let skipped):
                let argv = request.argv.enumerated().filter { !skipped.contains($0.offset) }.map(\.element)
                problem = checker.argv(argv, cwd: request.cwd, depth: 0)
            }
        case .terminal: problem = checker.script(request.argv.joined(), cwd: scope.root, depth: 0)
        case .file:
            guard let file = FileRequest(argv: request.argv), file.describes(request.payload),
                FileWrite.pathProblem(file.path) == nil,
                request.cwd == resolvePath(SandboxProfile.parent(of: file.path)), scope.contains(request.cwd)
            else { return Decision(verdict: .deny, reason: "not a file in the session folder", ruleID: ruleID) }
            problem = FileWrite.scopeProblem(
                file.path,
                resolvedFolder: request.cwd,
                scope: scope,
                resolvePath: resolvePath
            )
        case .terminalRead, .serial, .network, .broker: problem = nil
        }
        return problem.map { Decision(verdict: .deny, reason: $0, ruleID: ruleID) }
    }

    struct Refusal: Error {
        let text: String
        var ruleID = ArgumentScope.ruleID
    }

    /// The arguments of a recognised flasher that are not checked here (none if not a flasher): its one port, and the
    /// install's script a Python runs, which recognition checked. Or why it may not run: it names no port, several,
    /// or one that may not be used. `isFreePort` returns why a port is not free, or `nil`.
    static func port(
        _ argv: [String],
        scope: SessionScope,
        resolvePath: (String) -> String?,
        isFreePort: (String) -> String?
    ) -> Result<Set<Int>, Refusal> {
        guard FlasherCommand.isRecognised(argv, scope: scope, resolve: resolvePath) else { return .success([]) }
        let ports = FlasherCommand.portArguments(argv)
        guard let first = ports.first else {
            return .failure(
                Refusal(
                    text: "a flasher must name its port with -p: name the port from serial_list, so it never scans "
                        + "every port and reaches another board",
                    ruleID: "serial.no-port"
                )
            )
        }
        guard ports.count == 1 else { return .failure(Refusal(text: "a flasher may name one serial port only")) }
        if let why = isFreePort(first.port) {
            return .failure(Refusal(text: "`\(DisplayText.summary(first.port, limit: 120))` cannot be flashed: \(why)"))
        }
        return .success(Set([first.index] + (FlasherCommand.scriptIndex(argv).map { [$0] } ?? [])))
    }

    private struct Checker {
        let scope: SessionScope
        let resolvePath: (String) -> String?

        var tooDeep: String { "nested too deeply to check the paths it names" }

        /// Every argument after the program; after a shell, each later argument is also parsed as a script.
        func argv(_ argv: [String], cwd: String, depth: Int) -> String? {
            guard depth <= Classifier.maxDepth else { return tooDeep }
            var afterShell = false
            for (index, arg) in argv.enumerated() {
                if index > 0, let problem = word(arg, cwd: cwd) { return problem }
                if afterShell, let problem = script(arg, cwd: cwd, depth: depth + 1) { return problem }
                if Classifier.shells.contains(Classifier.programName(arg)) { afterShell = true }
            }
            return nil
        }

        func script(_ source: String, cwd: String, depth: Int) -> String? {
            guard depth <= Classifier.maxDepth else { return tooDeep }
            for command in ShellScript(parsing: source).commands {
                for target in command.redirectTargets {
                    if let problem = word(target.text, cwd: cwd) { return problem }
                }
                var words = command.words.map(\.text)[...]
                while let first = words.first,
                    Classifier.shellKeywords.contains(first) || Classifier.isAssignment(first)
                {
                    if let problem = word(first, cwd: cwd) { return problem }
                    words.removeFirst()
                }
                if words.count == 1, Classifier.programName(words[words.startIndex]) == "cd" {
                    return "`cd` without a folder goes to the agent's home, outside the session folder "
                        + DisplayText.escaped(scope.root)
                }
                if let problem = argv(Array(words), cwd: cwd, depth: depth + 1) { return problem }
            }
            return nil
        }

        func word(_ text: String, cwd: String) -> String? {
            // The value of an assignment or option is what the program gets, so it is checked first and always: a
            // `..` would otherwise make the whole word look like a path that resolves inside the session.
            if let equals = text.firstIndex(of: "=") {
                let value = String(text[text.index(after: equals)...])
                if value.hasPrefix("~") || Self.looksLikePath(value), let problem = word(value, cwd: cwd) {
                    return problem
                }
            }
            if text.hasPrefix("~") { return outside(text) }
            if Self.looksLikePath(text) {
                guard let resolved = resolve(text.hasPrefix("/") ? text : cwd + "/" + text) else {
                    return outside(text)
                }
                return check(resolved, text)
            }
            if !text.isEmpty, !text.hasPrefix("-"), let resolved = resolvePath(cwd + "/" + text),
                let problem = check(resolved, text)
            {
                return problem
            }
            return nil
        }

        static func looksLikePath(_ text: String) -> Bool {
            text.hasPrefix("/") || text.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        }

        /// realpath, or the longest prefix realpath resolves plus the rest applied lexically.
        func resolve(_ absolute: String) -> String? {
            if let real = resolvePath(absolute) { return real }
            let parts = absolute.split(separator: "/")
            for count in stride(from: parts.count - 1, through: 1, by: -1) {
                if let real = resolvePath("/" + parts[..<count].joined(separator: "/")) {
                    return ToolRouter.normalizedFolder(real + "/" + parts[count...].joined(separator: "/"))
                }
            }
            return ToolRouter.normalizedFolder(absolute)
        }

        func check(_ resolved: String, _ text: String) -> String? {
            if ArgumentScope.allowedSystemPaths.contains(resolved) { return nil }
            guard scope.contains(resolved) else { return outside(text) }
            if scope.protectedPaths.contains(where: { SessionScope.isSameOrInsideIgnoringCase(resolved, $0) }) {
                return "`\(DisplayText.summary(text, limit: 120))` is in a folder the agent may never reach"
            }
            return nil
        }

        func outside(_ text: String) -> String {
            "`\(DisplayText.summary(text, limit: 120))` is outside the session folder "
                + DisplayText.escaped(scope.root)
        }
    }
}
