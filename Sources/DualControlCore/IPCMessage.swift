import Foundation

/// The wire format between `dualcontrol-shim` and the app: newline-delimited JSON, one message per line.
///
/// JSON encoding never emits a raw newline, so a newline always ends a message. Both sides reject lines over
/// `maxMessageBytes` and messages with a different `version`.
public enum IPCProtocol {
    /// Wire format version. Bump on any incompatible change.
    public static let version = 1
    /// Largest accepted message, excluding the trailing newline.
    public static let maxMessageBytes = 1 << 20
    /// Longest accepted request id.
    public static let maxIDLength = 128

    /// Encodes a message as one line, newline included. Throws `IPCFailure.tooLarge` over the size limit.
    public static func frame<Message: Encodable>(_ message: Message) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(message)
        guard data.count <= maxMessageBytes else {
            throw IPCFailure(code: .tooLarge, message: "message is larger than \(maxMessageBytes) bytes")
        }
        data.append(0x0A)
        return data
    }

    /// Decodes and checks one request line (without its newline).
    public static func decodeRequest(_ line: Data) -> Result<IPCRequest, IPCFailure> {
        guard line.count <= maxMessageBytes else {
            return .failure(IPCFailure(code: .tooLarge, message: "message is larger than \(maxMessageBytes) bytes"))
        }
        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: line) else {
            return .failure(IPCFailure(code: .malformed, message: "not a valid request"))
        }
        guard request.version == version else {
            return .failure(
                IPCFailure(code: .unsupportedVersion, message: "expected version \(version), got \(request.version)")
            )
        }
        guard !request.id.isEmpty, request.id.utf8.count <= maxIDLength else {
            return .failure(IPCFailure(code: .malformed, message: "request id must be 1–\(maxIDLength) bytes"))
        }
        return .success(request)
    }

    /// Decodes one response line (without its newline) and checks it answers `requestID`.
    public static func decodeResponse(_ line: Data, requestID: String) -> Result<IPCResponse, IPCFailure> {
        guard line.count <= maxMessageBytes else {
            return .failure(IPCFailure(code: .tooLarge, message: "message is larger than \(maxMessageBytes) bytes"))
        }
        guard let response = try? JSONDecoder().decode(IPCResponse.self, from: line) else {
            return .failure(IPCFailure(code: .malformed, message: "not a valid response"))
        }
        guard response.version == version else {
            return .failure(
                IPCFailure(code: .unsupportedVersion, message: "expected version \(version), got \(response.version)")
            )
        }
        guard response.id == requestID, (response.result == nil) != (response.failure == nil) else {
            return .failure(IPCFailure(code: .malformed, message: "response does not match the request"))
        }
        return .success(response)
    }
}

/// A tool call forwarded from the shim to the app.
public struct IPCRequest: Sendable, Equatable, Codable {
    /// Wire format version; must equal `IPCProtocol.version`.
    public var version: Int
    /// Caller-chosen id, echoed in the response.
    public var id: String
    /// Tool name from the catalogue.
    public var tool: String
    /// Tool arguments as sent by the MCP client. Not validated yet.
    public var arguments: [String: JSONValue]

    /// Creates a request for the current protocol version.
    public init(id: String, tool: String, arguments: [String: JSONValue] = [:]) {
        self.version = IPCProtocol.version
        self.id = id
        self.tool = tool
        self.arguments = arguments
    }
}

/// The app's answer to one request: either a tool result or a protocol failure.
public struct IPCResponse: Sendable, Equatable, Codable {
    /// Wire format version.
    public var version: Int
    /// The request id, or empty if the request could not be read.
    public var id: String
    /// The tool result, if the request was understood.
    public var result: ToolResult?
    /// Why the request was rejected, if it was.
    public var failure: IPCFailure?

    /// A successful response.
    public init(id: String, result: ToolResult) {
        self.version = IPCProtocol.version
        self.id = id
        self.result = result
        self.failure = nil
    }

    /// A rejected request.
    public init(id: String, failure: IPCFailure) {
        self.version = IPCProtocol.version
        self.id = id
        self.result = nil
        self.failure = failure
    }
}

/// A protocol-level error (as opposed to a tool result with `isError`).
public struct IPCFailure: Error, Sendable, Equatable, Codable {
    /// What went wrong.
    public var code: IPCFailureCode
    /// Human-readable detail.
    public var message: String

    /// Creates a failure.
    public init(code: IPCFailureCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// Protocol error categories.
public enum IPCFailureCode: String, Sendable, Codable {
    /// Not valid JSON, missing fields or a bad id.
    case malformed
    /// Over `IPCProtocol.maxMessageBytes`.
    case tooLarge
    /// A different `IPCProtocol.version`.
    case unsupportedVersion
    /// The message did not arrive in time.
    case timeout
    /// The app failed to answer.
    case internalError
}
