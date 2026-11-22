# Using Dual Control day to day

How a supervised session goes, from opening the app to the report at the end. Why each wall is there is in
[security.md](security.md). Connecting Claude Desktop is in [claude-desktop.md](claude-desktop.md).

## Start a session

1. Open Dual Control. The first time, open **Setup…** and click **Check setup**. Every line should be green: the
   `claude-agent` user, the sudoers line, the shared folder group and tmux.
2. **Choose…** the session folder: one project under `~/Developer`. The agent works only there.
3. Wait for **Sandbox self-test passed**. Until then nothing runs as the agent. The shared terminal starts in the
   session folder as `claude-agent`.
4. Pick an approval mode, then start Claude Desktop (quit and reopen it once after reinstalling the app).

One session folder at a time. Choosing another closes serial ports, LAN endpoints and the terminal.

The app remembers the session folder. At the next launch, including after a reinstall, it chooses that folder
again and reruns every check: the folder rules, Check setup and the sandbox self-test. A folder that no longer
passes is forgotten. The mode always starts in **Ask each**. A banner offers **Resume: <folder> · Allow while
open** as one click; **Not now** hides it. The per-repository automatic push and cap are kept as well.

## Approval modes and the baton

- **Ask each**: every changing action waits for **Approve** or **Deny** in the window. Read-only commands run.
- **Allow 1 h / 2 h / while open**: changing actions run without asking until the time is up or the app quits.
  Always-blocked commands (sudo, eFuse writes, keychain) never run, in any mode.
- Privileged requests ask in every mode: reaching a LAN device (`net_allow_request`).
- **Take over** gives you a pane of your own in the shared terminal. While you hold the baton, Claude can't type
  into the terminal. **Hand back** closes your pane and forgets cached sudo credentials.

The shared terminal has two tabs, each a shell of its own as `claude-agent` in the session folder: **Agent**
(where `terminal_send` types by default) and **Second** (where Claude Code starts; the tab says **Claude Code**
while it runs). A hidden tab keeps running and shows a dot when there's new output. **Side by side** shows both.

- **Take over** opens your own pane in the Agent tab and locks Claude out everywhere, as before.
- **Type here** in the Second tab lets you type into Claude's shell there, for example to log in to something
  inside the sandbox. Only that tab is locked for Claude; it can still read it and use the Agent tab. What you
  type goes to the agent, so never type a password you use anywhere else. **Stop typing** gives it back.

The Activity feed shows every call. **Decision** is what the policy said; **Outcome** is what really happened.

## Stop and End session

- **Stop** (⌘.) denies everything, including requests waiting for you. It ends every process `claude-agent` owns:
  commands, jobs, the terminal and Claude Code inside it. It also closes the proxy, the model relay, serial ports
  and LAN forwarders. **Reset (ask each)** starts the terminal, proxy and relay again, fresh.
- **End session** stops everything and shows the session report. The report starts with **Files your tools
  run ⚠️**: changed Makefiles, editor settings, package manifests and git hooks. Read that list before you open
  the project in your own tools. Next comes **Credentials ⚠️**: files changed this session in the session folder
  or the agent's home that look like private keys or tokens (`sk-ant-`, `ghp_`, `github_pat_`, AWS keys, OAuth
  JSON). It shows the kind, never the secret. Revoke any real one before you do anything else. Claude Code's own
  login folder (`.claude` in the agent's home) is left out. The report is saved next to the audit log in
  `~/Library/Application Support/DualControl`.

## Flashing a board

1. Once per ESP-IDF version, Claude runs `esp_idf_install` (for example `v5.4`, `esp32s3`). It's a background job of
   a few minutes. The app then copies the result to `~/Developer/.dual-control/toolchains/esp-idf-<version>`,
   locked and hashed. Details: [esp-idf.md](esp-idf.md).
2. Claude finds the board with `serial_list` and flashes with `run_command`. It uses a flasher from that install,
   by absolute path, naming the port with `-p`. Only that port opens, and an install in the agent's home is
   refused.
3. Claude watches the console with `serial_open` and `serial_read`, after the flasher has let go of the port.

Close a serial session before flashing on the same port; an open one makes the flasher fail with "busy".

## Devices on your network

Claude asks with `net_allow_request`: an address in your private range, a port, TCP or UDP, and why. You approve
it in the window, in every mode. Claude then uses `127.0.0.1:<port>`, the local port the result names. It never
gets the device's address directly. Approvals last until Stop or a new session folder. The feed shows every
connection with its bytes.

## Claude Code inside the shared terminal

Once:

1. In the **Claude Code** row, keep the suggested version and click **Install**. The app downloads it as you,
   checks its SHA-256 and Anthropic's signature, and locks it in the toolchain folder.
2. Click **Model key…** and paste an API key from a dedicated Console workspace with a monthly spend limit. It
   goes into your keychain; the agent never sees it.

Each time:

3. Claude calls `claude_code_start`, or you click **Start in shared terminal**. Claude Code starts in the session
   folder as `claude-agent`.
4. Claude Desktop prompts it with `terminal_send` and reads it with `terminal_read`. In Ask each, you approve each
   prompt; for a long piece of work, use an Allow mode.

What to keep in mind:

- What Claude Code runs through its own tools isn't approved command by command. The sandbox, the proxy and the
  feed (network, serial, `model` rows) are the controls. Keep an eye on the pane, and use Stop.
- Each model request shows in the feed as `model` with its model name, bytes and time. In **Model key…** you
  can set a monthly budget in US dollars. The window shows this month's spend. Once the budget is reached the relay
  refuses new requests until the next month or until you raise it. The workspace's own spend limit stays as a
  second stop.
- To update, install a newer version. Start always runs the newest installed one.

## Writing files

Claude writes files with `write_file` (the whole file, text or base64, up to 256 KiB) and changes them with
`apply_patch` (a unified diff of one file). Both run as `claude-agent` and follow the approval mode; in Ask each,
the prompt shows the path and the size, or the patch's hunks and lines.

- A patch must match the file exactly, or nothing is written and Claude is told which hunk failed.
- The new file replaces the old one in one step, keeping its permissions.
- Never inside `.git`, through a symbolic link or outside the session folder. The folder must exist.

## Commits and pushes

The agent can't use its own git in your repositories, and it holds no GitHub credentials.

1. Claude calls `git_commit` with the repository folder, a message and a branch of its own (for example
   `claude/fix-parser`, never `main`). The commit stays local, unsigned, with your name.
2. The window shows **To review: claude/fix-parser in <repo>**. Click **Review…** to see the commits your
   remote doesn't have yet, with the stat and the full diff.
3. **Push as me** re-signs those commits with your key and pushes that branch with your SSH or credentials. It's a
   fast-forward only, and never to the default branch. Open the pull request yourself, as usual. The key is your
   global `user.signingkey`; if you set none, the repository's SSH signing key (`gpg.format ssh`) is used, if it's a
   key file of yours in `~/.ssh`. If signing fails, the feed shows git's own error.
4. **Dismiss** drops the entry without pushing. The commits stay in the repository.

Merge commits can't be pushed this way; have Claude rebase the branch first.

### Keeping up with the remote

The agent can't fetch on its own, so Claude calls `git_sync` with the repository and an action. The app fetches
the remote as you (your SSH and credentials) and hands the result to the agent's git:

- `fetch` only updates `origin/*`.
- `start` with a branch such as `claude/fix-parser` switches to it, making it from the remote's default branch if
  it's new. Claude should start new work this way, so it doesn't branch from a stale commit.
- `update` with a `claude/*` branch rebases it onto the remote's default branch. If that conflicts, it's aborted
  and Claude is told which files.
- `default` switches to the default branch and fast-forwards it. It never makes merge commits.

start, update and default refuse while there are uncommitted changes, and say which files. After an `update` the
branch no longer fast-forwards on the remote, so its next push (Push as me, or automatic) replaces the remote
branch with `--force-with-lease`. That only happens for `claude/*` branches, and only if nobody pushed to that
branch after the review.

### Automatic push and pull requests (per repository, off by default)

The window lists the repositories in the session folder. Each row shows the current branch and how far it is ahead
of and behind the remote's default branch (`origin/main`, say), as of the last fetch. It turns orange when the
branch is behind. Claude sees the same line in `status`. The app reads it as the agent, read-only, with hooks off.
It refreshes when a command ends, on every `status`, and every 5 minutes. For each repository:

- **Push claude/\* automatically and open a PR.** After each `git_commit` to a `claude/*` branch, the app does what
  Push as me does: it re-signs the commits and pushes the branch as you, with no force and no hooks. Then it opens a
  pull request with your `gh`, titled from the commit. It never touches the default branch or any branch outside
  `claude/*`, and it never merges. One click turns it off. Every push and pull request is in the feed and the
  audit log.
- **Max open: N** (default 2). `git_commit` refuses to start a new `claude/*` branch while N of them are open on
  the remote. Open means no pull request yet, or an open one. Merge or close one first. Committing to a branch
  that is already open always works. Claude sees the count and the cap in every `git_commit` result and in
  `status`.
- With automatic push on, once you merge a pull request the app deletes that `claude/*` branch on the remote and
  in the repository. The local one is deleted as the agent; if it's checked out, HEAD is detached at the same
  commit first. It checks after each commit and every 5 minutes.

Pull requests need the GitHub CLI (`brew install gh`, `gh auth login`) and a remote on github.com. An SSH host
alias counts if `ssh -G` resolves it to github.com. Without them, branches are still pushed.

**Protect `main` with a GitHub ruleset** (Settings → Rules → Rulesets): target the default branch, require a pull
request, block force pushes and deletions. Then even a mistake in Dual Control or a stolen key can't change `main`
without your review.

## Where things are

| What | Where |
|---|---|
| Audit log, session reports, review scratch space | `~/Library/Application Support/DualControl` |
| Toolchains (ESP-IDF, Claude Code), read-only for the agent | `~/Developer/.dual-control/toolchains` |
| The agent's home and temp folder | `~/Developer/.dual-control/agent-home`, `.../tmp` |
| Model key | your login keychain, "Dual Control model relay" |
| Shim log | `~/Library/Logs/Claude/mcp-server-dual-control.log` |

## When something looks wrong

- A command fails with "Operation not permitted": the sandbox refused something, often a path outside the session
  folder. The feed's Outcome says "blocked by sandbox".
- A host is refused: it appears under the network row with **Allow for this session** and **Always allow**.
- The window lists processes that survived Stop: quit and reopen the app. The next launch ends them first.
- The previous audit log fails its check: the window says so at the top. Keep the file and look at it before you
  carry on.
