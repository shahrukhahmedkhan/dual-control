# How the agent is contained

The full threat model comes with D9. This page lists the walls that exist today, and the risk that is still
yours.

## The walls

1. **Another user.** Everything Claude runs, runs as the standard user `claude-agent`. It has no sudo rights and
   is in none of the groups admin, wheel, tty or _developer. Check setup verifies all of this.
2. **The kernel sandbox.** Every agent process starts inside a Seatbelt profile (`SandboxProfile`), and its
   children inherit it:
   - CHANGING (the shared terminal and changing commands) may write only in the session folder and the agent's
     own HOME and TMPDIR (and its own Darwin temp and cache folders under `/private/var/folders`, where the
     `/usr/bin` developer stubs keep xcrun's cache; checked to be owned by `claude-agent` and writable by no one
     else), and cannot read the rest of your home. Outside your home it reads only an allowlist: system folders,
     `/opt/homebrew`, `/Library/Developer`, `/Library/Apple`, the selected Xcode and the Xcode licence record. Not
     `/Volumes`, `/Users/Shared`, other users' homes, `/private/tmp` or the rest of `/Library`. Its only network
     is the gatekeeper proxy (below).
   - READ-ONLY (auto-allowed commands) cannot write anywhere, has no network and cannot open serial ports.
3. **The policy engine.** Blocked commands are always denied. Everything that can change something follows the
   approval mode. Text typed into the shared terminal is never treated as read-only, because the shell runs it
   under CHANGING.

## Serial ports

The app opens serial ports itself, as you, so no agent process is involved. Every serial call still goes through
the policy engine, the audit log and the activity feed. Listing and reading are read-only, while opening, writing
and resetting follow the approval mode. Device output is shown escaped, in an untrusted data block, and never goes
into the audit log.

The eFuse block for serial ports is a second wall, not the first. A session reset into the ROM bootloader refuses
`serial_write`. So does a new session on a port whose last reset was into the bootloader, until a `run` reset.
That stops raw bootloader commands from reaching eFuse registers through the serial tools.

Agent processes can't open serial devices at all, with one exception. The CHANGING sandbox denies every
`/dev/cu.*` and `/dev/tty.*` device, kernel-enforced, to every command and to the shared terminal. Only a
recognised flasher or monitor started with `run_command` runs in a profile that allows them:

- idf.py `flash`, `app-flash`, `erase-flash` or `monitor` (with `build` alongside);
- esptool `write_flash`, `read_flash`, `chip_id` or `flash_id`, run directly or as `python -m esptool`;
- never with an eFuse word, a register write, `run`, another esptool command, `--before`/`--after no_reset…`
  (which would leave the chip in its bootloader without the app knowing) or an `@file` of arguments, and never
  behind a wrapper such as `env` or `sh`;
- the program, and the script a Python runs, must be absolute paths that realpath resolves into an ESP-IDF
  install in the owner's toolchain folder (`~/Developer/.dual-control/toolchains/esp-idf-<version>`), checked
  right before the command starts. The one exception is the Python environment's own interpreter
  (`<install>/tools/python_env/<env>/bin/python…`), a symlink to the Python it was made with: it counts by its own
  path if no folder on the way is a symlink and it still resolves to a Python. The script it runs isn't
  checked as an argument again; recognition already found it in the install;
- the install must still match the hash recorded when it was installed, with every entry the owner's, writable
  by nobody else and without an ACL entry that allows anything (checked once per install per app launch).

The agent can't write the toolchain folder: you own it, an inherited deny ACL names `claude-agent`, and no
sandbox profile allows writes there. The only way in is `esp_idf_install` ([esp-idf.md](esp-idf.md)): one fixed
script, audited and decided like any changing command, with only a release version and chip names passed to it.
It builds in a staging folder that only its own INSTALLING profile may write, and the app copies the result in as
you, in a sandbox, then checks it and records its hash. An install in the agent's own home is never recognised.

Such a command must name exactly one port with `-p`/`--port` (otherwise it's denied, `serial.no-port`, so a
tool never scans every port and reaches another board on the desk), and its profile allows only that port. The
port must be a `/dev/cu.*` device that `serial_list` shows as a USB serial device, and no Dual Control serial
session may hold it; this is checked when the call arrives and again right before it starts. No other argument
of any command may name a device. Flashing follows the approval mode like any changing command; device rules
never cover it.

These commands run with the install's ESP-IDF environment and nothing from yours. Once per install, the app runs
`<install>/python-bin/python3 <IDF_PATH>/tools/idf_tools.py export --format key-value` as `claude-agent`, in CHANGING without serial
ports, for at most a minute. It keeps only IDF_PATH, IDF_TOOLS_PATH, IDF_PYTHON_ENV_PATH, OPENOCD_SCRIPTS,
ESP_ROM_ELF_DIR, ESP_IDF_VERSION and PATH. Every path, and every folder PATH adds, must be inside the install, or
the whole environment is refused; PATH ends with the agent's usual folders. idf.py doesn't start without a valid
environment; esptool runs without one. Each export run is recorded in the audit log and the feed as part of the
flash that needed it ("esp-idf env derived from …", with its outcome); a cached environment isn't recorded again.

Residual risk: idf.py `build` runs code from the project (CMake files, components, Kconfig scripts) in the same
process tree as the flash, so a deliberately malicious agent can still put its own code behind `idf.py build
flash` and reach the port. esptool on its own (and `idf.py flash` of a project you have reviewed) runs only the
owner's toolchain. The argv eFuse rules still apply on top. The install itself runs code from Espressif's GitHub,
PyPI and Espressif's servers; nothing the agent controls besides the version and chip names reaches it.

Device rules ("always allow this device") match the USB vendor id, product id and serial number. Many boards
report a default serial number (TinyUSB's `123456`, a CP210x's `0001`), and two connected boards can share one.
For those, a rule also requires the same physical USB port (the IOKit location), and the approval card says so.
A rule made for a unique serial number stops covering other ports as soon as a second device with that number is
connected.

## The network

Agent processes must be able to install things (pip, uv, git, the ESP-IDF installer) but must not be able to
send project files to an arbitrary host. So the app runs a **gatekeeper**: an HTTP proxy on `127.0.0.1`, on a
port the system picks at each start.

- **The kernel keeps agent processes on it.** CHANGING denies every socket, then allows only TCP over IPv4 to
  `localhost:<proxy port>`, plus Unix sockets in the agent's own HOME and TMPDIR (tmux). There is no DNS (the
  resolver's socket is out of reach, so lookups cannot carry data out), no UDP, no other port, no listening
  socket. IPv4 only, so nobody else can squat `[::1]` on the same port. READ-ONLY has no network at all.
- **No proxy, no network.** The proxy starts only once the audit log is open. Stop, an audit failure and
  quitting close it and every connection through it; Reset starts a new one with a new port and token. While
  there is none, CHANGING has no allow rule for any port.
- **Who may use it.** Each start makes a random 256-bit token. It's in the proxy URL in the agent's environment
  (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, upper and lower case) and checked, in constant time, in the
  `Proxy-Authorization` header; anything else gets 407. A peer check isn't possible here: macOS has no peer
  credentials for TCP, pip, uv and git can't use a proxy on a Unix socket, and mapping a loopback connection to a
  process means scanning other users' descriptors, which is racy and needs root. Other users can't read the
  agent's environment. Git is told not to hand the proxy credentials to a credential helper (it would otherwise
  store the token in a keychain, and in the sandbox that hangs).
- **What it lets through.** `CONNECT host:443` (HTTPS, never intercepted: the proxy sees the host name only) and
  plain `http://` requests on port 80, to these hosts, checked against what pip, uv, git and the ESP-IDF v5.4
  installer actually reach: `pypi.org`, `files.pythonhosted.org`, `github.com`, `codeload.github.com`,
  `release-assets.githubusercontent.com` (where release downloads redirect today), `dl.espressif.com`
  (constraints and wheels), `components.espressif.com` and `components-file.espressif.com` (the component
  manager). Nothing else, unless you allow a host from the window, for this session or always. Subdomains are
  other hosts; addresses and single-label names can never be allowed.
- **Where it connects.** The proxy resolves names itself and refuses loopback, private (10/8, 172.16/12,
  192.168/16, fc00::/7), carrier-grade NAT, link-local (including 169.254.169.254) and multicast addresses,
  including IPv4 inside IPv6. It connects to the exact address it checked. Local devices get their own tools.
- **Plain HTTP is read strictly.** One request per connection: the head is checked (CRLF only, no folding, no
  non-ASCII), `Content-Length` together with `Transfer-Encoding`, or anything but plain `chunked`, is refused,
  exactly the framed body is forwarded, and the response is rewritten to `Connection: close`. A second request
  smuggled after the first never reaches the server. The token and hop-by-hop headers never leave.
- **GitHub is read-only for plain HTTP.** Any `git-receive-pack` path or `service=` (after decoding escapes, any
  case) is refused. Over HTTPS the proxy can't see paths. There, push fails because the agent has no GitHub
  credentials: its own empty HOME, no keychain of yours, an environment built from nothing, and git's helper is
  off for the proxy.
- **Every attempt is recorded**, allowed or refused: host, port, method and rule in the audit log and as a
  "network" row in the activity feed; for allowed ones, bytes each way and duration when they close. Refused
  hosts appear in the window with "Allow for this session" and "Always allow".

What it doesn't cover:

- **Data sent to an allowed host.** HTTPS isn't intercepted, so anything inside a tunnel to an allowed host goes
  through. The real case is GitHub: if a prompt injection hands the agent someone else's token, it can push your
  files to their repository over HTTPS. Uploads to PyPI need `upload.pypi.org`, which is not allowed.
- **Daemons that make connections for a process** (reached through system services rather than sockets) aren't
  covered by the socket rule. D9 reviews them.

### Devices on your network (D7b)

The proxy refuses private addresses, so a board on your Wi-Fi is out of reach until you approve it. The agent
asks with `net_allow_request`: an IPv4 address in a private range (10/8, 172.16/12, 192.168/16, never ending in .0
or .255), a port, TCP or UDP, and why. The request is privileged: you decide it in every mode, and no rule covers
it. Names aren't accepted, so there is no DNS or mDNS, and nothing can scan or broadcast.

Seatbelt can't name a remote address other than localhost, so the kernel never lets agent processes reach your
network themselves. On approval the app starts a forwarder on 127.0.0.1, on a port the system picks. The CHANGING
profile of commands started from then on allows that local port and no other. The forwarder connects only to the
approved address: TCP with half-close (request, then reply), or UDP through one socket connected to the device,
without `SO_BROADCAST`. Every connection goes to the audit log and the feed like the proxy's (`TCP`/`UDP`, rule
`lan.endpoint`, bytes each way), so the session report counts them under Network. The approval lasts until Stop or
a new session folder; asking again for an approved device returns the same port.

Other processes on your Mac can use a forwarder too, but they can reach the device directly anyway. It gives
the sandboxed agent only what you approved. The shared terminal keeps the profile it started with, so it doesn't
get endpoints approved later.

## Claude Code inside (D11)

Claude Code can run as `claude-agent` in the shared terminal, so Claude Desktop prompts it with `terminal_send`
and reads it with `terminal_read`. Only you install it, from the window, as yourself:

- The app downloads the release you name from `downloads.claude.ai`: the manifest, then the one binary for your
  Mac. Nothing runs while it does, and the agent and the proxy aren't involved.
- The binary must match the manifest's SHA-256 **and** be signed with Anthropic's Developer ID (team
  `Q6L2SF6YDW`, identifier `com.anthropic.claude-code`).
- It goes into `.dual-control/toolchains/claude-code-<version>/claude`, owned by you, with the agent's deny ACL
  and its hash recorded next to it, like an ESP-IDF install. The agent can run it, never change it.

**Terminal tabs.** The shared terminal is two tmux sessions on the agent's server (`claude` for the Agent tab,
`second` for the Second tab), both in CHANGING; Stop ends the server and both. `terminal_send` and
`terminal_read` take `tab`; the audit records it. The tab label "Claude Code" comes from tmux's
`pane_current_command`, never from terminal output (title escapes stay neutralised). **Type here** in the Second
tab passes the owner's keystrokes into the agent's pane (output is still hardened). While it's on,
`terminal_send` and `claude_code_start` for that tab are denied (`baton.tab`), also for requests already
approved. The global baton (Take over) is unchanged.

`claude_code_start` (or **Start in shared terminal**) types one fixed line into the Second tab's pane: `cd` to the session
folder, then the newest install with auto-update and non-essential traffic off. It's decided like terminal text:
only while Claude holds the baton, following the approval mode. Right before typing it, the app checks the
install's hash and signature again.

**The model relay.** No agent process holds a credential:

- The app runs a relay on 127.0.0.1 alongside the proxy, with a fresh port and session token each time. CHANGING
  allows its port, and agent processes get `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` (that token).
- You save your API key once with **Model key…**. It goes in your login keychain, this device only. Use a key
  from a dedicated Console workspace with a spend limit.
- The relay passes only `POST /v1/messages` and `/v1/messages/count_tokens` (optionally `?beta=true`), with a
  Content-Length body. It drops the agent's `authorization`, `x-api-key` and cookies, forwards an allowlist of
  headers, adds your key, and talks HTTPS to `api.anthropic.com`. It never follows a redirect.
- Answers stream back as they arrive. Every request goes to the audit log and the feed (`model`): its model,
  status, bytes and duration, never its body.
- **Budget (D12e).** The relay reads each answer's `usage` (`message_start.message.usage` and `message_delta.usage`
  in a stream, `usage` in JSON) as it streams past, without keeping the answer. It prices the usage with a table
  in code that leans high on purpose: each family at its dearest current model, cache writes at the 1-hour
  rate, fast mode doubled, unknown models at the top tier, plus 10%. It adds the cost to the month's spend,
  saved in the app's preferences. At the owner's monthly budget, new requests get 403 before anything goes
  upstream; the request that crosses the line still finishes. Each exchange's tokens and cost are audited, and
  so are budget changes.
- Stop closes the relay with the proxy. `api.anthropic.com` stays off the gatekeeper's allowlist.
- While a session runs, a prompt injection can still spend model calls through the relay, up to the workspace's
  spend limit. It can't take the key away.

**Writing files.** `write_file` and `apply_patch` are a capability of their own (`file`), decided like a changing
command and following the approval mode; "always allow" never covers them.

- The request the policy sees, and the audit records, is the operation, the path, and the size and SHA-256 of the
  content or patch. The bytes travel beside it and are never written to the audit.
- The path must be absolute and canonical, with no `.git` component in any case. Its folder must resolve inside
  the session folder, and the target must not be a symbolic link, inside `.git` or in a protected folder. All of
  this is checked again right before it runs.
- The app runs two fixed scripts as the agent in CHANGING. For a patch, one reads the file (at most 256 KiB,
  refusing a link). The app applies the hunks byte-exactly, with no fuzz, in its own code. The other writes a
  temporary file in the same folder and renames it over the target. A patch is written only if the file's SHA-256
  is still what was read, so nothing changed in between.
- The content reaches the script as a base64 argument, so another local user could see it in `ps` while it runs
  (milliseconds).
- Underneath, the kernel profile keeps writes inside the session folder and away from `.git` hooks and config.

**Automatic push of agent branches (D12b).** Off by default, per repository, saved in the app's preferences
(the agent can't write them); every change is audited.

- It runs only after a successful `git_commit` to a branch named `claude/<plain name>`. It uses exactly the
  owner's Push as me path: review in a scratch repository, re-sign, fast-forward push as the owner, never the
  default branch. Turning it off, or Stop, while a push is being prepared leaves the branch in the queue.
- Signing uses the owner's global `user.signingkey`. Without one, the repository's `gpg.format` and
  `user.signingkey` are read from its config file as data (the agent may be able to write it): only `ssh`, and only
  a regular file the owner owns in `~/.ssh`, reached without links or `..`. Signing programs (`gpg.program`,
  `gpg.ssh.program`) are never taken from the repository. Git's error is shown escaped, on one line.
- The pull request is opened with the owner's `gh`, always with `--repo owner/name` and `--head`/`--base`, in
  the app's folder, never in the agent's repository. The agent's commit message is quoted in a code fence
  longer than any backtick run in it, so nothing in it renders: no mentions, links or images. Nothing merges.
- Cleanup deletes only `claude/*` branches whose pull request `gh` reports as merged (pull requests from forks
  are ignored), on the remote as the owner and in the repository with a fixed script as the agent.
- The cap is an economy measure, not a wall: if the remote can't be reached, the last count stands; if it
  was never counted, nothing is refused.

**Credential scan (D12d).** At the end of a session the report lists files in the session folder and the agent's
home, changed this session (ctime), whose name or first 256 KiB look like a credential: SSH and PEM private keys,
key stores, `.netrc`, `.git-credentials`, AWS credentials, Anthropic (`sk-ant-`) and GitHub (`ghp_`, `gho_`,
`github_pat_`, ...) tokens, AWS access keys, and OAuth JSON (`refresh_token`, `access_token`, `client_secret`). The app
reads them as the owner. It never follows a link (`lstat`, then `open` with `O_NOFOLLOW | O_NONBLOCK`), reads only
regular files, and skips `.git`, `node_modules` and Claude Code's login folder (`.claude` in the agent's home).
The report shows where, the path and the kind, never the secret. Changed entries the owner can't read are listed
too: the agent made them private.

**Commits, review and push.** The agent can't use its own git in your repositories: they belong to you, and
their hooks and config stay unwritable.

- `git_commit(repository, message, branch)` runs one fixed script as the agent in CHANGING: switch to (or
  make) the branch, then `git add -A` and `git commit`. The branch may not be `main` or `master`. Hooks, fsmonitor and signing are off, no system or global config is read, `safe.directory` is
  given on the command line, and the identity is your git name and email.
- The branch goes to the window's review queue. Nothing the agent runs can push.
- **Review…** never runs your git inside the agent's repository, whose config could name programs to run:
  - the remote is read from its config file as data and must be a plain https or ssh URL;
  - a fresh repository in the app's folder fetches the branch over `file://`, every object checked. A
    repository with `objects/info/alternates` is refused;
  - the remote's own branches are fetched, and you see only the commits the remote doesn't have, with their stat
    and diff.
- **Push as me** re-creates each commit with its tree, message and author, signs it with your key, and pushes
  `refs/heads/<branch>`, as you, with your SSH and credentials.
- It never pushes the default branch, `main` or `master`, never forces, and never follows a hook.
- Merge commits are refused (rebase first). Which signed commit stands for which agent commit is kept in the
  app's folder, so the next push fast-forwards.

**Keeping a repository current (D13a).** The agent has no credentials, and its own git refuses your repository,
so it can't fetch. `git_sync(repository, action, branch)` splits the work:

- As you: the remote is read from the repository's config file as data (a plain https or ssh URL, as for Push),
  fetched with your git, SSH and credentials into a fresh scratch repository in the app's folder (every object
  checked), and all its branches written as a git bundle. The bundle goes into a new folder in
  `~/Developer/.dual-control/git-sync`, a folder only you may write (no inherited ACL, a deny entry for the agent,
  like the toolchain folder). The folder and file are made through descriptors (`mkdirat`, `openat` with
  `O_EXCL | O_NOFOLLOW`), so nothing the agent placed is followed or written to. The bundle is removed when the
  script ends.
- As the agent, in CHANGING: one fixed script, like `git_commit`'s (hooks, fsmonitor, signing and automatic gc
  off, no system or global config, `safe.directory` on the command line). It fetches the bundle into
  `refs/remotes/origin/*` with `--prune` (only the file transport, objects checked), then: `fetch` stops there;
  `start` switches to a `claude/*` branch, made from `origin/<default>` if new (the branch cap applies);
  `update` rebases a `claude/*` branch onto `origin/<default>`, and on a conflict aborts and lists the files;
  `default` switches to the default branch and fast-forwards it, never merging. start, update and default refuse
  while the working tree has changes and name them. Branches are made with `--no-track`, so no config is
  written. Nothing it does pushes.
- A rebase moves the branch away from what's on the remote. Its push (Push as me, or automatic) then uses
  `--force-with-lease` against the remote tip the review saw, and only for `claude/*` branches. If anyone pushed to
  that branch after the review, the push fails. Every other push still has to fast-forward.

Claude Code runs in the pane's CHANGING sandbox, like everything else there. What it then runs through its own
Bash tool is **not approved command by command**. Only the sandbox, the proxy and the feed's network and serial
rows bound it. Watch the pane, and use Stop. Its own permission settings live in the agent's home, which the agent
can write, so they're no boundary.

## The off switch

Stop, quitting the app and the next launch after a crash end **every** process `claude-agent` owns, not just
the commands Dual Control started. That includes background jobs in their own process group, daemons, and the
shared terminal. The app runs `kill -KILL -1` as the agent through the same sudoers rule, then checks the
kernel's process table. If anything survives, the window says which processes. After Stop → Reset, the shared
terminal starts again, fresh.

Nothing the agent schedules can run later either:

- `crontab`, `at`, `batch`, `atq`, `atrm`, `launchctl`, `sfltool` and `defaults write` of login-item domains
  are always blocked.
- The CHANGING sandbox denies writes to every `Library/LaunchAgents` and `Library/LaunchDaemons` folder, the
  agent's own home included, and to `/Library/StartupItems`, `/usr/lib/cron` and `/private/var/at`.

`defaults` writes go through the `cfprefsd` daemon, so the sandbox can't stop them; only the blocked-command
rule does. They could only reach the agent's own preferences, which matter only if `claude-agent` ever logs in
to the desktop. It's a hidden user with a random password, so it never does.

## Dual Control protects itself

- The session folder must be strictly inside `~/Developer`. It can't be `~/Developer` itself, the agent's work
  area `~/Developer/.dual-control`, or the Dual Control repo.
- Protected folders: `~/Developer/dual-control`, plus any folder whose `Package.swift` declares the package
  `DualControl`. When you choose a session folder, the app looks for those from `~/Developer` down to the session
  folder, and up to 6 levels inside it. It skips `.git`, `.build`, `node_modules` and similar folders, and stops
  after 50,000 folders.
- Both profiles end with deny rules for the protected folders, so a session folder that contains one still
  can't reach it. CHANGING denies reading and writing them, and renaming any folder above them. READ-ONLY
  denies writing them.
- The setup's ACL step also gives `claude-agent` an explicit deny entry on `~/Developer/dual-control`. macOS
  orders deny entries before allow entries, so the deny wins over the shared Developer folder's allow.

## Git's silent auto-executors

Git runs code from a repository's `.git` folder: hooks, and anything `.git/config` names (`core.hooksPath`,
filters, `core.fsmonitor`, aliases, diff drivers). If the agent could write those, the code would run later as
**you**, unsandboxed, the next time you or Claude Code run git in that repo.

So in every repo, CHANGING denies the agent writes to:

- `.git` itself (it can't create, delete or rename it, so a ready-made folder can't be swapped in),
- `.git/hooks/`, `.git/config`, `.git/config.worktree` and `.git/info/attributes`,
- the same files for submodules and worktrees kept under `.git/`, and their `commondir` and `gitdir` pointers.

Objects, refs and `HEAD` stay writable, so the agent can still commit in an existing repo. It can't run
`git init` or `git clone`, though, and it can't create a branch named `config` or `hooks`.

New repositories come from the app instead (`git_clone`, `git_init`). It runs the real git as the agent with a
fixed command line: no templates, hooks off, fsmonitor off, https only, no submodules, and no system or global
config. It runs in a CLONING profile, CHANGING plus one rule that lets this one process write `.git` inside the
new folder only. A clone needs a folder that doesn't exist yet; an init refuses a folder that already has `.git`.
Afterwards the app checks what git made:

- `.git` holds only git's own entries;
- `hooks` is empty and `info` holds only `exclude`;
- the config, listed by git in READ-ONLY with includes off, has only the `core` keys git sets (not bare), the
  origin (exactly the URL cloned) with its fetch line, and `branch.<name>.remote`/`.merge`.

Anything else, or a failed run, and the app removes what it made: the clone's folder, or only the new `.git`
after an init. From then on the usual denies keep that repository's hooks and config as they are.

## The risk that is still yours

The sandbox only restricts processes started as the agent. Files the agent writes in the session folder are
plain files, and anything that runs them **as you** runs them unsandboxed:

- Makefiles, shell scripts, `package.json` scripts, `Package.swift` and build plugins, Xcode build phases,
  `.envrc` files and editor or IDE task files,
- a folder the agent made to look like a bare git repository, if you run git inside it.

Before you build, run or open a project the agent has changed, review what it wrote, as you would review code
from someone else.

The end-of-session report (Stop or End session) starts with **Files your tools run**. It lists, with a warning,
every file in the session folder that your tools run on their own and that changed during the session: files
the agent owns (it created them) and files whose status changed since the session started (it edited yours).
That covers `.vscode/tasks.json`, `launch.json` and `settings.json`, `*.code-workspace`, JetBrains run
configurations, Xcode `project.pbxproj` and schemes, Makefiles and `*.mk`, CMake files, `package.json`,
`Package.swift`, `.envrc`, mise and `.tool-versions`, `.pre-commit-config.yaml`, and git hook folders (`.git/hooks`,
`.githooks`, `.husky`). The list is a reminder of where to look first, not a guarantee: a script any of these
calls, or a tool it doesn't know, can still run the agent's code. It skips `node_modules` and stops after 50,000
entries (and says so).
