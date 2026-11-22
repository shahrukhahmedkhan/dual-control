import Testing

@testable import DualControlCore

private let scope = try? SessionScope(ceiling: "/work", root: "/work/p")
private let home = "/work/.dual-control/agent-home"
private let install = "/work/.dual-control/toolchains/esp-idf-v5.3"
private let idfPath = install + "/idf"
private let tools = install + "/tools"
private let pythonEnv = tools + "/python_env/idf5.3_py3.9_env"

/// What `idf_tools.py export --format key-value` prints for a typical install, plus a warning on stderr.
private let exported = """
    WARNING: a tool is not installed
    OPENOCD_SCRIPTS=\(tools)/tools/openocd-esp32/v0.12.0/openocd-esp32/share/openocd/scripts
    ESP_IDF_VERSION=5.3
    ESP_ROM_ELF_DIR=\(tools)/tools/esp-rom-elfs/20240305/
    IDF_PYTHON_ENV_PATH=\(pythonEnv)
    IDF_TOOLS_EXPORT_CMD=\(idfPath)/export.sh
    PATH=\(tools)/tools/xtensa-esp-elf/esp-13.2.0/xtensa-esp-elf/bin:\(pythonEnv)/bin:\(idfPath)/tools:$PATH

    """

private func validated(_ output: String) throws -> Result<[String: String], IDFEnvironment.Problem> {
    IDFEnvironment.validated(output, idfPath: idfPath, scope: try #require(scope))
}

@Test func theInstallIsTheOneTheFlasherRunsFrom() throws {
    let scope = try #require(scope)
    let resolve: (String) -> String? = { $0 }
    #expect(
        IDFEnvironment.idfPath(for: [idfPath + "/tools/idf.py", "flash"], scope: scope, resolve: resolve) == idfPath
    )
    let elsewhere = "/work/.dual-control/toolchains/esp-idf-v5.4/idf"
    #expect(
        IDFEnvironment.idfPath(for: [elsewhere + "/tools/idf.py", "flash"], scope: scope, resolve: resolve) == elsewhere
    )
    #expect(
        IDFEnvironment.idfPath(for: [pythonEnv + "/bin/esptool.py", "chip_id"], scope: scope, resolve: resolve)
            == idfPath
    )
    // Not from the owner's toolchain folder: no environment at all, never a default in the agent's home.
    let agentIdf = home + "/esp/esp-idf/tools/idf.py"
    #expect(IDFEnvironment.idfPath(for: [agentIdf, "flash"], scope: scope, resolve: resolve) == nil)
    #expect(IDFEnvironment.toolsPath(idfPath: idfPath) == tools)
    #expect(
        IDFEnvironment.exportCommand(idfPath: idfPath) == [
            install + "/python-bin/python3", idfPath + "/tools/idf_tools.py", "export", "--format", "key-value",
        ]
    )
    #expect(IDFEnvironment.needed(for: [idfPath + "/tools/idf.py", "flash"]))
    #expect(!IDFEnvironment.needed(for: [pythonEnv + "/bin/esptool.py", "chip_id"]))
}

@Test func anInstallInTheAgentsHomeHasNoEnvironment() throws {
    let scope = try #require(scope)
    let agentIdf = home + "/esp/esp-idf"
    let result = IDFEnvironment.validated("PATH=\(agentIdf)/tools:$PATH", idfPath: agentIdf, scope: scope)
    #expect(throws: IDFEnvironment.Problem.self) { try result.get() }
}

@Test func idfPyRunByAPythonIsFoundToo() throws {
    let scope = try #require(scope)
    let resolve: (String) -> String? = { $0 }
    let elsewhere = "/work/.dual-control/toolchains/esp-idf-v5.4/idf"
    let argv = [pythonEnv + "/bin/python", elsewhere + "/tools/idf.py", "-p", "/dev/cu.usbmodem1", "flash"]
    #expect(IDFEnvironment.idfPath(for: argv, scope: scope, resolve: resolve) == elsewhere)
    #expect(IDFEnvironment.needed(for: argv))
    #expect(!IDFEnvironment.needed(for: [pythonEnv + "/bin/python", pythonEnv + "/bin/esptool.py", "chip_id"]))
    #expect(!IDFEnvironment.needed(for: [pythonEnv + "/bin/python", "-m", "esptool", "chip_id"]))
}

@Test func theExportBecomesAnAllowlistedEnvironment() throws {
    let environment = try validated(exported).get()
    #expect(
        environment == [
            "IDF_PATH": idfPath,
            "IDF_TOOLS_PATH": tools,
            "IDF_PYTHON_ENV_PATH": pythonEnv,
            "ESP_IDF_VERSION": "5.3",
            "ESP_ROM_ELF_DIR": tools + "/tools/esp-rom-elfs/20240305",
            "OPENOCD_SCRIPTS": tools + "/tools/openocd-esp32/v0.12.0/openocd-esp32/share/openocd/scripts",
            "PATH": "\(tools)/tools/xtensa-esp-elf/esp-13.2.0/xtensa-esp-elf/bin:\(pythonEnv)/bin:\(idfPath)/tools:"
                + AgentEnvironment.path,
        ]
    )
}

@Test func theCommandEnvironmentGainsOnlyThose() throws {
    let scope = try #require(scope)
    let idf = try validated(exported).get()
    let merged = AgentEnvironment.commandVariables(scope: scope, idf: idf)
    let base = AgentEnvironment.commandVariables(scope: scope)
    #expect(Set(merged.keys) == Set(base.keys).union(idf.keys))
    #expect(merged["HOME"] == base["HOME"] && merged["TMPDIR"] == base["TMPDIR"] && merged["PATH"] == idf["PATH"])
    // An environment that is not from validation never replaces the agent's own variables.
    #expect(
        AgentEnvironment.commandVariables(scope: scope, idf: ["HOME": "/x", "IDF_PATH": idfPath])["HOME"]
            == base["HOME"]
    )
}

@Test(arguments: [
    // PATH entries outside the install, relative, or with `..`.
    "PATH=/usr/local/bin:$PATH",
    "PATH=/Users/o/bin:\(pythonEnv)/bin:$PATH",
    "PATH=bin:$PATH",
    "PATH=\(tools)/../../p/bin:$PATH",
    "PATH=\(home)/bin:$PATH",
    // Path values outside the install.
    "PATH=\(pythonEnv)/bin:$PATH\nIDF_PYTHON_ENV_PATH=/work/p/env",
    "PATH=\(pythonEnv)/bin:$PATH\nOPENOCD_SCRIPTS=/etc",
    // Odd versions, control characters, a key twice.
    "PATH=\(pythonEnv)/bin:$PATH\nESP_IDF_VERSION=5.3; rm -rf /",
    "PATH=\(pythonEnv)/bin:$PATH\nESP_IDF_VERSION=5.3\u{1B}[2J",
    "PATH=\(pythonEnv)/bin:$PATH\nPATH=/usr/local/bin:$PATH",
    // No PATH at all.
    "ESP_IDF_VERSION=5.3",
    "",
])
func anythingOutsideTheInstallRejectsTheWholeEnvironment(_ output: String) throws {
    #expect(throws: IDFEnvironment.Problem.self, "\(output)") { try validated(output).get() }
}

@Test func unknownVariablesAreDroppedNotTrusted() throws {
    let output =
        "PATH=\(pythonEnv)/bin:$PATH\nDYLD_INSERT_LIBRARIES=\(tools)/x.dylib\nHOME=/Users/o\nPYTHONPATH=\(tools)"
    let environment = try validated(output).get()
    #expect(
        environment["DYLD_INSERT_LIBRARIES"] == nil && environment["HOME"] == nil && environment["PYTHONPATH"] == nil
    )
}

@Test func hugeOutputIsRejected() throws {
    let output = "PATH=\(pythonEnv)/bin:$PATH\n" + String(repeating: "#", count: IDFEnvironment.maxOutputBytes)
    #expect(throws: IDFEnvironment.Problem.self) { try validated(output).get() }
    let many = "PATH=" + Array(repeating: pythonEnv + "/bin", count: 65).joined(separator: ":")
    #expect(throws: IDFEnvironment.Problem.self) { try validated(many).get() }
}
