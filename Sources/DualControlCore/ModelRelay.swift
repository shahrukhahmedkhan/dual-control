import Foundation

/// D11 phase 2: the model relay. Claude Code inside the shared terminal reaches Anthropic's API only through the app,
/// on 127.0.0.1, with a per-session token (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`). The app adds the owner's
/// API key, kept in the owner's keychain, and forwards to `https://api.anthropic.com`, so no agent process ever holds
/// a credential worth stealing: the token works only on the relay, only while the session runs. The gatekeeper's
/// allowlist is unchanged; `api.anthropic.com` stays out of the agent's reach.
///
/// Only `POST /v1/messages` and `/v1/messages/count_tokens` (optionally `?beta=true`) pass, with a Content-Length
/// body; the headers that go upstream are an allowlist (never the agent's `authorization` or `x-api-key`). Every
/// request is audited with its model, status, sizes and duration, never its body.
public struct ModelRelayEndpoint: Sendable, Equatable {
    /// The relay's TCP port on 127.0.0.1.
    public let port: UInt16
    let token: String

    /// An endpoint, or `nil` unless `port` is non-zero and `token` is at least 32 lowercase hex digits.
    public init?(port: UInt16, token: String) {
        guard port != 0, token.utf8.count >= 32,
            token.utf8.allSatisfy({ NetworkHost.isDigit($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) })
        else { return nil }
        self.port = port
        self.token = token
    }

    /// What agent processes get: the relay's URL and the session token. Nothing else.
    public var variables: [String: String] {
        ["ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)", "ANTHROPIC_AUTH_TOKEN": token]
    }

    /// True if `value` is the token, compared in constant time.
    func matches(_ value: String) -> Bool {
        let given = Array(value.utf8)
        let expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// A request head sent to the relay: the request line and headers, nothing of the body.
public struct RelayRequestHead: Sendable, Equatable {
    /// Why a head cannot be read.
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        /// Why, for the 400 reply.
        public let description: String
    }

    /// The outcome of parsing bytes received so far.
    public enum Parse: Sendable, Equatable {
        /// More bytes are needed.
        case incomplete
        /// The head, and how many bytes it took (the body follows).
        case complete(RelayRequestHead, Int)
    }

    /// The largest head accepted.
    public static let maxHeadBytes = 64 << 10

    /// The method, e.g. `POST`.
    public let method: String
    /// The request target as sent, e.g. `/v1/messages?beta=true`.
    public let target: String
    /// The headers in order, names lowercased.
    public let headers: [(String, String)]

    /// Every value of header `name`.
    public func values(_ name: String) -> [String] {
        let name = name.lowercased()
        return headers.filter { $0.0 == name }.map(\.1)
    }

    /// The single value of header `name`, or `nil` if it is missing or repeated.
    public func value(_ name: String) -> String? {
        let all = values(name)
        return all.count == 1 ? all[0] : nil
    }

    /// Reads a head from the bytes received so far: HTTP/1.1 only, no folded or malformed headers, printable ASCII.
    public static func parse(_ bytes: [UInt8]) throws(ParseError) -> Parse {
        let end: Int? = bytes.withUnsafeBytes { buffer in
            let needle: [UInt8] = [13, 10, 13, 10]
            guard buffer.count >= 4 else { return nil }
            for index in 0...(buffer.count - 4) where buffer[index] == 13 {
                if buffer[index + 1] == needle[1], buffer[index + 2] == 13, buffer[index + 3] == 10 { return index }
            }
            return nil
        }
        guard let end else {
            if bytes.count > maxHeadBytes { throw ParseError(description: "the request head is too large") }
            return .incomplete
        }
        guard end + 4 <= maxHeadBytes else { throw ParseError(description: "the request head is too large") }
        guard bytes[..<end].allSatisfy({ $0 == 9 || $0 == 13 || $0 == 10 || (32...126).contains($0) }) else {
            throw ParseError(description: "the request head is not printable ASCII")
        }
        let text = String(decoding: bytes[..<end], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1", !requestLine[0].isEmpty, !requestLine[1].isEmpty
        else { throw ParseError(description: "not an HTTP/1.1 request line") }
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw ParseError(description: "a header is malformed")
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                throw ParseError(description: "a header name is malformed")
            }
            headers.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return .complete(
            RelayRequestHead(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers),
            end + 4
        )
    }

    /// Same method, target and headers in the same order.
    public static func == (lhs: RelayRequestHead, rhs: RelayRequestHead) -> Bool {
        lhs.method == rhs.method && lhs.target == rhs.target && lhs.headers.elementsEqual(rhs.headers) { $0 == $1 }
    }
}

/// What the relay does with a request.
public enum RelayDecision: Sendable, Equatable {
    /// Forward `path` (the target as sent) upstream with a body of `length` bytes and these headers, to which the app
    /// adds the owner's key.
    case forward(path: String, length: Int, headers: [(String, String)])
    /// Refuse with this status and reason.
    case refuse(Int, String)

    /// The same decision with the same details.
    public static func == (lhs: RelayDecision, rhs: RelayDecision) -> Bool {
        switch (lhs, rhs) {
        case (.forward(let a, let b, let c), .forward(let d, let e, let f)):
            return a == d && b == e && c.elementsEqual(f) { $0 == $1 }
        case (.refuse(let a, let b), .refuse(let c, let d)): return a == c && b == d
        default: return false
        }
    }
}

/// The relay's rules (pure).
public enum ModelRelayPolicy {
    /// Where requests go.
    public static let upstream = "https://api.anthropic.com"
    /// The largest request body accepted.
    public static let maxBodyBytes = 32 << 20
    /// The only paths that pass.
    public static let paths: Set<String> = ["/v1/messages", "/v1/messages/count_tokens"]
    /// The only query that passes.
    public static let queries: Set<String> = ["", "beta=true"]
    /// Request headers that go upstream: what the API reads. Prefixes end with `-`.
    static let forwardedHeaders: Set<String> = [
        "content-type", "accept", "user-agent", "anthropic-version", "anthropic-beta", "x-app",
        "x-claude-code-session-id",
    ]
    static let forwardedPrefixes = ["x-stainless-"]
    /// Response headers that come back: the body's type and what clients use to back off.
    public static let returnedHeaders: Set<String> = ["content-type", "request-id", "retry-after", "x-should-retry"]
    /// Prefixes of response headers that come back.
    public static let returnedPrefixes = ["anthropic-ratelimit-"]

    /// What to do with `head`, for a relay with `endpoint`.
    public static func decide(_ head: RelayRequestHead, endpoint: ModelRelayEndpoint) -> RelayDecision {
        let bearer = head.value("authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        guard bearer.map(endpoint.matches) == true || head.value("x-api-key").map(endpoint.matches) == true else {
            return .refuse(401, "the session token is missing or wrong")
        }
        let parts = head.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let query = parts.count > 1 ? String(parts[1]) : ""
        guard paths.contains(path), queries.contains(query) else {
            return .refuse(404, "only the messages endpoints are relayed")
        }
        guard head.method == "POST" else { return .refuse(405, "only POST is relayed") }
        guard head.values("transfer-encoding").isEmpty, !head.values("content-length").isEmpty else {
            return .refuse(411, "a Content-Length is required")
        }
        guard let text = head.value("content-length"), (1...10).contains(text.count),
            text.allSatisfy({ ("0"..."9").contains($0) }), let length = Int(text)
        else { return .refuse(400, "the Content-Length is not valid") }
        guard length <= maxBodyBytes else { return .refuse(413, "the request is too large") }
        let headers = head.headers.filter { name, _ in
            forwardedHeaders.contains(name) || forwardedPrefixes.contains { name.hasPrefix($0) }
        }
        return .forward(path: head.target, length: length, headers: headers)
    }

    /// Why `key` cannot be saved as the owner's API key, or `nil`: `sk-ant-` and printable characters without spaces.
    public static func keyProblem(_ key: String) -> String? {
        guard key.hasPrefix("sk-ant-"), (20...256).contains(key.utf8.count),
            key.utf8.allSatisfy({ (33...126).contains($0) })
        else { return "that is not an Anthropic API key (sk-ant-…)" }
        return nil
    }

    /// The request's `model`, for the audit log, or `?`: short, printable, nothing else of the body.
    public static func model(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let model = object["model"] as? String, (1...100).contains(model.utf8.count),
            model.utf8.allSatisfy({ (33...126).contains($0) })
        else { return "?" }
        return model
    }
}

/// One request through the relay, for the audit log and the feed.
public struct ModelRelayExchange: Sendable, Equatable {
    /// The relay's number for it.
    public let number: Int
    /// The request target.
    public let path: String
    /// The model it named, or `?`.
    public let model: String
    /// The status the agent got.
    public let status: Int
    /// Body bytes sent upstream.
    public let bytesUp: Int
    /// Body bytes returned.
    public let bytesDown: Int
    /// Seconds it took.
    public let duration: TimeInterval
    /// Why the relay refused it itself, or `nil`.
    public let refusal: String?
    /// The tokens the answer used, from its `usage` fields (D12e); `nil` if it had none.
    public let usage: RelayUsage?

    /// What it cost, in US dollars, at the conservative price table.
    public var cost: Double { usage?.cost(model: model) ?? 0 }

    /// An exchange.
    public init(
        number: Int,
        path: String,
        model: String,
        status: Int,
        bytesUp: Int,
        bytesDown: Int,
        duration: TimeInterval,
        refusal: String?,
        usage: RelayUsage? = nil
    ) {
        self.number = number
        self.path = path
        self.model = model
        self.status = status
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.duration = duration
        self.refusal = refusal
        self.usage = usage
    }
}
