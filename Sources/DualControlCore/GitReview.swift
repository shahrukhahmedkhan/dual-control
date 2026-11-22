import Foundation

/// D11 phase 3, the agent's side: `git_commit` commits everything in a repository of the session folder. Git refuses
/// a repository owned by another user, and CHANGING keeps hooks and config unwritable, so the agent cannot commit with
/// its own git; the app runs one fixed script instead, as the agent, in CHANGING, in the repository's top folder:
/// `git add -A` then `git commit`, with hooks, fsmonitor and signing off, `safe.directory` given on the command line,
/// no system or global config (nothing from the agent's home) and the owner's name and email. The commit stays
/// local and lands in the owner's review queue (`GitReview`); nothing the agent runs can push it.
public enum GitCommit {
    /// Seconds a commit may take.
    public static let timeoutSeconds = 120
    /// The longest message accepted.
    public static let maxMessageBytes = 4000
    /// The identity used when the owner's is unknown.
    public static let agentName = "Claude (Dual Control agent)"
    /// The email used when the owner's is unknown.
    public static let agentEmail = "claude-agent@dual-control.invalid"
    /// Variables added to the command environment: no system or global config, never prompt.
    public static let environment = GitSetup.environment

    /// The fixed script. `$1` is the message, `$2` and `$3` the name and email, `$4` a branch to switch to (made if
    /// missing) or empty; `DC_GIT` is the real git.
    public static let script = """
        set -eu
        message="$1"
        name="$2"
        email="$3"
        branch="$4"
        g() {
          "$DC_GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c commit.gpgsign=false \
        -c safe.directory="$PWD" -c user.name="$name" -c user.email="$email" "$@"
        }
        if [ -n "$branch" ]; then
          g switch --quiet "$branch" 2>/dev/null || g switch --quiet --create "$branch"
        fi
        g add -A -- .
        g commit --no-verify --quiet -m "$message"
        g rev-parse HEAD
        """

    /// The command line: the fixed script with the message, identity and branch (or "") as its arguments.
    public static func argv(message: String, name: String, email: String, branch: String = "") -> [String] {
        ["/bin/sh", "-c", script, "git_commit", message, name, email, branch]
    }

    /// True if `argv` is a command line from `argv(message:name:email:branch:)`.
    public static func isCommit(_ argv: [String]) -> Bool {
        argv.count == 8 && argv.prefix(4) == ["/bin/sh", "-c", script, "git_commit"]
    }

    /// Why `message` cannot be a commit message, or `nil`: not empty, at most `maxMessageBytes`, printable text
    /// (newlines and tabs allowed).
    public static func messageProblem(_ message: String) -> String? {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            message.utf8.count <= maxMessageBytes
        else { return "`message` must be 1 to \(maxMessageBytes) bytes of text" }
        guard
            !message.unicodeScalars.contains(where: {
                ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || $0.value == 0x7F
            })
        else { return "`message` may not contain control characters" }
        return nil
    }

    /// True if `name` and `email` can be passed as a git identity: short, printable, an email with one `@`.
    public static func isIdentity(name: String, email: String) -> Bool {
        func printable(_ text: String) -> Bool {
            text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && $0 != "<" && $0 != ">" }
        }
        return (1...200).contains(name.utf8.count) && printable(name) && (3...254).contains(email.utf8.count)
            && printable(email) && !email.contains(" ") && email.filter({ $0 == "@" }).count == 1
    }
}

/// D11 phase 3, the owner's side: the rules for reviewing and pushing the agent's commits. The owner's git never runs
/// in the agent's repository (its config could name programs to run). The app fetches the branch from it over
/// `file://` into a fresh repository of its own (objects checked), reads the remote's state, shows the commits the
/// remote does not have, and on the owner's click re-signs them there with the owner's key and pushes that branch, as
/// the owner. Never the default branch, never by force, never automatically.
public enum GitReview {
    /// What the remote has, from `git ls-remote --symref <remote> HEAD refs/heads/<branch>`.
    public struct RemoteState: Sendable, Equatable {
        /// The remote's default branch, if it says.
        public var defaultBranch: String?
        /// Its tip.
        public var defaultTip: String?
        /// The branch's tip there, if it exists.
        public var branchTip: String?
    }

    /// Branch names never pushed, whatever the remote's default is.
    public static let protectedBranches: Set<String> = ["main", "master", "HEAD"]

    /// Why `url` is not a remote the owner's push may use, or `nil`: `https://host/path` without credentials,
    /// `user@host:path` or `ssh://user@host[:port]/path`, plain characters only.
    public static func remoteProblem(_ url: String) -> String? {
        if url.hasPrefix("https://") { return GitSetup.urlProblem(url).map { "the remote: " + $0 } }
        let name = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let pathCharacters = name.union("/~")
        func plainPath<S: StringProtocol>(_ path: S) -> Bool {
            !path.isEmpty && !path.hasPrefix("-") && path.allSatisfy(pathCharacters.contains)
                && !path.split(separator: "/").contains("..")
        }
        func plainHost<S: StringProtocol>(_ host: S) -> Bool {
            !host.isEmpty && !host.hasPrefix("-") && host.allSatisfy(name.contains)
        }
        var rest = Substring(url)
        if rest.hasPrefix("ssh://") {
            rest = rest.dropFirst(6)
            guard let slash = rest.firstIndex(of: "/"), let at = rest[..<slash].firstIndex(of: "@") else {
                return "the remote must name a user, a host and a path"
            }
            let user = rest[..<at]
            var host = rest[rest.index(after: at)..<slash]
            if let colon = host.firstIndex(of: ":") {
                let port = host[host.index(after: colon)...]
                guard (1...5).contains(port.count), port.allSatisfy({ ("0"..."9").contains($0) }) else {
                    return "the remote's port is not a number"
                }
                host = host[..<colon]
            }
            guard plainHost(user), plainHost(host), plainPath(rest[rest.index(after: slash)...]) else {
                return "the remote may only hold plain names"
            }
            return nil
        }
        guard let at = rest.firstIndex(of: "@"), let colon = rest[at...].firstIndex(of: ":") else {
            return "only https://, ssh:// and user@host:path remotes are pushed to"
        }
        guard plainHost(rest[..<at]), plainHost(rest[rest.index(after: at)..<colon]),
            plainPath(rest[rest.index(after: colon)...])
        else { return "the remote may only hold plain names" }
        return nil
    }

    /// Why `branch` may not be pushed, or `nil`: a plain branch name that is not the remote's default, `main` or
    /// `master`.
    public static func branchProblem(_ branch: String, defaultBranch: String?) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        let parts = branch.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...200).contains(branch.count), branch.allSatisfy(allowed.contains), !branch.hasPrefix("-"),
            !branch.contains(".."), !branch.hasSuffix(".lock"),
            parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") })
        else { return "\(DisplayText.escaped(branch)) is not a plain branch name" }
        guard !protectedBranches.contains(branch), branch != defaultBranch else {
            return "\(branch) is the default branch; the agent's work is pushed to its own branch only"
        }
        return nil
    }

    /// The remote's state for `branch` from `ls-remote --symref` output.
    public static func parseLsRemote(_ output: String, branch: String) -> RemoteState {
        var state = RemoteState()
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            if fields[0].hasPrefix("ref: refs/heads/"), fields[1] == "HEAD" {
                state.defaultBranch = String(fields[0].dropFirst("ref: refs/heads/".count))
            } else if isObjectName(fields[0]) {
                if fields[1] == "HEAD" { state.defaultTip = fields[0] }
                if fields[1] == "refs/heads/" + branch { state.branchTip = fields[0] }
            }
        }
        return state
    }

    /// The branch a repository's `.git/HEAD` text names, or `nil` if it is detached or not a branch.
    public static func branch(fromHEAD text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else { return nil }
        let branch = String(line.dropFirst(prefix.count))
        return branchProblem(branch, defaultBranch: nil) == nil || protectedBranches.contains(branch) ? branch : nil
    }

    /// True if `text` is a full SHA-1 or SHA-256 object name in lowercase hex.
    public static func isObjectName(_ text: String) -> Bool {
        [40, 64].contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// A repository branch with commits from `git_commit` waiting for the owner.
public struct ReviewItem: Sendable, Equatable, Identifiable {
    /// Stable for this session.
    public let id: Int
    /// The repository's top folder.
    public let repository: String
    /// The branch the commits are on.
    public let branch: String
    /// The newest commit queued.
    public var commit: String
    /// When it was last queued.
    public var queuedAt: Date
    /// A `git_sync update` rebased it since it was last pushed: the push replaces the remote branch with a lease.
    public var rebased = false
}
