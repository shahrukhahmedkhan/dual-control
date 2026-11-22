#if os(macOS)
    import AppKit
    import Foundation
    import SwiftTerm
    import Testing

    @testable import DualControlTerminal

    /// Records what a terminal asks of its host.
    private final class Host: TerminalDelegate {
        var copied: [Data] = []
        var notified: [String] = []
        var colours = 0

        func clipboardCopy(source: Terminal, content: Data) { copied.append(content) }
        func notify(source: Terminal, title: String, body: String) { notified.append(title + body) }
        func setForegroundColor(source: Terminal, color: Color) { colours += 1 }
        func setBackgroundColor(source: Terminal, color: Color) { colours += 1 }
        func setCursorColor(source: Terminal, color: Color?) { colours += 1 }
        func colorChanged(source: Terminal, idx: Int?) { colours += 1 }
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
        func selectionChanged(source: Terminal) {}
        func isProcessTrusted(source: Terminal) -> Bool { true }
    }

    private let esc = "\u{1b}"
    private let bel = "\u{7}"
    /// "rm -rf ~\n", base64.
    private let payload = Data("rm -rf ~\n".utf8).base64EncodedString()

    private func terminal(hardened: Bool) -> (Terminal, Host) {
        let host = Host()
        let terminal = Terminal(delegate: host)
        if hardened { ViewOnlyTerminal.harden(terminal) }
        return (terminal, host)
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// The ways an OSC 52 copy can arrive: 7-bit with BEL or ST, 8-bit C1 introducer after a CSI start (the parser
    /// takes 0x9D as OSC in any state but ground), and after a full reset.
    private let copies: [[UInt8]] = [
        bytes("\(esc)]52;c;\(payload)\(bel)"),
        bytes("\(esc)]52;c;\(payload)\(esc)\\"),
        bytes("\(esc)[") + [0x9d] + bytes("52;c;\(payload)\(bel)"),
        bytes("\(esc)c\(esc)]52;c;\(payload)\(bel)"),
    ]

    @Test func swiftTermCopiesOSC52ToTheHostUnlessHardened() {
        for sequence in copies {
            // The gap: without hardening, agent output reaches the clipboard.
            let (plain, plainHost) = terminal(hardened: false)
            plain.feed(byteArray: sequence)
            #expect(plainHost.copied == [Data("rm -rf ~\n".utf8)])

            let (hardened, host) = terminal(hardened: true)
            hardened.feed(byteArray: sequence)
            #expect(host.copied.isEmpty)
        }
    }

    @Test func aCopySplitAcrossReadsIsDroppedToo() {
        let (hardened, host) = terminal(hardened: true)
        let sequence = copies[0]
        for byte in sequence { hardened.feed(byteArray: [byte]) }
        #expect(host.copied.isEmpty)
    }

    @Test func hyperlinksAreNotAttachedToText() {
        let link = bytes("\(esc)]8;;https://example.com/x\(bel)click\(esc)]8;;\(bel)")

        let (plain, _) = terminal(hardened: false)
        plain.feed(byteArray: link)
        #expect(plain.getCharData(col: 0, row: 0)?.getPayload() != nil)

        let (hardened, _) = terminal(hardened: true)
        hardened.feed(byteArray: link)
        #expect(hardened.getCharData(col: 0, row: 0)?.getPayload() == nil)
        // The text itself still shows.
        #expect(hardened.getLine(row: 0)?.translateToString(trimRight: true) == "click")
    }

    @Test func noOSCChangesColoursNotifiesOrTitles() {
        let sequences = bytes(
            "\(esc)]10;rgb:00/00/00\(bel)\(esc)]11;rgb:00/00/00\(bel)\(esc)]12;rgb:ff/00/00\(bel)"
                + "\(esc)]4;1;rgb:00/00/00\(bel)\(esc)]104\(bel)\(esc)]112\(bel)"
                + "\(esc)]777;notify;Dual Control;Approved\(bel)\(esc)]0;title\(bel)"
        )
        let (plain, plainHost) = terminal(hardened: false)
        plain.feed(byteArray: sequences)
        #expect(plainHost.colours > 0)
        #expect(!plainHost.notified.isEmpty)

        let (hardened, host) = terminal(hardened: true)
        let before = (hardened.foregroundColor, hardened.backgroundColor)
        hardened.feed(byteArray: sequences)
        #expect(host.colours == 0)
        #expect(host.notified.isEmpty)
        #expect(hardened.foregroundColor == before.0)
        #expect(hardened.backgroundColor == before.1)
    }

    @Test func everyOSCCodeSwiftTermHandlesIsNeutralised() {
        // From EscapeSequenceParser.dispatchOsc in SwiftTerm 1.10.1. Re-read it when SwiftTerm is updated.
        #expect(ViewOnlyTerminal.neutralisedOSC == [0, 1, 2, 4, 6, 7, 8, 9, 10, 11, 12, 52, 104, 112, 777, 1337])
    }

    @MainActor @Test func theViewDropsKeystrokesUnlessTheOwnerTypesAndReportsOutput() {
        let view = ViewOnlyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        #expect(!view.acceptsInput)
        var outputs = 0
        view.onOutput = { outputs += 1 }
        view.dataReceived(slice: bytes("hello")[...])
        #expect(outputs == 1)
        #expect(view.terminal.getLine(row: 0)?.translateToString(trimRight: true) == "hello")
        // Still hardened while it takes input.
        view.acceptsInput = true
        let before = NSPasteboard.general.changeCount
        view.dataReceived(slice: copies[0][...])
        #expect(NSPasteboard.general.changeCount == before)
    }

    @MainActor @Test func theViewOnlyViewLeavesThePasteboardAlone() {
        let view = ViewOnlyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let before = NSPasteboard.general.changeCount
        for sequence in copies { view.feed(byteArray: sequence[...]) }
        #expect(NSPasteboard.general.changeCount == before)
    }
#endif
