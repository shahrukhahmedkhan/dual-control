import Testing

@testable import DualControlCore

private let scope = try? SessionScope(ceiling: "/work", root: "/work/p")
private let home = "/work/.dual-control/agent-home"
private let install = "/work/.dual-control/toolchains/esp-idf-v5.4"
private let idf = install + "/idf/tools/idf.py"
private let python = install + "/tools/python_env/idf5.4_py3.12_env/bin/python"
private let esptool = install + "/tools/python_env/idf5.4_py3.12_env/bin/esptool.py"
private let venv = install + "/tools/python_env/idf5.4_py3.12_env/bin"
/// The same install in the agent's own home, where flashers were recognised before gap 8 was closed.
private let agentIdf = home + "/esp/esp-idf/tools/idf.py"
private let agentPython = home + "/.espressif/python_env/idf5.4_py3.12_env/bin/python"
private let agentEsptool = home + "/.espressif/python_env/idf5.4_py3.12_env/bin/esptool.py"

/// realpath, as the app would see the disk: the install's files resolve to themselves, a symlink in the install
/// resolves to what it points at, anything else does not exist.
private func resolve(_ path: String) -> String? {
    switch path {
    case idf, python, esptool, install + "/idf/export.sh": return path
    case agentIdf, agentPython, agentEsptool, home + "/.espressif/python_env/idf5.4_py3.12_env/bin": return path
    case install + "/idf/tools/linked.py": return "/work/p/evil.py"
    case install + "/idf/tools/to-agent.py": return agentIdf
    // A venv's interpreter is a symlink to the Python it was made with (live: the system or Xcode Python).
    case venv + "/python3": return "/usr/bin/python3"
    case venv + "/python3.9": return "/Applications/Xcode.app/Contents/Developer/usr/bin/python3.9"
    case venv + "/python-sh": return "/bin/sh"
    case venv: return venv
    case install + "/tools/python_env/linked/bin/python3": return "/usr/bin/python3"
    case install + "/tools/python_env/linked/bin": return venv
    case install + "/tools/tools/python3": return "/usr/bin/python3"
    case install + "/tools/tools": return install + "/tools/tools"
    case "/work/.dual-control/toolchains/other/idf/tools/idf.py": return path
    case "/work/p/esptool.py": return path
    default: return nil
    }
}

private func recognised(_ argv: [String]) throws -> Bool {
    FlasherCommand.isRecognised(argv, scope: try #require(scope), resolve: resolve)
}

@Test(arguments: [
    [idf, "flash"],
    [idf, "-p", "/dev/cu.usbserial-1", "-b", "460800", "app-flash"],
    [idf, "erase-flash"],
    [idf, "erase_flash"],
    [idf, "-C", "/work/p/blink", "build", "flash", "monitor"],
    [idf, "--port=/dev/cu.usbserial-1", "monitor"],
    [python, idf, "-p", "/dev/cu.usbserial-1", "flash"],
    [esptool, "--chip", "esp32s3", "-p", "/dev/cu.usbserial-1", "-b", "460800", "write_flash", "0x0", "app.bin"],
    [esptool, "--port", "/dev/cu.usbserial-1", "write-flash", "--flash_mode", "dio", "0x10000", "build/app.bin"],
    [esptool, "-p", "/dev/cu.usbserial-1", "read_flash", "0", "0x400000", "dump.bin"],
    [esptool, "chip_id"],
    [esptool, "--no-stub", "flash_id"],
    [esptool, "--before", "default_reset", "--after", "hard_reset", "chip_id"],
    [python, "-m", "esptool", "--chip", "esp32", "write_flash", "0x1000", "bootloader.bin"],
    [python, esptool, "flash-id"],
    // The venv's own interpreter counts by its own path, though it resolves out of the install (D9c, live).
    [venv + "/python3", idf, "-p", "/dev/cu.usbmodem1", "flash"],
    [venv + "/python3.9", esptool, "chip_id"],
    [venv + "/python3", "-m", "esptool", "flash_id"],
])
func flashersAndMonitorsFromTheInstallAreRecognised(_ argv: [String]) throws {
    #expect(try recognised(argv), "\(argv)")
}

@Test(arguments: [
    // Not a flasher, monitor or recognised operation.
    [idf, "build"],
    [idf, "menuconfig"],
    [idf, "partition-table-flash"],
    [esptool, "erase_flash"],
    [esptool, "run"],
    [esptool, "load_ram", "stub.bin"],
    [esptool, "write_mem", "0x6000", "1", "0xFF"],
    [esptool, "image_info", "app.bin"],
    [esptool],
    [idf],
    // eFuse and register writes, wherever they are.
    [idf, "flash", "efuse-burn", "X"],
    [idf, "efuse-summary", "monitor"],
    [esptool, "write_flash", "0x0", "a.bin", "write_reg"],
    [esptool, "burn_key", "flash_id"],
    [esptool, "write_flash", "0x0", "run"],
    // Leaving the chip in its bootloader without the app knowing (gap 8).
    [esptool, "--after", "no_reset", "write_flash", "0x0", "a.bin"],
    [esptool, "--after", "no-reset-stub", "chip_id"],
    [esptool, "--before", "no_reset", "chip_id"],
    [esptool, "--before=no_reset_no_sync", "chip_id"],
    [python, "-m", "esptool", "--after", "NO_RESET", "flash_id"],
    // A file of arguments could hide any command.
    [esptool, "@args.txt"],
    [esptool, "write_flash", "@more.txt"],
    // An unknown option's value is read as the command, so it is refused.
    [esptool, "--mystery", "write_flash", "chip_id"],
    // Not from the owner's toolchain folder.
    ["idf.py", "flash"],
    ["esptool.py", "chip_id"],
    ["/work/p/esptool.py", "chip_id"],
    [install + "/idf/tools/linked.py", "flash"],
    [install + "/idf/tools/missing.py", "flash"],
    ["/work/.dual-control/toolchains/other/idf/tools/idf.py", "flash"],
    // An install in the agent's own home, which it can edit, or a link from the toolchain folder into it (gap 8).
    [agentIdf, "-p", "/dev/cu.usbserial-1", "flash"],
    [agentEsptool, "chip_id"],
    [agentPython, "-m", "esptool", "chip_id"],
    [agentPython, agentIdf, "flash"],
    [python, agentIdf, "flash"],
    [agentPython, idf, "flash"],
    [install + "/idf/tools/to-agent.py", "flash"],
    // A venv interpreter that is not a Python, in a symlinked folder, outside python_env/<env>/bin, or running
    // anything but the install's own tools.
    [venv + "/python-sh", idf, "flash"],
    [install + "/tools/python_env/linked/bin/python3", idf, "flash"],
    [install + "/tools/tools/python3", idf, "flash"],
    [install + "/tools/python_env/idf5.4_py3.12_env/sub/bin/python3", idf, "flash"],
    [venv + "/python3", "/work/p/esptool.py", "chip_id"],
    [venv + "/python3", "-c", "import esptool"],
    ["/usr/bin/python3", idf, "flash"],
    [python, "/work/p/esptool.py", "chip_id"],
    [python, "-c", "import esptool", "chip_id"],
    [python, "-m", "espefuse", "summary"],
    [python, "-m", "esptool"],
    [python],
    // Paths written relatively or with `..` are not trusted.
    ["../.dual-control/toolchains/esp-idf-v5.4/idf/tools/idf.py", "flash"],
    // Behind any wrapper.
    ["/usr/bin/env", "IDF_PATH=\(install)/idf", python, idf, "flash"],
    ["/usr/bin/env", "-S", "\(idf) flash"],
    ["/usr/bin/env", "-i", idf, "flash"],
    ["/usr/bin/env", "lower=1", idf, "flash"],
    ["/usr/bin/env"],
    ["/bin/sh", "-c", ". \(install)/idf/export.sh && idf.py flash"],
    ["/usr/bin/time", idf, "flash"],
    // A shell, interpreter or anything else.
    ["/bin/cat", "/dev/cu.usbserial-1"],
    [],
])
func everythingElseIsNot(_ argv: [String]) throws {
    #expect(try !recognised(argv), "\(argv)")
}

@Test func onlyTheOwnersToolchainFolderCounts() throws {
    let other = try SessionScope(ceiling: "/elsewhere", root: "/elsewhere/p")
    #expect(!FlasherCommand.isRecognised([idf, "flash"], scope: other, resolve: resolve))
    #expect(FlasherCommand.installRoots(for: try #require(scope)) == ["/work/.dual-control/toolchains"])
}

@Test func theInstallAFlasherRunsFromIsItsScriptsOrElseItsPrograms() throws {
    let scope = try #require(scope)
    #expect(FlasherCommand.install(of: [idf, "flash"], scope: scope, resolve: resolve) == install)
    #expect(FlasherCommand.install(of: [python, idf, "flash"], scope: scope, resolve: resolve) == install)
    #expect(
        FlasherCommand.install(of: [venv + "/python3", "-m", "esptool"], scope: scope, resolve: resolve) == install
    )
    #expect(FlasherCommand.install(of: [agentIdf, "flash"], scope: scope, resolve: resolve) == nil)
    #expect(FlasherCommand.install(of: [agentPython, "-m", "esptool"], scope: scope, resolve: resolve) == nil)
}
