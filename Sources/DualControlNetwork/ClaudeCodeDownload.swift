#if canImport(Darwin)
    import DualControlCore
    import Foundation

    /// Downloads a Claude Code release for the owner (D11): the release manifest, then the binary for this Mac, from
    /// Anthropic's release host over HTTPS. Runs in the app, as the owner, outside the gatekeeper: it only fetches
    /// files, nothing runs. `ClaudeCodeStore.install` then checks the binary against the manifest's SHA-256 and
    /// Anthropic's signature before anything can start it.
    public enum ClaudeCodeDownload {
        /// What was downloaded: the binary's path and the SHA-256 the manifest gives for it.
        public struct Downloaded: Sendable, Equatable {
            /// The downloaded binary, owned by the owner.
            public let file: String
            /// Its SHA-256 according to the release manifest (not yet checked).
            public let sha256: String
        }

        /// Why a download failed.
        public struct Problem: Error, Equatable, CustomStringConvertible {
            /// Why, for the owner and the audit log.
            public let description: String
        }

        /// The release platform of this Mac.
        public static var platform: String {
            #if arch(arm64)
                return "darwin-arm64"
            #else
                return "darwin-x64"
            #endif
        }

        /// Downloads `version`'s manifest and binary; the binary is moved to a new file in `folder`.
        public static func fetch(version: String, into folder: String) async -> Result<Downloaded, Problem> {
            if let problem = ClaudeCode.versionProblem(version) { return .failure(Problem(description: problem)) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            configuration.timeoutIntervalForResource = 900
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            guard let manifestURL = URL(string: ClaudeCode.manifestURL(version: version)),
                let binaryURL = URL(string: ClaudeCode.binaryURL(version: version, platform: platform))
            else { return .failure(Problem(description: "the release URLs are not valid")) }
            do {
                let (manifest, response) = try await session.data(from: manifestURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return .failure(Problem(description: "Claude Code \(version) has no release manifest"))
                }
                guard let sha256 = ClaudeCode.checksum(manifest: manifest, platform: platform) else {
                    return .failure(Problem(description: "the release manifest has no checksum for \(platform)"))
                }
                let (temporary, binaryResponse) = try await session.download(from: binaryURL)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (binaryResponse as? HTTPURLResponse)?.statusCode == 200 else {
                    return .failure(Problem(description: "the binary for \(platform) could not be downloaded"))
                }
                let file = folder + "/claude-\(version)-\(UInt32.random(in: .min ... .max))"
                try FileManager.default.moveItem(at: temporary, to: URL(fileURLWithPath: file))
                return .success(Downloaded(file: file, sha256: sha256))
            } catch {
                return .failure(Problem(description: "the download failed: \(error.localizedDescription)"))
            }
        }
    }
#endif
