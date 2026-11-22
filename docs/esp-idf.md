# ESP-IDF for the agent

Flashers are recognised only when they come from an ESP-IDF install in the app's toolchain folder,
`~/Developer/.dual-control/toolchains/esp-idf-<version>` (see [security.md](security.md#serial-ports)). You own it;
the agent can read and run it but never change it, so it can't patch esptool to burn eFuses on the port it was
given (threat-model gap 8). An install in the agent's own home (`~/esp`, `~/.espressif`) is never recognised.
The only way in is `esp_idf_install`.

## Install with `esp_idf_install`

Claude calls `esp_idf_install` with a release tag and the chips it needs:

```json
{"version": "v5.4", "targets": ["esp32s3"]}
```

It always runs as a background job (follow it with `job_status`) and is decided like any changing command, so in
ask-each mode you approve it once. The app runs one fixed script, the same for every call. Only the version
(`vX.Y` or `vX.Y.Z`) and known chip names reach it, as arguments. The script runs as `claude-agent` in its own
INSTALLING sandbox. That sandbox may write only the staging folder `~/Developer/.dual-control/toolchain-staging`,
which nothing else the agent runs may write. It can't read the agent's home, its TMPDIR or the session folder, so a
`pip.conf`, `.gitconfig` or `usercustomize.py` planted there never reaches it. Outside your home it reads only the
system and developer folders `run_command` may read ([security.md](security.md)). HOME is a fresh folder inside the
staging folder, git is the real binary (not the xcrun stub), and pip and Python read no user configuration. The
script:

1. picks a Python 3.10 or newer from Homebrew (`/opt/homebrew/bin/python3.13` … `python3.10`), or stops and says
   so (see below);
2. empties the staging folder, except the downloaded tool archives (`tools/dist`, which `idf_tools.py` checks
   against their published hashes), so every install starts fresh;
3. clones that tag of `https://github.com/espressif/esp-idf.git` into `<staging>/idf` (shallow, with submodules,
   hooks off);
4. runs `install.sh <targets>` (with `IDF_TOOLS_PATH=<staging>/tools`) and then installs `cmake` and `ninja`
   into ESP-IDF's Python environment from PyPI.

Everything goes through the gatekeeper proxy (GitHub, PyPI and Espressif's servers are allowed by default) and
is recorded in the activity feed and the audit log like any job.

### Then the app copies it

When the job ends well, the app copies `idf`, `tools` and `python-bin` from the staging folder to
`toolchains/esp-idf-<version>`, as you:

- **The copy runs in a sandbox of its own** that reads only the staging folder and writes only the new install.
  bsdtar copies links as links and drops set-id bits. It leaves out `.git` (its hooks and config would run if you
  ran git there), Python byte code and the downloaded archives. `idf/version.txt` names the version instead of git.
- **Then it's checked and locked.** Folders become 0755 and files 0755 or 0644. Text files and links that name the
  staging folder are rewritten to name the install (Python's scripts and `pyvenv.cfg` hold absolute paths). Links
  that lead nowhere are removed. Every other link must resolve into the install, or into `/opt/homebrew`, `/usr`
  (not `/usr/local`), `/bin`, `/sbin`, `/System`, `/Library/Developer` or Xcode. Any file that still names the
  staging folder or the agent's home or TMPDIR fails the install.
- **Its hash is recorded** in `esp-idf-<version>.sha256` next to it, the audit log ("toolchain …: sha256 …") and the
  job's result. The hash covers every path, mode, file content and link target.
- **The toolchain folder is yours alone.** Its inherited ACL from the Developer folder is removed and replaced by a
  deny entry for `claude-agent` (write, delete, add, change permissions), inherited by everything in it. No sandbox
  profile lets an agent process write there either.

Only then does the new install replace an earlier one of that version. If anything fails, nothing new is left and
the earlier install is back in place. **Replacing an install:** run `esp_idf_install` again with the same
version. That's also how to add targets. Your old `~/esp` install (from before this) is simply ignored; delete it
whenever you like.

Before a flasher runs, the app checks once per app launch that its install still matches the recorded hash and
that every file is yours, writable by nobody else and without an ACL that allows anything. If not, the flasher
doesn't start ("the flasher's toolchain cannot be trusted"); reinstall to fix it.

Use it instead of a wrapper script in the session folder. Such a script runs whatever it contains with
everything the sandbox allows (threat-model gap 3); the install tool runs only the fixed script.

## Known problems on macOS

Observed with ESP-IDF v5.4:

- **macOS's own Python 3.9 leaves the environment broken.** Python 3.9's `importlib.metadata` doesn't find
  packages whose installed metadata uses normalised names (`ruamel.yaml`, `ruamel.yaml.clib`), so the Python
  environment `install.sh` builds with it doesn't work. Use Python 3.10 or newer: `brew install python@3.12` (as
  you, the owner). `esp_idf_install` picks it up, and stops with this advice if there is none.
- **cmake and ninja were missing.** macOS doesn't ship them, and builds need both. The pip wheels work:
  `esp_idf_install` installs them into ESP-IDF's Python environment, whose `bin` is on the flashers' PATH.
- **`/usr/bin/git` and `/usr/bin/python3` printed "couldn't create cache file …/T/xcrun_db-…".** These are xcrun
  stubs. They write a cache to the per-user Darwin temp folder (`getconf DARWIN_USER_TEMP_DIR`), not `TMPDIR`,
  and setting `DEVELOPER_DIR` or `xcrun_nocache` doesn't change that. CHANGING now lets the agent write its own
  Darwin temp and cache folders, after checking that they're owned by `claude-agent`, under `/private/var/folders`
  and not writable by anyone else.

## Flashing with the installed tools

Run flashers by absolute path from the install, `<I>` = `~/Developer/.dual-control/toolchains/esp-idf-<version>`
(see [claude-desktop.md](claude-desktop.md)):

- `<I>/idf/tools/idf.py -p <port> flash`, or the same through the Python environment's own interpreter:
  `<I>/tools/python_env/<env>/bin/python <I>/idf/tools/idf.py -p <port> flash`. That interpreter is a symlink to
  the Python the environment was made with. It counts as part of the install by its own path, as long as it sits
  directly in `python_env/<env>/bin`, no folder on the way is a symlink, and it still resolves to a Python.
- `<I>/tools/python_env/<env>/bin/esptool.py -p <port> write_flash …`.

Don't `source export.sh`: the app derives the install's environment itself and gives it to each flasher. For a
build in the shared terminal, set `IDF_TOOLS_PATH=<I>/tools` before sourcing `<I>/idf/export.sh`.

## New repositories in the session folder

`git clone` and `git init` can't work in the session folder: the agent may not create `.git` there
([security.md](security.md#gits-silent-auto-executors)). Claude uses `git_clone` (an https URL and a new folder)
and `git_init` (a folder without `.git`) instead. In the agent's own home, plain git works.
