import Foundation

// ---------------------------------------------------------------------------
// WebAdapterClient — 把 OpenAI 兼容的对话请求，翻译成第三方网页版接口，
// 再把它们的 SSE 增量翻译回 StreamDelta。
//
// 不是 MITM、不是劫持别人的进程：凭据由用户在本 App 自己的 WKWebView 里登录后
// 读出来，存在本机 Keychain，只用于他自己发起的请求。
// ---------------------------------------------------------------------------

public enum WebAdapterError: LocalizedError, Equatable, Sendable {
    case missingCredential
    case badSpec(String)
    case httpError(statusCode: Int, message: String)
    case upstream(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "还没有登录这个渠道，请先点「登录网页版」拿到凭据。"
        case let .badSpec(reason):
            return "渠道配置有问题：\(reason)"
        case let .httpError(code, message):
            return "上游返回 HTTP \(code)：\(message)"
        case let .upstream(message):
            return "上游返回异常：\(message)"
        }
    }
}

/// 有的上游给的是「整段快照」，有的是「增量补丁」。
/// 这里把快照流化：只吐新增的后缀。
public struct SnapshotAccumulator: Sendable {
    private var rendered = ""

    public init() {}

    public mutating func absorb(_ snapshot: String) -> String {
        guard !snapshot.isEmpty else { return "" }
        if snapshot == rendered { return "" }
        if snapshot.hasPrefix(rendered) {
            let delta = String(snapshot.dropFirst(rendered.count))
            rendered = snapshot
            return delta
        }
        rendered = snapshot
        return snapshot
    }

    public var text: String { rendered }
}

public struct WebAdapterClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: 请求构造

    public func makeRequest(
        spec: WebAdapterSpec,
        credential: String,
        model: String,
        messages: [ChatMessage]
    ) throws -> URLRequest {
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw WebAdapterError.missingCredential }
        guard let url = URL(string: spec.chatURL) else {
            throw WebAdapterError.badSpec("chatURL 不合法：\(spec.chatURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        for (key, rawValue) in spec.headers {
            request.setValue(
                WebAdapterTemplate.render(rawValue, values: ["token": token, "model": model]),
                forHTTPHeaderField: key
            )
        }

        let prompt = Self.flatten(messages)
        let values: [String: String] = [
            "token": token,
            "model": model,
            "prompt": WebAdapterTemplate.jsonEscape(prompt),
            "messages_json": Self.messagesJSON(messages),
            "local_conversation": UUID().uuidString.lowercased(),
            "local_message": UUID().uuidString.lowercased()
        ]
        let body = WebAdapterTemplate.render(spec.bodyTemplate, values: values)
        request.httpBody = Data(body.utf8)

        guard (try? JSONSerialization.jsonObject(with: Data(body.utf8))) != nil else {
            throw WebAdapterError.badSpec("请求体不是合法 JSON，请检查 bodyTemplate 的转义")
        }
        return request
    }

    public static func flatten(_ messages: [ChatMessage]) -> String {
        let usable = messages.filter { $0.role == .user || $0.role == .assistant || $0.role == .system }
        guard let lastUser = usable.last(where: { $0.role == .user }) else {
            return usable.map(\.content).joined(separator: "\n")
        }
        let system = usable.first(where: { $0.role == .system })?.content
        let history = usable.dropLast().filter { $0.role != .system }
        var parts: [String] = []
        if let system, !system.isEmpty {
            parts.append("[系统要求]\n\(system)")
        }
        if !history.isEmpty {
            let transcript = history.map { message -> String in
                let speaker = message.role == .user ? "用户" : "助手"
                return "\(speaker)：\(message.content)"
            }.joined(separator: "\n")
            parts.append("[对话历史]\n\(transcript)")
        }
        parts.append("[当前问题]\n\(lastUser.content)")
        return parts.joined(separator: "\n\n")
    }

    static func messagesJSON(_ messages: [ChatMessage]) -> String {
        let payload = messages
            .filter { $0.role == .user || $0.role == .assistant || $0.role == .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    // MARK: 流式调用

    public func stream(
        spec: WebAdapterSpec,
        credential: String,
        model: String,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        spec: spec, credential: credential, model: model, messages: messages
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 600 { break }
                        }
                        throw WebAdapterError.httpError(
                            statusCode: http.statusCode,
                            message: body.isEmpty ? "无响应体" : body
                        )
                    }

                    var extractor = WebDeltaExtractor(mode: spec.responseMode, streamPath: spec.streamPath)
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        if trimmed.hasPrefix("event:") || trimmed.hasPrefix("id:") { continue }
                        if trimmed.hasPrefix(":") { continue }  // SSE 心跳
                        let payload = trimmed.hasPrefix("data:")
                            ? String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            : trimmed
                        if payload == "[DONE]" { break }
                        for delta in extractor.extract(payload) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - 回包翻译

public struct WebDeltaExtractor: Sendable {
    public let mode: WebResponseMode
    public let streamPath: String
    private var accumulator = SnapshotAccumulator()
    private var emittedAny = false

    public init(mode: WebResponseMode, streamPath: String = "") {
        self.mode = mode
        self.streamPath = streamPath
    }

    public mutating func extract(_ payload: String) -> [StreamDelta] {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        switch mode {
        case .sseOpenAI:
            // 兼容 Qwen 的 phase:"think"
            if WebJSONPath.string(in: object, path: "choices.0.delta.phase") == "think",
               let thinking = WebJSONPath.string(in: object, path: "choices.0.delta.content"),
               !thinking.isEmpty {
                return [.reasoning(thinking)]
            }
            if let reasoning = WebJSONPath.string(in: object, path: "choices.0.delta.reasoning_content"),
               !reasoning.isEmpty {
                return [.reasoning(reasoning)]
            }
            if let content = WebJSONPath.string(in: object, path: "choices.0.delta.content"),
               !content.isEmpty {
                emittedAny = true
                return [.content(content)]
            }
            return []

        case .sseJSONText, .jsonText:
            if let text = WebJSONPath.string(in: object, path: streamPath), !text.isEmpty {
                let delta = accumulator.absorb(text)
                return delta.isEmpty ? [] : [.content(delta)]
            }
            return []

        case .sseDeepSeek:
            // 增量补丁：{"p":"response/fragments/-1/content","o":"APPEND","v":"..."}
            if let path = object as? [String: Any] {
                if let patchPath = path["p"] as? String, let value = path["v"] as? String {
                    if patchPath.contains("thinking") {
                        return value.isEmpty ? [] : [.reasoning(value)]
                    }
                    if patchPath.hasSuffix("content") {
                        emittedAny = true
                        return value.isEmpty ? [] : [.content(value)]
                    }
                    return []
                }
                // 快照：{"v":{"response":{"fragments":[{"content":"..."}]}}}
                if let snapshot = WebJSONPath.string(
                    in: object, path: "v.response.fragments.0.content"
                ), !snapshot.isEmpty, !emittedAny {
                    let delta = accumulator.absorb(snapshot)
                    return delta.isEmpty ? [] : [.content(delta)]
                }
            }
            return []

        case .sseDoubao:
            // {"event_type":2001,"event_data":"{\"message\":{\"content\":\"...\"}}"}
            if let eventData = WebJSONPath.string(in: object, path: "event_data"),
               let inner = eventData.data(using: .utf8),
               let innerObject = try? JSONSerialization.jsonObject(with: inner) {
                if let content = WebJSONPath.string(in: innerObject, path: "message.content") {
                    let delta = accumulator.absorb(content)
                    return delta.isEmpty ? [] : [.content(delta)]
                }
                if let patch = WebJSONPath.string(in: innerObject, path: "patch_object.patch_value"),
                   !patch.isEmpty {
                    emittedAny = true
                    return [.content(patch)]
                }
            }
            return []
        }
    }
}

// MARK: - 接进 Harness

public struct WebAdapterTransport: ModelStreamingTransport {
    public let spec: WebAdapterSpec
    public let credential: String
    private let client: WebAdapterClient

    public init(spec: WebAdapterSpec, credential: String, session: URLSession = .shared) {
        self.spec = spec
        self.credential = credential
        self.client = WebAdapterClient(session: session)
    }

    public func streamChatCompletion(
        config: ProviderConfig,
        apiKey: String,
        messages: [ChatMessage],
        includeWorkspaceTools: Bool,
        firewall: PrivacyFirewall
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let model = spec.models.contains(config.model) ? config.model : (spec.models.first ?? config.model)
        return client.stream(spec: spec, credential: credential, model: model, messages: messages)
    }
}

// MARK: - 凭据读取（WKWebView 抓到的东西）

public enum WebCredentialParser {
    /// 从 localStorage 字典或 cookie 字典里取出 spec 指定的凭据。
    public static func extract(
        spec: WebAdapterSpec,
        localStorage: [String: String],
        cookies: [String: String]
    ) -> String? {
        let raw: String?
        switch spec.credentialKind {
        case .localStorage:
            raw = localStorage[spec.credentialKey]
        case .cookie:
            raw = cookies[spec.credentialKey]
        }
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        // 值本身是 JSON（如 DeepSeek 的 userToken）时按路径取
        if let path = spec.credentialPath, !path.isEmpty,
           let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let nested = WebJSONPath.string(in: object, path: path.joined(separator: ".")) {
                value = nested
            }
        }
        // 有些站点把 token 包成 "\"...\"" 或加 Bearer 前缀
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 2 {
            value = String(value.dropFirst().dropLast())
        }
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7))
        }
        return value.isEmpty ? nil : value
    }
}
