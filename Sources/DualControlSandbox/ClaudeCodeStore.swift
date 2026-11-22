#if canImport(Darwin)
    import CryptoKit
    import Darwin
    import DualControlCore
    import Foundation

    /// The owner's pinned Claude Code installs on disk (`ClaudeCode`, D11). Everything here runs as the owner, in the
    /// app; nothing in it runs the binary.
    public struct ClaudeCodeStore: Sendable {
        /// Why an install cannot be made or used.
        public struct Problem: Error, Equatable, CustomStringConvertible {
            /// Why, for the owner and the audit log.
            public let description: String

            /// A problem with this description.
            public init(description: String) {
                self.description = description
            }
        }

        /// The system's codesign.
        static let codesign = "/usr/bin/codesign"

        let scope: SessionScope
        /// The user the toolchain folder's deny ACL names; `nil` (tests) adds none.
        let denyACLUser: String?

        /// The store for `scope`'s toolchain folder.
        public init(scope: SessionScope, denyACLUser: String?) {
            self.scope = scope
            self.denyACLUser = denyACLUser
        }

        private var toolchains: OwnerToolchainStore {
            OwnerToolchainStore(scope: scope, denyACLUser: denyACLUser)
        }

        /// Installs the downloaded binary `file` as Claude Code `version`: it must be a regular file of at most
        /// `ClaudeCode.maxBinaryBytes` whose SHA-256 is `sha256` (from the release manifest) and that is signed by
        /// Anthropic (`ClaudeCode.codeRequirement`). The copy is made from the same open file it was hashed from,
        /// checked again where it lies, locked, and only then replaces an earlier install of that version; its hash
        /// is recorded next to it. The download is removed either way. The digest, or why not.
        public func install(version: String, from file: String, sha256: String) -> Result<String, Problem> {
            defer { unlink(file) }
            if let problem = ClaudeCode.versionProblem(version) { return .failure(Problem(description: problem)) }
            let source = open(file, O_RDONLY | O_NOFOLLOW)
            guard source >= 0 else { return .failure(Problem(description: "the download cannot be opened")) }
            defer { close(source) }
            var info = stat()
            guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_size <= ClaudeCode.maxBinaryBytes
            else { return .failure(Problem(description: "the download is not a file of a plausible size")) }
            if let problem = toolchains.prepareRoot() { return .failure(Problem(description: problem.description)) }

            let install = ClaudeCode.install(version: version, scope: scope)
            let fresh = scope.toolchains + "/.new-claude-code-\(version)-\(UInt32.random(in: .min ... .max))"
            func failed(_ why: String) -> Result<String, Problem> {
                _ = Subprocess.run(["/bin/rm", "-rf", "--", fresh])
                return .failure(Problem(description: why))
            }
            guard mkdir(fresh, 0o755) == 0, chmod(fresh, 0o755) == 0 else {
                return failed("the install folder cannot be made")
            }
            let binary = ClaudeCode.binary(of: fresh)
            guard let copied = Self.copy(source, to: binary) else { return failed("the binary cannot be copied") }
            guard copied == sha256 else { return failed("the download does not match the release manifest's SHA-256") }
            if let problem = Self.signatureProblem(binary) { return failed(problem.description) }
            let digest: String
            switch toolchains.digest(fresh) {
            case .failure(let problem): return failed(problem.description)
            case .success(let value): digest = value
            }

            let hashFile = OwnerToolchain.hashFile(of: install)
            unlink(hashFile)
            Self.forget(install)
            let old = scope.toolchains + "/.replaced-claude-code-\(version)-\(UInt32.random(in: .min ... .max))"
            let hadOld = toolchains.exists(install)
            if hadOld, rename(install, old) != 0 { return failed("the earlier install cannot be moved aside") }
            guard rename(fresh, install) == 0 else {
                if hadOld { rename(old, install) }
                return failed("the install cannot be put in place")
            }
            guard toolchains.write(digest + "\n", to: hashFile) else {
                _ = Subprocess.run(["/bin/rm", "-rf", "--", install])
                if hadOld { rename(old, install) }
                return .failure(Problem(description: "its hash cannot be recorded"))
            }
            if hadOld { _ = Subprocess.run(["/bin/rm", "-rf", "--", old]) }
            return .success(digest)
        }

        /// `.success` with the digest if Claude Code `version` is installed, still matches its recorded hash
        /// (checked once while the app runs, like an ESP-IDF install) and is still signed by Anthropic (checked
        /// every time). Called right before every start.
        public func verify(version: String) -> Result<String, Problem> {
            guard ClaudeCode.versionProblem(version) == nil else {
                return .failure(Problem(description: "\(version) is not a Claude Code version"))
            }
            let install = ClaudeCode.install(version: version, scope: scope)
            guard toolchains.exists(install), toolchains.exists(OwnerToolchain.hashFile(of: install)) else {
                return .failure(
                    Problem(description: "Claude Code \(version) is not installed; install it in the window")
                )
            }
            switch toolchains.verify(install) {
            case .failure(let problem):
                return .failure(Problem(description: problem.description))
            case .success(let digest):
                if let problem = Self.signatureProblem(ClaudeCode.binary(of: install)) { return .failure(problem) }
                return .success(digest)
            }
        }

        /// The versions installed: folders named for a version, with a recorded hash. Not verified.
        public func versions() -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: scope.toolchains)) ?? []
            return names.compactMap { name in
                guard let version = ClaudeCode.version(ofInstallName: name),
                    toolchains.exists(OwnerToolchain.hashFile(of: scope.toolchains + "/" + name))
                else { return nil }
                return version
            }
            .sorted()
        }

        /// Why `path` is not Claude Code signed by Anthropic, or `nil`. codesign only reads the file.
        static func signatureProblem(_ path: String) -> Problem? {
            let argv = [codesign, "--verify", "--strict", "--test-requirement==" + ClaudeCode.codeRequirement, path]
            guard let run = Subprocess.run(argv), run.status == 0 else {
                return Problem(description: "the binary is not signed by Anthropic (Developer ID Q6L2SF6YDW)")
            }
            return nil
        }

        /// Copies `source` from its start into a new file at `path` (0755, never through a link) and returns the
        /// SHA-256 of what was written.
        static func copy(_ source: Int32, to path: String) -> String? {
            let target = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o755)
            guard target >= 0 else { return nil }
            defer { close(target) }
            guard lseek(source, 0, SEEK_SET) == 0, fchmod(target, 0o755) == 0 else { return nil }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var total = 0
            while true {
                let count = read(source, &buffer, buffer.count)
                if count < 0 { return nil }
                if count == 0 { break }
                total += count
                guard total <= ClaudeCode.maxBinaryBytes else { return nil }
                let written = buffer.withUnsafeBytes { Darwin.write(target, $0.baseAddress, count) }
                guard written == count else { return nil }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        static func forget(_ install: String) { OwnerToolchainStore.forget(install) }
    }
#endif
