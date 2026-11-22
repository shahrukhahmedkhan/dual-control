/// Which `run_command` commands may open serial devices. The CHANGING sandbox denies every `/dev/cu.*` and
/// `/dev/tty.*` device to everything else, kernel-enforced, so a program the agent writes cannot talk to a ROM
/// bootloader (and its eFuse registers) directly.
///
/// Recognised: idf.py `flash`, `app-flash`, `erase-flash` and `monitor` (with `build` alongside), and esptool
/// `write_flash`, `read_flash`, `chip_id` and `flash_id`; never with an eFuse word, a register write, `run`, or an
/// `@file` of more arguments anywhere, and never leaving the chip in its bootloader (`--before`/`--after
/// no_reset…`) without the app knowing. The program, and the script a Python runs, must be absolute paths that
/// realpath resolves into an install in the owner's toolchain folder (`OwnerToolchain`), which the agent cannot
/// write. The one exception is the Python environment's own interpreter, which resolves to the Python it was made
/// with (`isVenvPython`). No wrappers (env, sh, time…). An install in the agent's own home never counts: the agent
/// could edit it (gap 8). Whether the install still matches its recorded hash is checked by the macOS layer, right
/// before it runs.
public enum FlasherCommand {
    /// idf.py targets that use the port.
    static let idfDeviceTargets: Set<String> = ["flash", "app_flash", "erase_flash", "monitor"]
    /// idf.py targets allowed alongside them.
    static let idfOtherTargets: Set<String> = ["build"]
    /// idf.py options that take the next argument as their value.
    static let idfValuedOptions: Set<String> = [
        "-C", "--project-dir", "-B", "--build-dir", "-p", "--port", "-b", "--baud", "-D", "--define-cache-entry",
        "-G", "--generator",
    ]
    /// esptool commands allowed.
    static let esptoolCommands: Set<String> = ["write_flash", "read_flash", "chip_id", "flash_id"]
    /// Every other esptool command, refused wherever it appears.
    static let esptoolOtherCommands: Set<String> = [
        "load_ram", "dump_mem", "read_mem", "write_mem", "run", "image_info", "make_image", "elf2image", "read_mac",
        "read_flash_status", "write_flash_status", "verify_flash", "erase_flash", "erase_region", "merge_bin",
        "get_security_info", "read_flash_sfdp", "version",
    ]
    /// esptool options that take the next argument as their value.
    static let esptoolValuedOptions: Set<String> = [
        "-c", "--chip", "-p", "--port", "-b", "--baud", "--before", "--after", "--connect-attempts",
    ]

    /// The `-p`/`--port` values in `argv`, by argument index: `-p X` and `--port X` (the value's index) and
    /// `--port=X` (that argument's own index). Only meaningful for a recognised command.
    public static func portArguments(_ argv: [String]) -> [(index: Int, port: String)] {
        var found: [(index: Int, port: String)] = []
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg == "-p" || arg == "--port", index + 1 < argv.count {
                found.append((index + 1, argv[index + 1]))
                index += 2
                continue
            }
            if arg.hasPrefix("--port=") { found.append((index, String(arg.dropFirst("--port=".count)))) }
            index += 1
        }
        return found
    }

    /// The index of the script a Python runs (`python …/idf.py`), or `nil`: not a Python, or `-m`. Only meaningful
    /// for a recognised command, whose script recognition found in the install.
    public static func scriptIndex(_ argv: [String]) -> Int? {
        guard let program = argv.first, Classifier.isPython(Classifier.programName(program)), argv.count > 1,
            argv[1] != "-m"
        else { return nil }
        return 1
    }

    /// The folders an install must be in: the owner's toolchain folder only.
    public static func installRoots(for scope: SessionScope) -> [String] {
        [scope.toolchains]
    }

    /// The install a recognised `argv` runs from: the one its script (`python …/idf.py`) or else its program is in.
    public static func install(of argv: [String], scope: SessionScope, resolve: (String) -> String?) -> String? {
        let paths = scriptIndex(argv).map { [argv[$0]] } ?? []
        for path in paths + argv.prefix(1) {
            if let real = resolve(path), let install = OwnerToolchain.install(of: real, scope: scope) { return install }
            if isVenvPython(path, scope: scope, resolve: resolve) {
                return OwnerToolchain.install(of: path, scope: scope)
            }
        }
        return nil
    }

    /// True if `argv` is a recognised flasher or monitor from the install. `resolve` is realpath.
    public static func isRecognised(_ argv: [String], scope: SessionScope, resolve: (String) -> String?) -> Bool {
        guard let program = argv.first,
            isInstalled(program, scope: scope, resolve: resolve)
                || isVenvPython(program, scope: scope, resolve: resolve)
        else { return false }
        let name = Classifier.programName(program)
        var rest = Array(argv.dropFirst())
        if Classifier.isPython(name) {
            if rest.count >= 2, rest[0] == "-m", rest[1] == "esptool" {
                return isEsptool(Array(rest.dropFirst(2)))
            }
            guard let script = rest.first, isInstalled(script, scope: scope, resolve: resolve) else { return false }
            rest.removeFirst()
            return isTool(Classifier.programName(script), rest)
        }
        return isTool(name, rest)
    }

    private static func isTool(_ name: String, _ args: [String]) -> Bool {
        switch name {
        case "idf.py": return isIdf(args)
        case "esptool.py", "esptool": return isEsptool(args)
        default: return false
        }
    }

    /// An absolute, canonical path that realpath resolves into an install in the owner's toolchain folder.
    private static func isInstalled(_ path: String, scope: SessionScope, resolve: (String) -> String?) -> Bool {
        guard SessionScope.isCanonical(path), let real = resolve(path) else { return false }
        return OwnerToolchain.install(of: real, scope: scope) != nil
    }

    /// A Python environment's own interpreter, `<install>/tools/python_env/<env>/bin/python…`. In a venv it is a
    /// symlink to the Python the environment was made with, outside the install, so it counts by its own path: its
    /// folder must resolve to itself (no symlinked folders), and it must still resolve to a Python, not to a shell.
    private static func isVenvPython(_ path: String, scope: SessionScope, resolve: (String) -> String?) -> Bool {
        guard SessionScope.isCanonical(path), let install = OwnerToolchain.install(of: path, scope: scope),
            Classifier.isPython(Classifier.programName(path))
        else { return false }
        let parts = path.dropFirst(install.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == Substring(OwnerToolchain.toolsFolder), parts[1] == "python_env",
            !parts[2].isEmpty, parts[3] == "bin"
        else { return false }
        let folder = SandboxProfile.parent(of: path)
        guard resolve(folder) == folder, let real = resolve(path) else { return false }
        return Classifier.isPython(Classifier.programName(real))
    }

    /// Words no recognised command may contain anywhere, as an argument or an option's value. `no_reset` (as
    /// `--before` or `--after`) would leave the chip in its bootloader without the app knowing.
    private static func isForbidden(_ arg: String) -> Bool {
        let word = Classifier.normalizedOperation(arg)
        return arg.hasPrefix("@") || word.contains("efuse") || word.contains("burn_") || word.contains("write_reg")
            || word.contains("no_reset")
    }

    /// Every target is a known one and at least one uses the port.
    private static func isIdf(_ args: [String]) -> Bool {
        var targets: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if isForbidden(arg) { return false }
            if idfValuedOptions.contains(arg) {
                index += 2
                continue
            }
            if !arg.hasPrefix("-") { targets.append(Classifier.normalizedOperation(arg)) }
            index += 1
        }
        return targets.contains { idfDeviceTargets.contains($0) }
            && targets.allSatisfy { idfDeviceTargets.contains($0) || idfOtherTargets.contains($0) }
    }

    /// The first word that is not an option is an allowed command, and no other command follows it.
    private static func isEsptool(_ args: [String]) -> Bool {
        if args.contains(where: isForbidden) { return false }
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            index += esptoolValuedOptions.contains(args[index]) ? 2 : 1
        }
        guard index < args.count, esptoolCommands.contains(Classifier.normalizedOperation(args[index])) else {
            return false
        }
        let known = esptoolCommands.union(esptoolOtherCommands)
        return !args[(index + 1)...].contains { known.contains(Classifier.normalizedOperation($0)) }
    }
}
