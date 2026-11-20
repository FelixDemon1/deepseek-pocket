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

/// 供 iOS 端注入真实 WKWebView 同源流式执行器（自动过字节 shark_admin/a_bogus 与阿里 AWSC 签名）。
public protocol BrowserStreamPerformer: Sendable {
    func streamRawLines(
        spec: WebAdapterSpec,
        request: URLRequest,
        prompt: String,
        thinkingEnabled: Bool
    ) -> AsyncThrowingStream<String, Error>
}

public struct WebAdapterClient: Sendable {
    private let session: URLSession
    private let browserPerformer: BrowserStreamPerformer?

    public init(session: URLSession = .shared, browserPerformer: BrowserStreamPerformer? = nil) {
        self.session = session
        self.browserPerformer = browserPerformer
    }

    // MARK: 请求构造

    private static func headerTemplateValues(
        token: String,
        model: String,
        cookieHeader: String?
    ) -> [String: String] {
        let fallbackCookie = "sessionid=\(token)"
        let resolvedCookie = (cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? fallbackCookie
        return [
            "token": token,
            "model": model,
            "cookie": resolvedCookie,
            "cookie_header": resolvedCookie
        ]
    }

    private static func applyHeaders(
        spec: WebAdapterSpec,
        token: String,
        model: String,
        cookieHeader: String?,
        powHeaderPair: (name: String, value: String)? = nil,
        to request: inout URLRequest
    ) {
        let values = headerTemplateValues(token: token, model: model, cookieHeader: cookieHeader)
        var hasExplicitCookie = false
        for (key, rawValue) in spec.headers {
            if key.caseInsensitiveCompare("Cookie") == .orderedSame {
                hasExplicitCookie = true
            }
            request.setValue(WebAdapterTemplate.render(rawValue, values: values), forHTTPHeaderField: key)
        }
        if !hasExplicitCookie,
           let cookieHeader = cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let powHeaderPair {
            request.setValue(powHeaderPair.value, forHTTPHeaderField: powHeaderPair.name)
        }
    }

    /// 有些渠道要求先建会话，拿到 id 再发消息。
    public func createSession(
        spec: WebAdapterSpec,
        credential: String,
        cookieHeader: String? = nil,
        session: URLSession
    ) async throws -> String? {
        guard let sessionURL = spec.sessionURL,
              let url = URL(string: sessionURL),
              let path = spec.sessionIdPath, !path.isEmpty else { return nil }

        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        Self.applyHeaders(spec: spec, token: token, model: "", cookieHeader: cookieHeader, to: &request)
        request.httpBody = Data((spec.sessionBody ?? "{}").utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("text/html") {
            throw WebAdapterError.upstream("建会话时触发了网页防火墙（WAF）验证，建议优先使用「DeepSeek 网页版」或免费 API Key。")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw WebAdapterError.httpError(
                    statusCode: http.statusCode,
                    message: "登录状态过期了，回到「连接 AI」重新登录 \(spec.name) 就好"
                )
            }
            throw WebAdapterError.httpError(statusCode: http.statusCode, message: "建会话失败")
        }
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let env = Self.errorEnvelope(from: dict) {
            throw WebAdapterError.httpError(statusCode: 200, message: env)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let id = WebJSONPath.string(in: object, path: path) else {
            throw WebAdapterError.upstream("建会话成功但没解析到 session id（路径 \(path)）")
        }
        return id
    }

    /// 自动拉取并解算网页版工作量证明（DeepSeekHashV1），返回要塞进请求头的键值对。
    public func fetchAndSolvePoW(
        spec: WebAdapterSpec,
        credential: String,
        cookieHeader: String? = nil,
        session: URLSession
    ) async throws -> (name: String, value: String)? {
        guard let powURLString = spec.powURL,
              let url = URL(string: powURLString),
              let headerName = spec.powHeader, !headerName.isEmpty else {
            return nil
        }
        let targetPath = spec.powTargetPath ?? (URL(string: spec.chatURL)?.path ?? "/api/v0/chat/completion")
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        Self.applyHeaders(spec: spec, token: token, model: "", cookieHeader: cookieHeader, to: &request)
        let payload = try JSONSerialization.data(withJSONObject: ["target_path": targetPath])
        request.httpBody = payload

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebAdapterError.httpError(statusCode: http.statusCode, message: "获取工作量证明挑战失败")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebAdapterError.upstream("工作量证明挑战回包不是合法 JSON")
        }
        if let env = Self.errorEnvelope(from: root) {
            throw WebAdapterError.httpError(statusCode: 200, message: env)
        }
        guard let challengeDict = WebJSONPath.value(in: root, path: "data.biz_data.challenge") as? [String: Any],
              let algorithm = challengeDict["algorithm"] as? String,
              let challengeHex = challengeDict["challenge"] as? String,
              let salt = challengeDict["salt"] as? String,
              let signature = challengeDict["signature"] as? String else {
            throw WebAdapterError.upstream("未在挑战回包中找到 challenge 字段")
        }
        let difficulty = (challengeDict["difficulty"] as? NSNumber)?.intValue ?? 144_000
        let expireAt = (challengeDict["expire_at"] as? NSNumber)?.int64Value ?? 0

        guard algorithm == "DeepSeekHashV1" else {
            throw WebAdapterError.upstream("上游切换了未知工作量证明算法：\(algorithm)")
        }

        let answer = await Task.detached(priority: .userInitiated) {
            DeepSeekPoWSolver.solve(
                challenge: challengeHex,
                salt: salt,
                expireAt: expireAt,
                difficulty: difficulty
            )
        }.value

        guard let answer else {
            throw WebAdapterError.upstream("工作量证明未找到解（difficulty=\(difficulty)）")
        }

        let encoded = DeepSeekPoWSolver.encodeHeaderValue(
            algorithm: algorithm,
            challenge: challengeHex,
            salt: salt,
            answer: answer,
            signature: signature,
            targetPath: targetPath
        )
        return (name: headerName, value: encoded)
    }

    public func makeRequest(
        spec: WebAdapterSpec,
        credential: String,
        model: String,
        messages: [ChatMessage],
        sessionID: String? = nil,
        cookieHeader: String? = nil,
        powHeaderPair: (name: String, value: String)? = nil,
        toolManual: String? = nil
    ) throws -> URLRequest {
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw WebAdapterError.missingCredential }
        guard let url = URL(string: spec.chatURL) else {
            throw WebAdapterError.badSpec("chatURL 不合法：\(spec.chatURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        Self.applyHeaders(
            spec: spec,
            token: token,
            model: model,
            cookieHeader: cookieHeader,
            powHeaderPair: powHeaderPair,
            to: &request
        )

        let loweredModel = model.lowercased()
        let thinkingEnabled = loweredModel.contains("reasoner")
            || loweredModel.contains("r1")
            || loweredModel.contains("think")
            || loweredModel.contains("qwq")
        let prompt = Self.flatten(messages, toolManual: toolManual)
        let escapedPrompt = WebAdapterTemplate.jsonEscape(prompt)
        let headerVars = Self.headerTemplateValues(token: token, model: model, cookieHeader: cookieHeader)
        let values: [String: String] = [
            "token": token,
            "model": model,
            "cookie": headerVars["cookie"] ?? "",
            "cookie_header": headerVars["cookie_header"] ?? "",
            "thinking_enabled": thinkingEnabled ? "true" : "false",
            "session_id": WebAdapterTemplate.jsonEscape(sessionID ?? ""),
            "prompt": escapedPrompt,
            "prompt_nested": WebAdapterTemplate.jsonEscape(escapedPrompt),
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

    /// 剥掉本机沙盒工具索引标签，避免纯对话网页接口误以为自己挂了 function calling schema。
    private static func cleanSystemPrompt(_ raw: String) -> String {
        var cleaned = raw
        for tag in ["workspace_files", "device_context"] {
            if let start = cleaned.range(of: "<\(tag)>"),
               let end = cleaned.range(of: "</\(tag)>") {
                cleaned.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == AgentHarness.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
            return ""
        }
        return cleaned
    }

    /// `toolManual` 非空时走 agent 形态：保留工具调用与结果，让只有一个文本框的网页接口也能多步执行。
    public static func flatten(_ messages: [ChatMessage], toolManual: String? = nil) -> String {
        if let toolManual {
            return flattenForAgent(messages, toolManual: toolManual)
        }
        let usable = messages.filter { $0.role == .user || $0.role == .assistant || $0.role == .system }
        guard let lastUser = usable.last(where: { $0.role == .user }) else {
            return usable.map(\.content).joined(separator: "\n")
        }
        let rawSystem = usable.first(where: { $0.role == .system })?.content ?? ""
        let system = cleanSystemPrompt(rawSystem)
        let history = usable.dropLast().filter { $0.role != .system }
        if system.isEmpty && history.isEmpty {
            return lastUser.content
        }
        var parts: [String] = []
        if !system.isEmpty {
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

    private static func flattenForAgent(_ messages: [ChatMessage], toolManual: String) -> String {
        let system = messages.first(where: { $0.role == .system })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let turns = messages.filter { $0.role != .system }
        guard let taskIndex = turns.lastIndex(where: { $0.role == .user && !$0.isSteerInjection }) else {
            return ([system, toolManual] + turns.map(\.content)).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        func line(_ message: ChatMessage, resultLimit: Int) -> String {
            switch message.role {
            case .user:
                return (message.isSteerInjection ? "用户补充：" : "用户：") + message.content
            case .assistant:
                let calls = message.toolCalls.isEmpty ? "" : ToolCallTextProtocol.render(calls: message.toolCalls)
                return "助手：" + [message.content, calls].filter { !$0.isEmpty }.joined(separator: "\n")
            case .tool:
                let name = message.toolOutput?.toolName ?? "tool"
                let state = message.toolOutput?.isError == true ? "失败" : "成功"
                let body = message.content.count > resultLimit
                    ? String(message.content.prefix(resultLimit)) + "\n…（结果过长已截断）"
                    : message.content
                return "工具结果（\(name)，\(state)）：\n\(body)"
            case .system:
                return ""
            }
        }

        var parts: [String] = []
        if !system.isEmpty { parts.append("[系统要求]\n\(system)") }
        parts.append(toolManual)
        let history = turns[..<taskIndex]
        if !history.isEmpty {
            parts.append("[对话历史]\n" + history.map { line($0, resultLimit: 600) }.joined(separator: "\n"))
        }
        parts.append("[当前任务]\n\(turns[taskIndex].content)")
        let steps = turns[(taskIndex + 1)...]
        if !steps.isEmpty {
            parts.append("[本轮已执行的步骤]\n" + steps.map { line($0, resultLimit: 4000) }.joined(separator: "\n"))
            parts.append("[下一步]\n根据上面的工具结果继续：还需要信息或操作就再输出 tool 代码块；任务已经完成就直接给出最终回答，不要再输出 tool 代码块。")
        }
        return parts.joined(separator: "\n\n")
    }

    /// 识别上游的「HTTP 200 + 错误信封」（含整型 code、字符串 code 以及嵌套 biz_code）。
    static func errorEnvelope(from object: [String: Any]) -> String? {
        // 阿里系（千问）风控：{"ret":["FAIL_SYS_USER_VALIDATE","RGV587_ERROR::SM::哎哟喂,被挤爆啦..."],"data":{"url":".../punish?x5secdata=..."}}
        if let ret = object["ret"] as? [String], let first = ret.first,
           first.hasPrefix("FAIL_") || ret.contains(where: { $0.contains("RGV587") }) {
            let detail = ret.last?.components(separatedBy: "::").last ?? first
            return "官网触发了人机验证（\(detail)）。请稍等几分钟再试；仍不行就到「连接 AI」长按该渠道重新登录，在网页里完成验证。"
        }
        if let code = object["code"] as? Int, code != 0 {
            let message = (object["msg"] as? String) ?? (object["message"] as? String) ?? "未知错误"
            var hint = "上游返回 code \(code)：\(message)"
            let lowered = message.lowercased()
            if lowered.contains("token") || lowered.contains("auth") || code == 40002 || code == 40003 {
                hint += "。登录状态可能已经失效，长按渠道重新登录。"
            }
            if lowered.contains("pow") || lowered.contains("sign") || lowered.contains("challenge") || lowered.contains("header") {
                hint += "。该渠道启用了风控签名（PoW/签名头），请确认使用最新内置校准版本或切换官方 API Key。"
            }
            return hint
        }
        if let data = object["data"] as? [String: Any],
           let bizCode = data["biz_code"] as? Int, bizCode != 0 {
            let bizMsg = (data["biz_msg"] as? String) ?? "业务异常"
            return "上游业务返回 code \(bizCode)：\(bizMsg)"
        }
        if let codeStr = object["code"] as? String, !codeStr.isEmpty, codeStr != "0", codeStr.lowercased() != "ok" {
            let message = (object["message"] as? String) ?? (object["msg"] as? String) ?? codeStr
            if message.lowercased().contains("user invalid") || message.lowercased().contains("invalid user") {
                return "登录凭据不完整或已失效（\(codeStr)），请回到「连接 AI」长按该渠道重新登录。"
            }
            return "上游返回 \(codeStr)：\(String(message.prefix(200)))"
        }
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "未知错误"
            return "上游返回错误：\(message)"
        }
        if object["choices"] == nil, object["type"] == nil, object["event_type"] == nil,
           object["v"] == nil, object["p"] == nil,
           let message = object["msg"] as? String, !message.isEmpty {
            return "上游返回：\(message)"
        }
        return nil
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
        cookieHeader: String? = nil,
        model: String,
        messages: [ChatMessage],
        firewall: PrivacyFirewall? = nil,
        toolManual: String? = nil
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = ContinuousClock.now
                do {
                    let sessionID = try await createSession(
                        spec: spec,
                        credential: credential,
                        cookieHeader: cookieHeader,
                        session: session
                    )
                    let powPair = try await fetchAndSolvePoW(
                        spec: spec,
                        credential: credential,
                        cookieHeader: cookieHeader,
                        session: session
                    )
                    let request = try makeRequest(
                        spec: spec,
                        credential: credential,
                        model: model,
                        messages: messages,
                        sessionID: sessionID,
                        cookieHeader: cookieHeader,
                        powHeaderPair: powPair,
                        toolManual: toolManual
                    )
                    if let firewall, let chatURL = request.url {
                        try await firewall.authorize(request, purpose: .modelInference, allowingModelBase: chatURL)
                    }

                    let loweredModel = model.lowercased()
                    let thinkingEnabled = loweredModel.contains("reasoner") || loweredModel.contains("r1") || loweredModel.contains("think")
                    let flattenedPrompt = Self.flatten(messages, toolManual: toolManual)

                    var extractor = WebDeltaExtractor(mode: spec.responseMode, streamPath: spec.streamPath)
                    var sawAnyDelta = false
                    var receivedBytes = 0
                    var statusCode = 200

                    func consumeRawSSELine(_ rawLine: String, currentEvent: inout String) throws -> Bool {
                        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            currentEvent = "message"
                            return false
                        }
                        if trimmed.hasPrefix(":") || trimmed.hasPrefix("id:") {
                            return false
                        }
                        if trimmed.hasPrefix("event:") {
                            currentEvent = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            if currentEvent == "close" { return true }
                            return false
                        }

                        if !trimmed.hasPrefix("data:"),
                           let data = trimmed.data(using: .utf8),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let envelope = Self.errorEnvelope(from: object) {
                            throw WebAdapterError.httpError(statusCode: 200, message: envelope)
                        }

                        let payload = trimmed.hasPrefix("data:")
                            ? String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            : trimmed
                        let eventForThisData = currentEvent
                        currentEvent = "message"

                        if payload == "[DONE]" { return true }
                        if eventForThisData == "ready" || eventForThisData == "update_session" || eventForThisData == "title" {
                            return false
                        }
                        if eventForThisData == "close" {
                            return true
                        }

                        if let data = payload.data(using: .utf8),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            if eventForThisData == "gateway-error" || eventForThisData == "error" {
                                let msg = Self.errorEnvelope(from: object)
                                    ?? (object["message"] as? String)
                                    ?? (object["msg"] as? String)
                                    ?? payload
                                throw WebAdapterError.upstream(msg)
                            }
                            // 豆包 event_type == 2005 (ERR) 专门解包报错，避免静默空回
                            if (object["event_type"] as? NSNumber)?.intValue == 2005,
                               let errStr = object["event_data"] as? String,
                               let errData = errStr.data(using: .utf8),
                               let errObj = try? JSONSerialization.jsonObject(with: errData) as? [String: Any] {
                                let detail = WebJSONPath.string(in: errObj, path: "error_detail.message")
                                    ?? (errObj["message"] as? String)
                                    ?? errStr
                                let code = (errObj["code"] as? NSNumber)?.intValue ?? -1
                                throw WebAdapterError.upstream("豆包返回错误（\(code)）：\(detail)")
                            }
                            if (object["event_type"] as? NSNumber)?.intValue == 2003 {
                                return true
                            }
                            if let envelope = Self.errorEnvelope(from: object),
                               WebJSONPath.value(in: object, path: "choices") == nil {
                                throw WebAdapterError.httpError(statusCode: 200, message: envelope)
                            }
                        }

                        let deltas = extractor.extract(payload)
                        if !deltas.isEmpty { sawAnyDelta = true }
                        for delta in deltas {
                            continuation.yield(delta)
                        }
                        return false
                    }

                    if spec.useBrowserContext, let performer = browserPerformer {
                        var currentEvent = "message"
                        let browserLines = performer.streamRawLines(
                            spec: spec,
                            request: request,
                            prompt: flattenedPrompt,
                            thinkingEnabled: thinkingEnabled
                        )
                        for try await line in browserLines {
                            try Task.checkCancellation()
                            receivedBytes += line.utf8.count + 1
                            if try consumeRawSSELine(line, currentEvent: &currentEvent) {
                                break
                            }
                        }
                    } else {
                        let (bytes, response) = try await session.bytes(for: request)
                        let http = response as? HTTPURLResponse
                        statusCode = http?.statusCode ?? 200

                        if !(200..<300).contains(statusCode) {
                            var body = ""
                            for try await line in bytes.lines {
                                body += line
                                if body.count > 600 { break }
                            }
                            if let firewall {
                                await firewall.recordCompleted(
                                    request: request,
                                    purpose: .modelInference,
                                    statusCode: statusCode,
                                    bytesReceived: body.utf8.count,
                                    durationMs: Self.elapsedMs(since: startedAt),
                                    note: "WebAdapter HTTP \(statusCode)"
                                )
                            }
                            if statusCode == 401 || statusCode == 403 {
                                throw WebAdapterError.httpError(
                                    statusCode: statusCode,
                                    message: "登录状态过期了，回到「连接 AI」重新登录 \(spec.name) 就好"
                                )
                            }
                            throw WebAdapterError.httpError(
                                statusCode: statusCode,
                                message: body.isEmpty ? "无响应体" : body
                            )
                        }

                        if let contentType = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
                           contentType.contains("text/html") {
                            var htmlPreview = ""
                            for try await line in bytes.lines {
                                htmlPreview += line
                                if htmlPreview.count > 400 { break }
                            }
                            throw WebAdapterError.upstream(
                                "该网页渠道返回了防火墙人机验证页（WAF），直连被拦截；建议优先使用「DeepSeek 网页版」或免费 API Key。"
                            )
                        }

                        var currentEvent = "message"
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            receivedBytes += line.utf8.count + 1
                            if try consumeRawSSELine(line, currentEvent: &currentEvent) {
                                break
                            }
                        }
                    }

                    if let firewall {
                        await firewall.recordCompleted(
                            request: request,
                            purpose: .modelInference,
                            statusCode: statusCode,
                            bytesReceived: receivedBytes,
                            durationMs: Self.elapsedMs(since: startedAt),
                            note: spec.name
                        )
                    }

                    if !sawAnyDelta && spec.calibrated == false {
                        throw WebAdapterError.upstream(
                            "上游连上了但没有返回可识别的内容，这个渠道的回包格式还没校准（预期 \(spec.responseMode.rawValue)）"
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: ContinuousClock.now)
        return Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - 回包翻译

public struct WebDeltaExtractor: Sendable {
    public let mode: WebResponseMode
    public let streamPath: String
    private var accumulator = SnapshotAccumulator()
    private var thinkingAccumulator = SnapshotAccumulator()
    private var emittedAny = false

    // DeepSeek 网页版有状态补丁机：后续帧常省略 "p"/"o" 仅给 {"v":"..."}，且按 fragment.type 区分 THINK / RESPONSE
    private var dsFragmentAccumulators: [Int: SnapshotAccumulator] = [:]
    private var dsActiveFragmentId: Int = 0
    private var dsActiveFragmentType: String = "RESPONSE"
    private var dsActivePath: String = "response/fragments/-1/content"

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
            guard let dict = object as? [String: Any] else { return [] }
            return extractDeepSeek(dict)

        case .sseDoubao:
            guard let dict = object as? [String: Any] else { return [] }
            return extractDoubao(dict)

        case .sseQianwen:
            guard let dict = object as? [String: Any] else { return [] }
            return extractQianwen(dict)
        }
    }

    private mutating func extractDoubao(_ dict: [String: Any]) -> [StreamDelta] {
        guard let eventData = dict["event_data"] as? String,
              let inner = eventData.data(using: .utf8),
              let innerDict = try? JSONSerialization.jsonObject(with: inner) as? [String: Any] else {
            return []
        }

        var out: [StreamDelta] = []
        let isDelta = (innerDict["is_delta"] as? Bool) ?? false

        // 1) Samantha v2 patch_op -> patch_value.content_block (10040 thinking / 10000 text)
        if let patchOps = innerDict["patch_op"] as? [[String: Any]] {
            for op in patchOps {
                if let pv = op["patch_value"] as? [String: Any],
                   let blocks = pv["content_block"] as? [[String: Any]] {
                    for blk in blocks {
                        let bType = (blk["block_type"] as? NSNumber)?.intValue ?? 0
                        let contentDict = blk["content"] as? [String: Any]
                        if bType == 10040,
                           let think = WebJSONPath.string(in: contentDict as Any, path: "thinking_block.text")
                               ?? WebJSONPath.string(in: contentDict as Any, path: "text_block.text"),
                           !think.isEmpty {
                            let d = isDelta ? think : thinkingAccumulator.absorb(think)
                            if !d.isEmpty { out.append(.reasoning(d)) }
                        } else if let txt = WebJSONPath.string(in: contentDict as Any, path: "text_block.text"),
                                  !txt.isEmpty {
                            let d = isDelta ? txt : accumulator.absorb(txt)
                            if !d.isEmpty {
                                emittedAny = true
                                out.append(.content(d))
                            }
                        }
                    }
                }
            }
            if !out.isEmpty { return out }
        }

        // 2) BLOCKLIST (event_type 2022) -> blocks[].content
        if let blocks = innerDict["blocks"] as? [[String: Any]] {
            for blk in blocks {
                if let rawContent = blk["content"] as? String {
                    out.append(contentsOf: parseDoubaoContentString(rawContent, isDelta: true))
                }
            }
            if !out.isEmpty { return out }
        }

        // 3) Samantha v1 message.content（可能是 JSON 字符串 "{\"text\":\"...\"}"，也可能是纯文本快照）
        if let rawContent = WebJSONPath.string(in: innerDict, path: "message.content"), !rawContent.isEmpty {
            return parseDoubaoContentString(rawContent, isDelta: isDelta)
        }

        if let patch = WebJSONPath.string(in: innerDict, path: "patch_object.patch_value"), !patch.isEmpty {
            emittedAny = true
            return [.content(patch)]
        }
        return []
    }

    private mutating func parseDoubaoContentString(_ rawContent: String, isDelta: Bool) -> [StreamDelta] {
        if rawContent.hasPrefix("{"),
           let data = rawContent.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [StreamDelta] = []
            if let think = obj["think"] as? String, !think.isEmpty {
                let d = isDelta ? think : thinkingAccumulator.absorb(think)
                if !d.isEmpty { out.append(.reasoning(d)) }
            }
            if let text = obj["text"] as? String, !text.isEmpty {
                let d = isDelta ? text : accumulator.absorb(text)
                if !d.isEmpty {
                    emittedAny = true
                    out.append(.content(d))
                }
            }
            return out
        }
        let d = isDelta ? rawContent : accumulator.absorb(rawContent)
        guard !d.isEmpty else { return [] }
        emittedAny = true
        return [.content(d)]
    }

    private mutating func extractQianwen(_ dict: [String: Any]) -> [StreamDelta] {
        var out: [StreamDelta] = []
        let items: [[String: Any]] = (dict["contents"] as? [[String: Any]])
            ?? (WebJSONPath.value(in: dict, path: "data.messages") as? [[String: Any]])
            ?? []
        for item in items {
            let mime = (item["mime_type"] as? String) ?? ""

            // 千问 v2 JSON Patch 增量模式（op: add / replace）
            if let patches = item["patch"] as? [[String: Any]] {
                for patch in patches {
                    let op = (patch["op"] as? String) ?? ""
                    let path = (patch["path"] as? String) ?? ""
                    if path == "/content", let text = patch["value"] as? String, !text.isEmpty {
                        if op == "add" {
                            _ = accumulator.absorb(accumulator.text + text)
                            emittedAny = true
                            out.append(.content(text))
                        } else if op == "replace" {
                            let d = accumulator.absorb(text)
                            if !d.isEmpty {
                                emittedAny = true
                                out.append(.content(d))
                            }
                        }
                    } else if path.contains("think_content"), let think = patch["value"] as? String, !think.isEmpty {
                        if op == "add" {
                            _ = thinkingAccumulator.absorb(thinkingAccumulator.text + think)
                            out.append(.reasoning(think))
                        } else if op == "replace" {
                            let d = thinkingAccumulator.absorb(think)
                            if !d.isEmpty { out.append(.reasoning(d)) }
                        }
                    } else if let valDict = patch["value"] as? [String: Any],
                              let think = WebJSONPath.string(in: valDict, path: "content.think_content"),
                              !think.isEmpty {
                        let d = thinkingAccumulator.absorb(think)
                        if !d.isEmpty { out.append(.reasoning(d)) }
                    }
                }
                continue
            }

            if mime == "multi_load/iframe",
               let multi = WebJSONPath.value(in: item, path: "meta_data.multi_load") as? [[String: Any]] {
                for sub in multi {
                    let subType = (sub["type"] as? String) ?? ""
                    if subType.contains("think"),
                       let think = WebJSONPath.string(in: sub, path: "content.think_content"),
                       !think.isEmpty {
                        let d = thinkingAccumulator.absorb(think)
                        if !d.isEmpty { out.append(.reasoning(d)) }
                    }
                }
                // 千问 4.15+：正文直接放在 multi_load/iframe 的 content 里（累计快照，processing → complete）
                if let content = item["content"] as? String, !content.isEmpty {
                    let d = accumulator.absorb(content)
                    if !d.isEmpty {
                        emittedAny = true
                        out.append(.content(d))
                    }
                }
            } else if mime.isEmpty || mime == "text/plain" || mime.contains("markdown") {
                if let content = item["content"] as? String, !content.isEmpty {
                    let d = accumulator.absorb(content)
                    if !d.isEmpty {
                        emittedAny = true
                        out.append(.content(d))
                    }
                }
            }
        }
        if !out.isEmpty { return out }
        if let content = WebJSONPath.string(in: dict, path: "choices.0.delta.content"), !content.isEmpty {
            emittedAny = true
            return [.content(content)]
        }
        return []
    }

    private mutating func extractDeepSeek(_ dict: [String: Any]) -> [StreamDelta] {
        // 1) 首包整段快照：{"v": {"response": {"fragments": [...]}}}
        if dict["p"] == nil,
           let vDict = dict["v"] as? [String: Any],
           let resp = vDict["response"] as? [String: Any],
           let fragments = resp["fragments"] as? [[String: Any]] {
            return ingestDeepSeekFragments(fragments)
        }

        // 2) 带路径补丁帧：{"p": "...", "o": "...", "v": ...}
        if let patchPath = dict["p"] as? String {
            dsActivePath = patchPath
            let op = (dict["o"] as? String) ?? ""

            if patchPath == "response/fragments" || patchPath == "fragments" {
                if let list = dict["v"] as? [[String: Any]] {
                    return ingestDeepSeekFragments(list)
                }
                if let single = dict["v"] as? [String: Any] {
                    return ingestDeepSeekFragments([single])
                }
                return []
            }

            if (patchPath == "response" || patchPath.isEmpty),
               op == "BATCH",
               let items = dict["v"] as? [[String: Any]] {
                var out: [StreamDelta] = []
                for item in items {
                    var sub = item
                    if let subPath = sub["p"] as? String, !subPath.hasPrefix("response/") {
                        sub["p"] = "response/\(subPath)"
                    }
                    if sub["p"] as? String == "response/accumulated_token_usage",
                       let total = (sub["v"] as? NSNumber)?.intValue, total > 0 {
                        out.append(.usage(TokenUsage(promptTokens: 0, completionTokens: total)))
                    } else {
                        out.append(contentsOf: extractDeepSeek(sub))
                    }
                }
                return out
            }

            if let text = dict["v"] as? String {
                return emitDeepSeekText(text, forPath: patchPath)
            }
            return []
        }

        // 3) 省略了 p/o 的连续增量帧：{"v": "两个字"}（复用上一条 dsActivePath）
        if let text = dict["v"] as? String {
            return emitDeepSeekText(text, forPath: dsActivePath)
        }

        return []
    }

    private mutating func ingestDeepSeekFragments(_ fragments: [[String: Any]]) -> [StreamDelta] {
        var out: [StreamDelta] = []
        for (idx, frag) in fragments.enumerated() {
            let fragId = (frag["id"] as? NSNumber)?.intValue ?? (idx + 1)
            let fragType = ((frag["type"] as? String) ?? "RESPONSE").uppercased()
            let content = (frag["content"] as? String) ?? ""
            dsActiveFragmentId = fragId
            dsActiveFragmentType = fragType

            var acc = dsFragmentAccumulators[fragId] ?? SnapshotAccumulator()
            let delta = acc.absorb(content)
            dsFragmentAccumulators[fragId] = acc

            if !delta.isEmpty {
                if fragType == "THINK" {
                    out.append(.reasoning(delta))
                } else {
                    emittedAny = true
                    out.append(.content(delta))
                }
            }
        }
        return out
    }

    private mutating func emitDeepSeekText(_ text: String, forPath path: String) -> [StreamDelta] {
        guard !text.isEmpty else { return [] }
        if path.contains("thinking") {
            return [.reasoning(text)]
        }
        guard path.hasSuffix("content") else { return [] }

        var acc = dsFragmentAccumulators[dsActiveFragmentId] ?? SnapshotAccumulator()
        _ = acc.absorb(acc.text + text)
        dsFragmentAccumulators[dsActiveFragmentId] = acc

        if dsActiveFragmentType == "THINK" {
            return [.reasoning(text)]
        }
        emittedAny = true
        return [.content(text)]
    }
}

// MARK: - DeepSeekHashV1 纯原生解算器（23 轮 Keccak-f[1600]，跳过 RC[0]）

public enum DeepSeekPoWSolver {
    private static let rc23: (
        UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64
    ) = (
        0x00000000_00008082, 0x80000000_0000808a, 0x80000000_80008000, 0x00000000_0000808b,
        0x00000000_80000001, 0x80000000_80008081, 0x80000000_00008009, 0x00000000_0000008a,
        0x00000000_00000088, 0x00000000_80008009, 0x00000000_8000000a, 0x00000000_8000808b,
        0x80000000_0000008b, 0x80000000_00008089, 0x80000000_00008003, 0x80000000_00008002,
        0x80000000_00000080, 0x00000000_0000800a, 0x80000000_8000000a, 0x80000000_80008081,
        0x80000000_00008080, 0x00000000_80000001, 0x80000000_80008008
    )

    @inline(__always)
    private static func rotl(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x &<< n) | (x &>> (64 &- n))
    }

    @inline(__always)
    private static func round(
        _ a0: inout UInt64, _ a1: inout UInt64, _ a2: inout UInt64, _ a3: inout UInt64, _ a4: inout UInt64,
        _ a5: inout UInt64, _ a6: inout UInt64, _ a7: inout UInt64, _ a8: inout UInt64, _ a9: inout UInt64,
        _ a10: inout UInt64, _ a11: inout UInt64, _ a12: inout UInt64, _ a13: inout UInt64, _ a14: inout UInt64,
        _ a15: inout UInt64, _ a16: inout UInt64, _ a17: inout UInt64, _ a18: inout UInt64, _ a19: inout UInt64,
        _ a20: inout UInt64, _ a21: inout UInt64, _ a22: inout UInt64, _ a23: inout UInt64, _ a24: inout UInt64,
        rc: UInt64
    ) {
        let c0 = a0 ^ a5 ^ a10 ^ a15 ^ a20
        let c1 = a1 ^ a6 ^ a11 ^ a16 ^ a21
        let c2 = a2 ^ a7 ^ a12 ^ a17 ^ a22
        let c3 = a3 ^ a8 ^ a13 ^ a18 ^ a23
        let c4 = a4 ^ a9 ^ a14 ^ a19 ^ a24

        let d0 = c4 ^ rotl(c1, 1)
        let d1 = c0 ^ rotl(c2, 1)
        let d2 = c1 ^ rotl(c3, 1)
        let d3 = c2 ^ rotl(c4, 1)
        let d4 = c3 ^ rotl(c0, 1)

        let b0  = a0 ^ d0
        let b10 = rotl(a1 ^ d1, 1)
        let b20 = rotl(a2 ^ d2, 62)
        let b5  = rotl(a3 ^ d3, 28)
        let b15 = rotl(a4 ^ d4, 27)

        let b16 = rotl(a5 ^ d0, 36)
        let b1  = rotl(a6 ^ d1, 44)
        let b11 = rotl(a7 ^ d2, 6)
        let b21 = rotl(a8 ^ d3, 55)
        let b6  = rotl(a9 ^ d4, 20)

        let b7  = rotl(a10 ^ d0, 3)
        let b17 = rotl(a11 ^ d1, 10)
        let b2  = rotl(a12 ^ d2, 43)
        let b12 = rotl(a13 ^ d3, 25)
        let b22 = rotl(a14 ^ d4, 39)

        let b23 = rotl(a15 ^ d0, 41)
        let b8  = rotl(a16 ^ d1, 45)
        let b18 = rotl(a17 ^ d2, 15)
        let b3  = rotl(a18 ^ d3, 21)
        let b13 = rotl(a19 ^ d4, 8)

        let b14 = rotl(a20 ^ d0, 18)
        let b24 = rotl(a21 ^ d1, 2)
        let b9  = rotl(a22 ^ d2, 61)
        let b19 = rotl(a23 ^ d3, 56)
        let b4  = rotl(a24 ^ d4, 14)

        a0  = (b0  ^ ((~b1)  & b2)) ^ rc
        a1  =  b1  ^ ((~b2)  & b3)
        a2  =  b2  ^ ((~b3)  & b4)
        a3  =  b3  ^ ((~b4)  & b0)
        a4  =  b4  ^ ((~b0)  & b1)

        a5  =  b5  ^ ((~b6)  & b7)
        a6  =  b6  ^ ((~b7)  & b8)
        a7  =  b7  ^ ((~b8)  & b9)
        a8  =  b8  ^ ((~b9)  & b5)
        a9  =  b9  ^ ((~b5)  & b6)

        a10 =  b10 ^ ((~b11) & b12)
        a11 =  b11 ^ ((~b12) & b13)
        a12 =  b12 ^ ((~b13) & b14)
        a13 =  b13 ^ ((~b14) & b10)
        a14 =  b14 ^ ((~b10) & b11)

        a15 =  b15 ^ ((~b16) & b17)
        a16 =  b16 ^ ((~b17) & b18)
        a17 =  b17 ^ ((~b18) & b19)
        a18 =  b18 ^ ((~b19) & b15)
        a19 =  b19 ^ ((~b15) & b16)

        a20 =  b20 ^ ((~b21) & b22)
        a21 =  b21 ^ ((~b22) & b23)
        a22 =  b22 ^ ((~b23) & b24)
        a23 =  b23 ^ ((~b24) & b20)
        a24 =  b24 ^ ((~b20) & b21)
    }

    @inline(__always)
    private static func permute23(
        _ a0: inout UInt64, _ a1: inout UInt64, _ a2: inout UInt64, _ a3: inout UInt64, _ a4: inout UInt64,
        _ a5: inout UInt64, _ a6: inout UInt64, _ a7: inout UInt64, _ a8: inout UInt64, _ a9: inout UInt64,
        _ a10: inout UInt64, _ a11: inout UInt64, _ a12: inout UInt64, _ a13: inout UInt64, _ a14: inout UInt64,
        _ a15: inout UInt64, _ a16: inout UInt64, _ a17: inout UInt64, _ a18: inout UInt64, _ a19: inout UInt64,
        _ a20: inout UInt64, _ a21: inout UInt64, _ a22: inout UInt64, _ a23: inout UInt64, _ a24: inout UInt64
    ) {
        let r = rc23
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.0)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.1)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.2)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.3)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.4)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.5)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.6)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.7)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.8)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.9)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.10)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.11)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.12)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.13)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.14)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.15)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.16)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.17)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.18)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.19)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.20)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.21)
        round(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24, rc: r.22)
    }

    /// 计算任意文本的 DeepSeekHashV1 十六进制摘要（与官方 sha3_wasm_bg.wasm 逐位一致）。
    public static func hashHex(_ message: String) -> String {
        let bytes = Array(message.utf8)
        var a0: UInt64 = 0, a1: UInt64 = 0, a2: UInt64 = 0, a3: UInt64 = 0, a4: UInt64 = 0
        var a5: UInt64 = 0, a6: UInt64 = 0, a7: UInt64 = 0, a8: UInt64 = 0, a9: UInt64 = 0
        var a10: UInt64 = 0, a11: UInt64 = 0, a12: UInt64 = 0, a13: UInt64 = 0, a14: UInt64 = 0
        var a15: UInt64 = 0, a16: UInt64 = 0, a17: UInt64 = 0, a18: UInt64 = 0, a19: UInt64 = 0
        var a20: UInt64 = 0, a21: UInt64 = 0, a22: UInt64 = 0, a23: UInt64 = 0, a24: UInt64 = 0

        let rate = 136
        var offset = 0
        var block = [UInt8](repeating: 0, count: rate)

        func xorBlock(_ buf: UnsafeRawPointer) {
            a0  ^= UInt64(littleEndian: buf.load(fromByteOffset:   0, as: UInt64.self))
            a1  ^= UInt64(littleEndian: buf.load(fromByteOffset:   8, as: UInt64.self))
            a2  ^= UInt64(littleEndian: buf.load(fromByteOffset:  16, as: UInt64.self))
            a3  ^= UInt64(littleEndian: buf.load(fromByteOffset:  24, as: UInt64.self))
            a4  ^= UInt64(littleEndian: buf.load(fromByteOffset:  32, as: UInt64.self))
            a5  ^= UInt64(littleEndian: buf.load(fromByteOffset:  40, as: UInt64.self))
            a6  ^= UInt64(littleEndian: buf.load(fromByteOffset:  48, as: UInt64.self))
            a7  ^= UInt64(littleEndian: buf.load(fromByteOffset:  56, as: UInt64.self))
            a8  ^= UInt64(littleEndian: buf.load(fromByteOffset:  64, as: UInt64.self))
            a9  ^= UInt64(littleEndian: buf.load(fromByteOffset:  72, as: UInt64.self))
            a10 ^= UInt64(littleEndian: buf.load(fromByteOffset:  80, as: UInt64.self))
            a11 ^= UInt64(littleEndian: buf.load(fromByteOffset:  88, as: UInt64.self))
            a12 ^= UInt64(littleEndian: buf.load(fromByteOffset:  96, as: UInt64.self))
            a13 ^= UInt64(littleEndian: buf.load(fromByteOffset: 104, as: UInt64.self))
            a14 ^= UInt64(littleEndian: buf.load(fromByteOffset: 112, as: UInt64.self))
            a15 ^= UInt64(littleEndian: buf.load(fromByteOffset: 120, as: UInt64.self))
            a16 ^= UInt64(littleEndian: buf.load(fromByteOffset: 128, as: UInt64.self))
            permute23(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24)
        }

        while offset + rate <= bytes.count {
            for i in 0..<rate { block[i] = bytes[offset + i] }
            block.withUnsafeBytes { xorBlock($0.baseAddress!) }
            offset += rate
        }
        let rem = bytes.count - offset
        for i in 0..<rate { block[i] = i < rem ? bytes[offset + i] : 0 }
        block[rem] ^= 0x06
        block[rate - 1] ^= 0x80
        block.withUnsafeBytes { xorBlock($0.baseAddress!) }

        let words = [a0, a1, a2, a3]
        let hexChars = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for w in words {
            var le = w.littleEndian
            withUnsafeBytes(of: &le) { raw in
                for b in raw {
                    out.append(hexChars[Int(b >> 4)])
                    out.append(hexChars[Int(b & 0x0f)])
                }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 零堆分配单块热路径搜索 `nonce ∈ [0, difficulty)` 使得 `DeepSeekHashV1("\(salt)_\(expireAt)_\(nonce)") == challenge`。
    public static func solve(
        challenge: String,
        salt: String,
        expireAt: Int64,
        difficulty: Int
    ) -> Int? {
        guard let target = parseTargetWords(challenge), difficulty > 0 else { return nil }
        let prefixBytes = Array("\(salt)_\(expireAt)_".utf8)
        let prefixLen = prefixBytes.count
        guard prefixLen + 20 < 136 else {
            for nonce in 0..<difficulty {
                if hashHex("\(salt)_\(expireAt)_\(nonce)") == challenge.lowercased() {
                    return nonce
                }
            }
            return nil
        }

        let buf = UnsafeMutableRawPointer.allocate(byteCount: 136, alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: 136)
        let bytePtr = buf.assumingMemoryBound(to: UInt8.self)
        for i in 0..<prefixLen {
            bytePtr[i] = prefixBytes[i]
        }

        // 原地 ASCII 十进制自增器，避免每轮做除法取模
        var digitLen = 1
        bytePtr[prefixLen] = 0x30 // '0'

        let (t0, t1, t2, t3) = target

        for nonce in 0..<difficulty {
            let msgLen = prefixLen &+ digitLen
            bytePtr[msgLen] = 0x06
            bytePtr[135] ^= 0x80

            var a0  = UInt64(littleEndian: buf.load(fromByteOffset:   0, as: UInt64.self))
            var a1  = UInt64(littleEndian: buf.load(fromByteOffset:   8, as: UInt64.self))
            var a2  = UInt64(littleEndian: buf.load(fromByteOffset:  16, as: UInt64.self))
            var a3  = UInt64(littleEndian: buf.load(fromByteOffset:  24, as: UInt64.self))
            var a4  = UInt64(littleEndian: buf.load(fromByteOffset:  32, as: UInt64.self))
            var a5  = UInt64(littleEndian: buf.load(fromByteOffset:  40, as: UInt64.self))
            var a6  = UInt64(littleEndian: buf.load(fromByteOffset:  48, as: UInt64.self))
            var a7  = UInt64(littleEndian: buf.load(fromByteOffset:  56, as: UInt64.self))
            var a8  = UInt64(littleEndian: buf.load(fromByteOffset:  64, as: UInt64.self))
            var a9  = UInt64(littleEndian: buf.load(fromByteOffset:  72, as: UInt64.self))
            var a10 = UInt64(littleEndian: buf.load(fromByteOffset:  80, as: UInt64.self))
            var a11 = UInt64(littleEndian: buf.load(fromByteOffset:  88, as: UInt64.self))
            var a12 = UInt64(littleEndian: buf.load(fromByteOffset:  96, as: UInt64.self))
            var a13 = UInt64(littleEndian: buf.load(fromByteOffset: 104, as: UInt64.self))
            var a14 = UInt64(littleEndian: buf.load(fromByteOffset: 112, as: UInt64.self))
            var a15 = UInt64(littleEndian: buf.load(fromByteOffset: 120, as: UInt64.self))
            var a16 = UInt64(littleEndian: buf.load(fromByteOffset: 128, as: UInt64.self))
            var a17: UInt64 = 0, a18: UInt64 = 0, a19: UInt64 = 0, a20: UInt64 = 0
            var a21: UInt64 = 0, a22: UInt64 = 0, a23: UInt64 = 0, a24: UInt64 = 0

            permute23(&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,&a8,&a9,&a10,&a11,&a12,&a13,&a14,&a15,&a16,&a17,&a18,&a19,&a20,&a21,&a22,&a23,&a24)

            if a0 == t0 && a1 == t1 && a2 == t2 && a3 == t3 {
                return nonce
            }

            bytePtr[msgLen] = 0
            bytePtr[135] = 0

            // 自增十进制 ASCII 字符串
            var pos = prefixLen &+ digitLen &- 1
            while pos >= prefixLen {
                let c = bytePtr[pos]
                if c < 0x39 {
                    bytePtr[pos] = c &+ 1
                    break
                }
                bytePtr[pos] = 0x30
                pos &-= 1
            }
            if pos < prefixLen {
                bytePtr[prefixLen] = 0x31 // '1'
                for k in 1...digitLen {
                    bytePtr[prefixLen &+ k] = 0x30
                }
                digitLen &+= 1
            }
        }
        return nil
    }

    public static func encodeHeaderValue(
        algorithm: String,
        challenge: String,
        salt: String,
        answer: Int,
        signature: String,
        targetPath: String
    ) -> String {
        let json = """
        {"algorithm":"\(WebAdapterTemplate.jsonEscape(algorithm))","challenge":"\(WebAdapterTemplate.jsonEscape(challenge))","salt":"\(WebAdapterTemplate.jsonEscape(salt))","answer":\(answer),"signature":"\(WebAdapterTemplate.jsonEscape(signature))","target_path":"\(WebAdapterTemplate.jsonEscape(targetPath))"}
        """
        return Data(json.utf8).base64EncodedString()
    }

    private static func parseTargetWords(_ hex: String) -> (UInt64, UInt64, UInt64, UInt64)? {
        let utf8 = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard utf8.count == 64 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c &- 0x30
            case 0x61...0x66: return c &- 0x61 &+ 10
            case 0x41...0x46: return c &- 0x41 &+ 10
            default: return nil
            }
        }
        for i in 0..<32 {
            guard let hi = nibble(utf8[i * 2]), let lo = nibble(utf8[i * 2 + 1]) else { return nil }
            bytes[i] = (hi << 4) | lo
        }
        return bytes.withUnsafeBytes { raw in
            let p = raw.baseAddress!
            return (
                UInt64(littleEndian: p.load(fromByteOffset:  0, as: UInt64.self)),
                UInt64(littleEndian: p.load(fromByteOffset:  8, as: UInt64.self)),
                UInt64(littleEndian: p.load(fromByteOffset: 16, as: UInt64.self)),
                UInt64(littleEndian: p.load(fromByteOffset: 24, as: UInt64.self))
            )
        }
    }
}

// MARK: - 接进 Harness

public struct WebAdapterTransport: ModelStreamingTransport {
    public let spec: WebAdapterSpec
    public let credential: String
    public let cookieHeader: String?
    private let client: WebAdapterClient

    public init(
        spec: WebAdapterSpec,
        credential: String,
        cookieHeader: String? = nil,
        session: URLSession = .shared,
        browserPerformer: BrowserStreamPerformer? = nil
    ) {
        self.spec = spec
        self.credential = credential
        self.cookieHeader = cookieHeader
        self.client = WebAdapterClient(session: session, browserPerformer: browserPerformer)
    }

    public func streamChatCompletion(
        config: ProviderConfig,
        apiKey: String,
        messages: [ChatMessage],
        includeWorkspaceTools: Bool,
        firewall: PrivacyFirewall
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let model = spec.models.contains(config.model) ? config.model : (spec.models.first ?? config.model)
        let usesTools = includeWorkspaceTools && Self.supportsTextTools(spec)
        let stream = client.stream(
            spec: spec,
            credential: credential,
            cookieHeader: cookieHeader,
            model: model,
            messages: messages,
            firewall: firewall,
            toolManual: usesTools ? ToolCallTextProtocol.manual(schemas: WorkspaceToolset.toolSchemas) : nil
        )
        return usesTools ? ToolCallTextProtocol.wrap(stream) : stream
    }

    /// 多步工具循环每一步都要发一条消息。靠驱动官网页面发消息的渠道（豆包 / 千问）连发会触发风控，
    /// 也会在用户账号里刷出一串新对话，所以只对直连接口的渠道开放工具。
    public static func supportsTextTools(_ spec: WebAdapterSpec) -> Bool {
        !spec.useBrowserContext
    }
}

// MARK: - 凭据读取（WKWebView 抓到的东西）

public enum WebCredentialParser {
    /// 从 localStorage 字典或 cookie 字典里取出 spec 指定的凭据（主来源优先，另一来源兜底）。
    public static func extract(
        spec: WebAdapterSpec,
        localStorage: [String: String],
        cookies: [String: String]
    ) -> String? {
        let raw: String?
        switch spec.credentialKind {
        case .localStorage:
            raw = localStorage[spec.credentialKey] ?? cookies[spec.credentialKey]
        case .cookie:
            raw = cookies[spec.credentialKey]
                ?? localStorage[spec.credentialKey]
                ?? (spec.id == "web_qwen"
                    ? (cookies["tongyi_sso_ticket"]
                        ?? cookies["login_aliyunid_ticket"]
                        ?? cookies["token"]
                        ?? localStorage["token"])
                    : nil)
        }
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let path = spec.credentialPath, !path.isEmpty,
           let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let nested = WebJSONPath.string(in: object, path: path.joined(separator: ".")) {
                value = nested
            }
        }
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 2 {
            value = String(value.dropFirst().dropLast())
        }
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7))
        }
        return value.isEmpty ? nil : value
    }

    /// 把当前站点所有 Cookie 压成请求头格式，解决豆包/千问/AWS WAF 依赖附属 Cookie 的问题。
    public static func cookieHeader(from cookies: [String: String]) -> String? {
        guard !cookies.isEmpty else { return nil }
        let joined = cookies.keys.sorted().compactMap { key -> String? in
            guard let val = cookies[key], !val.isEmpty else { return nil }
            return "\(key)=\(val)"
        }.joined(separator: "; ")
        return joined.isEmpty ? nil : joined
    }
}
