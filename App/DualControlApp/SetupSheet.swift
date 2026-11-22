import AppKit
import DualControlCore
import DualControlSandbox
import SwiftUI

/// The one-time admin steps, as commands to paste into Terminal, and "Check setup". The app never runs the admin
/// steps itself.
struct SetupSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent setup").font(.title2.bold())
            Text(
                "Run these once, in order, in Terminal. They need your admin password. Dual Control only shows them."
            )
            .foregroundStyle(.secondary)
            if let guide = model.setupGuide {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(guide.steps.enumerated()), id: \.element.id) { index, step in
                            StepView(number: index + 1, step: step)
                        }
                    }
                }
                .frame(maxHeight: 340)
            } else {
                Text("Your account name or home folder cannot be put into commands safely.").foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button(model.isCheckingSetup ? "Checking…" : "Check setup", action: model.checkSetup)
                    .disabled(model.isCheckingSetup)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ForEach(model.setupItems) { item in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: item.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(item.passed ? .green : .red)
                    Text(item.title)
                    Spacer()
                    Text(DisplayText.escaped(item.detail))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(20)
        .frame(width: 720)
    }

    private struct StepView: View {
        let number: Int
        let step: SetupGuide.Step

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(number). \(step.title)").font(.headline)
                Text(step.explanation).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(step.command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(step.command, forType: .string)
                    }
                }
            }
        }
    }
}
