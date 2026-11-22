# Security policy

Dual Control is pre-release. There are no supported releases yet: fixes go to `main`.

## Reporting a vulnerability

Please don't open a public issue, discussion or pull request for a vulnerability. Report it privately with
GitHub's private vulnerability reporting: the **Report a vulnerability** button under this repository's
**Security** tab.

Helpful to include: what you did (steps or a proof of concept), what happened and what should have happened,
the commit you tested, and your macOS version. Reports are read by one maintainer, on a best-effort basis; you'll
get an answer in the advisory thread, and credit in the fix if you want it.

## Scope

In scope: three kinds of problem, whether the assistant, a prompt injection in what it reads, or another local
user causes them.

**Sandbox escape.** Anything that lets the assistant

- escape the `claude-agent` user or the kernel sandbox: write outside the session folder and its own home, read
  the owner's home, or open a serial port it wasn't given;
- reach the network other than through the gatekeeper proxy, or a host the proxy should refuse;
- get code to run as the owner (git hooks or config, the owner's terminal pane, the clipboard);
- connect to the app's local socket from another user.

**Approval bypass.** Anything that lets the assistant

- act without the approval the owner's mode requires, or reach an always-blocked operation (sudo, eFuse writes,
  credentials and the keychain);
- make an approval prompt or the activity feed show something other than what will run;
- tamper with the audit log without it being detected.

**Credential exposure.** Anything that lets the assistant, or anything it runs, read or use

- the owner's SSH or signing keys, keychain items or the model relay's API key;
- a token or password through a git remote URL, a push, the proxy, the audit log or the activity feed.

The known gaps and their status are listed in [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md). A report about one of
them is still welcome if you can show it is worse than described.

Out of scope: attacks that need the owner's admin rights or physical access, and the owner running a file the
assistant wrote without reviewing it (documented in [docs/security.md](docs/security.md)). Bugs in a dependency
belong upstream, unless the way Dual Control uses it makes them exploitable here.
