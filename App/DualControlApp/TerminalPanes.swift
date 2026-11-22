import AppKit
import DualControlCore
import DualControlSandbox
import DualControlTerminal
import SwiftTerm
import SwiftUI

/// The shared terminal (D12c): two tabs, each its own tmux session as the agent, each at full size. A tab that is
/// hidden keeps running and gets a dot when output arrives. Side by side shows both. Take over (the baton) opens the
/// owner's own pane in the Agent tab; in the Second tab the owner can type into the agent's shell instead, which
/// locks only that tab for Claude.
struct TerminalPanes: View {
    let model: AppModel
    /// Bumped per tab to reattach its view after its client exits.
    @State private var attachment: [TerminalTab: Int] = [:]
    @State private var selected: TerminalTab = .agent
    @State private var sideBySide = false
    /// Tabs with output the owner has not seen.
    @State private var unseen: Set<TerminalTab> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Shared terminal").font(.headline)
                Text(batonText).foregroundStyle(.secondary)
                Spacer()
                Toggle("Side by side", isOn: $sideBySide)
                    .onChange(of: sideBySide) { unseen = [] }
                batonButtons
            }
            if case .takeoverRequested(let reason) = model.supervisor.engine.baton {
                Label("Claude asks you to take over: \(reason)", systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .task { model.scanHookFiles() }
                HookFilesNote(found: model.hookFiles)
            }
            if let error = model.terminalError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if !sideBySide {
                Picker("Tab", selection: $selected) {
                    ForEach(TerminalTab.allCases, id: \.self) { tab in
                        Text((unseen.contains(tab) ? "● " : "") + label(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: selected) {
                    unseen.remove(selected)
                    if selected == .second { model.refreshSecondTab() }
                }
            }
            if sideBySide {
                HStack(spacing: 8) {
                    ForEach(TerminalTab.allCases, id: \.self) { tab in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(tab)).font(.subheadline.bold())
                            tabContent(tab, visible: true)
                        }
                    }
                }
            } else {
                // Both stay alive at the same size; only the selected one shows and takes clicks.
                ZStack {
                    ForEach(TerminalTab.allCases, id: \.self) { tab in
                        tabContent(tab, visible: tab == selected)
                            .opacity(tab == selected ? 1 : 0)
                            .allowsHitTesting(tab == selected)
                    }
                }
            }
        }
    }

    private func label(_ tab: TerminalTab) -> String {
        tab.label(currentCommand: tab == .second ? model.secondTabCommand : nil)
    }

    @ViewBuilder private func tabContent(_ tab: TerminalTab, visible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if tab == .agent, model.ownerPaneOpen, let root = model.supervisor.scope?.root {
                Text(
                    "Your pane: runs as you, not sandboxed, and starts in your home so no shell hook runs Claude's "
                        + "files. Hand back closes it and forgets cached sudo credentials."
                )
                .font(.caption)
                .foregroundStyle(.orange)
                EnterFolderLine(line: SharedTerminal.enterSessionFolder(root))
                HookFilesNote(found: model.hookFiles)
                OwnerPane(handingBack: model.handingBack, closed: model.ownerPaneClosed)
                    .frame(minHeight: 260)
            } else if let terminal = model.terminal, let argv = try? terminal.attachArgv(tab: tab) {
                let typing = model.supervisor.ownerTypingTabs.contains(tab)
                if tab == .second { typingRow(typing) }
                AgentPane(
                    argv: argv,
                    interactive: typing && visible,
                    output: { if !visible { unseen.insert(tab) } },
                    ended: {
                        // At most once a second, so a dead tmux server cannot make the view respawn sudo in a loop.
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            attachment[tab, default: 0] += 1
                        }
                    }
                )
                .id("\(terminal.sandbox.scope.root)#\(tab.rawValue)#\(attachment[tab, default: 0])")
                .frame(minHeight: 260)
            } else {
                Text("The shared terminal starts once a session folder is chosen and the sandbox self-test passes.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }

    /// Typing into the agent's second tab: the owner's keystrokes go to Claude's shell, as the agent, sandboxed.
    @ViewBuilder private func typingRow(_ typing: Bool) -> some View {
        HStack(spacing: 8) {
            if typing {
                Text(
                    "You are typing into Claude's shell, as claude-agent, inside its sandbox. Claude can read what you "
                        + "type here: never type a password you use anywhere else."
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            Spacer()
            Button(typing ? "Stop typing" : "Type here") { model.setOwnerTyping(in: .second, !typing) }
                .controlSize(.small)
                .disabled(model.supervisor.engine.isStopped)
        }
    }

    private var batonText: String {
        switch model.supervisor.engine.baton {
        case .claude: return "Claude has the baton; you are watching."
        case .owner: return "You have the baton; Claude's input is locked."
        case .takeoverRequested: return "Claude is waiting for you."
        }
    }

    @ViewBuilder private var batonButtons: some View {
        switch model.supervisor.engine.baton {
        case .claude:
            Button("Take over", action: takeOver).disabled(model.supervisor.scope == nil)
        case .owner:
            Button("Hand back", action: model.handBack).disabled(model.handingBack)
        case .takeoverRequested:
            Button("Decline", action: model.declineTakeover)
            Button("Take over", action: takeOver).buttonStyle(.borderedProminent)
        }
    }

    /// The owner's pane opens in the Agent tab, so that tab comes to the front.
    private func takeOver() {
        selected = .agent
        model.takeOver()
    }
}

/// A tab's pane: a tmux client running as the agent inside the sandbox. View only (keystrokes dropped) unless the
/// owner chose to type in this tab.
private struct AgentPane: NSViewRepresentable {
    let argv: [String]
    let interactive: Bool
    let output: @MainActor () -> Void
    let ended: @MainActor @Sendable () -> Void

    func makeNSView(context: Context) -> ViewOnlyTerminalView {
        let view = ViewOnlyTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.onOutput = output
        view.startProcess(
            executable: argv[0],
            args: Array(argv.dropFirst()),
            environment: ["TERM=xterm-256color"],
            currentDirectory: "/"
        )
        return view
    }

    func updateNSView(_ view: ViewOnlyTerminalView, context: Context) {
        view.onOutput = output
        if interactive != view.acceptsInput {
            view.acceptsInput = interactive
            if interactive { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        }
    }

    static func dismantleNSView(_ view: ViewOnlyTerminalView, coordinator: Coordinator) {
        view.terminate()
    }

    func makeCoordinator() -> Coordinator { Coordinator(ended: ended) }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let ended: @MainActor @Sendable () -> Void
        init(ended: @escaping @MainActor @Sendable () -> Void) { self.ended = ended }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let ended = self.ended
            Task { @MainActor in ended() }
        }
    }
}

/// The line that takes the owner's pane into the session folder: theirs to type or paste, so entering it is a choice.
private struct EnterFolderLine: View {
    let line: String

    var body: some View {
        HStack {
            Text(verbatim: line)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            }
            .controlSize(.small)
            .help("Copy this line, to paste into your pane")
        }
    }
}

/// Shell-hook files in the session folder, which Claude may have written: entering their folder in the owner's own
/// shell runs or loads them as the owner (direnv, mise, asdf, nvm, autoenv, dotenv plugins).
private struct HookFilesNote: View {
    let found: ShellHookFiles.Found?
    private static let shown = 8

    var body: some View {
        if let found, !found.files.isEmpty || found.incomplete {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    "Check before you cd there: your shell hooks (direnv, mise, asdf, nvm, autoenv) act on these "
                        + "files in the session folder, which Claude may have written.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                ForEach(found.files.prefix(Self.shown), id: \.self) { file in
                    Text(verbatim: DisplayText.summary(file, limit: 160))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if found.files.count > Self.shown {
                    Text("and \(found.files.count - Self.shown) more").font(.caption).foregroundStyle(.secondary)
                }
                if found.incomplete {
                    Text("The folder is too large to check completely; there may be more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The owner's pane: their login shell, as themselves, in their home. Not in the session folder: shell hooks
/// (direnv, mise, nvm and others) would act on files the agent wrote there as soon as the shell started.
private struct OwnerPane: NSViewRepresentable {
    let handingBack: Bool
    let closed: @MainActor @Sendable () -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let inherited = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "SHELL"].compactMap { key in
            ProcessInfo.processInfo.environment[key].map { "\(key)=\($0)" }
        }
        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: inherited + ["TERM=xterm-256color"],
            execName: "-" + (shell.split(separator: "/").last.map(String.init) ?? "zsh"),
            currentDirectory: NSHomeDirectory()
        )
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        if handingBack, !context.coordinator.sentHandBack {
            context.coordinator.sentHandBack = true
            view.send(txt: SharedTerminal.handBackText)
            // Closed for sure after a moment, whatever the shell does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { view.terminate() }
        }
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        view.terminate()
    }

    func makeCoordinator() -> Coordinator { Coordinator(closed: closed) }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let closed: @MainActor @Sendable () -> Void
        var sentHandBack = false
        init(closed: @escaping @MainActor @Sendable () -> Void) { self.closed = closed }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let closed = self.closed
            Task { @MainActor in closed() }
        }
    }
}
