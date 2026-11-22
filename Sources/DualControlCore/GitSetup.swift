/// New git repositories in the session folder (D9c, threat-model gap 9). CHANGING denies every `.git` entry, hook
/// and config file in the session (code there would later run unsandboxed as whoever runs git), so `git clone` and
/// `git init` fail there. The app makes the repository itself instead: `git_clone` and `git_init` run the real git
/// with a fixed command line (no templates, no hooks, https only, no submodules), as the agent, in a CLONING profile
/// that lifts the `.git` denies only inside the new repository and only for that one process. Afterwards the app
/// checks what git wrote (`configProblem`) and deletes it if anything else is there. From then on the normal
/// CHANGING denies keep its hooks and config as they are; commits, fetches and branches work.
public enum GitSetup {
    /// What is being made.
    public enum Kind: Sendable, Equatable {
        /// `git clone` into a new folder.
        case clone
        /// `git init` in a folder that has no `.git` yet.
        case initialize
    }

    /// Seconds a clone may take.
    public static let timeoutSeconds = 1800
    /// Seconds an init may take.
    public static let initTimeoutSeconds = 60

    /// Options for every git process here: no hooks, no fsmonitor; for clones only https.
    static let safeOptions = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
    static let httpsOnly = ["-c", "protocol.allow=never", "-c", "protocol.https.allow=always"]

    /// Variables added to the command environment: no system or global config, never prompt for credentials.
    public static let environment = [
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
    ]

    /// The clone's command line; `git` is replaced by the real binary when it runs.
    public static func cloneArgv(url: String, folder: String) -> [String] {
        ["git"] + safeOptions + httpsOnly + ["clone", "--template=", "--no-recurse-submodules", "--", url, folder]
    }

    /// The init's command line; `git` is replaced by the real binary when it runs.
    public static func initArgv(folder: String) -> [String] {
        ["git"] + safeOptions + ["init", "--template=", "--", folder]
    }

    /// Why `url` cannot be cloned, or `nil`: only `https://host/path`, lowercase host (and port), no credentials,
    /// query, fragment, `..`, spaces or control characters.
    public static func urlProblem(_ url: String) -> String? {
        let prefix = "https://"
        guard url.hasPrefix(prefix), url.count <= 2048 else { return "only https:// URLs can be cloned" }
        let rest = url.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return "the URL names no repository" }
        let host = rest[..<slash]
        let path = rest[rest.index(after: slash)...]
        let hostCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.-:")
        guard !host.isEmpty, host.allSatisfy(hostCharacters.contains), !host.hasPrefix("-"), !host.hasPrefix(".")
        else { return "the URL's host is not a plain host name (no credentials)" }
        let pathCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/+%")
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.allSatisfy(pathCharacters.contains),
            !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return "the URL's path may only hold plain names (no query, `..` or special characters)" }
        return nil
    }

    /// Why `folder` cannot become a repository, or `nil`: it must be absolute and canonical, not `/`, with no
    /// component named `.git` (in any case).
    public static func folderProblem(_ folder: String) -> String? {
        guard SessionScope.isCanonical(folder), folder != "/" else { return "the folder must be an absolute path" }
        if folder.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) {
            return "the folder may not be inside a .git folder"
        }
        return nil
    }

    /// Why the config git wrote is not what a plain clone or init writes, or `nil`. `entries` are `key, value` as
    /// `git config --list` prints them (keys lowercased). Accepted: the `core` keys git sets itself (not bare),
    /// `extensions.objectformat`, and for a clone only `remote.origin.url` (exactly `url`), `remote.origin.fetch`,
    /// and `branch.<name>.remote` / `.merge`.
    public static func configProblem(_ entries: [(String, String)], kind: Kind, url: String?) -> String? {
        let core: Set<String> = [
            "core.repositoryformatversion", "core.filemode", "core.bare", "core.logallrefupdates", "core.ignorecase",
            "core.precomposeunicode", "core.symlinks", "extensions.objectformat",
        ]
        for (key, value) in entries {
            if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                return "`\(DisplayText.summary(key, limit: 80))` has a control character"
            }
            if core.contains(key) {
                if key == "core.bare", value != "false" { return "the repository is bare" }
                continue
            }
            guard kind == .clone else { return "`\(DisplayText.summary(key, limit: 80))` is not set by git init" }
            switch key {
            case "remote.origin.url":
                if value != url { return "the origin is not the URL that was cloned" }
            case "remote.origin.fetch":
                continue
            default:
                let parts = key.split(separator: ".", omittingEmptySubsequences: false)
                let isBranch =
                    parts.count >= 3 && parts.first == "branch" && ["remote", "merge"].contains(parts.last)
                guard isBranch else { return "`\(DisplayText.summary(key, limit: 80))` is not set by git clone" }
            }
        }
        return nil
    }
}

/// A `git_clone` or `git_init` launch: what it makes and where.
public struct GitLaunch: Sendable, Equatable {
    /// Clone or init.
    public let kind: GitSetup.Kind
    /// The new repository's folder (its work tree).
    public let target: String
    /// For a clone, the URL; its origin must be exactly this.
    public let url: String?
}
