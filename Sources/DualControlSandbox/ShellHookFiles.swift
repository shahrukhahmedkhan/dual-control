#if canImport(Darwin)
    import DualControlCore
    import Foundation

    /// The files in the session folder that a shell hook would act on if the owner's own shell entered their folder
    /// (`SharedTerminal.isShellHookFile`). Listed when the owner takes over, since the agent may have written them.
    public enum ShellHookFiles {
        /// What a scan found.
        public struct Found: Sendable, Equatable {
            /// Paths relative to the scanned folder, sorted.
            public let files: [String]
            /// The scan stopped at its entry limit, so there may be more.
            public let incomplete: Bool
        }

        /// Folders not entered: git's own (the sandbox keeps the agent out of `.git`) and package caches, which are
        /// large and not where anyone works.
        static let skipped: Set<String> = [".git", "node_modules"]

        /// Scans `root` down to `maxDepth` levels (1 = only its own entries), looking at no more than `limit` entries.
        /// Symlinks are listed by name and never followed.
        public static func find(in root: String, maxDepth: Int = 3, limit: Int = 20_000) -> Found {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard
                let entries = FileManager.default.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [],
                    errorHandler: { _, _ in true }
                )
            else { return Found(files: [], incomplete: false) }
            let prefix = rootURL.standardizedFileURL.path + "/"
            var files: [String] = []
            var seen = 0
            for case let url as URL in entries {
                seen += 1
                if seen > limit { return Found(files: files.sorted(), incomplete: true) }
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
                if SharedTerminal.isShellHookFile(name) {
                    let path = url.standardizedFileURL.path
                    files.append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : name)
                }
                if isFolder, entries.level >= maxDepth || skipped.contains(name.lowercased()) {
                    entries.skipDescendants()
                }
            }
            return Found(files: files.sorted(), incomplete: false)
        }
    }
#endif
