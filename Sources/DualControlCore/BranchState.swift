/// D13c: where a repository of the session folder stands: its current branch and how far it is ahead of and behind
/// the remote's default branch, as of the last fetch. The owner's git never runs in the agent's repository, so the
/// app runs one fixed script as the agent in READ-ONLY (hooks and fsmonitor off, no optional locks, no system or
/// global config) and parses what it prints as untrusted text.
public struct BranchState: Sendable, Equatable {
    /// The checked-out branch, or `nil` if HEAD is detached.
    public var branch: String?
    /// What it is compared with, e.g. `origin/main`, or `nil` if the repository has no such remote branch.
    public var base: String?
    /// Commits on HEAD that `base` does not have.
    public var ahead: Int?
    /// Commits on `base` that HEAD does not have.
    public var behind: Int?

    /// Creates a state.
    public init(branch: String?, base: String?, ahead: Int? = nil, behind: Int? = nil) {
        self.branch = branch
        self.base = base
        self.ahead = ahead
        self.behind = behind
    }

    /// Seconds the script may take.
    public static let timeoutSeconds = 30

    /// The fixed script; `DC_GIT` is the real git. It prints three lines: `branch <name>`, `base <origin/name>` and
    /// `counts <behind> <ahead>`, each value possibly empty. The base is `origin/HEAD`'s branch, else `origin/main`,
    /// else `origin/master`.
    public static let script = """
        g() {
          "$DC_GIT" --no-optional-locks -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        -c safe.directory="$PWD" "$@"
        }
        branch="$(g symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        base="$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        if [ -z "$base" ]; then
          for name in main master; do
            if g show-ref --verify --quiet "refs/remotes/origin/$name"; then
              base="origin/$name"
              break
            fi
          done
        fi
        counts=""
        if [ -n "$base" ]; then
          counts="$(g rev-list --left-right --count "$base...HEAD" 2>/dev/null || true)"
        fi
        printf 'branch %s\\nbase %s\\ncounts %s\\n' "$branch" "$base" "$counts"
        """

    /// The command line.
    public static func argv() -> [String] {
        ["/bin/sh", "-c", script, "branch_state"]
    }

    /// The state from the script's output, or `nil` if it is not exactly what the script prints. Names that are not
    /// plain branch names are dropped; counts must be plain numbers.
    public static func parse(_ output: String) -> BranchState? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 4, lines[3].isEmpty, lines[0].hasPrefix("branch "), lines[1].hasPrefix("base "),
            lines[2].hasPrefix("counts ")
        else { return nil }
        func plain(_ name: String) -> String? {
            !name.isEmpty && isPlain(name) ? name : nil
        }
        let branch = plain(String(lines[0].dropFirst("branch ".count)))
        var base = String(lines[1].dropFirst("base ".count))
        base = base.hasPrefix("origin/") && plain(String(base.dropFirst("origin/".count))) != nil ? base : ""
        var state = BranchState(branch: branch, base: base.isEmpty ? nil : base)
        let counts = lines[2].dropFirst("counts ".count).split(whereSeparator: { $0 == "\t" || $0 == " " })
        if state.base != nil, counts.count == 2, counts.allSatisfy({ $0.count <= 9 && $0.allSatisfy(\.isASCIIDigit) }),
            let behind = Int(counts[0]), let ahead = Int(counts[1])
        {
            state.behind = behind
            state.ahead = ahead
        }
        return state
    }

    /// One line for the agent and the window, e.g. `claude/x, 2 ahead and 6 behind origin/main`.
    public var summary: String {
        var line = branch.map { "on \($0)" } ?? "HEAD detached"
        guard let base else { return line + ", no origin branch to compare with" }
        if let ahead, let behind {
            if ahead == 0, behind == 0 {
                line += ", up to date with \(base)"
            } else {
                line += ", \(ahead) ahead and \(behind) behind \(base)"
            }
        } else {
            line += ", not comparable with \(base)"
        }
        return line + " (as of the last fetch)"
    }
}

extension BranchState {
    /// True if `name` is a plain branch name (`GitReview.branchProblem`), `main` and `master` included.
    static func isPlain(_ name: String) -> Bool {
        GitReview.branchProblem(name, defaultBranch: nil) == nil
            || (GitReview.protectedBranches.contains(name) && name != "HEAD")
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
