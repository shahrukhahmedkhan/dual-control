import Foundation

/// D12b: the agent's `claude/*` branches. Per repository the owner may let the app push them automatically after a
/// `git_commit` and open a pull request, as the owner (off by default), and caps how many may be open on the remote
/// at once: `git_commit` refuses to start another until one is merged or closed. Once a pull request is merged the app
/// deletes the branch on the remote and in the repository.
public enum AgentBranches {
    /// Every agent branch starts with this.
    public static let prefix = "claude/"
    /// Open agent branches allowed per repository, unless the owner says otherwise.
    public static let defaultCap = 2
    /// The caps the owner may choose.
    public static let capRange = 1...10
    /// The longest pull request title.
    public static let maxTitle = 200
    /// The longest commit message quoted in a pull request.
    public static let maxBody = 10_000

    /// True if `name` is a plain branch name under `claude/`.
    public static func isAgentBranch(_ name: String) -> Bool {
        name.hasPrefix(prefix) && name.count > prefix.count && GitReview.branchProblem(name, defaultBranch: nil) == nil
    }

    /// The agent branches in `git ls-remote --heads` output, sorted, each once.
    public static func parseHeads(_ output: String) -> [String] {
        var names: Set<String> = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2, GitReview.isObjectName(fields[0]), fields[1].hasPrefix("refs/heads/") else {
                continue
            }
            let name = String(fields[1].dropFirst("refs/heads/".count))
            if isAgentBranch(name) { names.insert(name) }
        }
        return names.sorted()
    }

    /// `owner/name` for a remote on github.com, or `nil`. An SSH host other than github.com counts if `resolveHost`
    /// (ssh's own configuration) says it is github.com. `remote` has passed `GitReview.remoteProblem`.
    public static func gitHubSlug(remote: String, resolveHost: (String) -> String?) -> String? {
        let host: Substring
        var path: Substring
        if remote.hasPrefix("https://") {
            let rest = remote.dropFirst("https://".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = rest[..<slash]
            path = rest[rest.index(after: slash)...]
        } else if remote.hasPrefix("ssh://") {
            let rest = remote.dropFirst("ssh://".count)
            guard let slash = rest.firstIndex(of: "/"), let at = rest[..<slash].firstIndex(of: "@") else { return nil }
            host = rest[rest.index(after: at)..<slash].split(separator: ":").first ?? ""
            path = rest[rest.index(after: slash)...]
        } else {
            guard let at = remote.firstIndex(of: "@"), let colon = remote[at...].firstIndex(of: ":") else { return nil }
            host = remote[remote.index(after: at)..<colon]
            path = remote[remote.index(after: colon)...]
        }
        guard host == "github.com" || (remote.hasPrefix("https://") ? false : resolveHost(String(host)) == "github.com")
        else { return nil }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.count == 2,
            parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && $0.allSatisfy(allowed.contains) })
        else { return nil }
        return parts.joined(separator: "/")
    }

    /// The pull request's title: the commit's first line, at most `maxTitle` characters.
    public static func pullRequestTitle(_ message: String) -> String {
        let first = message.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return first.isEmpty ? "Agent changes" : String(first.prefix(maxTitle))
    }

    /// The pull request's body: who opened it and why, then the commit message quoted in a fence longer than any
    /// run of backticks in it, so none of the agent's text is rendered (no mentions, links or images).
    public static func pullRequestBody(_ message: String, branch: String) -> String {
        let quoted = String(message.prefix(maxBody))
        var longest = 0
        var run = 0
        for character in quoted {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let text = quoted.hasSuffix("\n") ? quoted : quoted + "\n"
        return """
            Opened by Dual Control for the agent's branch `\(branch)`, pushed and re-signed as you. Review it \
            before merging; Dual Control never merges.

            The agent's commit message:

            \(fence)
            \(text)\(fence)
            """
    }

    /// A pull request's state, as `gh` reports it.
    public enum PullRequestState: String, Sendable, Equatable {
        /// Waiting for review.
        case open = "OPEN"
        /// Closed without merging.
        case closed = "CLOSED"
        /// Merged.
        case merged = "MERGED"
    }

    /// The state of `branch`'s pull requests in `gh pr list --json state,headRefName,isCrossRepository` output, or
    /// `nil` if it has none: open if one is open, else merged if one was merged, else closed. Pull requests from
    /// forks are ignored.
    public static func pullRequestState(listJSON: String, branch: String) -> PullRequestState? {
        struct Entry: Decodable {
            let state: String
            let headRefName: String
            let isCrossRepository: Bool
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: Data(listJSON.utf8)) else { return nil }
        let states = Set(
            entries.filter { $0.headRefName == branch && !$0.isCrossRepository }.compactMap {
                PullRequestState(rawValue: $0.state)
            }
        )
        return [.open, .merged, .closed].first(where: states.contains)
    }

    /// True if a branch whose pull requests are in `state` counts against the cap: none yet, or one open.
    public static func countsAsOpen(_ state: PullRequestState?) -> Bool {
        state == nil || state == .open
    }

    /// The fixed script that deletes a merged agent branch in the repository, run as the agent like `git_commit`
    /// (hooks and fsmonitor off, no global config). `$1` is the branch; if it is checked out, HEAD is first detached
    /// at the same commit, which leaves the working tree as it is. `DC_GIT` is the real git.
    public static let deleteScript = """
        set -eu
        branch="$1"
        g() {
          "$DC_GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c safe.directory="$PWD" "$@"
        }
        if [ "$(g symbolic-ref --quiet HEAD 2>/dev/null || true)" = "refs/heads/$branch" ]; then
          g switch --quiet --detach
        fi
        g branch --quiet -D "$branch"
        """

    /// The command line that deletes `branch` (an agent branch) in a repository.
    public static func deleteArgv(branch: String) -> [String] {
        ["/bin/sh", "-c", deleteScript, "delete_branch", branch]
    }

    /// The `git_commit` refusal at the cap.
    static func capRefusal(repository: String, open: [String], cap: Int) -> String {
        "\(open.count) of \(cap) agent branches are open on the remote of "
            + "\(DisplayText.escaped(name(of: repository))) (\(shown(open))): merge or close one "
            + "first; committing to one of them is fine"
    }

    /// One line for the agent: how many agent branches are open and the cap.
    static func note(open: [String], policy: RepositoryPolicy) -> String {
        var line = "Agent branches open on the remote: \(open.count) of \(policy.maxOpenBranches)"
        if !open.isEmpty { line += " (\(shown(open)))" }
        line +=
            policy.autoPush
            ? ". claude/* branches are pushed automatically and get a pull request."
            : ". The owner reviews and pushes."
        return line
    }

    /// A repository's folder name.
    static func name(of repository: String) -> String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }

    private static func shown(_ branches: [String]) -> String {
        branches.map(DisplayText.escaped).joined(separator: ", ")
    }
}

/// What the owner chose for one repository (D12b).
public struct RepositoryPolicy: Sendable, Equatable, Codable {
    /// Push the agent's `claude/*` branches automatically after `git_commit` and open a pull request.
    public var autoPush: Bool
    /// Open agent branches allowed on the remote; clamped to `AgentBranches.capRange`.
    public var maxOpenBranches: Int {
        didSet { maxOpenBranches = Self.clamped(maxOpenBranches) }
    }

    /// Creates a policy; the defaults are auto-push off and a cap of `AgentBranches.defaultCap`.
    public init(autoPush: Bool = false, maxOpenBranches: Int = AgentBranches.defaultCap) {
        self.autoPush = autoPush
        self.maxOpenBranches = Self.clamped(maxOpenBranches)
    }

    /// Decodes a saved policy, clamping its cap.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoPush = try container.decode(Bool.self, forKey: .autoPush)
        maxOpenBranches = Self.clamped(try container.decode(Int.self, forKey: .maxOpenBranches))
    }

    private static func clamped(_ cap: Int) -> Int {
        min(max(cap, AgentBranches.capRange.lowerBound), AgentBranches.capRange.upperBound)
    }

    var description: String {
        "auto-push \(autoPush ? "on" : "off"), at most \(maxOpenBranches) open agent branches"
    }
}
