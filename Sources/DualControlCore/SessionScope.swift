/// The folders a session may reach (SAFE-003). The ceiling is `<owner home>/Developer`, fixed in code; a session
/// narrows it to one subfolder, `root`. The agent's work area (its HOME and TMPDIR) also sits under the ceiling.
///
/// Every path here must already be resolved with realpath (symlinks, `..`, `/tmp` → `/private/tmp`, on-disk case);
/// that needs I/O, so the caller does it. Paths that are not in that canonical form are refused, never repaired, and
/// containment compares bytes, as the kernel sandbox does.
///
/// Self-protection: the Dual Control repo is never a session and never reachable by the agent. Its folder under the
/// ceiling is protected by name, and so is any folder whose Package.swift declares the `DualControl` package (the
/// caller finds those on disk and passes them in). A session may not be, or be inside, a protected folder or the
/// work area; those checks ignore case, because the default APFS volume does. The sandbox profiles deny the
/// protected paths even when a session folder contains one.
public struct SessionScope: Sendable, Equatable {
    /// Folder in the owner's home that is the ceiling. Changing it is a code change.
    public static let ceilingFolderName = "Developer"
    /// Folder under the ceiling for the agent's HOME and TMPDIR. Never a session root.
    public static let workAreaFolderName = ".dual-control"
    /// Folder under the ceiling that holds the Dual Control repo; always protected.
    public static let protectedFolderName = "dual-control"

    /// Why a scope was refused.
    public enum Error: Swift.Error, Equatable {
        /// A path is not absolute and canonical.
        case notCanonical(String)
        /// The root is not strictly inside the ceiling.
        case outsideCeiling(String)
        /// The root is the agent's work area or inside it.
        case insideWorkArea(String)
        /// The root is a protected folder (the Dual Control repo) or inside one.
        case protected(String)
    }

    /// The resolved ceiling.
    public let ceiling: String
    /// The resolved session folder, strictly inside the ceiling.
    public let root: String
    /// Folders the agent may never read or write, sorted: the repo folder under the ceiling first, then the
    /// detected packages.
    public let protectedPaths: [String]

    /// `<owner home>/Developer`, or `nil` if `ownerHome` is not an absolute, canonical path other than `/`. The
    /// result still has to be resolved with realpath.
    public static func developerCeiling(ownerHome: String) -> String? {
        var home = ownerHome
        if home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard home != "/", isCanonical(home) else { return nil }
        return home + "/" + ceilingFolderName
    }

    /// A scope for `root` under `ceiling`; both must be resolved already. Only tests pass a ceiling other than the
    /// resolved `developerCeiling`. `protected` lists the resolved folders found to hold a DualControl package.
    public init(ceiling: String, root: String, protected: [String] = []) throws(Error) {
        guard Self.isCanonical(ceiling), ceiling != "/" else { throw .notCanonical(ceiling) }
        guard Self.isCanonical(root) else { throw .notCanonical(root) }
        for path in protected where !Self.isCanonical(path) || path == "/" { throw .notCanonical(path) }
        guard Self.isStrictlyInside(root, ceiling) else { throw .outsideCeiling(root) }
        guard !Self.isSameOrInsideIgnoringCase(root, ceiling + "/" + Self.workAreaFolderName) else {
            throw .insideWorkArea(root)
        }
        let repo = ceiling + "/" + Self.protectedFolderName
        let paths = [repo] + Set(protected).subtracting([repo]).sorted()
        guard !paths.contains(where: { Self.isSameOrInsideIgnoringCase(root, $0) }) else { throw .protected(root) }
        self.ceiling = ceiling
        self.root = root
        self.protectedPaths = paths
    }

    /// True if `manifest`, the text of a Package.swift, declares the package `DualControl`.
    public static func declaresDualControlPackage(_ manifest: String) -> Bool {
        manifest.contains(#/Package\s*\(\s*name\s*:\s*"DualControl"/#)
    }

    /// The agent's work area.
    public var workArea: String { ceiling + "/" + Self.workAreaFolderName }
    /// The agent's HOME.
    public var agentHome: String { workArea + "/agent-home" }
    /// The agent's TMPDIR.
    public var agentTmp: String { workArea + "/tmp" }
    /// The owner's toolchain folder (`OwnerToolchain`): the agent can read it, never write it.
    public var toolchains: String { workArea + "/toolchains" }
    /// Where `esp_idf_install` builds an install before the app copies it; only its INSTALLING profile writes here.
    public var toolchainStaging: String { workArea + "/toolchain-staging" }
    /// Where the owner's side of `git_sync` leaves the remote's branches as a bundle: the agent can read it, never
    /// write it.
    public var gitSync: String { workArea + "/" + GitSync.folderName }

    /// True if the resolved `path` is the session root or inside it.
    public func contains(_ path: String) -> Bool {
        Self.isCanonical(path) && (path.utf8.elementsEqual(root.utf8) || Self.isStrictlyInside(path, root))
    }

    /// Absolute, no empty, `.` or `..` components, no trailing slash, no NUL.
    static func isCanonical(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        if path == "/" { return true }
        return path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).dropFirst().allSatisfy {
            !$0.isEmpty && !$0.elementsEqual(".".utf8) && !$0.elementsEqual("..".utf8)
        }
    }

    /// `path` is `folder` or inside it, ignoring ASCII and Unicode case.
    static func isSameOrInsideIgnoringCase(_ path: String, _ folder: String) -> Bool {
        let path = path.lowercased()
        let folder = folder.lowercased()
        return path == folder || isStrictlyInside(path, folder)
    }

    /// Byte-wise: `path` starts with `folder` followed by `/`.
    static func isStrictlyInside(_ path: String, _ folder: String) -> Bool {
        let prefix = Array(folder.utf8) + (folder == "/" ? [] : [UInt8(ascii: "/")])
        let bytes = Array(path.utf8)
        return bytes.count > prefix.count && bytes.starts(with: prefix)
    }
}
