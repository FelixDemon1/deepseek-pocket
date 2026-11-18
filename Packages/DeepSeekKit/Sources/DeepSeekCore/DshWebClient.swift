import Foundation

/// Authentic wire-compatible client for official `deepseek-ai/deepseek-harness` (`dsh web`).
/// Connects directly over LAN / Tailscale / SSH port-forward with zero third-party relay servers.
public struct DshLaunchURL: Equatable, Sendable {
    public let baseURI: URL
    public let token: String

    public init(baseURI: URL, token: String) {
        self.baseURI = baseURI
        self.token = token
    }

    /// Parses either `dsh web: http://127.0.0.1:3080/?token=...` or a bare URL.
    public static func parse(_ text: String) -> DshLaunchURL? {
        let pattern = #"https?://[^\s]+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let raw = String(text[range])
        guard var comps = URLComponents(string: raw),
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            return nil
        }
        comps.query = nil
        comps.fragment = nil
        if comps.path == "/" {
            comps.path = ""
        }
        guard let base = comps.url else { return nil }
        return DshLaunchURL(baseURI: base, token: token)
    }
}

public struct DshAuthCookie: Codable, Equatable, Sendable {
    public let name: String
    public let value: String
    public let authority: String

    public init(name: String, value: String, authority: String) {
        self.name = name
        self.value = value
        self.authority = authority
    }

    public var headerValue: String { "\(name)=\(value)" }
}

public struct DshRemoteSessionSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var updatedAt: Date?

    public init(id: String, title: String, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

public enum DshWebError: LocalizedError, Equatable, Sendable {
    case invalidLaunchURL
    case authenticationFailed(Int)
    case protocolMismatch(String)
    case remoteException(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLaunchURL:
            return "无法解析 dsh web 启动链接，请粘贴包含 ?token=... 的完整地址。"
        case let .authenticationFailed(status):
            return "远程 DSH 主机认证失败 (HTTP \(status))，请检查 token 或重新获取。"
        case let .protocolMismatch(detail):
            return "DSH 协议校验失败：\(detail)"
        case let .remoteException(code, message):
            return "远程主机错误 [\(code)]：\(message)"
        }
    }
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Capture `303 See Other` + `Set-Cookie: dsh-auth-*` directly without following redirect!
        completionHandler(nil)
    }
}

public actor DshWebClient {
    public let baseURI: URL
    public let hostAuthority: String
    private(set) public var cookie: DshAuthCookie?
    private let firewall: PrivacyFirewall
    private let session: URLSession

    public init(
        baseURI: URL,
        hostHeaderOverride: String? = nil,
        cookie: DshAuthCookie? = nil,
        firewall: PrivacyFirewall,
        urlSession: URLSession? = nil
    ) {
        self.baseURI = baseURI
        if let hostHeaderOverride, !hostHeaderOverride.isEmpty {
            self.hostAuthority = hostHeaderOverride
        } else {
            let host = baseURI.host ?? "127.0.0.1"
            if let port = baseURI.port {
                self.hostAuthority = "\(host):\(port)"
            } else {
                self.hostAuthority = host
            }
        }
        self.cookie = cookie
        self.firewall = firewall
        if let urlSession {
            self.session = urlSession
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
        }
    }

    /// Exchanges `GET /?token=<launchToken>` for the 30-day `dsh-auth-<hash>` cookie.
    @discardableResult
    public func login(token: String) async throws -> DshAuthCookie {
        await firewall.setAllowedRemoteDshBaseURL(baseURI)
        guard var comps = URLComponents(url: baseURI, resolvingAgainstBaseURL: false) else {
            throw DshWebError.invalidLaunchURL
        }
        if comps.path.isEmpty {
            comps.path = "/"
        }
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let loginURL = comps.url else {
            throw DshWebError.invalidLaunchURL
        }

        var req = URLRequest(url: loginURL)
        req.httpMethod = "GET"
        req.setValue(hostAuthority, forHTTPHeaderField: "Host")
        try await firewall.authorize(req, purpose: .remoteDshHost)

        let start = ContinuousClock.now
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw DshWebError.protocolMismatch("非 HTTP 响应")
        }
        await firewall.recordCompleted(
            request: req,
            purpose: .remoteDshHost,
            statusCode: http.statusCode,
            bytesReceived: data.count,
            durationMs: Self.elapsedMs(since: start),
            note: "dsh web login"
        )

        guard http.statusCode == 303 || http.statusCode == 200 else {
            throw DshWebError.authenticationFailed(http.statusCode)
        }

        guard let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
              let minted = Self.parseAuthCookie(setCookie, authority: hostAuthority) else {
            throw DshWebError.protocolMismatch("响应未携带 dsh-auth 会话 Cookie")
        }
        self.cookie = minted
        return minted
    }

    /// Performs a unary Typert Remote RPC call (`POST /api/<endpoint>` with `client-request` envelope).
    public func call(endpoint: String, args: [String: Any]) async throws -> Any? {
        await firewall.setAllowedRemoteDshBaseURL(baseURI)
        let rpcId = UUID().uuidString.lowercased()
        let envelope = Self.makeClientRequestEnvelope(rpcId: rpcId, endpoint: endpoint, args: args)

        let baseStr = baseURI.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseStr)/api/\(endpoint)") else {
            throw DshWebError.invalidLaunchURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(hostAuthority, forHTTPHeaderField: "Host")
        if let cookie {
            req.setValue(cookie.headerValue, forHTTPHeaderField: "Cookie")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: envelope)

        try await firewall.authorize(req, purpose: .remoteDshHost)
        let start = ContinuousClock.now
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw DshWebError.protocolMismatch("无有效 HTTP 响应")
        }
        await firewall.recordCompleted(
            request: req,
            purpose: .remoteDshHost,
            statusCode: http.statusCode,
            bytesReceived: data.count,
            durationMs: Self.elapsedMs(since: start),
            note: endpoint
        )

        if http.statusCode == 401 || http.statusCode == 403 {
            throw DshWebError.authenticationFailed(http.statusCode)
        }
        guard http.statusCode == 200 else {
            throw DshWebError.protocolMismatch("HTTP \(http.statusCode)")
        }

        return try Self.decodeServerResponseEnvelope(data: data, expectedRpcId: rpcId, endpoint: endpoint)
    }

    public func listSessions() async throws -> [DshRemoteSessionSummary] {
        let raw = try await call(endpoint: "session/list", args: ["_request": [String: Any]()])
        guard let dict = raw as? [String: Any], let items = dict["items"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let id = item["sessionId"] as? String ?? item["id"] as? String else { return nil }
            let title = (item["title"] as? String) ?? "远程会话 \(id.prefix(6))"
            return DshRemoteSessionSummary(id: id, title: title)
        }
    }

    public func createSession(cwd: String? = nil) async throws -> String {
        var reqObj: [String: Any] = [:]
        if let cwd, !cwd.isEmpty { reqObj["cwd"] = cwd }
        let raw = try await call(endpoint: "session/create", args: ["request": reqObj])
        guard let dict = raw as? [String: Any], let sessionId = dict["sessionId"] as? String, !sessionId.isEmpty else {
            throw DshWebError.protocolMismatch("session/create 未返回 sessionId")
        }
        return sessionId
    }

    public func sendPrompt(sessionId: String, text: String, steer: Bool = false) async throws -> String {
        let requestId = UUID().uuidString.lowercased()
        let reqObj: [String: Any] = [
            "requestId": requestId,
            "sessionId": sessionId,
            "mode": steer ? "steer" : "queue",
            "content": [
                ["type": "text", "text": text]
            ],
            "clientTimeZone": TimeZone.current.identifier
        ]
        _ = try await call(endpoint: "session/prompt", args: ["request": reqObj])
        return requestId
    }

    public func cancelSession(sessionId: String) async throws {
        _ = try await call(endpoint: "session/cancel", args: ["request": ["sessionId": sessionId]])
    }

    /// Streams `/api/remote.mux` raw JSON frames (`$events` ready handshake + `session/follow` live deltas).
    public func followSession(sessionId: String) -> AsyncThrowingStream<String, Error> {
        let currentCookie = self.cookie
        let authority = self.hostAuthority
        let base = self.baseURI
        let fw = self.firewall

        return AsyncThrowingStream { continuation in
            let task = Task {
                let baseStr = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let wsStr = baseStr
                    .replacingOccurrences(of: "https://", with: "wss://")
                    .replacingOccurrences(of: "http://", with: "ws://") + "/api/remote.mux"
                guard let wsURL = URL(string: wsStr) else {
                    continuation.finish(throwing: DshWebError.invalidLaunchURL)
                    return
                }

                var req = URLRequest(url: wsURL)
                req.setValue(authority, forHTTPHeaderField: "Host")
                if let currentCookie {
                    req.setValue(currentCookie.headerValue, forHTTPHeaderField: "Cookie")
                }

                do {
                    await fw.setAllowedRemoteDshBaseURL(base)
                    try await fw.authorize(req, purpose: .remoteDshHost)
                    let wsTask = URLSession.shared.webSocketTask(with: req)
                    wsTask.resume()

                    let eventsStreamId = UUID().uuidString.lowercased()
                    let followStreamId = UUID().uuidString.lowercased()

                    try await Self.sendMuxJSON(wsTask, [
                        "type": "open",
                        "streamId": eventsStreamId,
                        "endpoint": "$events",
                        "payload": ["args": [String: Any]()]
                    ])
                    try await Self.sendMuxJSON(wsTask, [
                        "type": "open",
                        "streamId": followStreamId,
                        "endpoint": "session/follow",
                        "payload": [
                            "args": [
                                "request": [
                                    "sessionId": sessionId,
                                    "assistantStream": true
                                ]
                            ]
                        ]
                    ])

                    while !Task.isCancelled {
                        let msg = try await wsTask.receive()
                        if case let .string(text) = msg {
                            continuation.yield(text)
                        }
                    }
                    wsTask.cancel(with: .normalClosure, reason: nil)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func parseAuthCookie(_ setCookieHeader: String, authority: String) -> DshAuthCookie? {
        for segment in setCookieHeader.components(separatedBy: CharacterSet(charactersIn: ";,")) {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("dsh-auth-"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            if !value.isEmpty {
                return DshAuthCookie(name: name, value: value, authority: authority)
            }
        }
        return nil
    }

    public static func makeClientRequestEnvelope(rpcId: String, endpoint: String, args: [String: Any]) -> [String: Any] {
        [
            "type": "client-request",
            "rpcId": rpcId,
            "method": endpoint,
            "payload": ["args": args]
        ]
    }

    public static func decodeServerResponseEnvelope(data: Data, expectedRpcId: String, endpoint: String) throws -> Any? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              decoded["type"] as? String == "server-response",
              let result = decoded["result"] as? [String: Any] else {
            throw DshWebError.protocolMismatch("\(endpoint): 非标准 server-response 信封")
        }
        if result["ok"] as? Bool == true {
            let echoed = decoded["rpcId"] as? String
            guard echoed == expectedRpcId else {
                throw DshWebError.protocolMismatch("\(endpoint): rpcId 不匹配")
            }
            return result["value"]
        }
        if result["ok"] as? Bool == false {
            let errObj = (result["error"] as? [String: Any]) ?? [:]
            let code = (errObj["code"] as? String) ?? "UNKNOWN"
            let message = (errObj["message"] as? String) ?? "远程调用失败"
            throw DshWebError.remoteException(code: code, message: message)
        }
        throw DshWebError.protocolMismatch("\(endpoint): 未知响应状态")
    }

    private static func sendMuxJSON(_ ws: URLSessionWebSocketTask, _ dict: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: ContinuousClock.now)
        return Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}
