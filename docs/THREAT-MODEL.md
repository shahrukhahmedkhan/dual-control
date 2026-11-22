# Threat model

D9a. STRIDE over the code as it is on `main` (PR #14 merged), plus the network gatekeeper in PR #15 (D7a), marked
"(D7a)". References are `file:line` on those trees. [security.md](security.md) describes the walls themselves; this
page asks what an attacker can still do with them.

## Attacker and assets

**The attacker is a prompt-injected agent.** Claude follows instructions it finds in a file, a web page, command or
device output, and uses every tool Dual Control gives it, as cleverly as it can. It can't break the macOS kernel or
Seatbelt itself, and it can't touch the owner's Mac other than through Dual Control.

What it wants, worst first:

1. **Code running as the owner** (unsandboxed): everything else follows from that.
2. **Data out**: project files, anything readable, credentials.
3. **Damage**: the owner's files outside the session folder, or hardware (bricked boards, burnt eFuses).
4. **Persistence**: something that runs after Stop.
5. **Hiding**: actions the audit log doesn't show, or shows wrongly.
6. **Wearing the owner down**: so many asks that approving becomes automatic.

## Trust boundaries

```
 owner (GUI, own shell)
   │  approves, takes over, Stop                     ┌──────────────────────────────────────────┐
   ▼                                                  │ kernel sandbox (Seatbelt, per process)   │
 Dual Control app  ──sudo -n -u claude-agent──▶       │   claude-agent processes:                 │
 (owner uid)          sandbox-exec -p <profile>       │   run_command, jobs, tmux shared terminal │
   ▲   ▲   │                                          └───────────────┬──────────────────────────┘
   │   │   └── serial ports (opened by the app)                       │ TCP 127.0.0.1:<port> only (D7a)
   │   └────── gatekeeper proxy (D7a) ◀───────────────────────────────┘
   │                └──▶ allowed hosts on the internet
 Unix socket (0700 dir, peer uid = owner)
   │
 dualcontrol-shim (owner uid) ◀── stdio MCP ── Claude Desktop ◀── Claude (the attacker's voice)
```

| Boundary | What crosses it | Main control |
|---|---|---|
| Claude → shim | tool calls (untrusted arguments) | parsed by `ToolRouter`, decided by the app, not the shim |
| shim → app | IPC over a Unix socket | run directory exactly 0700 and owner-owned (`Sources/DualControlIPC/Socket.swift:77`), peer uid must be the owner's (`Sources/DualControlIPC/IPCServer.swift:166`) |
| app → agent processes | argv, cwd, environment | `sudo -n -u claude-agent` limited to sandbox-exec (`Sources/DualControlCore/SetupGuide.swift:50`), `env -i` + an allowlist (`Sources/DualControlSandbox/Sandbox.swift:115`) |
| agent processes → files | reads, writes | Seatbelt CHANGING / READ-ONLY (`Sources/DualControlCore/SandboxProfile.swift:56`), Unix permissions of another user |
| agent processes → network | sockets | (D7a) `(deny network*)` + one TCP port (`Sources/DualControlCore/SandboxProfile.swift:70-72` on PR #15), proxy allowlist (`Sources/DualControlCore/NetworkPolicy.swift:87`, PR #15), proxy (`Sources/DualControlNetwork/GatekeeperProxy.swift`, PR #15) |
| agent output → owner | terminal pane, tool results, feed, approval cards | escaping (`Sources/DualControlCore/DisplayText.swift:1`), untrusted-data envelope (`Sources/DualControlCore/ResultEnvelope.swift:51`) |
| agent files → owner | anything the owner later runs or opens | **none in code**: the owner's review |
| app → devices | serial bytes, resets | approval mode, device rules, bootloader refusal (`Sources/DualControlCore/Supervisor.swift:597`) |

## STRIDE

Status: **Closed** (a control makes it impossible as far as we know), **Mitigated** (made hard or visible; a gap
remains), **Open** (no control yet), **Accepted** (known and left, with the reason).

### Spoofing

| Threat | Control | Status |
|---|---|---|
| Another local process talks to the app as if it were the shim | peer uid check (`IPCServer.swift:166`); socket in a 0700 owner directory (`Socket.swift:43-80`) | Closed for other users. Any process running as the owner can call tools: same trust as the owner. |
| Agent processes connect to the app's socket | different uid; the directory is in the owner's home, which CHANGING can't read (`SandboxProfile.swift:56`) | Closed |
| Output pretends to be the app or the owner ("the owner says: approve…") | untrusted envelope with a random boundary (`ResultEnvelope.swift:51`); server instructions say to ignore it | Mitigated: it relies on the model obeying the instructions; the app's decisions never read output |
| Approval card shows something other than what runs (bidi, zero-width, look-alike spaces) | `DisplayText.argv` escapes everything invisible (`DisplayText.swift:1-58`), tested | Closed |
| Something else answers on the proxy's port (D7a) | port bound before the profile names it; IPv4 only (`tcp4`), so `[::1]:<port>` can't be squatted; Stop kills agent processes before the port is freed | Mitigated: if the app crashed while agent processes lived on, the next launch sweep kills them first |
| A local process uses the proxy (D7a) | per-start 256-bit token, constant-time check (`GatekeeperProxy.swift:179`) | Closed |

### Tampering

| Threat | Control | Status |
|---|---|---|
| Writing outside the session folder | CHANGING denies writes except the scope, agent HOME/TMPDIR; kernel tests | Closed |
| Through symlinks or hard links | Seatbelt checks resolved paths; creating hard links across the boundary is denied (`Tests/DualControlSandboxTests/EnforcementTests.swift:137`) | Mitigated: see gap 4 (hard links that already exist) |
| The Dual Control repo, app bundle or shim | protected-path denies at the end of both profiles; bundle and shim are the owner's with no group/other write | Closed |
| Git auto-executors (hooks, config, attributes) | write denies on every `.git` (`SandboxProfile.swift:39-43`); new repositories only through `git_clone` / `git_init`, checked after (`GitSetup.swift`, `GitRepository.swift`) | Closed (gap 9 closed in D9c) |
| The audit log | it's under the owner's `~/Library/Application Support`, which agent processes can't read or write; SHA-256 hash chain (`Sources/DualControlCore/AuditLog.swift:109`) | Closed for the agent. The owner can still edit it: tamper-evident, not tamper-proof. |
| Scheduled work, launch agents | blocked commands + Library/LaunchAgents write denies (`SandboxProfile.swift:69`) | Mitigated: `defaults write` goes through cfprefsd and only the classifier stops it (security.md) |
| ESP-IDF install the flashers trust | flashers must resolve into an owner-owned install under `toolchains/` that still matches its recorded hash (`Sources/DualControlCore/OwnerToolchain.swift`, `Sources/DualControlSandbox/OwnerToolchainStore.swift`); the agent can't write it (Unix + deny ACL + every profile) | Closed (C1): see gap 8 |

### Repudiation

| Threat | Control | Status |
|---|---|---|
| An action runs with no record | "starting" must be persisted before anything runs (`AppModel.run`, `Supervisor.begin`); a failed write stops the app | Closed |
| Network use without a record (D7a) | every attempt with a valid token, and how each allowed one ended, goes to the log (`GatekeeperProxy.swift:184-219`) | Closed |
| What happened inside the shared terminal | only the typed text and the decision are recorded, not what the shell then ran or printed | Mitigated: the owner can watch the pane; D8a's report should say so |
| Approvals given without reading | none (approval timing is in the log) | Open: D8a flags approvals under 2 s as rubber-stamped |

### Information disclosure

| Threat | Control | Status |
|---|---|---|
| The owner's home, keychain, SSH keys | CHANGING denies reading the owner's home outside the scope (`SandboxProfile.swift:56`); another user | Closed |
| Everything readable outside the owner's home | CHANGING reads only an allowlist of system and developer folders (`SandboxProfile.changingReadPaths`); `/Users/Shared`, `/Volumes/*`, the rest of `/Library`, `/private/tmp` and other users' files are denied (`Tests/DualControlSandboxTests/ReadScopeTests.swift`) | Closed (C2): see gap 10 |
| Sending data out (D7a) | no socket except the proxy; the proxy allows only listed hosts; no DNS | Mitigated: see gap 7 (tunnels to allowed hosts) |
| Reaching devices on the LAN (D7b) | only owner-approved private unicast endpoints, through an app forwarder on 127.0.0.1 whose port alone the profile allows; every connection audited (`LANEndpoint.swift`, `LANForwarder.swift`, `Tests/DualControlSandboxTests/LANEndpointEnforcementTests.swift`) | Mitigated: the device itself is reachable as approved (its firmware is the owner's risk); data can leave through it if the device forwards it |
| DNS as a channel (D7a) | the resolver's socket is out of reach; the proxy decides before it resolves (`GatekeeperProxy.swift:184` before `:219`), so names that aren't allowed are never looked up | Closed |
| The proxy token | in the agent's environment only; other users can't read it; git is kept from storing it in a keychain | Closed. The agent is allowed to know it. |
| Environment leaking from the owner | `env -i` + allowlist (`Sandbox.swift:115`, `SandboxProfile.swift:157`); IDF variables validated (`Sources/DualControlCore/IDFEnvironment.swift:52`) | Closed. See gap 6 |
| Notifications on the lock screen | only the tool name (`App/DualControlApp/AppModel.swift:679`) | Closed |

### Denial of service

| Threat | Control | Status |
|---|---|---|
| Runaway commands | timeouts, output cap 1 MiB (`Sources/DualControlCore/ActionRequest.swift:59`), Stop kills everything the agent owns (`Sources/DualControlSandbox/AgentProcesses.swift:47-53`) | Closed |
| Filling the disk | none: the agent can write without limit in the scope and its home | Accepted for now: visible, and undone by deleting files |
| Fork bombs | the per-user process limit; Stop | Mitigated |
| Proxy exhaustion (D7a) | 128 connections at once, head timeout 15 s, idle timeout 300 s | Mitigated: affects only the agent's own network |
| Approval flooding | asks are counted as interventions; the timeout denies | Mitigated: D8a makes fatigue visible |
| Hardware: holding a port, resetting boards | approval mode, device rules, one user per port | Mitigated |

### Elevation of privilege

| Threat | Control | Status |
|---|---|---|
| sudo, admin rights | the agent isn't in sudoers or admin; `sudo` is always blocked (`Sources/DualControlCore/Classifier.swift:103`) | Closed |
| Escaping Seatbelt | the kernel; self-test before anything runs | Accepted: `sandbox-exec` is deprecated but still shipped; D10 (VM) is the long-term answer |
| **The owner runs a file the agent wrote** | review, documented (security.md "The risk that is still yours"); the session report lists changed files the owner's tools run, first, with a warning (`OwnerRunFiles`, `OwnerRunFileScan`) | **Open, made visible** (C3): the largest risk. See gap 3 |
| The owner's takeover pane | the owner's login shell starts in their home; the card lists shell-hook files in the session folder (`App/DualControlApp/TerminalPanes.swift`, `Sources/DualControlSandbox/ShellHookFiles.swift`) | Mitigated (D9b): see gap 11 |
| The terminal view runs escape sequences from agent output | the view drops input and ignores every OSC code SwiftTerm acts on, 52 and 8 included (`Sources/DualControlTerminal/ViewOnlyTerminal.swift`) | Closed (D9b): see gap 12 |
| eFuse burning or bricking | eFuse commands and `no_reset` blocked in argv; bootloader refusal (`Supervisor.swift:597`, `:652`); flashers only from the owner's toolchain | Mitigated: see gap 8 (`idf.py build` runs project code) |

## Known gaps

Each gap has its status today and a proposed fix for D9. Nothing here is implemented in D9a.

**1. `$HOME/x` expansions and `-I/x` attached option values.** `ArgumentScope` doesn't expand shell variables and
doesn't split attached short-option values (`Sources/DualControlCore/ArgumentScope.swift:15-17`). *Status:*
Mitigated. The kernel stops every write outside and every read of the owner's home. It doesn't stop reads of paths
outside the home (gap 10), so `cc -I/Volumes/x` reads there while the feed shows a plain "Allowed". *Fix:* (a)
treat any `-X/abs` argument (one dash, one letter, then `/`) as a path; (b) in shell text, expand `$HOME`,
`${HOME}`, `$TMPDIR`, `$PWD` with the agent's known values and refuse words with any other expansion in path
position (ask, not deny, in ask-each mode); (c) close gap 10 so the kernel covers reads too.
*D9c (live finding):* the value after `=` (`NAME=value`, `--opt=value`) wasn't checked when the whole word also
had a `..` component: `env A=/etc/../etc/passwd` resolved as the in-scope path `<cwd>/A=/etc/passwd` and passed.
Values are now always checked first. Paths in the agent's own HOME and TMPDIR stay refused as arguments, the
same as everywhere outside the session, although the kernel lets the agent write there. That's the stricter of
the two consistent options: those folders are outside what the owner reviews (the session folder and the D8a
report), and they hold the toolchains flashers trust (gap 8). The legitimate need, installing ESP-IDF there, has
its own tool (gap 3).

**2. Interpreter `-c` strings (`python3 -c`, `node -e`, `perl -e`).** The classifier only scans their words for
blocked program names, and makes them CHANGING (`Classifier.swift:226`); `ArgumentScope` doesn't look inside.
*Status:* Mitigated. Kernel as in gap 1; obfuscated names (`'su'+'do'`) get past the word scan, but `sudo` needs a
password the agent doesn't have. *Fix:* none in the classifier: code can't be parsed reliably. Rely on the kernel
and close gap 10. Show "runs interpreter code" on the approval card so the owner knows the summary isn't complete.

**3. Agent-written scripts later run by the owner.** Makefiles, `package.json` scripts, `Package.swift`, `.envrc`,
Xcode build phases, editor task files, git config in folders that look like bare repositories. *Status:* **Open**,
the largest risk: it turns a contained agent into code running as the owner. *Fix:* (a) files the agent *creates*
are owned by `claude-agent`, so `find <scope> -user claude-agent` lists them exactly. Files it *edits* keep the
owner's uid, so also list files whose ctime is after the session start; (b) the D8a report lists both, executable
and build files first; (c) a "Review changes" sheet before Hand back and on End session; (d) longer term, D10: the
owner only ever sees the agent's work as a diff to apply.
*D9c:* the live ESP-IDF install needed exactly this pattern: a wrapper script in the session folder (`./x.sh`)
installed into the agent's home, because no tool could name paths there. `esp_idf_install` replaces it with one
fixed, audited script that takes only a checked release version and chip names (`ESPIDFInstall.swift`,
`docs/esp-idf.md`). It's exempt from the argument check by tool name only; the same script through `run_command`
is refused.
*C3:* (a) and (b) are done for the files that matter most. The session report starts with "Files your tools run"
(`OwnerRunFiles`, `OwnerRunFileScan`, shown on Stop and End session). It lists every file in the session folder
that the owner's tools run on open, build or commit and that changed during the session: owned by `claude-agent`
(created), or ctime after the report's start (edited). That covers editor tasks and settings, JetBrains run
configurations, Xcode project files and schemes, make/CMake, `package.json`, `Package.swift`, direnv/mise/asdf
files, pre-commit and git hook folders. Each is marked new or changed, with a warning. The scan never follows
links, skips `node_modules`, looks into `.git` only for `hooks`, and stops at 50,000 entries (said in the
report). *Remaining:* (c) the review sheet before Hand back and a live list in the window; files these call
(scripts, CMake includes elsewhere, build plugins); a ctime change by the owner also counts as "changed".

**4. Symlinks and hard links inside the scope.** Symlinks: `ArgumentScope` resolves them (realpath), Seatbelt
checks resolved paths, tested. Hard links: the agent can't make one across the boundary (tested), but Seatbelt
checks the path used, so a hard link the *owner* left in the session folder to a file outside it is writable.
*Status:* Mitigated. *Fix:* when a session folder is chosen, list regular files with `st_nlink > 1` and warn (it's
rare: `cp -al`, some backup tools).

**5. TOCTOU on cwd.** The folder is resolved and checked right before spawning
(`Sources/DualControlSandbox/CommandRunner.swift:32`), but `posix_spawn` changes into it by path
(`CommandRunner.swift:144`). A background job of the agent's could swap a component for a symlink in between.
*Status:* Mitigated: the kernel still decides every access, so the process only starts with a cwd outside, where
it can do nothing it couldn't do anyway. Relative arguments were checked against the old folder. *Fix:* open the
folder with `O_DIRECTORY | O_NOFOLLOW` component by component (`openat`), compare `fstat` device and inode with
the checked path, and spawn with `posix_spawn_file_actions_addfchdir_np` on that descriptor.

**6. Environment leakage.** *Status:* Closed in both directions. Nothing of the owner's environment reaches agent
processes (`env -i` after sandbox-exec, so not even sudo's `SUDO_*` variables survive). The agent's variables
reach the owner only as displayed text. One exception, accepted: the IDF export runs as the agent and its output is
validated against an allowlist before use (`IDFEnvironment.swift:52`).

**7. DNS and data through the proxy (D7a).** DNS: closed (see Information disclosure). Data: HTTPS isn't
intercepted, so anything inside a tunnel to an allowed host goes through. The concrete risk is a token supplied by a
prompt injection, used to push to someone else's GitHub repository. Paths and query strings to allowed hosts are a
weak channel too (GitHub shows repository owners popular paths). *Status:* Mitigated. *Fix options:* (a) remove
`github.com` from the defaults and offer a `git_fetch` tool where the app runs the clone itself with a fixed argv
(no credentials, `protocol.file.allow=never`, no hooks); (b) TLS interception for `github.com` only, refusing
`git-receive-pack` and any `Authorization` header. (a) is simpler and needs no CA in the agent's trust store.

**8. Serial write abuse.** `serial_write` follows the approval mode, and device rules let it run without asking.
After a bootloader reset, writes are refused (`Supervisor.swift:597`, `:652`). Flashers run in FLASHING with one
named port, eFuse commands are blocked in argv, but the flasher is a file in the agent's own home
(`FlasherCommand.swift:11`). The agent can edit `esptool` there to burn eFuses on the port it was given. *Status:*
Closed for the toolchain in C1, as proposed, with these details:
- `esp_idf_install` builds in `.dual-control/toolchain-staging`, in an INSTALLING profile, the only one that may
  write there. It can't read the agent's HOME, TMPDIR or the session folder (planted pip/git/Python
  configuration). It gets a HOME inside the staging folder, the real git and no user site. Outside the home it
  reads only CHANGING's allowlist (gap 10).
- The app then copies `idf`, `tools` and `python-bin` to `.dual-control/toolchains/esp-idf-<version>` as the
  owner, with bsdtar in a profile that reads only the staging folder (and, outside the home, CHANGING's system
  folders) and writes only the new install. No `.git`,
  byte code or archives; set-id bits dropped.
- The app normalises modes and rewrites the staging path in text files and links. Remaining links must resolve
  into the install or system/Homebrew folders. Any file still naming the staging folder or the agent's folders
  fails the install.
- It records a SHA-256 over the manifest (paths, modes, contents, link targets) next to the install and in the
  audit log, and replaces an earlier install of that version only after all of that (that's the "replace an
  install" path).
- The toolchain folder loses the Developer folder's inherited allow ACL and gets an inherited deny entry for
  `claude-agent`.
- Flashers are recognised only there, and start only if the install still matches its hash, with every entry the
  owner's, not group/other-writable and without allowing ACLs (checked once per install per app launch).
- `--before`/`--after no_reset…` are refused.

Kernel tests: no profile can write the toolchain folder, rename it or plant an install. Only INSTALLING writes the
staging folder, not even through a hard link. INSTALLING can't read the agent's home, TMPDIR or session folder.
The owner's copy can't read the owner's files. Neither reads `/Volumes`, `/Users/Shared` or `/private/tmp`. Tests
also show that an install copied into the agent's home, or changed after it was recorded, doesn't run. *Remaining:* `idf.py build flash` runs project code (CMake, Kconfig)
next to the port; esptool alone runs only the owner's toolchain. The hash is checked once per app launch, so a
change by the owner afterwards is noticed only at the next launch (the agent can't make one). Not verified live
yet: a full ESP-IDF install and flash through the new path (needs a reinstall of the app).

**9. `git clone` into the session folder fails, and `/usr/bin/git` can't cache (live finding).**
CHANGING denies creating `.git` anywhere outside the agent's own HOME and TMPDIR (`SandboxProfile.swift:39-43`), so a
clone into the session folder fails. Separately, `/usr/bin/git` is the xcrun stub: it keeps its cache in the
*user's Darwin temp folder* (`confstr(_CS_DARWIN_USER_TEMP_DIR)`, `/var/folders/…/T/`), not `TMPDIR`, so setting
`TMPDIR` (already the agent's tmp, `SandboxProfile.swift:157`) doesn't help, and CHANGING doesn't allow that folder.
Seen in the D7a live run: `couldn't create cache file '/var/folders/…/T/xcrun_db-…' (Operation not permitted)`.

*Status:* Closed in D9c, as designed below, with these differences. (1) The xcrun cache: setting `DEVELOPER_DIR`
or `xcrun_nocache` doesn't stop the stub (tested), so the PATH change wasn't made. Instead CHANGING allows the
agent's own Darwin temp and cache folders, read with `getconf` inside the sandbox and checked
(`AgentSystemFolders`); kernel test: `/usr/bin/python3` prints no cache error. (2) No submodules: their
`.git/modules/*/config` holds `core.worktree`, which the check would have to trust. (3) `.git` is checked against
an allowlist of git's own entries, not a list of bad ones. Live check (test user, real proxy): a clone of a public
GitHub repository passed the check, then a commit and a fetch worked, and writing a hook was denied.

*Design (D9a):*

- **Clone through the app, not in the sandbox.** A tool such as `git_clone(url, folder)`: the app checks the URL
  (https, an allowed host, no credentials in it) and the target (a new folder inside the scope). It then runs the
  real git (`Toolchain.git()`, not the stub) as the agent in a **CLONING** profile: CHANGING without the `.git`
  denies, but only for the duration of this one fixed command line. Hooks and config injection are off:
  `--template=` (empty), `-c core.hooksPath=/dev/null`, `-c protocol.file.allow=never`, `GIT_CONFIG_NOSYSTEM=1`,
  `GIT_CONFIG_GLOBAL=/dev/null`, `--recurse-submodules` with the same `-c` options.
- **Check what it made, then lock it.** After the clone the app verifies `.git` before anything else may run there.
  `hooks/` must be empty. `config` may hold only `core.*` (no `hooksPath`, `fsmonitor`, `sshCommand`, `pager`,
  `editor`), `remote.origin.url` and `.fetch`, and `branch.*.remote` and `.merge`. There must be no
  `info/attributes`, and the same for `.git/modules/*`. Any other key → the clone is deleted and the call fails.
  From then on the normal CHANGING denies apply: the repository works for commits, but its hooks and config stay
  unchanged.
- **Why not just allow `mkdir .git`:** Seatbelt can't tell creating a new `.git` from renaming a ready-made folder
  into place, and a clone has to write `config`. Allowing either inside the sandbox reopens the hole the ban closes.
- **`git init`** works the same way (`git_init(folder)`, same checks).
- **The xcrun stub:** put the developer folder's `usr/bin` before `/usr/bin` on the agent's PATH, so `git`, `clang`
  and `python3` are the real binaries and need no cache. Also allow writes to the agent's own Darwin temp and cache
  folders, read once with `getconf DARWIN_USER_TEMP_DIR` / `DARWIN_USER_CACHE_DIR` run as the agent, and checked
  to be owned by `claude-agent` and under `/private/var/folders`. They're per user (0700), so this opens nothing
  shared.

**10. Reads outside the owner's home.** CHANGING allows every read outside the owner's home that Unix permissions
allow: external volumes (often mounted with ownership ignored), `/Users/Shared`, other users' world-readable files.
*Status:* Closed in C2, with an allowlist rather than a list of denies. CHANGING (and FLASHING and CLONING, which
build on it) now starts reads from `(deny file-read*)`. Allowed outside the owner's home:
- READ-ONLY's system folders (`/usr`, `/bin`, `/sbin`, `/System`, `/opt/homebrew`, `/private/etc`, …);
- `/Library/Developer` (Command Line Tools, custom Swift toolchains) and `/Library/Apple` (Apple components that
  `/System` links to; xcodebuild loads MobileDevice from there);
- the selected Xcode as a whole bundle (its tools stat `Contents/Info.plist`) and the one file
  `/Library/Preferences/com.apple.dt.Xcode.plist` (where the developer stubs find that the licence was accepted);
- the agent's own Darwin temp and cache folders, and the terminal devices;
- metadata only of the folders above all of those.

Inside the home, as before, only the session folder and the agent's work area. Kernel tests
(`ReadScopeTests`) show:
- reads of `/Volumes` (and each volume), `/Users`, `/Users/Shared`, `/Library/Preferences`, `/private/var/log`,
  `/private/tmp`, `/Applications` and a world-readable file outside the home fail, the last also through its
  `/System/Volumes/Data` firmlink path, in CHANGING, FLASHING and CLONING;
- these still build and run: clang, swiftc, a SwiftPM package (`--disable-sandbox`, since SwiftPM's own
  sandbox-exec can't nest), `/usr/bin/python3`, a Homebrew Python venv with pip, uv, git and make.

*Remaining:* `/usr/local` and `/opt/homebrew` are readable whole (tools live there; so does anything the owner
installed with Homebrew). ESP-IDF itself wasn't built in the test (no install on CI); its toolchain is in the work
area or the owner's toolchain folder, both readable. Other macOS tools may need more paths; they fail with
"Operation not permitted" and need a deliberate addition.

**11. The owner's takeover pane starts in the session folder.** It's the owner's login shell, unsandboxed, with
the session folder as its working directory (`TerminalPanes.swift:117-134`). Shell hooks run project files as the
owner when they see them: direnv (`.envrc` once allowed), mise or asdf (`.mise.toml`, `.tool-versions`), nvm
auto-use, prompt themes that run project tools. *Status:* Mitigated in D9b. The owner pane starts in the owner's
home. Above it is the quoted `cd '<session folder>'` line with a Copy button, so entering the folder is the owner's
choice. The takeover card and the pane list the shell-hook files in the session folder
(`SharedTerminal.shellHookFileNames`: direnv, mise, asdf, nvm, pyenv, rbenv, autoenv, dotenv, `.venv`, compared
ignoring case). The scan goes three levels deep, skips `.git` and `node_modules`, never follows symlinks, and stops
at 20,000 entries (and says so). *Remaining:* hooks the list doesn't know, deeper files, and anything the owner
runs after `cd`. The list is a warning, not a control.

**12. Escape sequences from agent output in the owner's window.** The view-only pane renders whatever the agent's
tmux client prints. SwiftTerm's `LocalProcessTerminalView.clipboardCopy` writes OSC 52 content to the general
pasteboard. tmux forwards OSC 52 once `set-clipboard` is on, which the agent can set: it owns the tmux server. A
command planted on the owner's clipboard is one paste from running as the owner. OSC 8 links go to
`NSWorkspace.open`, so they need a click, but can be disguised. *Status:* Closed in D9b. Reproduced against real
SwiftTerm 1.10.1 in `Tests/DualControlTerminalTests`: an unhardened terminal copies the payload for 7-bit OSC 52
with BEL or ST, after a full reset, and for an 8-bit `0x9D` introducer right after `ESC [`. The parser takes C1 OSC
in every state but ground, so a byte filter looking for `ESC ]` would miss that one. The fix doesn't filter bytes.
`ViewOnlyTerminalView` registers no-op handlers for every OSC code SwiftTerm acts on
(`ViewOnlyTerminal.neutralisedOSC`), and those come first in SwiftTerm's dispatch however the sequence arrived.
Also covered: colours (text could be made invisible), notifications, iTerm2 transfers, titles. Tests: none of those
reach the host, no link payload is attached, and the real view leaves `NSPasteboard.general` unchanged.
*Remaining:* SwiftTerm still draws Sixel and Kitty images, which can show anything but can't run or copy. Re-check
`dispatchOsc` whenever SwiftTerm is updated; a test pins the list.

## Order for D9

1. Gap 12 (clipboard) and gap 11 (owner pane): done in D9b.
2. Gap 3 (review of agent-written files) with D8a's report.
3. Gap 9 (`git_clone` / `git_init` through the app, real binaries on PATH): blocks real project work today.
4. Gap 10 (reads outside the home): done in C2. Gaps 1 and 2 now have the kernel behind reads too.
5. Gap 8 (owner-owned toolchain): done in C1.
6. Gap 7 (`git_fetch` instead of `github.com` in the defaults), gap 5 (fd-based cwd), gap 4 (hard-link warning).
