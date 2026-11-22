/// The ESP-IDF toolchains flashers trust (gap 8). `esp_idf_install` builds an install as the agent in a staging
/// folder (`SessionScope.toolchainStaging`) that only its INSTALLING profile may write. When it ends, the app copies
/// it, as the owner, to `<toolchains>/esp-idf-<version>`: owned by the owner, with a deny ACL for the agent, and
/// outside every folder a CHANGING profile may write. The copy is checked (modes, links, no trace of the staging
/// folder or the agent's home left) and its hash is recorded next to it; flashers are recognised only in an install
/// there (`FlasherCommand`), and only while that hash still matches. The agent's own `~/esp` is never trusted.
///
/// Pure: the layout and the checks on paths and bytes. The macOS layer copies, walks and hashes.
public enum OwnerToolchain {
    /// In an install: ESP-IDF itself (IDF_PATH).
    public static let idfFolder = "idf"
    /// In an install: IDF_TOOLS_PATH, with the tools and the Python environment.
    public static let toolsFolder = "tools"
    /// In an install: `python3`, a link to the Homebrew Python it was made with.
    public static let pythonFolder = "python-bin"
    /// What is copied out of the staging folder.
    public static let copiedFolders = [idfFolder, toolsFolder, pythonFolder]
    /// Never copied (bsdtar patterns, at any depth): git's own files, whose hooks and config the owner's git would
    /// run; Python byte code, which names the staging folder; the downloaded archives.
    public static let excludedPatterns = [".git", "__pycache__", "*.pyc", toolsFolder + "/dist"]
    /// Folders outside an install that its links may lead into: system and Homebrew folders the agent cannot write.
    public static let linkRoots = [
        "/opt/homebrew", "/usr", "/bin", "/sbin", "/System", "/Library/Developer", "/Applications/Xcode.app",
    ]
    /// Inside `linkRoots`, but often writable by more than root.
    static let excludedLinkRoots = ["/usr/local"]
    /// The prefix of every install's folder name.
    static let namePrefix = "esp-idf-"

    /// The install's folder name for an ESP-IDF release (`ESPIDFInstall.versionProblem` has checked it).
    public static func installName(version: String) -> String {
        namePrefix + version
    }

    /// The install `path` is strictly inside: `<toolchains>/esp-idf-<version>`, or `nil`. The path must be canonical
    /// (resolved already).
    public static func install(of path: String, scope: SessionScope) -> String? {
        guard SessionScope.isCanonical(path), SessionScope.isStrictlyInside(path, scope.toolchains) else { return nil }
        let rest = path.dropFirst(scope.toolchains.count + 1)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let name = rest[..<slash]
        guard name.hasPrefix(namePrefix), ESPIDFInstall.versionProblem(String(name.dropFirst(namePrefix.count))) == nil
        else { return nil }
        return scope.toolchains + "/" + name
    }

    /// The file next to `install` that holds its hash.
    public static func hashFile(of install: String) -> String {
        install + ".sha256"
    }

    /// True if a link in `install` may resolve to `real`: into the install, or into `linkRoots`.
    public static func mayLink(to real: String, install: String) -> Bool {
        func within(_ folder: String) -> Bool { real == folder || SessionScope.isStrictlyInside(real, folder) }
        guard SessionScope.isCanonical(real) else { return false }
        if within(install) { return true }
        return !excludedLinkRoots.contains(where: within) && linkRoots.contains(where: within)
    }

    /// `bytes` with every `from/` replaced by `to/`, if they are text (no NUL byte) and contain it; otherwise `nil`.
    public static func relocated(_ bytes: [UInt8], from: String, to: String) -> [UInt8]? {
        let needle = Array((from + "/").utf8)
        guard !bytes.contains(0), firstIndex(of: needle, in: bytes) != nil else { return nil }
        let replacement = Array((to + "/").utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var start = 0
        while let found = firstIndex(of: needle, in: bytes, from: start) {
            result += bytes[start..<found]
            result += replacement
            start = found + needle.count
        }
        result += bytes[start...]
        return result
    }

    /// A link target with `from/` at its start replaced by `to/`, or `nil` if it does not start with it.
    public static func relocatedLink(_ target: String, from: String, to: String) -> String? {
        guard target == from || target.hasPrefix(from + "/") else { return nil }
        return to + target.dropFirst(from.count)
    }

    /// The first index of `needle` in `bytes` at or after `start`, or `nil`.
    static func firstIndex(of needle: [UInt8], in bytes: [UInt8], from start: Int = 0) -> Int? {
        guard let first = needle.first, bytes.count - start >= needle.count else { return nil }
        var index = start
        let last = bytes.count - needle.count
        while index <= last {
            if bytes[index] == first, bytes[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    /// One line of an install's manifest, which its hash is taken over: the entry's kind, path inside the install,
    /// permission bits, and its content's SHA-256 (files) or target (links).
    public static func manifestLine(kind: Character, path: String, mode: UInt16, value: String) -> String {
        "\(kind) \(String(mode & 0o7777, radix: 8)) \(DisplayText.escaped(path)) \(DisplayText.escaped(value))\n"
    }
}
