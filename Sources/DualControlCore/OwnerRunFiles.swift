/// Files the owner's own tools run code from when the owner opens, builds or commits in a folder (gap 3): an agent
/// that writes one has its code run unsandboxed, as the owner, later. The end-of-session report lists every one that
/// changed during the session, first and with a warning (`SessionReport.ownerRunFiles`). Pure: which paths count;
/// the macOS layer finds the changed files.
public enum OwnerRunFiles {
    /// When a file of this kind runs, for the report.
    static let exactNames: [String: String] = [
        "makefile": "make", "gnumakefile": "make", "cmakelists.txt": "CMake configure",
        "cmakepresets.json": "CMake configure", "cmakeuserpresets.json": "CMake configure",
        "package.json": "npm/yarn/pnpm scripts", "package.swift": "Xcode/SwiftPM on open (manifest)",
        ".envrc": "direnv on cd", ".mise.toml": "mise on cd", "mise.toml": "mise on cd",
        ".tool-versions": "asdf/mise on cd", ".pre-commit-config.yaml": "pre-commit on git commit",
    ]
    /// Files under a folder, by `folder/name`.
    static let folderFiles: [String: String] = [
        ".vscode/tasks.json": "VS Code tasks", ".vscode/launch.json": "VS Code run/debug",
        ".vscode/settings.json": "VS Code settings (can name programs it runs)", ".mise/config.toml": "mise on cd",
        ".idea/workspace.xml": "JetBrains run configurations",
    ]
    /// Every file inside these folders, by the folder's path.
    static let folders: [String: String] = [
        ".idea/runconfigurations": "JetBrains run configurations", ".run": "JetBrains run configurations",
        ".git/hooks": "git hooks", ".githooks": "git hooks (hooksPath)", ".husky": "git hooks (husky)",
    ]

    /// When `path` (relative to the session folder, `/`-separated) runs, or `nil` if the owner's tools don't run it.
    /// Names are compared ignoring case, as on the default APFS volume.
    public static func kind(of path: String) -> String? {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        if let kind = exactNames[name] { return kind }
        if name.hasSuffix(".mk") { return "make (included makefile)" }
        if name.hasSuffix(".cmake") { return "CMake configure" }
        if name.hasSuffix(".code-workspace") { return "VS Code workspace tasks and settings" }
        if parts.count >= 2 {
            let parent = parts[parts.count - 2]
            if let kind = folderFiles[parent + "/" + name] { return kind }
            if parent.hasSuffix(".xcodeproj"), name == "project.pbxproj" { return "Xcode build phases" }
            if name.hasSuffix(".xcscheme") { return "Xcode scheme pre/post actions" }
        }
        for index in parts.indices.dropLast() {
            let folder = parts[...index].suffix(2).joined(separator: "/")
            if let kind = folders[folder] ?? folders[parts[index]] { return kind }
        }
        return nil
    }
}

/// One changed file the owner's tools run.
public struct OwnerRunFile: Sendable, Equatable {
    /// Relative to the session folder.
    public let path: String
    /// When it runs (`OwnerRunFiles.kind`).
    public let kind: String
    /// The agent owns it, so the agent created it; otherwise it was changed during the session (its ctime).
    public let createdByAgent: Bool

    /// A file.
    public init(path: String, kind: String, createdByAgent: Bool) {
        self.path = path
        self.kind = kind
        self.createdByAgent = createdByAgent
    }
}

/// What a scan of the session folder for changed files found.
public struct OwnerRunScan: Sendable, Equatable {
    /// The session folder.
    public let folder: String
    /// Changed files the owner's tools run, sorted by path.
    public let files: [OwnerRunFile]
    /// Entries looked at.
    public let scanned: Int
    /// The scan stopped at its limit, so there may be more.
    public let incomplete: Bool

    /// A scan result.
    public init(folder: String, files: [OwnerRunFile], scanned: Int, incomplete: Bool) {
        self.folder = folder
        self.files = files.sorted { $0.path < $1.path }
        self.scanned = scanned
        self.incomplete = incomplete
    }
}
