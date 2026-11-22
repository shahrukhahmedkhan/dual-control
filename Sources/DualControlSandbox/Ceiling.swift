#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// realpath(3): absolute, symlinks followed, `..` removed, on-disk case.
    public enum RealPath {
        /// The resolved form of the absolute `path`, or `nil` if it is relative, contains NUL or does not exist.
        public static func resolve(_ path: String) -> String? {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// The hard ceiling on disk: `<owner home>/Developer`, resolved at launch. Not configurable.
    public enum DeveloperCeiling {
        /// The home folder of the user running the app, from the password database. `$HOME` is not trusted.
        static func ownerHome() -> String? {
            guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
            return String(cString: directory)
        }

        /// The setup commands for the user running the app, with their name and home filled in at runtime.
        public static func setupGuide() -> SetupGuide? {
            guard let entry = getpwuid(getuid()), let name = entry.pointee.pw_name, let home = ownerHome() else {
                return nil
            }
            return SetupGuide(ownerUser: String(cString: name), ownerHome: home)
        }

        /// The resolved ceiling, or `nil` if it does not exist.
        public static func resolve() -> String? {
            ownerHome().flatMap(SessionScope.developerCeiling(ownerHome:)).flatMap(RealPath.resolve)
        }
    }

    /// Session scopes built from paths on disk.
    public enum ResolvedScope {
        /// Why a folder cannot be the session folder.
        public enum Error: Swift.Error, Equatable {
            /// The ceiling does not exist.
            case noCeiling
            /// The chosen folder does not exist.
            case missing(String)
            /// The resolved folder is not a valid scope.
            case refused(SessionScope.Error)
        }

        /// A scope for `folder` under the production ceiling.
        public static func production(choosing folder: String) throws(Error) -> SessionScope {
            guard let ceiling = DeveloperCeiling.resolve() else { throw .noCeiling }
            return try make(choosing: folder, ceiling: ceiling)
        }

        /// A scope for `folder` under `ceiling`, both resolved first. Tests pass their own ceiling.
        static func make(choosing folder: String, ceiling: String) throws(Error) -> SessionScope {
            guard let resolvedCeiling = RealPath.resolve(ceiling) else { throw .noCeiling }
            guard let root = RealPath.resolve(folder) else { throw .missing(folder) }
            do {
                // Check first, so only a folder inside the ceiling is ever scanned.
                _ = try SessionScope(ceiling: resolvedCeiling, root: root)
                return try SessionScope(
                    ceiling: resolvedCeiling,
                    root: root,
                    protected: ProtectedFolders.find(root: root, ceiling: resolvedCeiling)
                )
            } catch {
                throw .refused(error)
            }
        }
    }

    /// Finds the folders to protect for a session (self-protection): the repo folder under the ceiling as it is
    /// spelled on disk, and every folder whose Package.swift declares the `DualControl` package, from the ceiling
    /// down to the session folder and in the session folder's own tree.
    enum ProtectedFolders {
        /// How deep below the session folder the scan looks.
        static let maxDepth = 6
        /// How many folders the scan visits at most, so a huge tree cannot stall choosing a folder. The repo folder
        /// under the ceiling is protected whatever the scan finds.
        static let maxFolders = 50_000
        /// Folders not scanned: build output and dependency caches, never a checkout of ours.
        static let skipped: Set<String> = [".git", ".build", "node_modules", "DerivedData", "Pods", ".swiftpm"]
        /// Package.swift files larger than this are not read.
        static let maxManifestBytes = 256 * 1024

        /// Resolved folders to protect, for `root` under `ceiling` (both resolved).
        static func find(root: String, ceiling: String) -> [String] {
            var found: [String] = []
            if let repo = RealPath.resolve(ceiling + "/" + SessionScope.protectedFolderName) { found.append(repo) }
            var folder = root
            while folder.hasPrefix(ceiling + "/") {
                if declaresDualControl(folder) { found.append(folder) }
                folder = String(folder[..<(folder.lastIndex(of: "/") ?? folder.startIndex)])
            }
            var queue = [(root, 0)]
            var visited = 0
            while !queue.isEmpty, visited < maxFolders {
                let (current, depth) = queue.removeFirst()
                visited += 1
                if current != root, declaresDualControl(current) { found.append(current) }
                guard depth < maxDepth, let names = try? FileManager.default.contentsOfDirectory(atPath: current)
                else { continue }
                for name in names.sorted() where !skipped.contains(name) {
                    let child = current + "/" + name
                    var info = stat()
                    // lstat: never follow a symlink out of the tree.
                    if lstat(child, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { queue.append((child, depth + 1)) }
                }
            }
            return found
        }

        /// True if `folder` holds a regular Package.swift that declares the `DualControl` package.
        static func declaresDualControl(_ folder: String) -> Bool {
            let path = folder + "/Package.swift"
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxManifestBytes,
                let data = FileManager.default.contents(atPath: path)
            else { return false }
            return SessionScope.declaresDualControlPackage(String(decoding: data, as: UTF8.self))
        }
    }
#endif
