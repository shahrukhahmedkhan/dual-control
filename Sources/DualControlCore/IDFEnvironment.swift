/// The ESP-IDF environment a recognised flasher (`FlasherCommand`) runs with, so idf.py finds its Python
/// environment and tools. It is derived from the install itself, never from the owner's environment: the macOS
/// layer runs `idf_tools.py export --format key-value` as the agent, in the sandbox, and `validated` turns its
/// output into an allowlist. Anything outside the install rejects the whole environment.
public enum IDFEnvironment {
    /// Why an export cannot be used.
    public struct Problem: Error, Equatable, CustomStringConvertible {
        /// What was wrong, escaped.
        public let description: String

        /// A problem described by `description`.
        public init(description: String) {
            self.description = description
        }
    }

    /// The most output an export may print.
    public static let maxOutputBytes = 64 << 10
    /// The most PATH entries it may add.
    public static let maxPathEntries = 64
    /// Variables whose value must be a folder in the install.
    static let pathKeys: Set<String> = ["IDF_PYTHON_ENV_PATH", "OPENOCD_SCRIPTS", "ESP_ROM_ELF_DIR"]
    /// Every variable taken from an export; all others are dropped.
    static let exportedKeys = pathKeys.union(["ESP_IDF_VERSION", "PATH"])
    /// Every variable `validated` may return.
    static let keys = exportedKeys.union(["IDF_PATH", "IDF_TOOLS_PATH"])

    /// The ESP-IDF folder for `argv`: the one in the owner's toolchain install it runs from
    /// (`FlasherCommand.install`), or `nil` if it runs from none.
    public static func idfPath(for argv: [String], scope: SessionScope, resolve: (String) -> String?) -> String? {
        FlasherCommand.install(of: argv, scope: scope, resolve: resolve).map { $0 + "/" + OwnerToolchain.idfFolder }
    }

    /// IDF_TOOLS_PATH for the ESP-IDF folder `idfPath`: the install's tools folder next to it.
    public static func toolsPath(idfPath: String) -> String {
        SandboxProfile.parent(of: idfPath) + "/" + OwnerToolchain.toolsFolder
    }

    /// True if the command cannot run without the environment: idf.py. esptool runs from its Python
    /// environment's own `bin`.
    public static func needed(for argv: [String]) -> Bool {
        idfScript(argv) != nil
    }

    /// The idf.py `argv` runs: the program itself, or the script a Python runs.
    static func idfScript(_ argv: [String]) -> String? {
        guard let program = argv.first else { return nil }
        if Classifier.programName(program) == "idf.py" { return program }
        if Classifier.isPython(Classifier.programName(program)), argv.count > 1,
            Classifier.programName(argv[1]) == "idf.py"
        {
            return argv[1]
        }
        return nil
    }

    /// What prints the environment, run by the Python the install was made with.
    public static func exportCommand(idfPath: String) -> [String] {
        let python = SandboxProfile.parent(of: idfPath) + "/" + OwnerToolchain.pythonFolder + "/python3"
        return [python, idfPath + "/tools/idf_tools.py", "export", "--format", "key-value"]
    }

    /// The environment from `output`: `IDF_PATH`, `IDF_TOOLS_PATH`, and the exported variables that are allowed,
    /// with PATH as the export's additions in front of the agent's own PATH. Lines that are not `KEY=value` are
    /// ignored (warnings).
    public static func validated(_ output: String, idfPath: String, scope: SessionScope) -> Result<
        [String: String], Problem
    > {
        func problem(_ text: String) -> Result<[String: String], Problem> {
            .failure(Problem(description: "the ESP-IDF environment cannot be used: " + text))
        }
        guard let install = OwnerToolchain.install(of: idfPath, scope: scope),
            idfPath == install + "/" + OwnerToolchain.idfFolder
        else { return problem("\(DisplayText.escaped(idfPath)) is not in an install in the toolchain folder") }
        func inInstall(_ path: String) -> Bool {
            SessionScope.isCanonical(path) && SessionScope.isStrictlyInside(path, install)
        }
        guard output.utf8.count <= maxOutputBytes else { return problem("the export printed too much") }
        var environment = ["IDF_PATH": idfPath, "IDF_TOOLS_PATH": toolsPath(idfPath: idfPath)]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            guard exportedKeys.contains(key) else { continue }
            var value = String(line[line.index(after: equals)...])
            guard environment[key] == nil else { return problem("\(key) is set twice") }
            guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                return problem("\(key) contains control characters")
            }
            switch key {
            case "PATH":
                let entries = value.split(separator: ":").map(String.init).filter { $0 != "$PATH" }
                guard !entries.isEmpty, entries.count <= maxPathEntries else {
                    return problem("PATH adds no folder, or too many")
                }
                for entry in entries where !inInstall(entry) {
                    return problem("PATH adds \(DisplayText.escaped(entry)), which is not in the install")
                }
                value = (entries + [AgentEnvironment.path]).joined(separator: ":")
            case "ESP_IDF_VERSION":
                guard (1...32).contains(value.count),
                    value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) })
                else { return problem("ESP_IDF_VERSION is not a version") }
            default:
                if value.count > 1, value.hasSuffix("/") { value.removeLast() }
                guard inInstall(value) else {
                    return problem("\(key) is \(DisplayText.escaped(value)), which is not in the install")
                }
            }
            environment[key] = value
        }
        guard environment["PATH"] != nil else { return problem("the export set no PATH") }
        return .success(environment)
    }
}

extension AgentEnvironment {
    /// The `run_command` allowlist plus a validated ESP-IDF environment. Only `IDFEnvironment`'s variables are
    /// taken from `idf`; the agent's HOME, TMPDIR, LANG and TERM always stay.
    public static func commandVariables(scope: SessionScope, idf: [String: String]) -> [String: String] {
        var variables = commandVariables(scope: scope)
        for (key, value) in idf where IDFEnvironment.keys.contains(key) && (key == "PATH" || variables[key] == nil) {
            variables[key] = value
        }
        return variables
    }
}
