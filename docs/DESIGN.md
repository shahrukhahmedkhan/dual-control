# Design notes

Why the agent runs the way it does today, what happens if the main piece goes away, and how a move to virtual machines could look. [security.md](security.md) describes the walls in detail and the [threat model](THREAT-MODEL.md) what they don't stop.

## Why a separate user and sandbox-exec

Everything the assistant runs, runs as the standard user `claude-agent`, started with `sudo -n -u claude-agent` and wrapped in `sandbox-exec` with a Seatbelt profile for the session folder. There are two separate walls. Unix permissions keep the agent out of your home folder, your keychain and your SSH keys, and they don't depend on Seatbelt. The Seatbelt profile then limits where it can write, what it can read outside your home, and which network ports it can reach. Both are enforced by the kernel, and the agent's processes and all their children inherit them.

Three other ways to do this were considered:

- App Sandbox is meant for an app to confine itself. Every child process inherits the app's own sandbox, so the agent's commands would get the app's rights, not narrower ones, and the app itself would lose things it needs: opening serial ports, running `sudo` to the agent user, reading the owner's git config to push. It also can't give a compiler or `idf.py` a per-folder set of rights that changes with the session.
- A container (Docker and similar) on macOS runs inside a Linux VM. That helps for ESP-IDF, which has Linux builds, but not for Xcode or other macOS tools. USB serial devices can't be passed through to it on macOS, so flashing and the serial console would need a bridge anyway, and it adds a large runtime that has to be installed and kept up to date.
- A full VM gives the strongest isolation, because the agent no longer shares a kernel with you. It costs boot time, disk space, and serial access, which is the part that matters most for embedded work. Section 3 goes into this.

The separate user and sandbox-exec run at native speed, use the tools already installed on the Mac (Xcode, Homebrew, a protected ESP-IDF copy), and leave serial ports with the app, which opens them as you. The cost is that the agent shares your kernel, and that `sandbox-exec` is deprecated.

## If Apple removes sandbox-exec

`sandbox-exec` has been deprecated for years but still ships with macOS. Every agent process starts as `[sudo …] /usr/bin/sandbox-exec -p <profile> /usr/bin/env -i … <command>`, so there's no path that runs the command without it. If the binary is gone, the launch fails and nothing runs.

Before anything runs as the agent, the app runs a self-test as the agent (`Sandbox.selfTest()` in `Sources/DualControlSandbox/Sandbox.swift`). It checks that the CHANGING profile can write in the agent's temp folder but not next to the session folder, that the READ-ONLY profile can't write at all, and that a connection to a local port that isn't the proxy's doesn't get through. The test runs when you pick a session folder, when the app starts again with the last one, and when you run Check setup in the Setup sheet. It fails closed:

- If `/usr/bin/sandbox-exec` is missing or can't be started, the result is "sandbox-exec could not be started".
- If it starts but rejects the profile, the result is "the sandbox could not be applied", with the first part of its output.
- If it runs but no longer enforces something, the probe that got through names it, for example "a probe write outside the session folder succeeded".

Until the self-test passes, the session starts in the state "the sandbox self-test has not run", and on a failure the app keeps the reason. While a reason is set, every command and every executable file write is denied with the rule `sandbox.unavailable` and the reason in the result. Anything already waiting for approval is denied, and the last check right before anything runs refuses everything except the serial tools. The shared terminal isn't started, and a running one is stopped. Only the serial tools keep working, because the app opens the ports itself and no agent process is involved.

You'd notice in a few places: the failed check in the Setup sheet, the reason in every tool result the assistant gets, and a `sandboxChecked` entry in the audit log. The sandbox tests in `swift test` would also fail on that Mac. CI runs them on a pinned `macos-15` runner, so it would only show a change in a newer macOS once the runner is moved up.

The self-test doesn't check reads. Reads of your home folder are also blocked by Unix permissions, so a Seatbelt that stopped enforcing reads wouldn't open your files to the agent. It would still open things outside your home that the profile now keeps out, like `/Volumes` or `/Users/Shared`.

## Moving to a VM per folder

The longer-term plan is a VM per project folder on Virtualization.framework, with the app as the only way in and out: one shared folder, the proxy, serial forwarding, approvals, the audit log and Stop. These are the tradeoffs as currently understood. Points marked "to be verified" need a spike before the design relies on them.

Boot time. A small Linux guest should boot in a few seconds; a macOS guest takes much longer. Keeping the VM running for the whole session, and suspending it between sessions, would hide most of this. Real numbers on real hardware are to be verified.

USB and serial. This is the hard part for ESP32 work. Virtualization.framework appears to have no general USB passthrough on macOS 14. macOS 15 added a USB controller, but only for USB mass storage devices, so a USB serial adapter still can't be handed to the guest (to be verified on macOS 15 and later). What it does have is virtio console ports that the host connects to file handles. The app could keep opening the serial port itself, as it does now, and pass the bytes through such a port. A byte stream doesn't carry DTR and RTS, which esptool uses to reset the chip into the bootloader. Two ways around that: the app keeps doing resets itself (it already does for `serial_reset`), or the app runs an RFC 2217 server and esptool in the guest connects to it over the network with an `rfc2217://` port, which carries the control lines. Whether flashing works reliably through either is to be verified.

Network. A file-handle network attachment lets the host app see every frame the guest sends, so the app could stay the only way out, like the proxy today. NAT is simpler but gives the guest its own route out, so the proxy would have to be enforced inside the guest instead. Which one is practical is to be verified.

Shared folder. virtiofs shares a host folder with the guest. The session folder would be the only share. File ownership and permissions across the share, and whether file events reach the host quickly enough for the app's file checks, are to be verified.

Disk. Each VM needs its own disk image. A Linux image with ESP-IDF and its tools takes a few GB; a macOS guest needs a restore image and a much larger disk. Cloning one base image per folder with APFS clones would mean each folder only pays for its changes. That should work with sparse disk images, but it's to be verified.

Toolchains. Inside the guest, the assistant could install whatever a project needs without touching the host, which is the main reason to do this. ESP-IDF has Linux arm64 builds, so a Linux guest covers the embedded work. macOS-only tools like Xcode would need a macOS guest, which is larger and slower, and the macOS licence allows only a small number of macOS VMs per Mac. Installs would still go through the proxy and its host list. The protected toolchain folder could become a read-only share or a read-only disk image, so a project can't change it.

Apple's `container` tool runs each Linux container in its own small VM on the same framework. That may be a quicker way to try this than managing VMs directly. It needs macOS 26, which is to be verified against what the rest of the app supports.
