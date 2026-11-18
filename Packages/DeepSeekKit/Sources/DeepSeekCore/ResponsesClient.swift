import Foundation

// ---------------------------------------------------------------------------
// 协议层自适应。
//
// 同样是「OpenAI 兼容」的网关，实际可能挂在两种接口上：
//   · POST /v1/chat/completions   —— 目前绝大多数（DeepSeek / Qwen / Groq / OpenRouter / 硅基流动）
//   · POST /v1/responses          —— OpenAI 新版（GPT-5 系列）以及部分聚合网关
//
// 用户是小白，不该让他选。连上的时候探一次，探到哪种就用哪种，记在 ProviderConfig 里。
// ---------------------------------------------------------------------------

public enum APIProtocolFlavor: String, Codable, Sendable, CaseIterable {
    case chatCompletions
    case responses

    public var displayName: String {
        switch self {
        case .chatCompletions: return "chat/completions"
        case .responses: return "responses"
        }
    }
}

/// 走 `/v1/responses` 的客户端。只实现 harness 真正用到的部分：流式文本、思考摘要、函数调用。
public struct ResponsesClient: ModelStreamingTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func responsesURL(from baseURL: URL) -> URL {
        let str = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if str.hasSuffix("/responses") { return URL(string: str) ?? baseURL }
        return URL(string: "\(str)/responses") ?? baseURL.appendingPathComponent("responses")
    }

    // MARK: 探测

    /// 连通性探测 + 协议判定：先试 chat/completions，404/405 再试 responses。
    /// 两个都失败时抛最后一个错误。
    public static func detectProtocol(
        baseURL: URL,
        apiKey: String,
        firewall: PrivacyFirewall,
        session: URLSession = .shared
    ) async -> APIProtocolFlavor? {
        if await probe(url: DeepSeekClient.chatCompletionsURL(from: baseURL),
                       apiKey: apiKey, firewall: firewall, session: session) {
            return .chatCompletions
        }
        if await probe(url: responsesURL(from: baseURL),
                       apiKey: apiKey, firewall: firewall, session: session) {
            return .responses
        }
        return nil
    }

    private static func probe(
        url: URL,
        apiKey: String,
        firewall: PrivacyFirewall,
        session: URLSession
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = url.absoluteString.hasSuffix("/responses")
            ? ["model": "probe", "input": "ping", "max_output_tokens": 1]
            : ["model": "probe", "messages": [["role": "user", "content": "ping"]], "max_tokens": 1]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        await firewall.setAllowedModelBaseURL(url)
        guard (try? await firewall.authorize(request, purpose: .modelInference)) != nil else { return false }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        // 400/422 说明路由是存在的，只是参数不对；404/405 才是「没这个接口」
        return http.statusCode != 404 && http.statusCode != 405
    }

    // MARK: 流式

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
                    let endpoint = Self.responsesURL(from: config.baseURL)
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 180
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !apiKey.isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }

                    var payload: [String: Any] = [
                        "model": config.model,
                        "stream": true,
                        "temperature": config.temperature
                    ]

                    let system = messages.first(where: { $0.role == .system })?.content
                    if let system, !system.isEmpty { payload["instructions"] = system }

                    payload["input"] = messages
                        .filter { $0.role != .system }
                        .map { message -> [String: Any] in
                            var item: [String: Any] = [
                                "role": message.role == .user ? "user" : "assistant"
                            ]
                            if message.role == .tool {
                                item["type"] = "function_call_output"
                                item["call_id"] = message.toolOutput?.toolCallId ?? message.id.uuidString
                                item["output"] = message.content
                            } else {
                                item["content"] = message.content
                            }
                            return item
                        }

                    if includeWorkspaceTools {
                        // Responses 的函数工具是扁平结构：type/name/parameters
                        // chat/completions 是 {"type":"function","function":{...}}，
                        // Responses 是扁平结构，这里就地展平。
                        let tools: [[String: Any]] = WorkspaceToolset.toolSchemas.compactMap { schema in
                            guard let function = schema["function"] as? [String: Any],
                                  let name = function["name"] as? String else { return nil }
                            return [
                                "type": "function",
                                "name": name,
                                "description": function["description"] as? String ?? "",
                                "parameters": function["parameters"] as? [String: Any] ?? [:]
                            ]
                        }
                        if !tools.isEmpty {
                            payload["tools"] = tools
                            payload["tool_choice"] = "auto"
                        }
                    }

                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    await firewall.setAllowedModelBaseURL(config.baseURL)
                    try await firewall.authorize(request, purpose: .modelInference)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw DeepSeekClientError.invalidEndpoint(endpoint.absoluteString)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 800 { break }
                        }
                        throw DeepSeekClientError.httpError(statusCode: http.statusCode, message: body)
                    }

                    var toolCalls: [ToolCallRequest] = []

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payloadText = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payloadText == "[DONE]" { break }
                        guard let data = payloadText.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = object["type"] as? String else { continue }

                        switch type {
                        case "response.output_text.delta":
                            if let delta = object["delta"] as? String, !delta.isEmpty {
                                continuation.yield(.content(delta))
                            }
                        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                            if let delta = object["delta"] as? String, !delta.isEmpty {
                                continuation.yield(.reasoning(delta))
                            }
                        case "response.output_item.done":
                            if let item = object["item"] as? [String: Any],
                               (item["type"] as? String) == "function_call",
                               let name = item["name"] as? String {
                                let callId = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
                                let arguments = (item["arguments"] as? String) ?? "{}"
                                toolCalls.append(
                                    ToolCallRequest(id: callId, name: name, argumentsJSON: arguments)
                                )
                            }
                        case "response.completed":
                            if let responseObject = object["response"] as? [String: Any],
                               let usage = responseObject["usage"] as? [String: Any] {
                                let prompt = usage["input_tokens"] as? Int ?? 0
                                let completion = usage["output_tokens"] as? Int ?? 0
                                continuation.yield(.usage(
                                    TokenUsage(promptTokens: prompt, completionTokens: completion)
                                ))
                            }
                        default:
                            break
                        }
                    }

                    if !toolCalls.isEmpty {
                        continuation.yield(.toolCalls(toolCalls))
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
