import Foundation
import Testing

@testable import DualControlCore

private func line(_ text: String) -> Data { Data(text.utf8) }

@Test func requestRoundTripsAsOneLine() throws {
    let request = IPCRequest(
        id: "42",
        tool: "run_command",
        arguments: [
            "argv": .array([.string("echo"), .string("a\nb")]), "n": .int(3), "x": .double(1.5), "z": .null,
            "ok": .bool(true), "o": .object(["k": .string("/v")]),
        ]
    )
    let framed = try IPCProtocol.frame(request)
    #expect(framed.last == 0x0A)
    #expect(framed.filter { $0 == 0x0A }.count == 1)
    #expect(try IPCProtocol.decodeRequest(framed.dropLast()).get() == request)
}

@Test func responseRoundTrips() throws {
    let ok = IPCResponse(id: "7", result: ToolResult(text: "H\nx", isError: false))
    #expect(try IPCProtocol.decodeResponse(IPCProtocol.frame(ok).dropLast(), requestID: "7").get() == ok)
    let failed = IPCResponse(id: "7", failure: IPCFailure(code: .malformed, message: "m"))
    #expect(try IPCProtocol.decodeResponse(IPCProtocol.frame(failed).dropLast(), requestID: "7").get() == failed)
}

@Test(
    arguments: [
        ("", IPCFailureCode.malformed),
        ("not json", .malformed),
        ("[]", .malformed),
        (#"{"version":1,"id":"1","tool":"status"}"#, .malformed),
        (#"{"version":1,"id":"","tool":"status","arguments":{}}"#, .malformed),
        (#"{"version":1,"id":1,"tool":"status","arguments":{}}"#, .malformed),
        (#"{"version":2,"id":"1","tool":"status","arguments":{}}"#, .unsupportedVersion),
        (#"{"version":1,"id":"\#(String(repeating: "i", count: 129))","tool":"s","arguments":{}}"#, .malformed),
    ]
)
func badRequestsAreRejected(_ text: String, _ code: IPCFailureCode) {
    guard case .failure(let failure) = IPCProtocol.decodeRequest(line(text)) else {
        Issue.record("accepted: \(text)")
        return
    }
    #expect(failure.code == code)
}

@Test func validMinimalRequestIsAccepted() throws {
    let request = try IPCProtocol.decodeRequest(line(#"{"version":1,"id":"a","tool":"status","arguments":{}}"#)).get()
    #expect(request == IPCRequest(id: "a", tool: "status"))
}

@Test func oversizeIsRejectedBothWays() {
    let big = Data(repeating: 0x20, count: IPCProtocol.maxMessageBytes + 1)
    #expect(throws: IPCFailure.self) { try IPCProtocol.decodeRequest(big).get() }
    let huge = IPCResponse(id: "1", result: ToolResult(text: String(repeating: "x", count: 1 << 20), isError: false))
    #expect(throws: IPCFailure(code: .tooLarge, message: "message is larger than 1048576 bytes")) {
        try IPCProtocol.frame(huge)
    }
}

@Test(
    arguments: [
        #"{"version":1,"id":"other","result":{"text":"t","isError":false}}"#,
        #"{"version":1,"id":"1"}"#,
        #"{"version":1,"id":"1","result":{"text":"t","isError":false},"failure":{"code":"timeout","message":"m"}}"#,
        #"{"version":9,"id":"1","result":{"text":"t","isError":false}}"#,
        "garbage",
    ]
)
func badResponsesAreRejected(_ text: String) {
    #expect(throws: IPCFailure.self) { try IPCProtocol.decodeResponse(line(text), requestID: "1").get() }
}
