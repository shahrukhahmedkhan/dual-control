/// Why the proxy refuses a request or response as HTTP.
public enum ProxyProtocolError: Error, Equatable, CustomStringConvertible {
    /// The head is longer than `ProxyRequest.maxHeadBytes`.
    case tooLarge
    /// Not well-formed HTTP/1.x, or ambiguous.
    case malformed(String)

    /// Why, for the refusal.
    public var description: String {
        switch self {
        case .tooLarge: return "the request head is too large"
        case .malformed(let why): return "malformed request: \(why)"
        }
    }
}

/// One header line, name as sent.
public struct HTTPHeader: Sendable, Equatable {
    /// The field name.
    public let name: String
    /// The field value, without surrounding spaces.
    public let value: String
}

/// How a request body ends.
public enum BodyFraming: Sendable, Equatable {
    /// No body.
    case none
    /// Exactly this many bytes.
    case length(Int)
    /// Chunked transfer coding; `ChunkedBodyScanner` finds the end.
    case chunked
}

/// A request to the gatekeeper proxy: `CONNECT host:port` or a plain-HTTP request in absolute form. Parsed strictly
/// (CRLF only, no folded or non-ASCII headers), since anything ambiguous could make the proxy and the server
/// disagree about where a request ends.
public struct ProxyRequest: Sendable, Equatable {
    /// The longest head accepted.
    public static let maxHeadBytes = 16 << 10
    /// The largest `Content-Length` accepted.
    public static let maxBodyBytes = 1 << 30

    /// Result of parsing what has arrived so far.
    public enum Parse: Sendable, Equatable {
        /// The head is not complete yet.
        case incomplete
        /// The request, and the length of its head including the blank line.
        case complete(ProxyRequest, headLength: Int)
    }

    /// A tunnel or a forwarded request.
    public let kind: ProxyKind
    /// The method, e.g. `CONNECT` or `GET`.
    public let method: String
    /// The host as written (not normalized).
    public let host: String
    /// The port: given, or 80 for `http://`.
    public let port: Int
    /// The headers in order.
    public let headers: [HTTPHeader]

    /// Parses the head at the start of `bytes`.
    public static func parse(_ bytes: [UInt8]) throws(ProxyProtocolError) -> Parse {
        guard let end = headEnd(bytes) else {
            if bytes.count > maxHeadBytes { throw .tooLarge }
            return .incomplete
        }
        guard end <= maxHeadBytes else { throw .tooLarge }
        var lines = try headLines(bytes[..<(end - 4)])
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            throw .malformed("bad request line")
        }
        let method = String(parts[0])
        guard !method.isEmpty, method.utf8.allSatisfy(isTokenByte) else { throw .malformed("bad method") }
        let headers = try lines.map(header)
        let target = String(parts[1])
        if method == "CONNECT" {
            let (host, port) = try authority(target, defaultPort: nil)
            return .complete(
                ProxyRequest(kind: .connect, method: method, host: host, port: port, headers: headers),
                headLength: end
            )
        }
        guard target.utf8.count > 7, target.prefix(7).lowercased() == "http://" else {
            throw .malformed("only CONNECT and absolute http:// requests are proxied")
        }
        let rest = target.dropFirst(7)
        guard !rest.contains("#") else { throw .malformed("fragment in request target") }
        let split = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        let (host, port) = try authority(String(rest[..<split]), defaultPort: 80)
        var path = String(rest[split...])
        if !path.hasPrefix("/") { path = "/" + path }
        return .complete(
            ProxyRequest(kind: .forward(path: path), method: method, host: host, port: port, headers: headers),
            headLength: end
        )
    }

    /// The values of every header named `name`, case-insensitively.
    public func header(_ name: String) -> [String] {
        headers.filter { $0.name.lowercased() == name.lowercased() }.map(\.value)
    }

    /// True if the request carries exactly one `Proxy-Authorization` header with `endpoint`'s token. The scheme
    /// name is case-insensitive; the credentials are compared in constant time.
    public func isAuthorized(by endpoint: ProxyEndpoint) -> Bool {
        let values = header("Proxy-Authorization")
        guard values.count == 1, let space = values[0].firstIndex(of: " ") else { return false }
        let scheme = values[0][..<space].lowercased()
        let given = Array(values[0][values[0].index(after: space)...].utf8)
        let expected = Array(endpoint.authorization.dropFirst("Basic ".count).utf8)
        guard scheme == "basic", given.count == expected.count else { return false }
        return zip(given, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The head sent upstream for a forwarded request: origin-form target, HTTP/1.1, `Host` set from the request
    /// target, the token and every hop-by-hop header removed (and any header `Connection` names), `Expect` and
    /// `Upgrade` dropped, and `Connection: close`, so exactly one request goes over the upstream connection.
    public func forwardedHead() -> [UInt8] {
        guard case .forward(let path) = kind else { return [] }
        let named = Set(
            header("Connection").flatMap { $0.split(separator: ",") }
                .map { $0.trimmingSpaces().lowercased() }
        )
        let dropped: Set<String> = [
            "host", "connection", "proxy-connection", "keep-alive", "proxy-authorization", "proxy-authenticate", "te",
            "trailer", "upgrade", "expect",
        ]
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\(port == 80 ? "" : ":\(port)")\r\n"
        for field in headers
        where !dropped.contains(field.name.lowercased()) && !named.contains(field.name.lowercased()) {
            head += "\(field.name): \(field.value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Array(head.utf8)
    }

    /// How the request body ends. Refuses anything two parsers could read differently: both `Content-Length` and
    /// `Transfer-Encoding`, differing or non-numeric lengths, or any coding other than plain `chunked`.
    public func bodyFraming() throws(ProxyProtocolError) -> BodyFraming {
        let codings = header("Transfer-Encoding")
        let lengths = header("Content-Length")
        if !codings.isEmpty {
            guard lengths.isEmpty else { throw .malformed("both Content-Length and Transfer-Encoding") }
            guard codings.count == 1, codings[0].lowercased() == "chunked" else {
                throw .malformed("unsupported Transfer-Encoding")
            }
            return .chunked
        }
        guard let first = lengths.first else { return .none }
        guard lengths.allSatisfy({ $0 == first }), !first.isEmpty, first.utf8.count <= 10,
            first.utf8.allSatisfy(NetworkHost.isDigit), let length = Int(first), length <= Self.maxBodyBytes
        else { throw .malformed("bad Content-Length") }
        return .length(length)
    }

    // MARK: - Parsing helpers

    static func headEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index + 4
        }
        return nil
    }

    /// The head's lines; every line must end in CRLF, with no other CR, LF or control byte (except tab) and no
    /// byte above 0x7E.
    static func headLines(_ head: ArraySlice<UInt8>) throws(ProxyProtocolError) -> [String] {
        var lines: [String] = []
        var line: [UInt8] = []
        var index = head.startIndex
        while index < head.endIndex {
            let byte = head[index]
            if byte == 13 {
                guard index + 1 < head.endIndex, head[index + 1] == 10 else { throw .malformed("bare CR") }
                lines.append(String(decoding: line, as: UTF8.self))
                line = []
                index += 2
                continue
            }
            guard byte == 9 || (0x20...0x7E).contains(byte) else { throw .malformed("control or non-ASCII byte") }
            line.append(byte)
            index += 1
        }
        lines.append(String(decoding: line, as: UTF8.self))
        return lines
    }

    static func header(_ line: String) throws(ProxyProtocolError) -> HTTPHeader {
        guard let colon = line.firstIndex(of: ":") else { throw .malformed("header without a colon") }
        let name = String(line[..<colon])
        guard !name.isEmpty, name.utf8.allSatisfy(isTokenByte) else { throw .malformed("bad header name") }
        return HTTPHeader(name: name, value: line[line.index(after: colon)...].trimmingSpaces())
    }

    /// `host:port`, with no user info, brackets or path; `defaultPort` if the port is left out (not for CONNECT).
    static func authority(_ text: String, defaultPort: Int?) throws(ProxyProtocolError) -> (String, Int) {
        guard !text.contains("@"), !text.contains("["), !text.contains("/") else { throw .malformed("bad authority") }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = pieces.first, !host.isEmpty, pieces.count <= 2 else { throw .malformed("bad host") }
        guard pieces.count == 2 else {
            guard let defaultPort else { throw .malformed("CONNECT needs a port") }
            return (String(host), defaultPort)
        }
        let digits = pieces[1]
        guard (1...5).contains(digits.utf8.count), digits.utf8.allSatisfy(NetworkHost.isDigit), let port = Int(digits),
            (1...65535).contains(port)
        else { throw .malformed("bad port") }
        return (String(host), port)
    }

    /// RFC 9110 token characters.
    static func isTokenByte(_ byte: UInt8) -> Bool {
        NetworkHost.isLetterOrDigit(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
}

/// Finds the exact end of a chunked request body, so not one byte after it reaches the server: anything after the
/// last chunk could be a second, unchecked request.
public struct ChunkedBodyScanner: Sendable {
    private enum State {
        case size, data(Int), dataEnd, trailer
    }

    private var state = State.size
    private var line: [UInt8] = []
    private var sawCR = false
    /// True once the last chunk and the trailer have been seen.
    public private(set) var isDone = false

    /// A scanner at the start of a body.
    public init() {}

    /// Feeds `bytes`; returns how many of them belong to the body (all of them until the end is reached).
    public mutating func consume(_ bytes: ArraySlice<UInt8>) throws(ProxyProtocolError) -> Int {
        var index = bytes.startIndex
        while index < bytes.endIndex, !isDone {
            if case .data(let remaining) = state {
                let take = min(remaining, bytes.endIndex - index)
                index += take
                state = remaining == take ? .dataEnd : .data(remaining - take)
                continue
            }
            let byte = bytes[index]
            index += 1
            if case .dataEnd = state, !sawCR, byte != 13 { throw .malformed("chunk longer than its size") }
            guard let text = try lineByte(byte) else { continue }
            switch state {
            case .size:
                let size = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                guard (1...16).contains(size.utf8.count), let length = Int(size, radix: 16), length >= 0,
                    size.utf8.allSatisfy({ NetworkHost.isDigit($0) || "abcdefABCDEF".utf8.contains($0) })
                else { throw .malformed("bad chunk size") }
                state = length == 0 ? .trailer : .data(length)
            case .dataEnd:
                guard text.isEmpty else { throw .malformed("chunk longer than its size") }
                state = .size
            case .trailer:
                if text.isEmpty { isDone = true }
            case .data:
                break
            }
        }
        return index - bytes.startIndex
    }

    /// Collects a CRLF-terminated line; returns it once complete.
    private mutating func lineByte(_ byte: UInt8) throws(ProxyProtocolError) -> String? {
        if sawCR {
            guard byte == 10 else { throw .malformed("bare CR in chunk framing") }
            sawCR = false
            defer { line = [] }
            return String(decoding: line, as: UTF8.self)
        }
        switch byte {
        case 13: sawCR = true
        case 10: throw .malformed("bare LF in chunk framing")
        default:
            guard line.count < 4096 else { throw .malformed("chunk line too long") }
            line.append(byte)
        }
        return nil
    }
}

/// Rewrites the upstream response head of a forwarded request so the client never reuses the connection: every
/// later request has to come back through the proxy and its checks. Interim (1xx) heads pass unchanged; the final
/// head loses `Connection`, `Keep-Alive` and `Proxy-Connection` and gains `Connection: close`. The body passes as is.
public struct ResponseHeadRewriter: Sendable {
    private var buffer: [UInt8] = []
    /// True once the final head has been rewritten; later bytes pass straight through.
    public private(set) var isDone = false

    /// A rewriter at the start of a response.
    public init() {}

    /// Feeds bytes from upstream; returns the bytes to send to the client now.
    public mutating func feed(_ bytes: ArraySlice<UInt8>) throws(ProxyProtocolError) -> [UInt8] {
        guard !isDone else { return Array(bytes) }
        buffer += bytes
        var out: [UInt8] = []
        while !isDone, let end = ProxyRequest.headEnd(buffer) {
            guard end <= ProxyRequest.maxHeadBytes else { throw .tooLarge }
            let head = Array(buffer[..<end])
            buffer.removeFirst(end)
            // Lines are kept as bytes: servers do send non-ASCII values (file names), which pass unchanged.
            let pieces = head.dropLast(4).split(separator: 13, omittingEmptySubsequences: false)
            guard pieces.dropFirst().allSatisfy({ $0.first == 10 }),
                pieces.allSatisfy({ !$0.dropFirst().contains(10) }),
                pieces.first?.first != 10
            else { throw .malformed("bare CR or LF in response head") }
            var lines = pieces.enumerated().map { $0.offset == 0 ? Array($0.element) : Array($0.element.dropFirst()) }
            let status = String(decoding: lines.removeFirst(), as: UTF8.self)
            let parts = status.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0", parts[1].utf8.count == 3,
                let code = Int(parts[1])
            else { throw .malformed("bad response status line") }
            if (100...199).contains(code) && code != 101 {
                out += head
                continue
            }
            let dropped: Set<String> = ["connection", "keep-alive", "proxy-connection"]
            var rewritten = Array((status + "\r\n").utf8)
            for line in lines {
                guard let colon = line.firstIndex(of: UInt8(ascii: ":")), colon > 0,
                    line[..<colon].allSatisfy(ProxyRequest.isTokenByte)
                else { throw .malformed("bad response header") }
                let name = String(decoding: line[..<colon], as: UTF8.self).lowercased()
                if !dropped.contains(name) { rewritten += line + [13, 10] }
            }
            out += rewritten + Array("Connection: close\r\n\r\n".utf8) + buffer
            buffer = []
            isDone = true
        }
        if !isDone, buffer.count > ProxyRequest.maxHeadBytes { throw .tooLarge }
        return out
    }
}

/// Responses the proxy writes itself.
public enum ProxyResponse {
    /// The reply to an allowed `CONNECT`, after which the tunnel carries raw bytes.
    public static let established = Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8)

    /// A refusal with `status` (400, 403, 407, 502 or 504) and a one-line plain-text reason; the proxy closes the
    /// connection after it. 407 also asks for the proxy credentials.
    public static func refusal(_ status: Int, _ reason: String) -> [UInt8] {
        let phrases = [
            400: "Bad Request", 403: "Forbidden", 407: "Proxy Authentication Required", 502: "Bad Gateway",
            504: "Gateway Timeout",
        ]
        let body = "Dual Control: " + DisplayText.escaped(reason) + "\n"
        var head = "HTTP/1.1 \(status) \(phrases[status] ?? "Error")\r\n"
        if status == 407 { head += "Proxy-Authenticate: Basic realm=\"Dual Control\"\r\n" }
        head +=
            "Content-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return Array((head + body).utf8)
    }
}

extension StringProtocol {
    func trimmingSpaces() -> String {
        var scalars = Substring(self).unicodeScalars[...]
        while let first = scalars.first, first == " " || first == "\t" { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }
}
