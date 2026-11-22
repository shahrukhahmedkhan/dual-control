#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    @testable import DualControlCore
    @testable import DualControlSandbox

    /// D11 phase 3 with real git: the agent commits through `git_commit` in CHANGING, the owner reviews and pushes,
    /// re-signed with an SSH key, to a local bare "remote". The kernel enforces the profiles for any user, so the tests
    /// run as the test user.
    ///
    ///     <base>/remote.git                 the remote (default branch main)
    ///     <base>/home/Developer/p/repo      the owner's clone, the session folder's repository
    ///     <base>/owner/gitconfig            the owner's git config (HOME is <base>/owner)
    ///     <base>/owner/.ssh/key             the owner's signing key
    private final class Fixture {
        let base: String
        let scope: SessionScope
        let sandbox: Sandbox
        let git: String
        let repo: String
        let remote: String
        let key: String
        let ownerEnvironment: [String: String]
        let push: OwnerPush

        /// `globalSigning` false: the owner's global config names no signing key (the owner sets it per repository).
        init(globalSigning: Bool = true) throws {
            var template = Array("/tmp/dc-test-XXXXXX".utf8CString)
            let made = try #require(mkdtemp(&template).map { String(cString: $0) })
            base = try #require(RealPath.resolve(made))
            git = try #require(Toolchain.git())
            for folder in [
                "/home/Developer/p", "/home/Developer/.dual-control/agent-home", "/home/Developer/.dual-control/tmp",
                "/owner/.ssh", "/scratch",
            ] {
                try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
            }
            scope = try ResolvedScope.make(choosing: base + "/home/Developer/p", ceiling: base + "/home/Developer")
            sandbox = Sandbox(scope: scope, toolchains: Toolchain.readPaths())
            repo = scope.root + "/repo"
            remote = base + "/remote.git"
            key = base + "/owner/.ssh/key"
            _ = Subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "owner", "-f", key])
            let signing = globalSigning ? "\tsigningkey = \(key)\n[gpg]\n\tformat = ssh\n" : ""
            try Data(
                """
                [user]
                \tname = Owner Name
                \temail = owner@example.invalid
                \(signing)[init]
                \tdefaultBranch = main

                """.utf8
            ).write(to: URL(fileURLWithPath: base + "/owner/gitconfig"))
            ownerEnvironment = [
                "GIT_CONFIG_GLOBAL": base + "/owner/gitconfig", "GIT_CONFIG_NOSYSTEM": "1", "HOME": base + "/owner",
            ]
            push = OwnerPush(
                git: git,
                scratch: base + "/scratch",
                mapFile: base + "/owner/map.json",
                extraEnvironment: ownerEnvironment,
                allowFileRemotes: true
            )
            try owner(["init", "--bare", "--quiet", remote])
            try owner(["clone", "--quiet", remote, repo])
            try write("hello\n", "README")
            try owner(["-C", repo, "add", "README"])
            try owner(["-C", repo, "commit", "--quiet", "-m", "first"])
            try owner(["-C", repo, "push", "--quiet", "origin", "main"])
        }

        deinit {
            try? FileManager.default.removeItem(atPath: base)
        }

        /// The owner's git, as the test user, with the owner's config.
        @discardableResult
        func owner(_ arguments: [String]) throws -> String {
            let result = try #require(push.run(arguments))
            try #require(result.status == 0, "git \(arguments.joined(separator: " ")) failed")
            return result.out
        }

        func write(_ text: String, _ name: String) throws {
            try Data(text.utf8).write(to: URL(fileURLWithPath: repo + "/" + name))
        }

        /// A `git_commit` as `Supervisor.begin` launches it, run by the agent's runner.
        func agentCommit(_ message: String, branch: String = "") throws -> CommandOutcome {
            let request = ActionRequest(
                capability: .command,
                argv: GitCommit.argv(
                    message: message,
                    name: "Owner Name",
                    email: "owner@example.invalid",
                    branch: branch
                ),
                cwd: repo,
                projectID: repo,
                timeoutSeconds: 60
            )
            let decision = Decision(verdict: .allow, reason: "test", ruleID: "test")
            let execution = Execution(id: "c1", tool: "git_commit", request: request, decision: decision, scope: scope)
            let launch = Launch(
                execution: execution,
                scope: scope,
                readOnly: false,
                serialPort: nil,
                timeoutSeconds: 60,
                gitCommit: true
            )
            return try sandbox.start(launch).wait()
        }

        /// A `git_sync` as the app runs it: the owner's bundle, then the agent's script; the bundle is removed after.
        func agentSync(_ action: GitSync.Action) throws -> CommandOutcome {
            #expect(OwnerPush.prepareSyncFolder(scope.gitSync, denyACLUser: nil) == nil)
            let bundle = try push.syncBundle(repository: repo, root: scope.gitSync).get()
            defer { push.discard(bundle) }
            let request = ActionRequest(
                capability: .command,
                argv: GitSync.argv(action, name: "Owner Name", email: "owner@example.invalid"),
                cwd: repo,
                projectID: repo,
                timeoutSeconds: 60
            )
            let decision = Decision(verdict: .allow, reason: "test", ruleID: "test")
            let execution = Execution(id: "s1", tool: "git_sync", request: request, decision: decision, scope: scope)
            var launch = Launch(
                execution: execution,
                scope: scope,
                readOnly: false,
                serialPort: nil,
                timeoutSeconds: 60
            )
            launch.gitSync = action
            return try sandbox.start(launch, sync: bundle).wait()
        }

        /// A commit on the remote's `branch` (default main) from another clone of the owner's.
        func upstream(_ text: String, _ name: String, branch: String = "main") throws {
            let other = base + "/upstream"
            if !FileManager.default.fileExists(atPath: other) { try owner(["clone", "--quiet", remote, other]) }
            try owner(["-C", other, "fetch", "--quiet", "origin"])
            try owner(["-C", other, "checkout", "--quiet", "-B", branch, "origin/" + branch])
            try Data(text.utf8).write(to: URL(fileURLWithPath: other + "/" + name))
            try owner(["-C", other, "add", name])
            try owner(["-C", other, "commit", "--quiet", "-m", "upstream " + name])
            try owner(["-C", other, "push", "--quiet", "origin", branch])
        }

        func tip(_ ref: String, remote: Bool = false) throws -> String {
            try owner((remote ? ["--git-dir", self.remote] : ["-C", repo]) + ["rev-parse", ref])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test func theAgentCommitsWithHooksAndSigningOffAndCannotTouchConfig() throws {
        let f = try Fixture()
        // The owner's repository would run a hook and sign; the agent's commit does neither.
        try Data("#!/bin/sh\ntouch '\(f.base)/hook-ran'\n".utf8).write(
            to: URL(fileURLWithPath: f.repo + "/.git/hooks/pre-commit")
        )
        chmod(f.repo + "/.git/hooks/pre-commit", 0o755)
        try f.owner(["-C", f.repo, "config", "commit.gpgsign", "true"])
        try f.write("hello world\n", "README")
        try f.write("new\n", "NEW.txt")
        // The agent makes its own branch with the tool; main stays where it was.
        let outcome = try f.agentCommit("Agent change", branch: "claude/fix")
        #expect(outcome.status == 0, "\(outcome.output)")
        #expect(try f.owner(["-C", f.repo, "rev-parse", "--abbrev-ref", "HEAD"]) == "claude/fix\n")
        #expect(try f.owner(["-C", f.repo, "log", "--format=%s", "main"]) == "first\n")
        // Committing again on the same branch switches to it, then commits.
        try f.write("more\n", "NEW.txt")
        #expect(try f.agentCommit("Second", branch: "claude/fix").status == 0)
        try f.owner(["-C", f.repo, "reset", "--quiet", "--soft", "HEAD~1"])
        #expect(GitReview.isObjectName(outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!FileManager.default.fileExists(atPath: f.base + "/hook-ran"))
        let log = try f.owner(["-C", f.repo, "log", "-1", "--format=%an <%ae>|%s|%G?"])
        #expect(log.trimmingCharacters(in: .newlines) == "Owner Name <owner@example.invalid>|Agent change|N")
        #expect(try f.owner(["-C", f.repo, "show", "--name-only", "--format=", "HEAD"]).contains("NEW.txt"))
        // Still nothing the agent runs can change the repository's config.
        let run = try f.sandbox.run(
            ["/bin/sh", "-c", "echo '[core]' >> '\(f.repo)/.git/config'"],
            kind: .changing,
            cwd: f.repo
        )
        #expect(run.status != 0 && run.output.contains("Operation not permitted"))
    }

    @Test func theOwnerReviewsThenPushesTheBranchReSignedAndLaterPushesFastForward() throws {
        let f = try Fixture()
        try f.owner(["-C", f.repo, "checkout", "--quiet", "-b", "claude/fix"])
        try f.write("hello world\n", "README")
        #expect(try f.agentCommit("Change one").status == 0)

        let review = try f.push.review(repository: f.repo, branch: "claude/fix").get()
        #expect(review.commits.count == 1 && review.remoteTip == nil)
        #expect(review.log.contains("Change one") && review.diff.contains("+hello world"))
        #expect(review.stat.contains("README"))
        let tip = try f.push.push(review).get()
        #expect(!FileManager.default.fileExists(atPath: review.id), "the scratch repository is removed")

        let pushed = try f.owner(["--git-dir", f.remote, "cat-file", "commit", "refs/heads/claude/fix"])
        #expect(pushed.contains("gpgsig -----BEGIN SSH SIGNATURE-----"), "\(pushed)")
        #expect(try f.owner(["--git-dir", f.remote, "rev-parse", "refs/heads/claude/fix"]).hasPrefix(tip))
        #expect(pushed.contains("author Owner Name <owner@example.invalid>") && pushed.hasSuffix("Change one\n"))
        // Same tree as the agent's commit.
        let agentTree = try f.owner(["-C", f.repo, "rev-parse", "HEAD^{tree}"])
        #expect(try f.owner(["--git-dir", f.remote, "rev-parse", "refs/heads/claude/fix^{tree}"]) == agentTree)

        // The next commit: only it is shown, and the push fast-forwards the signed branch.
        try f.write("third\n", "THIRD")
        #expect(try f.agentCommit("Change two").status == 0)
        let next = try f.push.review(repository: f.repo, branch: "claude/fix").get()
        #expect(next.commits.count == 1 && next.log.contains("Change two") && !next.log.contains("Change one"))
        #expect(next.diff.contains("+third") && !next.diff.contains("hello world"))
        let second = try f.push.push(next).get()
        let parent = try f.owner(["--git-dir", f.remote, "rev-parse", "refs/heads/claude/fix^"])
        #expect(parent.hasPrefix(tip) && second != tip)
        // main is untouched.
        #expect(try f.owner(["--git-dir", f.remote, "log", "--format=%s", "main"]) == "first\n")
    }

    @Test func theDefaultBranchIsNeverReviewedOrPushed() throws {
        let f = try Fixture()
        try f.write("x\n", "README")
        #expect(try f.agentCommit("On main").status == 0)
        for branch in ["main", "master"] {
            guard case .failure(let problem) = f.push.review(repository: f.repo, branch: branch) else {
                Issue.record("\(branch) was reviewed")
                continue
            }
            #expect(problem.description.contains("default branch"))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: f.base + "/scratch")
        #expect(names.isEmpty)
    }

    @Test func aRemoteThatRunsCodeOrBorrowedObjectsAreRefused() throws {
        let f = try Fixture()
        try f.owner(["-C", f.repo, "checkout", "--quiet", "-b", "claude/fix"])
        try f.write("x\n", "README")
        #expect(try f.agentCommit("c").status == 0)
        let marker = f.base + "/ext-ran"
        try f.owner(["-C", f.repo, "remote", "set-url", "origin", "ext::sh -c touch% \(marker)"])
        guard case .failure = f.push.review(repository: f.repo, branch: "claude/fix") else {
            Issue.record("an ext:: remote was used")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: marker))

        try f.owner(["-C", f.repo, "remote", "set-url", "origin", f.remote])
        try Data((f.remote + "/objects\n").utf8).write(
            to: URL(fileURLWithPath: f.repo + "/.git/objects/info/alternates")
        )
        guard case .failure(let problem) = f.push.review(repository: f.repo, branch: "claude/fix") else {
            Issue.record("alternates were followed")
            return
        }
        #expect(problem.description.contains("alternates"))
    }

    @Test func nothingNewMeansNothingToPush() throws {
        let f = try Fixture()
        try f.owner(["-C", f.repo, "checkout", "--quiet", "-b", "claude/fix"])
        guard case .failure(let problem) = f.push.review(repository: f.repo, branch: "claude/fix") else {
            Issue.record("an empty review")
            return
        }
        #expect(problem.description.contains("already has everything"))
    }

    // MARK: - F1: signing as the owner's git does in the repository

    /// The agent's commit on `claude/fix`, reviewed.
    private func reviewed(_ f: Fixture) throws -> OwnerPush.Review {
        try f.write("hello world\n", "README")
        #expect(try f.agentCommit("Change one", branch: "claude/fix").status == 0)
        return try f.push.review(repository: f.repo, branch: "claude/fix").get()
    }

    @Test func withoutAGlobalKeyTheRepositorysSSHKeyIsUsedButNeverItsProgram() throws {
        let f = try Fixture(globalSigning: false)
        try f.owner(["-C", f.repo, "config", "gpg.format", "ssh"])
        try f.owner(["-C", f.repo, "config", "user.signingkey", "~/.ssh/key.pub"])
        let marker = f.base + "/program-ran"
        let program = f.base + "/owner/program"
        try Data("#!/bin/sh\ntouch '\(marker)'\nexit 1\n".utf8).write(to: URL(fileURLWithPath: program))
        chmod(program, 0o755)
        try f.owner(["-C", f.repo, "config", "gpg.ssh.program", program])

        let tip = try f.push.push(try reviewed(f)).get()
        let pushed = try f.owner(["--git-dir", f.remote, "cat-file", "commit", "refs/heads/claude/fix"])
        #expect(pushed.contains("gpgsig -----BEGIN SSH SIGNATURE-----"), "\(pushed)")
        #expect(try f.owner(["--git-dir", f.remote, "rev-parse", "refs/heads/claude/fix"]).hasPrefix(tip))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func aRepositorySigningKeyThatIsNotAnSSHKeyFileOfTheOwnersIsRefused() throws {
        let f = try Fixture(globalSigning: false)
        _ = try reviewed(f)
        // A push removes its review either way; each try reviews again.
        func review() throws -> OwnerPush.Review { try f.push.review(repository: f.repo, branch: "claude/fix").get() }
        // A key the agent could have made, reached directly, through `..` and through a link in ~/.ssh.
        let elsewhere = f.repo + "/agent-key"
        _ = Subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "agent", "-f", elsewhere])
        let link = f.base + "/owner/.ssh/link.pub"
        #expect(symlink(elsewhere + ".pub", link) == 0)
        try f.owner(["-C", f.repo, "config", "gpg.format", "ssh"])
        for key in [elsewhere + ".pub", f.base + "/owner/.ssh/../../home/Developer/p/repo/agent-key.pub", link] {
            try f.owner(["-C", f.repo, "config", "user.signingkey", key])
            guard case .failure(let problem) = f.push.push(try review()) else {
                Issue.record("\(key) was used")
                continue
            }
            #expect(problem.description.contains("not an SSH key file of yours in ~/.ssh"), "\(problem)")
        }
        // Not SSH signing.
        try f.owner(["-C", f.repo, "config", "user.signingkey", f.key + ".pub"])
        try f.owner(["-C", f.repo, "config", "gpg.format", "openpgp"])
        guard case .failure(let problem) = f.push.push(try review()) else {
            Issue.record("openpgp was used")
            return
        }
        #expect(problem.description.contains("not an SSH key file of yours"), "\(problem)")
        #expect(try f.owner(["--git-dir", f.remote, "branch", "--list", "claude/fix"]).isEmpty)
    }

    @Test func withNoSigningKeyAnywhereThePushSaysWhatToSet() throws {
        let f = try Fixture(globalSigning: false)
        guard case .failure(let problem) = f.push.push(try reviewed(f)) else {
            Issue.record("pushed unsigned")
            return
        }
        #expect(problem.description.contains("no SSH signing key"), "\(problem)")
        #expect(problem.description.contains("git config --global user.signingkey"), "\(problem)")
    }

    @Test func aSigningFailureShowsGitsOwnError() throws {
        let f = try Fixture(globalSigning: false)
        let bogus = f.base + "/owner/.ssh/bogus.pub"
        try Data("not a key\n".utf8).write(to: URL(fileURLWithPath: bogus))
        try f.owner(["-C", f.repo, "config", "gpg.format", "ssh"])
        try f.owner(["-C", f.repo, "config", "user.signingkey", bogus])
        guard case .failure(let problem) = f.push.push(try reviewed(f)) else {
            Issue.record("pushed")
            return
        }
        #expect(problem.description.contains("could not be signed with your key: "), "\(problem)")
        #expect(problem.description.contains("bogus.pub"), "git's error names the key: \(problem)")
        #expect(!problem.description.contains("\n"), "one escaped line")
    }

    // MARK: - D12b

    @Test func agentBranchesOnTheRemoteAreCountedAndAMergedOneIsDeletedThereAndLocally() throws {
        let f = try Fixture()
        try f.write("hello world\n", "README")
        #expect(try f.agentCommit("Change one", branch: "claude/fix").status == 0)
        let review = try f.push.review(repository: f.repo, branch: "claude/fix").get()
        #expect(review.defaultBranch == "main")
        _ = try f.push.push(review).get()
        try f.owner(["--git-dir", f.remote, "branch", "feature/other", "main"])

        let remote = try f.push.origin(of: f.repo).get()
        #expect(try f.push.agentBranches(on: remote).get() == ["claude/fix"])
        // Only agent branches are ever deleted on the remote.
        #expect(f.push.deleteAgentBranch("main", on: remote) != nil)
        #expect(f.push.deleteAgentBranch("feature/other", on: remote) != nil)
        #expect(f.push.deleteAgentBranch("claude/fix", on: remote) == nil)
        #expect(try f.push.agentBranches(on: remote).get().isEmpty)
        #expect(try f.owner(["--git-dir", f.remote, "branch", "--list"]).contains("feature/other"))

        // Locally, as the agent: HEAD is on the branch, so it is detached at the same commit first.
        let head = try f.owner(["-C", f.repo, "rev-parse", "HEAD"])
        #expect(f.sandbox.deleteAgentBranch("claude/fix", in: f.repo))
        #expect(try f.owner(["-C", f.repo, "branch", "--list", "claude/fix"]).isEmpty)
        #expect(try f.owner(["-C", f.repo, "rev-parse", "HEAD"]) == head)
        #expect(
            String(decoding: FileManager.default.contents(atPath: f.repo + "/README") ?? Data(), as: UTF8.self)
                == "hello world\n"
        )
        #expect(!f.sandbox.deleteAgentBranch("main", in: f.repo))
        #expect(try f.owner(["-C", f.repo, "branch", "--list", "main"]).contains("main"))
    }

    // MARK: - D13a: git_sync

    @Test func syncFetchesThroughTheOwnersBundleAndStartBranchesFromTheLatestDefault() throws {
        let f = try Fixture()
        try f.upstream("new upstream\n", "UP.txt")
        // The working tree is behind; start makes the branch from the remote's default, not from HEAD.
        let started = try f.agentSync(.start(branch: "claude/new"))
        #expect(started.status == 0, "\(started.output)")
        #expect(try f.tip("refs/remotes/origin/main") == f.tip("refs/heads/main", remote: true))
        #expect(
            try f.owner(["-C", f.repo, "symbolic-ref", "refs/remotes/origin/HEAD"]) == "refs/remotes/origin/main\n"
        )
        #expect(try f.owner(["-C", f.repo, "rev-parse", "--abbrev-ref", "HEAD"]) == "claude/new\n")
        #expect(try f.tip("HEAD") == f.tip("refs/heads/main", remote: true))
        #expect(FileManager.default.fileExists(atPath: f.repo + "/UP.txt"))
        #expect(started.output.contains("behind 0, ahead 0 of origin/main"))
        #expect(started.output.split(separator: "\n").last.map(String.init) == (try f.tip("HEAD")))
        // No tracking config was written; the local main did not move; the bundle is gone.
        #expect(try f.push.run(["-C", f.repo, "config", "--get", "branch.claude/new.remote"])?.status == 1)
        #expect(try f.tip("main") != f.tip("refs/heads/main", remote: true))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.scope.gitSync).isEmpty)
        // Starting it again switches to it.
        let again = try f.agentSync(.start(branch: "claude/new"))
        #expect(again.status == 0 && again.output.contains("already exists"), "\(again.output)")
    }

    @Test func theAgentCannotWriteTheSyncFolder() throws {
        let f = try Fixture()
        #expect(OwnerPush.prepareSyncFolder(f.scope.gitSync, denyACLUser: nil) == nil)
        let run = try f.sandbox.run(
            ["/bin/sh", "-c", "mkdir '\(f.scope.gitSync)/sync-planted' && ln -s /tmp '\(f.scope.gitSync)/x'"],
            kind: .changing,
            cwd: f.repo
        )
        #expect(run.status != 0 && run.output.contains("Operation not permitted"), "\(run.output)")
        // A folder in its place that is not the owner's is refused (here: a link).
        try FileManager.default.removeItem(atPath: f.scope.gitSync)
        #expect(symlink(f.base + "/scratch", f.scope.gitSync) == 0)
        #expect(OwnerPush.prepareSyncFolder(f.scope.gitSync, denyACLUser: nil) != nil)
        guard case .failure = f.push.syncBundle(repository: f.repo, root: f.scope.gitSync) else {
            Issue.record("a bundle was written through a link")
            return
        }
    }

    @Test func syncRefusesUncommittedChangesAndNamesThem() throws {
        let f = try Fixture()
        try f.write("changed\n", "README")
        try f.write("new\n", "UNTRACKED.txt")
        for action: GitSync.Action in [.start(branch: "claude/x"), .update(branch: "claude/x"), .switchToDefault] {
            let outcome = try f.agentSync(action)
            #expect(outcome.status == GitSync.dirtyStatus, "\(action): \(outcome.output)")
            #expect(outcome.output.contains("README") && outcome.output.contains("UNTRACKED.txt"))
            #expect(try f.owner(["-C", f.repo, "rev-parse", "--abbrev-ref", "HEAD"]) == "main\n")
        }
        // A plain fetch does not mind.
        #expect(try f.agentSync(.fetch).status == 0)
    }

    @Test func updateRebasesOntoTheDefaultAndOnlyALeasedPushReplacesTheAgentBranch() throws {
        let f = try Fixture()
        try f.write("agent\n", "AGENT.txt")
        #expect(try f.agentCommit("Agent work", branch: "claude/fix").status == 0)
        _ = try f.push.push(try f.push.review(repository: f.repo, branch: "claude/fix").get()).get()
        try f.upstream("upstream\n", "UP.txt")

        let updated = try f.agentSync(.update(branch: "claude/fix"))
        #expect(updated.status == 0, "\(updated.output)")
        #expect(GitSync.rebasedTip(updated.output) == (try f.tip("HEAD")))
        #expect(try f.tip("HEAD^") == f.tip("refs/heads/main", remote: true))
        #expect(updated.output.contains("behind 0, ahead 1 of origin/main"))

        // A plain push must fast-forward and is refused.
        guard
            case .failure(let refused) = f.push.push(try f.push.review(repository: f.repo, branch: "claude/fix").get())
        else {
            Issue.record("a rebased branch was pushed without a lease")
            return
        }
        #expect(refused.description.contains("fast-forward"), "\(refused)")
        // With the lease: replaced, signed, on top of main.
        let review = try f.push.review(repository: f.repo, branch: "claude/fix").get()
        #expect(review.commits.count == 1 && review.log.contains("Agent work"))
        let signed = try f.push.push(review, lease: true).get()
        #expect(try f.tip("refs/heads/claude/fix", remote: true) == signed)
        #expect(try f.tip("refs/heads/claude/fix^", remote: true) == f.tip("refs/heads/main", remote: true))
        #expect(
            try f.owner(["--git-dir", f.remote, "cat-file", "commit", "refs/heads/claude/fix"]).contains("gpgsig ")
        )
        // Nothing to rebase the second time.
        let unchanged = try f.agentSync(.update(branch: "claude/fix"))
        #expect(unchanged.status == 0 && GitSync.rebasedTip(unchanged.output) == nil, "\(unchanged.output)")
    }

    @Test func theLeaseFailsIfTheRemoteBranchMovedAndNeverForcesOtherBranches() throws {
        let f = try Fixture()
        try f.write("agent\n", "AGENT.txt")
        #expect(try f.agentCommit("Agent work", branch: "claude/fix").status == 0)
        _ = try f.push.push(try f.push.review(repository: f.repo, branch: "claude/fix").get()).get()
        try f.upstream("upstream\n", "UP.txt")
        #expect(try f.agentSync(.update(branch: "claude/fix")).status == 0)
        let review = try f.push.review(repository: f.repo, branch: "claude/fix").get()
        // Someone pushes to the branch after the review: the lease protects their commit.
        try f.upstream("theirs\n", "THEIRS.txt", branch: "claude/fix")
        let theirs = try f.tip("refs/heads/claude/fix", remote: true)
        guard case .failure(let problem) = f.push.push(review, lease: true) else {
            Issue.record("the lease did not hold")
            return
        }
        #expect(problem.description.contains("moved since the review"), "\(problem)")
        #expect(try f.tip("refs/heads/claude/fix", remote: true) == theirs)

        // A branch that is not the agent's is never forced, lease or not.
        try f.owner(["-C", f.repo, "checkout", "--quiet", "-b", "feature", "main"])
        try f.write("feature\n", "F.txt")
        #expect(try f.agentCommit("Feature").status == 0)
        _ = try f.push.push(try f.push.review(repository: f.repo, branch: "feature").get()).get()
        try f.owner(["-C", f.repo, "commit", "--quiet", "--amend", "-m", "Feature rewritten"])
        guard
            case .failure(let refused) = f.push.push(
                try f.push.review(repository: f.repo, branch: "feature").get(),
                lease: true
            )
        else {
            Issue.record("a non-agent branch was forced")
            return
        }
        #expect(refused.description.contains("fast-forward"), "\(refused)")
    }

    @Test func aConflictingUpdateIsAbortedCleanlyAndNamesTheFiles() throws {
        let f = try Fixture()
        try f.write("agent's line\n", "README")
        #expect(try f.agentCommit("Agent edit", branch: "claude/fix").status == 0)
        let before = try f.tip("HEAD")
        try f.upstream("upstream's line\n", "README")
        let outcome = try f.agentSync(.update(branch: "claude/fix"))
        #expect(outcome.status == GitSync.conflictStatus, "\(outcome.output)")
        #expect(outcome.output.contains("conflicts") && outcome.output.contains("README"))
        #expect(try f.tip("HEAD") == before)
        #expect(try f.owner(["-C", f.repo, "rev-parse", "--abbrev-ref", "HEAD"]) == "claude/fix\n")
        #expect(try f.owner(["-C", f.repo, "status", "--porcelain"]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.repo + "/.git/rebase-merge"))
    }

    @Test func defaultSwitchesAndFastForwardsButNeverMerges() throws {
        let f = try Fixture()
        try f.write("agent\n", "AGENT.txt")
        #expect(try f.agentCommit("Agent work", branch: "claude/fix").status == 0)
        try f.upstream("upstream\n", "UP.txt")
        let outcome = try f.agentSync(.switchToDefault)
        #expect(outcome.status == 0, "\(outcome.output)")
        #expect(try f.owner(["-C", f.repo, "rev-parse", "--abbrev-ref", "HEAD"]) == "main\n")
        #expect(try f.tip("main") == f.tip("refs/heads/main", remote: true))

        // A local main with its own commit is left alone.
        try f.write("local\n", "LOCAL.txt")
        try f.owner(["-C", f.repo, "add", "LOCAL.txt"])
        try f.owner(["-C", f.repo, "commit", "--quiet", "-m", "local only"])
        try f.upstream("more\n", "MORE.txt")
        let local = try f.tip("main")
        let refused = try f.agentSync(.switchToDefault)
        #expect(refused.status == GitSync.notFastForwardStatus, "\(refused.output)")
        #expect(try f.tip("main") == local)
    }

    @Test func syncPrunesDeletedRemoteBranchesAndRunsNoHooks() throws {
        let f = try Fixture()
        try f.owner(["--git-dir", f.remote, "branch", "claude/old", "main"])
        #expect(try f.agentSync(.fetch).status == 0)
        #expect(try f.owner(["-C", f.repo, "branch", "-r"]).contains("origin/claude/old"))
        try f.owner(["--git-dir", f.remote, "branch", "-D", "claude/old"])
        let marker = f.base + "/hook-ran"
        for hook in ["post-checkout", "reference-transaction", "pre-rebase", "post-rewrite", "post-merge"] {
            let path = f.repo + "/.git/hooks/" + hook
            try Data("#!/bin/sh\ntouch '\(marker)'\n".utf8).write(to: URL(fileURLWithPath: path))
            chmod(path, 0o755)
        }
        try f.upstream("upstream\n", "UP.txt")
        #expect(try f.agentSync(.fetch).status == 0)
        #expect(try !f.owner(["-C", f.repo, "branch", "-r"]).contains("origin/claude/old"))
        #expect(try f.agentSync(.start(branch: "claude/x")).status == 0)
        try f.write("agent\n", "AGENT.txt")
        #expect(try f.agentCommit("Agent", branch: "claude/x").status == 0)
        try f.upstream("again\n", "AGAIN.txt")
        #expect(try f.agentSync(.update(branch: "claude/x")).status == 0)
        #expect(try f.agentSync(.switchToDefault).status == 0)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func aRemoteThatRunsCodeIsNeverFetchedForSync() throws {
        let f = try Fixture()
        let marker = f.base + "/ext-ran"
        try f.owner(["-C", f.repo, "remote", "set-url", "origin", "ext::sh -c touch% \(marker)"])
        #expect(OwnerPush.prepareSyncFolder(f.scope.gitSync, denyACLUser: nil) == nil)
        guard case .failure = f.push.syncBundle(repository: f.repo, root: f.scope.gitSync) else {
            Issue.record("an ext:: remote was used")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.scope.gitSync).isEmpty)
    }

    @Test func theRunnerNeedsTheOwnersBundleFromTheSyncFolder() throws {
        let f = try Fixture()
        let request = ActionRequest(
            capability: .command,
            argv: GitSync.argv(.fetch, name: "n", email: "e@example.invalid"),
            cwd: f.repo,
            projectID: f.repo,
            timeoutSeconds: 60
        )
        let decision = Decision(verdict: .allow, reason: "test", ruleID: "test")
        let execution = Execution(id: "s1", tool: "git_sync", request: request, decision: decision, scope: f.scope)
        var launch = Launch(execution: execution, scope: f.scope, readOnly: false, serialPort: nil, timeoutSeconds: 60)
        launch.gitSync = .fetch
        #expect(throws: SandboxError.self) { try f.sandbox.start(launch) }
        let elsewhere = OwnerPush.SyncBundle(
            folder: f.repo + "/sync-1",
            bundle: f.repo + "/sync-1/" + GitSync.bundleName,
            defaultBranch: "main",
            remote: f.remote
        )
        #expect(throws: SandboxError.self) { try f.sandbox.start(launch, sync: elsewhere) }
    }

    // MARK: - D13c

    @Test func theBranchStateIsReadAsTheAgentWithoutRunningOrWritingAnything() throws {
        let f = try Fixture()
        #expect(
            f.sandbox.branchState(in: f.repo)
                == BranchState(branch: "main", base: "origin/main", ahead: 0, behind: 0)
        )
        // The remote moves on and the repository fetches it; then the agent commits on its own branch.
        let other = f.base + "/upstream"
        try f.owner(["clone", "--quiet", f.remote, other])
        try Data("up\n".utf8).write(to: URL(fileURLWithPath: other + "/UP.txt"))
        try f.owner(["-C", other, "add", "UP.txt"])
        try f.owner(["-C", other, "commit", "--quiet", "-m", "upstream"])
        try f.owner(["-C", other, "push", "--quiet", "origin", "main"])
        try f.owner(["-C", f.repo, "fetch", "--quiet", "origin"])
        try f.write("agent\n", "AGENT.txt")
        #expect(try f.agentCommit("Agent", branch: "claude/x").status == 0)

        let marker = f.base + "/hook-ran"
        for hook in ["reference-transaction", "post-index-change", "post-checkout"] {
            let path = f.repo + "/.git/hooks/" + hook
            try Data("#!/bin/sh\ntouch '\(marker)'\n".utf8).write(to: URL(fileURLWithPath: path))
            chmod(path, 0o755)
        }
        let index = try FileManager.default.attributesOfItem(atPath: f.repo + "/.git/index")[.modificationDate] as? Date
        let state = try #require(f.sandbox.branchState(in: f.repo))
        #expect(state == BranchState(branch: "claude/x", base: "origin/main", ahead: 1, behind: 1))
        #expect(state.summary == "on claude/x, 1 ahead and 1 behind origin/main (as of the last fetch)")
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(
            try FileManager.default.attributesOfItem(atPath: f.repo + "/.git/index")[.modificationDate] as? Date
                == index
        )

        // Detached, and outside the session: nothing to name, nothing read.
        try f.owner(["-C", f.repo, "switch", "--quiet", "--detach"])
        #expect(f.sandbox.branchState(in: f.repo)?.branch == nil)
        #expect(f.sandbox.branchState(in: other) == nil)
    }
#endif
