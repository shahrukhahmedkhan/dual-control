#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    /// The model relay (D11 phase 2, `ModelRelayPolicy`): HTTP on 127.0.0.1 for agent processes, HTTPS to Anthropic
    /// as the app. It reads one request per connection (head, then exactly its Content-Length body), decides it,
    /// adds the owner's key from `credential` and streams the answer back chunked as it arrives, so Claude Code's
    /// server-sent events flow. Requests without the session token get 401 and are not reported, like the
    /// gatekeeper's 407; every other request is reported once it ends. Redirects are never followed: the key goes to
    /// the upstream host only.
    ///
    /// One thread per connection. `stop()` closes the listener and every open connection; a stopped relay cannot be
    /// started again (make a new one, with a new port and token).
    public final class ModelRelayServer: @unchecked Sendable {
        /// Connections served at once; more are closed at once.
        public static let maxConnections = 32
        /// Seconds a client has to send its request.
        static let requestTimeout: Int32 = 30

        private let upstream: String
        private let credential: @Sendable () -> String?
        private let budgetRefusal: @Sendable () -> String?
        private let onExchange: @Sendable (ModelRelayExchange) -> Void
        private let session: URLSession
        private let lock = NSLock()
        private var listener: Int32 = -1
        private var wake: [Int32] = [-1, -1]
        private var live: Set<Int32> = []
        private var stopped = false
        private var nextNumber = 1
        private var current: ModelRelayEndpoint?

        /// A relay to `upstream` (tests pass a local server). `credential` is read for every request; `nil` means
        /// the owner has not set a key. `budgetRefusal` is asked before every request goes upstream and refuses it
        /// with its reason (D12e). `onExchange` runs on the relay's threads.
        public init(
            upstream: String = ModelRelayPolicy.upstream,
            credential: @escaping @Sendable () -> String?,
            budgetRefusal: @escaping @Sendable () -> String? = { nil },
            onExchange: @escaping @Sendable (ModelRelayExchange) -> Void
        ) {
            self.upstream = upstream
            self.credential = credential
            self.budgetRefusal = budgetRefusal
            self.onExchange = onExchange
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 3600
            session = URLSession(configuration: configuration)
        }

        /// Where agent processes reach it, once started.
        public var endpoint: ModelRelayEndpoint? { lock.withLock { current } }

        /// Binds 127.0.0.1 on a port the system picks, with a fresh token, and starts accepting.
        public func start() throws -> ModelRelayEndpoint {
            try lock.withLock {
                guard !stopped, listener < 0 else { throw ConnectFailure(reason: "already started", timedOut: false) }
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { throw ConnectFailure(reason: "socket: errno \(errno)", timedOut: false) }
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let bound = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
                    }
                }
                guard bound, listen(fd, 64) == 0, pipe(&wake) == 0,
                    let endpoint = ModelRelayEndpoint(
                        port: UInt16(bigEndian: address.sin_port),
                        token: ProxyEndpoint.newToken()
                    )
                else {
                    close(fd)
                    throw ConnectFailure(reason: "could not listen on 127.0.0.1: errno \(errno)", timedOut: false)
                }
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                listener = fd
                current = endpoint
                let thread = Thread { [self] in acceptLoop(fd, endpoint: endpoint) }
                thread.name = "DualControl.relay"
                thread.start()
                return endpoint
            }
        }

        /// Closes the listener and every open connection now; requests in flight upstream are cancelled. Safe to
        /// call more than once.
        public func stop() {
            lock.withLock {
                guard !stopped else { return }
                stopped = true
                current = nil
                if wake[1] >= 0 { _ = write(wake[1], "x", 1) }
                for fd in live { shutdown(fd, SHUT_RDWR) }
            }
            session.invalidateAndCancel()
        }

        private func acceptLoop(_ fd: Int32, endpoint: ModelRelayEndpoint) {
            defer {
                lock.withLock {
                    close(fd)
                    close(wake[0])
                    close(wake[1])
                    listener = -1
                }
            }
            while true {
                var fds = [
                    pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0),
                ]
                let ready = poll(&fds, 2, -1)
                if ready < 0 && errno == EINTR { continue }
                if ready < 0 || fds[1].revents != 0 || lock.withLock({ stopped }) { return }
                guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                prepare(client)
                let admitted: Int? = lock.withLock {
                    guard !stopped, live.count < Self.maxConnections else { return nil }
                    live.insert(client)
                    defer { nextNumber += 1 }
                    return nextNumber
                }
                guard let number = admitted else {
                    close(client)
                    continue
                }
                let thread = Thread { [self] in
                    serve(client, number: number, endpoint: endpoint)
                    lock.withLock {
                        live.remove(client)
                        close(client)
                    }
                }
                thread.name = "DualControl.relay-connection"
                thread.start()
            }
        }

        // MARK: - One request

        private func serve(_ client: Int32, number: Int, endpoint: ModelRelayEndpoint) {
            var buffer: [UInt8] = []
            let head: RelayRequestHead
            let headLength: Int
            while true {
                do {
                    if case .complete(let parsed, let length) = try RelayRequestHead.parse(buffer) {
                        head = parsed
                        headLength = length
                        break
                    }
                } catch {
                    _ = writeAll(client, Self.refusal(400, error.description))
                    return
                }
                guard let chunk = readSome(client, timeout: Self.requestTimeout) else { return }
                buffer += chunk
            }
            let started = Date()
            func refuse(_ status: Int, _ reason: String, model: String = "?", report: Bool = true) {
                _ = writeAll(client, Self.refusal(status, reason))
                guard report else { return }
                onExchange(
                    ModelRelayExchange(
                        number: number,
                        path: head.target,
                        model: model,
                        status: status,
                        bytesUp: 0,
                        bytesDown: 0,
                        duration: Date().timeIntervalSince(started),
                        refusal: reason
                    )
                )
            }
            let path: String
            let length: Int
            let headers: [(String, String)]
            switch ModelRelayPolicy.decide(head, endpoint: endpoint) {
            case .refuse(let status, let reason):
                return refuse(status, reason, report: status != 401)
            case .forward(let target, let bodyLength, let forwarded):
                (path, length, headers) = (target, bodyLength, forwarded)
            }
            var body = Array(buffer[headLength...].prefix(length))
            while body.count < length {
                guard let chunk = readSome(client, timeout: Self.requestTimeout) else { return }
                body += chunk.prefix(length - body.count)
            }
            let bodyData = Data(body)
            let model = ModelRelayPolicy.model(bodyData)
            guard let key = credential(), ModelRelayPolicy.keyProblem(key) == nil else {
                return refuse(503, "the owner has not set a model key in Dual Control", model: model)
            }
            // 403, not 429: the budget does not come back by retrying.
            if let reason = budgetRefusal() { return refuse(403, reason, model: model) }
            guard let url = URL(string: upstream + path) else { return refuse(400, "the path is not valid") }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            for (name, value) in headers { request.addValue(value, forHTTPHeaderField: name) }
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.httpBody = bodyData
            request.httpShouldHandleCookies = false

            let stream = RelayStream(client: client)
            let task = session.dataTask(with: request)
            task.delegate = stream
            task.resume()
            stream.done.wait()
            onExchange(
                ModelRelayExchange(
                    number: number,
                    path: path,
                    model: model,
                    status: stream.status,
                    bytesUp: length,
                    bytesDown: stream.bytesDown,
                    duration: Date().timeIntervalSince(started),
                    refusal: stream.status == 502 && !stream.upstreamAnswered ? "Anthropic's API was not reached" : nil,
                    usage: stream.usage()
                )
            )
        }

        /// A complete JSON error reply in the API's shape, then close.
        static func refusal(_ status: Int, _ reason: String) -> [UInt8] {
            let message = reason.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "'")
            let body = #"{"type":"error","error":{"type":"dual_control_relay","message":"\#(message)"}}"#
            return Array(
                ("HTTP/1.1 \(status) Relay\r\ncontent-type: application/json\r\ncontent-length: \(body.utf8.count)\r\n"
                    + "connection: close\r\n\r\n" + body).utf8
            )
        }
    }

    /// Streams one upstream response to the client as it arrives: the status and the allowed headers, then the body
    /// in HTTP/1.1 chunks. Stops the task if the client goes away; refuses every redirect.
    final class RelayStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let client: Int32
        let done = DispatchSemaphore(value: 0)
        private(set) var status = 502
        private(set) var bytesDown = 0
        private(set) var upstreamAnswered = false
        private var headSent = false
        private var clientGone = false
        private var scanner = UsageScanner()

        /// The tokens the answer reported, once it has ended.
        func usage() -> RelayUsage? { scanner.finish() }

        init(client: Int32) {
            self.client = client
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            upstreamAnswered = true
            status = http.statusCode
            var head = "HTTP/1.1 \(http.statusCode) \(http.statusCode == 200 ? "OK" : "Relay")\r\n"
            for case (let name as String, let value as String) in http.allHeaderFields {
                let lower = name.lowercased()
                guard
                    ModelRelayPolicy.returnedHeaders.contains(lower)
                        || ModelRelayPolicy.returnedPrefixes.contains(where: { lower.hasPrefix($0) }),
                    !value.contains("\r"), !value.contains("\n")
                else { continue }
                head += "\(lower): \(value)\r\n"
            }
            head += "transfer-encoding: chunked\r\nconnection: close\r\n\r\n"
            headSent = true
            guard writeAll(client, Array(head.utf8)) else {
                clientGone = true
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !clientGone, !data.isEmpty else { return }
            scanner.feed(Array(data))
            let chunk = Array((String(data.count, radix: 16) + "\r\n").utf8) + Array(data) + [13, 10]
            if writeAll(client, chunk) {
                bytesDown += data.count
            } else {
                clientGone = true
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if !headSent {
                status = 502
                _ = writeAll(client, ModelRelayServer.refusal(502, "Anthropic's API could not be reached"))
            } else if !clientGone {
                // A broken upstream stream ends without the last chunk, so the client sees it was cut short.
                if error == nil { _ = writeAll(client, Array("0\r\n\r\n".utf8)) }
            }
            done.signal()
        }
    }
#endif
