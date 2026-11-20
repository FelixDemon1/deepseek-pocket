import Foundation

public enum StreamDelta: Equatable, Sendable {
    case reasoning(String)
    case content(String)
    case toolCalls([ToolCallRequest])
    case usage(TokenUsage)
}

public protocol ModelStreamingTransport: Sendable {
    func streamChatCompletion(
        config: ProviderConfig,
        apiKey: String,
        messages: [ChatMessage],
        includeWorkspaceTools: Bool,
        firewall: PrivacyFirewall
    ) -> AsyncThrowingStream<StreamDelta, Error>
}

public enum DeepSeekClientError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidEndpoint(String)
    case httpError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置 API Key。请在右上角「设置」中填入你的钥匙串凭据。"
        case let .invalidEndpoint(url):
            return "无效的模型接口地址：\(url)"
        case let .httpError(code, message):
            return Self.friendlyHTTPMessage(statusCode: code, message: message)
        }
    }

    /// 把网关 / 厂商常见状态码翻译成能直接照做的人话（402 额度用尽、429 太快、401 Key 失效、5xx 服务端故障）。
    static func friendlyHTTPMessage(statusCode code: Int, message: String) -> String {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : "（\(detail)）"
        let quotaLike = detail.contains("额度") || detail.lowercased().contains("quota") || detail.lowercased().contains("budget")
        switch code {
        case 402:
            return "免费额度已用完\(suffix)。可以明天再来，或在「连接 AI」换成自己的 API Key / 网页版登录。"
        case 429 where quotaLike:
            return "今日额度暂时耗尽\(suffix)。稍后再试，或在「连接 AI」换成自己的 API Key / 网页版登录。"
        case 429:
            return "请求太快了\(suffix)，等几十秒再发。"
        case 401, 403:
            return "API Key 无效或已过期（HTTP \(code)）\(suffix)。到「连接 AI」重新粘贴 Key。"
        case 500...599:
            return "模型服务暂时不可用（HTTP \(code)）\(suffix)，稍后重试。"
        default:
            return "模型接口返回 HTTP \(code)：\(message)"
        }
    }
}

public struct DeepSeekClient: ModelStreamingTransport {
    public init() {}

    public func streamChatCompletion(
        config: ProviderConfig,
        apiKey: String,
        messages: [ChatMessage],
        includeWorkspaceTools: Bool,
        firewall: PrivacyFirewall
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    let requiresKey = (config.baseURL.host?.lowercased() ?? "") == "api.deepseek.com"
                    if requiresKey && trimmedKey.isEmpty {
                        throw DeepSeekClientError.missingAPIKey
                    }

                    let endpoint = Self.chatCompletionsURL(from: config.baseURL)
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 180
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if !trimmedKey.isEmpty {
                        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
                    }

                    let schemas = includeWorkspaceTools ? WorkspaceToolset.toolSchemas : []
                    let body = Self.buildRequestPayload(config: config, messages: messages, tools: schemas)
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    try await firewall.authorize(request, purpose: .modelInference, allowingModelBase: config.baseURL)

                    let startedAt = ContinuousClock.now
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw DeepSeekClientError.invalidEndpoint(endpoint.absoluteString)
                    }

                    if !(200..<300).contains(http.statusCode) {
                        var errorBytes = Data()
                        for try await b in bytes {
                            errorBytes.append(b)
                            if errorBytes.count > 4096 { break }
                        }
                        let elapsed = Self.elapsedMs(since: startedAt)
                        await firewall.recordCompleted(
                            request: request,
                            purpose: .modelInference,
                            statusCode: http.statusCode,
                            bytesReceived: errorBytes.count,
                            durationMs: elapsed,
                            note: "HTTP error"
                        )
                        let errText = String(decoding: errorBytes, as: UTF8.self)
                        throw DeepSeekClientError.httpError(statusCode: http.statusCode, message: Self.extractAPIErrorMessage(errText))
                    }

                    var parser = SSECompletionAssembler()
                    var receivedBytes = 0

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        receivedBytes += line.utf8.count + 1
                        for delta in parser.feed(line: line) {
                            continuation.yield(delta)
                        }
                    }

                    for delta in parser.finish() {
                        continuation.yield(delta)
                    }

                    await firewall.recordCompleted(
                        request: request,
                        purpose: .modelInference,
                        statusCode: http.statusCode,
                        bytesReceived: receivedBytes,
                        durationMs: Self.elapsedMs(since: startedAt),
                        note: config.model
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public static func chatCompletionsURL(from baseURL: URL) -> URL {
        let str = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if str.hasSuffix("/chat/completions") {
            return URL(string: str) ?? baseURL
        }
        return URL(string: "\(str)/chat/completions") ?? baseURL.appendingPathComponent("chat/completions")
    }

    /// Discovers available model IDs from any OpenAI-compatible `/v1/models` gateway.
    public func fetchAvailableModels(
        baseURL: URL,
        apiKey: String,
        firewall: PrivacyFirewall
    ) async throws -> [String] {
        let baseStr = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let modelsURLString = baseStr.hasSuffix("/models") ? baseStr : "\(baseStr)/models"
        guard let url = URL(string: modelsURLString) else {
            throw DeepSeekClientError.invalidEndpoint(modelsURLString)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }

        try await firewall.authorize(req, purpose: .modelInference, allowingModelBase: baseURL)

        let started = ContinuousClock.now
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
        await firewall.recordCompleted(
            request: req,
            purpose: .modelInference,
            statusCode: status,
            bytesReceived: data.count,
            durationMs: Self.elapsedMs(since: started),
            note: "GET /models"
        )
        guard (200..<300).contains(status) else {
            throw DeepSeekClientError.httpError(statusCode: status, message: Self.extractAPIErrorMessage(String(decoding: data, as: UTF8.self)))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    /// Queries official DeepSeek account balance (`GET https://api.deepseek.com/user/balance`).
    public func fetchDeepSeekBalance(
        apiKey: String,
        firewall: PrivacyFirewall
    ) async throws -> DeepSeekBalanceInfo {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeepSeekClientError.missingAPIKey }
        let url = URL(string: "https://api.deepseek.com/user/balance")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        try await firewall.authorize(req, purpose: .modelInference, allowingModelBase: url)

        let started = ContinuousClock.now
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
        await firewall.recordCompleted(
            request: req,
            purpose: .modelInference,
            statusCode: status,
            bytesReceived: data.count,
            durationMs: Self.elapsedMs(since: started),
            note: "GET /user/balance"
        )
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekClientError.httpError(statusCode: status, message: "无法读取余额")
        }
        let available = (json["is_available"] as? Bool) ?? false
        let infos = (json["balance_infos"] as? [[String: Any]]) ?? []
        let preferred = infos.first(where: { ($0["currency"] as? String) == "CNY" }) ?? infos.first ?? [:]
        return DeepSeekBalanceInfo(
            isAvailable: available,
            currency: (preferred["currency"] as? String) ?? "CNY",
            totalBalance: (preferred["total_balance"] as? String) ?? "0.00",
            grantedBalance: (preferred["granted_balance"] as? String) ?? "0.00",
            toppedUpBalance: (preferred["topped_up_balance"] as? String) ?? "0.00"
        )
    }

    /// DeepSeek R1 (`deepseek-reasoner`) tool-calling contract:
    /// Within the active user turn (after the latest real `.user` message), assistant tool-call turns MUST include
    /// `reasoning_content`; for earlier completed turns, `reasoning_content` MUST be omitted to avoid HTTP 400.
    public static func buildRequestPayload(
        config: ProviderConfig,
        messages: [ChatMessage],
        tools: [[String: Any]]
    ) -> [String: Any] {
        let isReasoner = config.model.lowercased().contains("reasoner") || config.model.lowercased().contains("r1")
        let lastUserIndex = messages.lastIndex { $0.role == .user && !$0.isSteerInjection } ?? 0

        let wireMessages: [[String: Any]] = messages.enumerated().map { index, msg in
            switch msg.role {
            case .system:
                return ["role": "system", "content": msg.content]
            case .user:
                let prefix = msg.isSteerInjection ? "[用户中途纠偏指令] " : ""
                return ["role": "user", "content": prefix + msg.content]
            case .assistant:
                var item: [String: Any] = [
                    "role": "assistant",
                    "content": msg.content
                ]
                if isReasoner && index > lastUserIndex && !msg.toolCalls.isEmpty {
                    item["reasoning_content"] = msg.reasoningContent ?? ""
                }
                if !msg.toolCalls.isEmpty {
                    item["tool_calls"] = msg.toolCalls.map { tc in
                        [
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": tc.argumentsJSON
                            ]
                        ]
                    }
                }
                return item
            case .tool:
                return [
                    "role": "tool",
                    "tool_call_id": msg.toolOutput?.toolCallId ?? "",
                    "content": msg.content
                ]
            }
        }

        var payload: [String: Any] = [
            "model": config.model,
            "messages": wireMessages,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        if !isReasoner {
            payload["temperature"] = config.temperature
        }
        if !tools.isEmpty {
            payload["tools"] = tools
        }
        return payload
    }

    static func extractAPIErrorMessage(_ raw: String) -> String {
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知错误" : String(trimmed.prefix(240))
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: ContinuousClock.now)
        return Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Pure, unit-testable SSE parser & tool-call delta assembler for DeepSeek / OpenAI streaming responses.
public struct SSECompletionAssembler: Sendable {
    private struct PartialToolCall: Sendable {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    private var partialTools: [Int: PartialToolCall] = [:]
    private var emittedTools = false

    public init() {}

    public mutating func feed(line: String) -> [StreamDelta] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return [] }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return finish()
        }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var out: [StreamDelta] = []

        if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
            if let delta = first["delta"] as? [String: Any] {
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                    out.append(.reasoning(reasoning))
                }
                if let content = delta["content"] as? String, !content.isEmpty {
                    out.append(.content(content))
                }
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        let idx = (tc["index"] as? Int) ?? 0
                        var entry = partialTools[idx] ?? PartialToolCall()
                        if let id = tc["id"] as? String, !id.isEmpty {
                            entry.id = id
                        }
                        if let fn = tc["function"] as? [String: Any] {
                            if let name = fn["name"] as? String {
                                entry.name += name
                            }
                            if let args = fn["arguments"] as? String {
                                entry.arguments += args
                            }
                        }
                        partialTools[idx] = entry
                    }
                }
            }
            if let finishReason = first["finish_reason"] as? String,
               (finishReason == "tool_calls" || finishReason == "stop"),
               !partialTools.isEmpty && !emittedTools {
                out.append(contentsOf: flushToolCalls())
            }
        }

        if let usage = json["usage"] as? [String: Any] {
            let promptTokens = usage["prompt_tokens"] as? Int ?? 0
            let completionTokens = usage["completion_tokens"] as? Int ?? 0
            let hit = usage["prompt_cache_hit_tokens"] as? Int
                ?? ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
                ?? 0
            let miss = usage["prompt_cache_miss_tokens"] as? Int ?? max(0, promptTokens - hit)
            let reasoningTokens = ((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int) ?? 0
            out.append(.usage(TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                reasoningTokens: reasoningTokens,
                cacheHitTokens: hit,
                cacheMissTokens: miss
            )))
        }

        return out
    }

    public mutating func finish() -> [StreamDelta] {
        guard !partialTools.isEmpty && !emittedTools else { return [] }
        return flushToolCalls()
    }

    private mutating func flushToolCalls() -> [StreamDelta] {
        emittedTools = true
        let calls = partialTools.keys.sorted().compactMap { key -> ToolCallRequest? in
            guard let item = partialTools[key], !item.name.isEmpty else { return nil }
            let id = item.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : item.id
            let args = item.arguments.isEmpty ? "{}" : item.arguments
            return ToolCallRequest(id: id, name: item.name, argumentsJSON: args)
        }
        return calls.isEmpty ? [] : [.toolCalls(calls)]
    }
}
