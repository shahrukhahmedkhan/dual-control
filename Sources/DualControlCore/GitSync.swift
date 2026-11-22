/// D13a: `git_sync` keeps a repository of the session folder current with its remote. The agent has no credentials
/// and its own git refuses the owner's repository, so neither can fetch. The app splits the work:
///
/// 1. As the owner (`OwnerPush.syncBundle`): the remote is read from the repository's config file as data, fetched
///    into a fresh scratch repository of the app's (every object checked), and its branches written as a git bundle
///    into the sync folder of the work area, which the agent may read but never write.
/// 2. As the agent, in CHANGING, in the repository's top folder: one fixed script, like `git_commit`'s, with hooks,
///    fsmonitor, signing and automatic gc off, `safe.directory` on the command line and no system or global config.
///    It fetches the bundle into `refs/remotes/origin/*` (pruned; only the file transport) and then does the action.
///    Nothing it does writes config (`--no-track`) or pushes.
///
/// After a rebase (`update`) the owner's push of the agent's branch may replace the remote branch, with
/// `--force-with-lease` and only for `claude/*` branches; nothing else is ever forced.
public enum GitSync {
    /// What `git_sync` does after fetching.
    public enum Action: Sendable, Equatable {
        /// Only fetch.
        case fetch
        /// Fetch, then switch to the agent branch, made from the remote's default branch if it is new.
        case start(branch: String)
        /// Fetch, then rebase the agent branch onto the remote's default branch.
        case update(branch: String)
        /// Fetch, then switch to the default branch and fast-forward it.
        case switchToDefault

        /// The name the tool takes.
        public var name: String {
            switch self {
            case .fetch: return "fetch"
            case .start: return "start"
            case .update: return "update"
            case .switchToDefault: return "default"
            }
        }

        /// The branch it names, or "".
        public var branch: String {
            switch self {
            case .start(let branch), .update(let branch): return branch
            case .fetch, .switchToDefault: return ""
            }
        }
    }

    /// Seconds the agent's part may take.
    public static let timeoutSeconds = 300
    /// Variables added to the command environment: no system or global config, never prompt.
    public static let environment = GitSetup.environment
    /// The folder in the work area that holds the bundles (`SessionScope.gitSync`).
    public static let folderName = "git-sync"
    /// The bundle's file name in its folder.
    public static let bundleName = "origin.bundle"

    /// Exit status: the working tree has uncommitted changes.
    public static let dirtyStatus: Int32 = 3
    /// Exit status: the rebase conflicted and was aborted.
    public static let conflictStatus: Int32 = 4
    /// Exit status: the default branch has commits the remote does not have.
    public static let notFastForwardStatus: Int32 = 5

    /// The fixed script. `$1` is the action, `$2` the branch or "", `$3` and `$4` the name and email a rebase
    /// commits with. `DC_GIT` is the real git, `DC_BUNDLE` the bundle and `DC_DEFAULT` the remote's default branch,
    /// all set by the app. Its last line is HEAD's commit.
    public static let script = """
        set -eu
        action="$1"
        branch="$2"
        name="$3"
        email="$4"
        base="refs/remotes/origin/$DC_DEFAULT"
        g() {
          "$DC_GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c commit.gpgsign=false -c gc.auto=0 \
        -c maintenance.auto=false -c safe.directory="$PWD" -c user.name="$name" -c user.email="$email" "$@"
        }
        clean() {
          changes="$(g status --porcelain --untracked-files=all)"
          if [ -n "$changes" ]; then
            echo "Nothing was switched: the working tree has uncommitted changes. Commit them with git_commit first:"
            printf '%s\\n' "$changes" | head -n 50
            exit 3
          fi
        }
        g -c protocol.allow=never -c protocol.file.allow=always -c fetch.fsckObjects=true fetch --quiet --prune \
        --no-tags --no-write-fetch-head -- "$DC_BUNDLE" "+refs/heads/*:refs/remotes/origin/*"
        g symbolic-ref refs/remotes/origin/HEAD "$base"
        echo "Fetched origin (default branch $DC_DEFAULT)."
        case "$action" in
        fetch) ;;
        start)
          clean
          if g show-ref --verify --quiet "refs/heads/$branch"; then
            g switch --quiet "$branch"
            echo "$branch already exists; switched to it. update rebases it onto origin/$DC_DEFAULT."
          else
            g switch --quiet --no-track --create "$branch" "$base"
            echo "Made $branch from origin/$DC_DEFAULT."
          fi
          ;;
        update)
          clean
          g switch --quiet "$branch"
          before="$(g rev-parse HEAD)"
          if ! g rebase --quiet "$base" >/dev/null 2>&1; then
            files="$(g diff --name-only --diff-filter=U)"
            g rebase --abort
            echo "Rebasing $branch onto origin/$DC_DEFAULT conflicts, so it was aborted; nothing changed. Files:"
            printf '%s\\n' "$files"
            exit 4
          fi
          if [ "$before" = "$(g rev-parse HEAD)" ]; then
            echo "$branch is already on origin/$DC_DEFAULT."
          else
            echo "rebased: yes"
          fi
          ;;
        default)
          clean
          if g show-ref --verify --quiet "refs/heads/$DC_DEFAULT"; then
            g switch --quiet "$DC_DEFAULT"
            if ! g merge --quiet --ff-only "$base" >/dev/null 2>&1; then
              echo "$DC_DEFAULT has commits origin/$DC_DEFAULT does not; it was not changed (no merge commits)."
              exit 5
            fi
          else
            g switch --quiet --no-track --create "$DC_DEFAULT" "$base"
          fi
          ;;
        *) exit 2 ;;
        esac
        echo "branch: $(g symbolic-ref --quiet --short HEAD || echo '(detached)')"
        counts="$(g rev-list --left-right --count "$base...HEAD")"
        set -- $counts
        echo "behind $1, ahead $2 of origin/$DC_DEFAULT"
        g rev-parse HEAD
        """

    /// Why an action was refused.
    public struct Problem: Error, Equatable, CustomStringConvertible {
        /// Why, for the agent.
        public let description: String
    }

    /// The action named `name` with `branch`, or why not: `fetch` and `default` take no branch; `start` and
    /// `update` need an agent branch (`claude/<name>`).
    public static func parse(_ name: String, branch: String?) -> Result<Action, Problem> {
        switch name {
        case "fetch", "default":
            guard branch == nil else { return .failure(Problem(description: "`\(name)` takes no `branch`")) }
            return .success(name == "fetch" ? .fetch : .switchToDefault)
        case "start", "update":
            guard let branch, AgentBranches.isAgentBranch(branch) else {
                return .failure(
                    Problem(description: "`\(name)` needs a `branch` of your own: claude/<name>, plain characters")
                )
            }
            return .success(name == "start" ? .start(branch: branch) : .update(branch: branch))
        default:
            return .failure(Problem(description: "`action` must be fetch, start, update or default"))
        }
    }

    /// The command line: the fixed script with the action, branch and identity as its arguments.
    public static func argv(_ action: Action, name: String, email: String) -> [String] {
        ["/bin/sh", "-c", script, "git_sync", action.name, action.branch, name, email]
    }

    /// The action of a command line from `argv(_:name:email:)`, or `nil` if it is not one.
    public static func action(of argv: [String]) -> Action? {
        guard argv.count == 8, argv.prefix(4) == ["/bin/sh", "-c", script, "git_sync"],
            case .success(let action) = parse(argv[4], branch: argv[5].isEmpty ? nil : argv[5])
        else { return nil }
        return action
    }

    /// True if `argv` is a command line from `argv(_:name:email:)`.
    public static func isSync(_ argv: [String]) -> Bool {
        action(of: argv) != nil
    }

    /// True if `name` is a remote default branch the script may be given: a plain branch name, `main` and `master`
    /// included.
    public static func isDefaultBranch(_ name: String) -> Bool {
        GitReview.branchProblem(name, defaultBranch: nil) == nil
            || (GitReview.protectedBranches.contains(name) && name != "HEAD")
    }

    /// What a successful `update` printed: the commit HEAD is on (the last line), if the rebase moved it.
    public static func rebasedTip(_ output: String) -> String? {
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.contains("rebased: yes"), let tip = lines.last, GitReview.isObjectName(tip) else { return nil }
        return tip
    }
}
