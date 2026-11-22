import Foundation

/// D12d: files that look like credentials, for the end-of-session report. The app scans the files in the session
/// folder and the agent's home that changed this session (as the owner, never following links) and lists the ones
/// whose name or first bytes look like a private key or a token, with the kind only, never the secret. Claude Code's
/// own login folder in the agent's home is left out: its token is meant to be there.
public enum CredentialFiles {
    /// Bytes of each file read.
    public static let headBytes = 256 << 10
    /// Claude Code's login folder, in the agent's home.
    public static let claudeCodeFolder = ".claude"

    /// Exact file names (lowercase) and what they are.
    static let names: [String: String] = [
        "id_rsa": "private key file", "id_dsa": "private key file", "id_ecdsa": "private key file",
        "id_ed25519": "private key file", "id_ecdsa_sk": "private key file", "id_ed25519_sk": "private key file",
        ".netrc": "login file (.netrc)", ".git-credentials": "git credentials file",
        ".pgpass": "database password file",
    ]
    /// Extensions (lowercase) of key and certificate stores.
    static let extensions: Set<String> = ["pem", "key", "p12", "pfx", "jks", "keystore", "ppk"]

    /// Content patterns: a literal start, the characters that must follow, at least how many, and the kind.
    private static let tokens: [(prefix: String, body: Set<Character>, minimum: Int, kind: String)] = {
        let word = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let alphanumeric = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let upper = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var patterns: [(String, Set<Character>, Int, String)] = [("sk-ant-", word, 20, "Anthropic API key")]
        for prefix in ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"] {
            patterns.append((prefix, alphanumeric, 36, "GitHub token"))
        }
        patterns.append(("github_pat_", word, 22, "GitHub token"))
        patterns.append(("AKIA", upper, 16, "AWS access key"))
        patterns.append(("ASIA", upper, 16, "AWS access key"))
        return patterns
    }()

    /// What `path` (relative, `/`-separated) looks like, from its name and its first bytes `head`: each kind once,
    /// name-based kinds first. Empty if nothing.
    public static func kinds(path: String, head: [UInt8]) -> [String] {
        var found: [String] = []
        func add(_ kind: String) { if !found.contains(kind) { found.append(kind) } }
        let parts = path.lowercased().split(separator: "/").map(String.init)
        let name = parts.last ?? ""
        if let kind = names[name] { add(kind) }
        if let dot = name.lastIndex(of: "."), extensions.contains(String(name[name.index(after: dot)...])) {
            add("key or certificate file")
        }
        if parts.suffix(2) == [".aws", "credentials"] { add("AWS credentials file") }
        if name.hasPrefix("client_secret"), name.hasSuffix(".json") { add("OAuth client secret file") }

        let text = String(decoding: head, as: UTF8.self)
        if text.contains("-----BEGIN "), text.contains("PRIVATE KEY-----") {
            for line in text.split(separator: "\n") where line.contains("-----BEGIN ") {
                if line.contains("PRIVATE KEY-----") {
                    add("private key")
                    break
                }
            }
        }
        for pattern in tokens where hasToken(text, pattern.prefix, pattern.body, pattern.minimum) { add(pattern.kind) }
        if text.lowercased().contains("aws_secret_access_key") { add("AWS secret key") }
        if name.hasSuffix(".json"),
            ["\"refresh_token\"", "\"access_token\"", "\"client_secret\""].contains(where: text.contains)
        {
            add("OAuth tokens")
        }
        return found
    }

    /// True if `text` has `prefix` followed by at least `minimum` characters from `body`, not preceded by one.
    private static func hasToken(_ text: String, _ prefix: String, _ body: Set<Character>, _ minimum: Int) -> Bool {
        var rest = text[...]
        while let range = rest.range(of: prefix) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let run = rest[range.upperBound...].prefix(while: body.contains).count
            if run >= minimum, before.map({ !body.contains($0) }) ?? true { return true }
            rest = rest[range.upperBound...]
        }
        return false
    }

    /// True if `path` (relative to its place) is left out: Claude Code's login folder in the agent's home.
    public static func isExcluded(_ path: String, inAgentHome: Bool) -> Bool {
        inAgentHome && path.split(separator: "/").first.map { $0.lowercased() == claudeCodeFolder } == true
    }
}

/// A file that looks like a credential, or an entry the scan could not read.
public struct CredentialFile: Sendable, Equatable {
    /// Where it was found.
    public enum Place: String, Sendable {
        /// The session folder.
        case sessionFolder = "session folder"
        /// The agent's home.
        case agentHome = "agent home"
    }

    /// Where it was found.
    public let place: Place
    /// Relative to its place.
    public let path: String
    /// What it looks like (`CredentialFiles.kinds`); empty for an entry that could not be read.
    public let kinds: [String]

    /// A file.
    public init(place: Place, path: String, kinds: [String]) {
        self.place = place
        self.path = path
        self.kinds = kinds
    }
}

/// What the end-of-session credential scan found.
public struct CredentialScan: Sendable, Equatable {
    /// Changed files that look like credentials.
    public let files: [CredentialFile]
    /// Changed entries the owner cannot read (likely made private by the agent): they may hold anything.
    public let unreadable: [CredentialFile]
    /// Entries looked at.
    public let scanned: Int
    /// The scan stopped at its limit, so there may be more.
    public let incomplete: Bool

    /// A scan result.
    public init(files: [CredentialFile], unreadable: [CredentialFile], scanned: Int, incomplete: Bool) {
        self.files = files
        self.unreadable = unreadable
        self.scanned = scanned
        self.incomplete = incomplete
    }
}
