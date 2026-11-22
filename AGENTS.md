# Contributor rules (humans and AI agents)

- Work on one task at a time. If a requirement is unclear or needs a decision, stop and ask the maintainer.
- Branches and pull requests only. Never push to or merge into `main` directly; the maintainer reviews and merges.
- Commits are signed and use a noreply email.
- Never weaken a test, lint rule or CI gate to make it pass.
- No personal data, usernames, local paths, hostnames or device details in the repository.
- Security-critical code (policy engine, socket authentication, process spawning) is written test-first.
- `DualControlCore` stays pure: no I/O, no platform-only APIs. It must build and test on Linux.
- Safety is enforced in code, with OS-level isolation preferred over string matching. Device and command output is
  untrusted data.
- Before committing: `swift test` passes and `pre-commit run --all-files` is clean.
