/// `esp_idf_install` (D9c, gap 8): builds an ESP-IDF install that the app then copies into the owner's toolchain
/// folder, the only place flashers are recognised (`OwnerToolchain`). A wrapper script in the session folder can do
/// anything the kernel allows, so the install is one fixed script, the same for every call: only a release version
/// and chip names (both checked) are passed to it, as arguments. It runs as an audited background job, decided like
/// any CHANGING command, with the gatekeeper proxy as its only network, in its own INSTALLING profile: it may write
/// only the staging folder, which no other agent process may write, and cannot read the agent's home, TMPDIR or the
/// session folder, where configuration for pip, git or Python could be planted. Its environment (`environment`)
/// gives it a HOME inside the staging folder, the real git, and no user site or pip configuration. What it does:
///
/// 1. Picks a Python 3.10 or newer from Homebrew (macOS's 3.9 leaves ESP-IDF v5.4's environment broken), else stops.
/// 2. Empties the staging folder, except the downloaded tool archives (`tools/dist`, checked against their hashes
///    by `idf_tools.py`), so every install starts fresh: there is nothing to refuse or replace in place.
/// 3. Clones the version's tag from Espressif's GitHub into `<staging>/idf` (shallow, with submodules, hooks off).
/// 4. Runs its `install.sh` for the targets, then installs cmake (below 4: ESP-IDF v5.4 is not ready for it) and
///    ninja into its Python environment (pip wheels), which macOS does not have.
///
/// The job starts in `/`, not the session folder it cannot read (a shell there cannot find its working directory);
/// the script uses only absolute paths.
///
/// When it has ended well, the app copies it to `<toolchains>/esp-idf-<version>`, replacing an earlier install of
/// that version (`Sandbox.finishToolchain`).
public enum ESPIDFInstall {
    /// Seconds an install may take.
    public static let timeoutSeconds = 3600
    /// Chips `install.sh` takes.
    public static let targets: Set<String> = [
        "esp32", "esp32s2", "esp32s3", "esp32c2", "esp32c3", "esp32c5", "esp32c6", "esp32c61", "esp32h2", "esp32p4",
    ]

    /// Why `version` cannot be installed, or `nil`: a release tag, `v<major>.<minor>` or `v<major>.<minor>.<patch>`.
    public static func versionProblem(_ version: String) -> String? {
        guard version.hasPrefix("v") else { return "the version must be a release tag such as v5.4" }
        let numbers = version.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(numbers.count),
            numbers.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return "the version must be a release tag such as v5.4 or v5.4.1" }
        return nil
    }

    /// Why `chips` cannot be installed, or `nil`: one to ten known chip names.
    public static func targetsProblem(_ chips: [String]) -> String? {
        guard (1...10).contains(chips.count), chips.allSatisfy(targets.contains) else {
            return "`targets` must name 1 to 10 chips from: " + targets.sorted().joined(separator: ", ")
        }
        return nil
    }

    /// The command line: the fixed script, then the version and the comma-separated targets as its arguments.
    public static func argv(version: String, targets: [String]) -> [String] {
        ["/bin/sh", "-c", script, "esp_idf_install", version, targets.joined(separator: ",")]
    }

    /// The version an `argv` from `argv(version:targets:)` installs, or `nil` if it is not one.
    public static func version(of argv: [String]) -> String? {
        guard argv.count == 6, argv.prefix(4) == ["/bin/sh", "-c", script, "esp_idf_install"],
            versionProblem(argv[4]) == nil
        else { return nil }
        return argv[4]
    }

    /// The whole environment the script runs with: the `run_command` allowlist with HOME and TMPDIR inside the
    /// staging folder, `git` the real git binary (not the xcrun stub, whose cache the agent can write), and pip, git
    /// and Python kept from reading any configuration of the agent's.
    public static func environment(scope: SessionScope, git: String) -> [String: String] {
        let staging = scope.toolchainStaging
        var variables = AgentEnvironment.commandVariables(scope: scope)
        variables["HOME"] = staging + "/home"
        variables["TMPDIR"] = staging + "/tmp/"
        variables.merge([
            "DC_TOOLCHAIN_STAGING": staging,
            "DC_GIT": git,
            "IDF_TOOLS_PATH": staging + "/" + OwnerToolchain.toolsFolder,
            "XDG_CONFIG_HOME": staging + "/home/.config",
            "PYTHONNOUSERSITE": "1",
            "PIP_CONFIG_FILE": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        ]) { $1 }
        return variables
    }

    /// The fixed install script. `$1` is the version, `$2` the targets; the staging folder and git come from
    /// `environment`.
    public static let script = """
        set -eu
        version="$1"
        targets="$2"
        staging="$DC_TOOLCHAIN_STAGING"
        git="$DC_GIT"
        idf="$staging/idf"
        python=""
        for candidate in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 \
        /opt/homebrew/bin/python3.10; do
          if [ -x "$candidate" ]; then python="$candidate"; break; fi
        done
        if [ -z "$python" ]; then
          echo "esp_idf_install: no Python 3.10 or newer in /opt/homebrew/bin. macOS's Python 3.9 leaves the ESP-IDF \
        environment broken. Ask the owner to install one (brew install python@3.12), then try again." >&2
          exit 2
        fi
        mkdir -p "$staging/tools"
        cd "$staging"
        find "$staging" -mindepth 1 -maxdepth 1 ! -name tools -exec rm -rf {} +
        find "$staging/tools" -mindepth 1 -maxdepth 1 ! -name dist -exec rm -rf {} +
        mkdir -p "$HOME" "$TMPDIR" "$staging/python-bin"
        ln -s "$python" "$staging/python-bin/python3"
        PATH="$staging/python-bin:$(dirname "$git"):$PATH"
        export PATH
        "$git" -c core.hooksPath=/dev/null -c protocol.allow=never -c protocol.https.allow=always clone --depth 1 \
        --branch "$version" --recurse-submodules --shallow-submodules https://github.com/espressif/esp-idf.git "$idf"
        cd "$idf"
        ./install.sh "$targets"
        . ./export.sh >/dev/null
        python -m pip install "cmake>=3.24,<4" ninja
        echo "esp_idf_install: ESP-IDF $version for $targets is built; Dual Control copies it to its toolchain folder."
        """
}
