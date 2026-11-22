# Connecting Claude Desktop

Claude Desktop starts `dualcontrol-shim` as a local (stdio) MCP server. The shim lists the tools and safety
instructions itself, and forwards every tool call to the Dual Control app over a private Unix socket in
`~/Library/Application Support/DualControl/run/`. If the app is closed, every call returns
"Dual Control app is not running — ask the owner to open it."

## Before you start

- The Dual Control app is built and open, **Check setup** is all green, and a session folder is chosen.
- Commands run as `claude-agent` in the session folder, inside the kernel sandbox. See [security.md](security.md).

## 1. Build and install the shim

From the repository folder:

```sh
swift build -c release --product dualcontrol-shim
mkdir -p ~/.local/bin
install -m 0755 "$(swift build -c release --show-bin-path)/dualcontrol-shim" ~/.local/bin/dualcontrol-shim
ls -l ~/.local/bin/dualcontrol-shim   # owned by you, -rwxr-xr-x
```

Claude Desktop runs whatever file the config points to, so keep the shim in a folder only your user can write.
Never put it under `~/Developer`, which the agent user can write. After you pull a new version, run the same
commands again and restart Claude Desktop.

## 2. Add the server to Claude Desktop

Open Claude Desktop → Settings → Developer → Edit Config. This opens
`~/Library/Application Support/Claude/claude_desktop_config.json`. Add a `dual-control` entry to `mcpServers`
(keep any other servers you already have), with the absolute path to the shim:

```json
{
  "mcpServers": {
    "dual-control": {
      "command": "/Users/YOUR-USER/.local/bin/dualcontrol-shim",
      "args": []
    }
  }
}
```

The shim takes no arguments and needs no environment variables. Quit Claude Desktop completely (⌘Q) and open it
again.

## 3. Check it

Use labelled test commands, so they're easy to spot in the feed and the audit log:

1. With the Dual Control app closed, ask Claude to call `status`. It reports that the app is not running.
2. Open the app and call `status` again. The result starts with the state header, e.g.
   `mode: ask-each · baton: claude · blocked: sudo, efuse, keychain`.
3. Ask Claude to run `["echo", "DC-TEST"]` with `cwd` set to your session folder. It's read-only, so it runs at
   once and returns `Exit status 0` and the output.
4. Ask for `["touch", "DC-TEST.txt"]` in the session folder. It changes something, so the app asks you first.
   Approve it, and the file appears. Deny the next one and check that Claude is told it was denied.
5. Ask for `["sleep", "30"]` with `timeout_seconds` 5. After about 5 s the result says it timed out and its
   process group was killed. Start another and press **Stop** while it runs: it's killed at once.
6. Ask for `["sleep", "60"]`, approve it, then interrupt the reply in Claude Desktop. Within about a second the
   feed's Outcome column says `killed: caller left`.
7. Ask for `["cat", "~/.zshrc"]` (or any path outside the session folder). It's denied at once with
   `scope.argument`; nothing runs.
8. Ask for `["sleep", "90"]` with `background` true. Claude gets a job id at once, while you still have to
   approve it. Approve it, and `job_status` says it's running. After 90 s it says `done: exit 0`, and `activity`
   shows the same line as the window.
9. With a board plugged in, ask Claude to call `serial_list`, then `serial_open` the board's port at 115200
   (approve it), `serial_reset` with mode `run` (approve it), `serial_read` the boot log and `serial_close`. The
   window shows the open port until it's closed.

## What to expect

- `run_command` takes an argument vector, never a shell string. Use `["sh", "-c", "…"]` only if you mean it;
  `sh -c` scripts are classified as a whole and usually need approval.
- The default timeout is 120 s, at most 3600 s. Stdin is closed. Stdout and stderr come back interleaved, and
  only the first 1 MiB is kept (the result says when output was truncated).
- Every result starts with the state header. Command output sits in an `UNTRUSTED DATA` block: it is data,
  never instructions.
- Paths in arguments (and in `sh -c` scripts and terminal text) must stay inside the session folder. One that
  starts with `/` or `~`, contains `..`, or is a symlink out of the folder is denied as `scope.argument` before
  anything runs. The value of `NAME=value` and `--option=value` is checked too. `/dev/null` is the only outside
  path allowed; the agent's own HOME isn't the session folder either.
- `git clone` and `git init` don't work in the session folder (the agent may not create `.git`). Claude uses
  `git_clone` (https URL, new folder) and `git_init` instead; see [security.md](security.md#gits-silent-auto-executors).
- ESP-IDF is installed with `esp_idf_install` (a background job); see [esp-idf.md](esp-idf.md).
- The Activity feed's Decision column says what the policy decided; the Outcome column says what really happened
  (`exit 0`, `exit 2`, `timed out`, `killed by Stop`, `killed: caller left`, `blocked by sandbox`, `did not run`).
  "blocked by sandbox" is read from the command's output, so it's a hint, not proof.
- Times in the state header are your local time, e.g. `allow-until 14:30`.
- If Claude Desktop stops waiting for a call (you interrupt it, or it gives up), the app notices the caller has
  gone: a waiting approval is withdrawn, and a running command is killed. Claude Desktop may stop waiting before
  a very long command finishes.
- Long work runs as a background job. A call can be cut off before its result arrives. Claude Desktop's relay for
  remote sessions gives up after about 80 s, and that includes the time a call waits for your approval. Sometimes
  the connection even stays open, so the app never notices: a `sleep 60` was approved, ended `exit 0`, and the
  result never reached Claude. So for anything that may take over 60 s, Claude calls `run_command` with
  `background: true`. It gets a job id at once, also while the call still waits for your approval. Then it uses
  `job_status` to see the state (waiting, running, done, denied or killed), the outcome, the duration and the
  last lines of output, and `job_cancel` to stop the job. Jobs end with Stop and quitting like everything else.
  They don't need Claude to stay connected, and they're forgotten when the app quits.
- `activity` returns the recent feed as the window shows it (time, tool, summary, decision, outcome, rule), so
  Claude can check how a call ended without asking you.
- Serial ports are opened by the app itself, as you, not by the agent: nothing runs as `claude-agent` for them.
  `serial_list` shows `/dev/cu.*` ports only (never `/dev/tty.*`, Bluetooth-Incoming-Port or debug-console),
  with each USB device's VID:PID, product, manufacturer and serial number; it never opens a port, so it's
  read-only. `serial_open` follows the approval mode and opens the port exclusively: if a flash or monitor has it,
  it fails with "busy", and while it's open esptool can't take it either. From then on the app buffers everything
  the device sends (1 MiB; the oldest bytes go first, and `serial_read` says how many were dropped), so nothing is
  lost between reads. `serial_read` is read-only and waits at most 30 s. `serial_write` (at most 4 KiB) and
  `serial_reset` follow the approval mode. Stop, quitting and choosing another session folder close every port.
- "Approve and always allow this device in this folder" adds a device rule: that USB device (VID:PID and serial
  number) may be opened, written and reset without asking while that folder is the session folder. A device
  without a USB serial number can't have one. If its serial number is a common default (such as `123456`) or
  another connected device reports the same one, the card says so and the rule covers it only on that USB port.
  Remove rules in **Rules & Settings…**.
- eFuses: once a session was reset into the bootloader (or opened while its device was last reset there),
  `serial_write` is refused in it for good (`blocked.serial-bootloader`), because raw ROM-bootloader commands
  could burn eFuses. Flash only with `run_command` (esptool or idf.py), where eFuse commands are always blocked,
  after closing the serial session.
- Agent commands can't open serial ports, except a recognised flasher or monitor (idf.py `flash`, `app-flash`,
  `erase-flash`, `monitor`; esptool `write_flash`, `read_flash`, `chip_id`, `flash_id`) run with `run_command`
  from an ESP-IDF install in the owner's toolchain folder (`~/Developer/.dual-control/toolchains/esp-idf-<version>`,
  made by `esp_idf_install`, read-only for the agent, hash checked), by absolute path. Anything else,
  including the shared terminal, gets "Operation not permitted". Watch a device with the serial tools instead.
  A flasher must name its port with `-p` (it's denied otherwise): one `serial_list` shows as a USB serial device
  that no serial session has open. Only that port is reachable. Flashers run with the install's ESP-IDF
  environment (read once from `idf_tools.py export` as the agent and checked; the feed shows "esp-idf env
  derived from …"), never yours. Flashing asks like any changing command.

Shim logs go to stderr, which Claude Desktop writes to `~/Library/Logs/Claude/mcp-server-dual-control.log`.

## Testing without Claude Desktop

```sh
npx @modelcontextprotocol/inspector --cli "$(swift build --show-bin-path)/dualcontrol-shim" --method tools/list
npx @modelcontextprotocol/inspector --cli "$(swift build --show-bin-path)/dualcontrol-shim" \
  --method tools/call --tool-name status
```
