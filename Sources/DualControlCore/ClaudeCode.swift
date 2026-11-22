import Foundation

/// D11 phase 1: a pinned Claude Code the agent can run but never change. The owner installs a release from the app:
/// the app downloads the single binary from Anthropic's release host as the owner (nothing runs while it does), checks
/// it against the release manifest's SHA-256 and against Anthropic's Developer ID signature, and puts it in
/// `<toolchains>/claude-code-<version>/claude`: owned by the owner, with the agent's deny ACL, its hash recorded
/// next to it like an ESP-IDF install (`OwnerToolchain`). Both checks run again before every start.
///
/// `claude_code_start` types one fixed line into the shared terminal: the pane is the agent's, in CHANGING, so Claude
/// Code and everything it runs inherit the kernel sandbox. Auto-update and non-essential traffic are off; updating
/// means installing another version.
///
/// Pure: the layout, the checks on names and the manifest, and the launch line. The macOS layer downloads, checks
/// signatures and locks.
public enum ClaudeCode {
    /// Where releases are published (the host the official installer uses).
    public static let downloadBase = "https://downloads.claude.ai/claude-code-releases"
    /// The version this build of Dual Control was checked with; the window offers it first.
    public static let recommendedVersion = "2.1.311"
    /// The binary's name in an install.
    public static let binaryName = "claude"
    /// The largest binary the app accepts.
    public static let maxBinaryBytes = 512 << 20
    /// The largest manifest the app accepts.
    public static let maxManifestBytes = 1 << 20
    /// Anthropic's designated requirement for the binary: its identifier, signed with a Developer ID Application
    /// certificate of Anthropic's team.
    public static let codeRequirement =
        #"identifier "com.anthropic.claude-code" and anchor apple generic and "#
        + #"certificate 1[field.1.2.840.113635.100.6.2.6] exists and "#
        + #"certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "Q6L2SF6YDW""#
    /// What every start sets: no self-update (the binary is the owner's), no telemetry or error reports (hosts the
    /// gatekeeper does not allow anyway).
    public static let environment = [("DISABLE_AUTOUPDATER", "1"), ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1")]
    /// The prefix of every install's folder name.
    static let namePrefix = "claude-code-"

    /// Why `version` cannot be installed, or `nil`: a release number such as 2.1.311.
    public static func versionProblem(_ version: String) -> String? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts.allSatisfy({ (1...5).contains($0.count) && $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return "the version must be a release number such as \(recommendedVersion)" }
        return nil
    }

    /// The install folder for `version` in `scope`'s toolchain folder.
    public static func install(version: String, scope: SessionScope) -> String {
        scope.toolchains + "/" + namePrefix + version
    }

    /// The binary in `install`.
    public static func binary(of install: String) -> String {
        install + "/" + binaryName
    }

    /// The version an install folder's name stands for, or `nil` if it is not one.
    public static func version(ofInstallName name: String) -> String? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let version = String(name.dropFirst(namePrefix.count))
        return versionProblem(version) == nil ? version : nil
    }

    /// The highest of `versions`, compared number by number; invalid ones are ignored.
    public static func newest(_ versions: [String]) -> String? {
        func numbers(_ version: String) -> [Int] { version.split(separator: ".").compactMap { Int($0) } }
        return versions.filter { versionProblem($0) == nil }.max { numbers($0).lexicographicallyPrecedes(numbers($1)) }
    }

    /// The release manifest, with each platform's SHA-256.
    public static func manifestURL(version: String) -> String {
        "\(downloadBase)/\(version)/manifest.json"
    }

    /// The binary for `platform` (`darwin-arm64` or `darwin-x64`).
    public static func binaryURL(version: String, platform: String) -> String {
        "\(downloadBase)/\(version)/\(platform)/\(binaryName)"
    }

    /// `platforms[platform].checksum` from a manifest, if it is 64 lowercase hex digits; otherwise `nil`.
    public static func checksum(manifest: Data, platform: String) -> String? {
        guard manifest.count <= maxManifestBytes,
            let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
            let platforms = object["platforms"] as? [String: Any],
            let entry = platforms[platform] as? [String: Any],
            let checksum = entry["checksum"] as? String,
            checksum.utf8.count == 64,
            checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        return checksum
    }

    /// The line `claude_code_start` types: into the session folder, then the pinned binary with `environment`. `nil`
    /// if the version is not valid or a path cannot be single-quoted safely.
    public static func launchLine(version: String, scope: SessionScope) -> String? {
        guard versionProblem(version) == nil, let root = quoted(scope.root),
            let binary = quoted(binary(of: install(version: version, scope: scope)))
        else { return nil }
        let variables = environment.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        return "cd \(root) && \(variables) \(binary)\n"
    }

    /// The version `line` starts, if it is exactly a `launchLine` for `scope`; otherwise `nil`.
    public static func version(ofLaunchLine line: String, scope: SessionScope) -> String? {
        let prefix = scope.toolchains + "/" + namePrefix
        guard let start = line.range(of: prefix)?.upperBound,
            let end = line[start...].range(of: "/" + binaryName + "'")?.lowerBound
        else { return nil }
        let version = String(line[start..<end])
        return launchLine(version: version, scope: scope) == line ? version : nil
    }

    /// `path` in single quotes, if it has no quote and no control character.
    static func quoted(_ path: String) -> String? {
        guard !path.unicodeScalars.contains(where: { $0 == "'" || $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        return "'" + path + "'"
    }
}
