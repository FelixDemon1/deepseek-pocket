import Foundation

// ---------------------------------------------------------------------------
// Web Adapter — 手机端「反代」的落地形态。
//
// iOS 上没法像桌面 wb2api 那样 hook 别人的进程，也读不到别的 App 的 Keychain；
// 但只要把「协议翻译」做进我们自己的 App，就不需要外部反代服务：
//
//   1) 在我们自己的 WKWebView 里让用户登录官方网页版（chat.deepseek.com /
//      chat.qwen.ai / www.doubao.com）—— 自己的 webview 读自己的
//      localStorage 与 cookie，不越权、不 MITM、不需要越狱。
//   2) token 存进 Keychain（WhenUnlockedThisDeviceOnly）。
//   3) 用 AdapterSpec 声明「官网接口长什么样」，把 OpenAI 兼容请求翻译过去，
//      再把它们的 SSE 回包翻译回来。
//
// spec 与 gateway/byoa.go 的 AdapterSpec 同构：桌面抓到的配置能直接粘进手机。
// ---------------------------------------------------------------------------

public enum WebCredentialKind: String, Codable, Sendable {
    case localStorage
    case cookie
}

public enum WebResponseMode: String, Codable, Sendable {
    /// 标准 OpenAI SSE：`data: {"choices":[{"delta":{"content":"..."}}]}`
    case sseOpenAI = "sse_openai"
    /// 通用点路径 SSE：`data: {"<stream_path>":"增量文本"}`
    case sseJSONText = "sse_json_text"
    /// DeepSeek 网页版：`{"p":"response/fragments/-1/content","o":"APPEND","v":"..."}`
    case sseDeepSeek = "sse_deepseek"
    /// 豆包网页版：`{"event_type":2001,"event_data":"..."}`（兼容 v1 message.content 与 v2 patch_op / content_block）
    case sseDoubao = "sse_doubao"
    /// 通义千问国内版（qianwen.com）：`{"contents":[{"mime_type":"text/plain","content":"..."}]}`
    case sseQianwen = "sse_qianwen"
    /// 一次性 JSON 回包
    case jsonText = "json_text"
}

public struct WebAdapterSpec: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// 登录页；用户在我们自己的 webview 里登录
    public var loginURL: String
    public var credentialKind: WebCredentialKind
    /// localStorage 的 key，或 cookie 的 name
    public var credentialKey: String
    /// 凭据值是 JSON 时取值的路径（如 ["value"]）
    public var credentialPath: [String]?
    /// 真正的对话接口
    public var chatURL: String
    public var headers: [String: String]
    /// `{{token}} {{prompt}} {{messages_json}} {{model}}` 会被替换
    public var bodyTemplate: String
    public var responseMode: WebResponseMode
    /// sse_json_text / json_text 用的点路径
    public var streamPath: String
    public var models: [String]
    /// 有些渠道必须先建会话才能发消息（DeepSeek 网页版就是：chat_session_id 不接受 null）
    public var sessionURL: String?
    /// 建会话用的请求体，默认 {}
    public var sessionBody: String?
    /// 从建会话回包里取 id 的点路径
    public var sessionIdPath: String?
    /// 工作量证明挑战接口（如 DeepSeek 网页版 `/api/v0/chat/create_pow_challenge`）
    public var powURL: String?
    /// 工作量证明绑定的目标路径（如 `/api/v0/chat/completion`）
    public var powTargetPath: String?
    /// 工作量证明签名写回的请求头名（如 `x-ds-pow-response`）
    public var powHeader: String?
    /// 是否在隐藏同源 WKWebView 页面上下文内发流（自动带上豆包 a_bogus/shark_admin 与千问 AWSC/baxia 签名）
    public var useBrowserContext: Bool
    /// 是否已用真实抓包校准
    public var calibrated: Bool
    public var notes: String

    public init(
        id: String,
        name: String,
        loginURL: String,
        credentialKind: WebCredentialKind,
        credentialKey: String,
        credentialPath: [String]? = nil,
        chatURL: String,
        headers: [String: String],
        bodyTemplate: String,
        responseMode: WebResponseMode,
        streamPath: String = "",
        models: [String],
        sessionURL: String? = nil,
        sessionBody: String? = nil,
        sessionIdPath: String? = nil,
        powURL: String? = nil,
        powTargetPath: String? = nil,
        powHeader: String? = nil,
        useBrowserContext: Bool = false,
        calibrated: Bool = false,
        notes: String = ""
    ) {
        self.sessionURL = sessionURL
        self.sessionBody = sessionBody
        self.sessionIdPath = sessionIdPath
        self.powURL = powURL
        self.powTargetPath = powTargetPath
        self.powHeader = powHeader
        self.useBrowserContext = useBrowserContext
        self.id = id
        self.name = name
        self.loginURL = loginURL
        self.credentialKind = credentialKind
        self.credentialKey = credentialKey
        self.credentialPath = credentialPath
        self.chatURL = chatURL
        self.headers = headers
        self.bodyTemplate = bodyTemplate
        self.responseMode = responseMode
        self.streamPath = streamPath
        self.models = models
        self.calibrated = calibrated
        self.notes = notes
    }

    private struct FlexKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        static func k(_ s: String) -> FlexKey { FlexKey(stringValue: s)! }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FlexKey.self)
        func str(_ keys: String...) -> String? {
            for k in keys {
                if let v = try? c.decodeIfPresent(String.self, forKey: .k(k)) { return v }
            }
            return nil
        }
        guard let chatURL = str("chatURL", "chat_url"), !chatURL.isEmpty else {
            throw DecodingError.keyNotFound(
                FlexKey.k("chatURL"),
                .init(codingPath: decoder.codingPath, debugDescription: "缺少 chatURL / chat_url")
            )
        }
        let name = str("name") ?? (URL(string: chatURL)?.host ?? "自定义网页渠道")
        let id = str("id") ?? Self.stableID(for: chatURL)
        let origin: String = {
            guard let u = URL(string: chatURL), let scheme = u.scheme, let host = u.host else { return chatURL }
            return "\(scheme)://\(host)/"
        }()
        let loginURL = str("loginURL", "login_url") ?? origin
        let kindRaw = str("credentialKind", "credential_kind") ?? "cookie"
        let credentialKind = WebCredentialKind(rawValue: kindRaw) ?? .cookie
        let credentialKey = str("credentialKey", "credential_key") ?? "token"
        let credentialPath = (try? c.decodeIfPresent([String].self, forKey: .k("credentialPath")))
            ?? (try? c.decodeIfPresent([String].self, forKey: .k("credential_path")))
        let headers = (try? c.decodeIfPresent([String: String].self, forKey: .k("headers"))) ?? [:]
        let bodyTemplate = str("bodyTemplate", "body_template") ?? "{}"
        let modeRaw = str("responseMode", "response_mode") ?? "sse_openai"
        let responseMode: WebResponseMode = {
            if modeRaw == "sse_text" { return .sseJSONText }
            return WebResponseMode(rawValue: modeRaw) ?? .sseOpenAI
        }()
        let streamPath = str("streamPath", "stream_path") ?? ""
        let models = (try? c.decodeIfPresent([String].self, forKey: .k("models"))) ?? ["default"]
        let sessionURL = str("sessionURL", "session_url")
        let sessionBody = str("sessionBody", "session_body")
        let sessionIdPath = str("sessionIdPath", "session_id_path")
        let powURL = str("powURL", "pow_url")
        let powTargetPath = str("powTargetPath", "pow_target_path")
        let powHeader = str("powHeader", "pow_header")
        let useBrowserContext = (try? c.decodeIfPresent(Bool.self, forKey: .k("useBrowserContext")))
            ?? (try? c.decodeIfPresent(Bool.self, forKey: .k("use_browser_context")))
            ?? false
        let calibrated = (try? c.decodeIfPresent(Bool.self, forKey: .k("calibrated"))) ?? false
        let notes = str("notes") ?? ""

        self.init(
            id: id,
            name: name,
            loginURL: loginURL,
            credentialKind: credentialKind,
            credentialKey: credentialKey,
            credentialPath: credentialPath,
            chatURL: chatURL,
            headers: headers,
            bodyTemplate: bodyTemplate,
            responseMode: responseMode,
            streamPath: streamPath,
            models: models,
            sessionURL: sessionURL,
            sessionBody: sessionBody,
            sessionIdPath: sessionIdPath,
            powURL: powURL,
            powTargetPath: powTargetPath,
            powHeader: powHeader,
            useBrowserContext: useBrowserContext,
            calibrated: calibrated,
            notes: notes
        )
    }
}

// MARK: - 稳定 id · 合法性校验 · 云端合并

public extension WebAdapterSpec {
    /// 缺省 id 用 chatURL 的 FNV-1a 摘要：跨启动稳定（`String.hashValue` 每次启动随机，且 `abs(Int.min)` 会崩）。
    static func stableID(for chatURL: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in chatURL.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "custom_" + String(hash, radix: 16)
    }

    /// 返回 nil 表示可用；否则是给人看的原因。云端下发 / 用户粘贴的规格都先过这一道。
    var validationIssue: String? {
        func isWebURL(_ raw: String?) -> Bool {
            guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return false }
            return true
        }
        if id.trimmingCharacters(in: .whitespaces).isEmpty { return "缺少 id" }
        if !isWebURL(chatURL) { return "chatURL 不合法" }
        if !isWebURL(loginURL) { return "loginURL 不合法" }
        for (label, optional) in [("sessionURL", sessionURL), ("powURL", powURL)] {
            if let optional, !optional.isEmpty, !isWebURL(optional) { return "\(label) 不合法" }
        }
        if credentialKey.trimmingCharacters(in: .whitespaces).isEmpty { return "缺少 credentialKey" }
        if models.filter({ !$0.isEmpty }).isEmpty { return "models 为空" }
        let probe = WebAdapterTemplate.render(bodyTemplate, values: [
            "token": "t", "model": "m", "cookie": "c", "cookie_header": "c",
            "thinking_enabled": "false", "session_id": "s",
            "prompt": "p", "prompt_nested": "p", "messages_json": "[]",
            "local_conversation": "l", "local_message": "l"
        ])
        if (try? JSONSerialization.jsonObject(with: Data(probe.utf8))) == nil {
            return "bodyTemplate 填充后不是合法 JSON"
        }
        return nil
    }

    /// 云端规格合并：只采纳校验通过的条目；内置预设按 id 被云端覆盖（云端缺席时保留内置，
    /// 绝不让当前在用的渠道凭空消失）；云端新增的追加在后；用户自己粘贴的保持不动。
    static func merging(remote: [WebAdapterSpec], into current: [WebAdapterSpec]) -> [WebAdapterSpec] {
        var validRemote: [WebAdapterSpec] = []
        for spec in remote where spec.validationIssue == nil && !validRemote.contains(where: { $0.id == spec.id }) {
            validRemote.append(spec)
        }
        var out = presets.map { preset in validRemote.first { $0.id == preset.id } ?? preset }
        for spec in validRemote where !out.contains(where: { $0.id == spec.id }) {
            out.append(spec)
        }
        for spec in current where !out.contains(where: { $0.id == spec.id }) {
            out.append(spec)
        }
        return out
    }
}

// MARK: - 内置预设

public extension WebAdapterSpec {
    static let presets: [WebAdapterSpec] = [deepSeekWeb, doubaoWeb, qwenWeb]

    static let deepSeekWeb = WebAdapterSpec(
        id: "web_deepseek",
        name: "DeepSeek 网页版",
        loginURL: "https://chat.deepseek.com/sign_in",
        credentialKind: .localStorage,
        credentialKey: "userToken",
        credentialPath: ["value"],
        chatURL: "https://chat.deepseek.com/api/v0/chat/completion",
        headers: [
            "Content-Type": "application/json",
            "Accept": "*/*",
            "Referer": "https://chat.deepseek.com/",
            "Origin": "https://chat.deepseek.com",
            "x-client-platform": "web",
            "x-client-version": "1.0.0-always",
            "x-client-locale": "zh_CN",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            "Authorization": "Bearer {{token}}"
        ],
        bodyTemplate: #"{"chat_session_id":"{{session_id}}","parent_message_id":null,"prompt":"{{prompt}}","ref_file_ids":[],"thinking_enabled":{{thinking_enabled}},"search_enabled":false,"stream":true}"#,
        responseMode: .sseDeepSeek,
        models: ["deepseek-chat", "deepseek-reasoner"],
        sessionURL: "https://chat.deepseek.com/api/v0/chat_session/create",
        sessionBody: #"{}"#,
        sessionIdPath: "data.biz_data.chat_session.id",
        powURL: "https://chat.deepseek.com/api/v0/chat/create_pow_challenge",
        powTargetPath: "/api/v0/chat/completion",
        powHeader: "x-ds-pow-response",
        useBrowserContext: false,
        calibrated: true,
        notes: "已实机校准：自动建会话 + 原生解算 DeepSeekHashV1 工作量证明 + 状态机解析 V3/R1 增量流。"
    )

    static let qwenWeb = WebAdapterSpec(
        id: "web_qwen",
        name: "通义千问网页版（国内版）",
        loginURL: "https://www.qianwen.com/",
        credentialKind: .cookie,
        credentialKey: "tongyi_sso_ticket_hash",
        chatURL: "https://chat2.qianwen.com/api/v2/chat",
        headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream, text/plain, */*",
            "Referer": "https://www.qianwen.com/",
            "Origin": "https://www.qianwen.com",
            "Cookie": "{{cookie}}"
        ],
        bodyTemplate: #"{"req_id":"{{local_message}}","parent_req_id":"0","messages":[{"mime_type":"text/plain","content":"{{prompt}}","meta_data":{},"status":"complete"}],"scene":"chat","sub_scene":"","scene_param":"first_turn","session_id":"{{local_conversation}}","biz_id":"ai_qwen","topic_id":"{{local_message}}","model":"{{model}}","from":"default","protocol_version":"v2","messages_merge":false,"chat_client":"h5","deep_search":"0"}"#,
        responseMode: .sseQianwen,
        models: ["qwen3-max", "qwen-plus", "qwen-turbo", "qwq-32b"],
        useBrowserContext: true,
        calibrated: true,
        notes: "国内官方 www.qianwen.com（支持手机号/支付宝/淘宝登录），可选 Qwen3-Max / Plus / Turbo / QwQ 推理。"
    )

    static let doubaoWeb = WebAdapterSpec(
        id: "web_doubao",
        name: "豆包网页版",
        loginURL: "https://www.doubao.com/chat/",
        credentialKind: .cookie,
        credentialKey: "sessionid",
        chatURL: "https://www.doubao.com/samantha/chat/completion?aid=497858&device_platform=web&language=zh&pkg_type=release_version&real_aid=497858&region=CN&samantha_web=1&sys_region=CN&use-olympus-account=1&version_code=20800",
        headers: [
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "Agw-Js-Conv": "str",
            "Referer": "https://www.doubao.com/chat/",
            "Origin": "https://www.doubao.com",
            "Cookie": "{{cookie}}"
        ],
        bodyTemplate: #"{"messages":[{"content":"{\"text\":\"{{prompt_nested}}\"}","content_type":2001,"attachments":[],"references":[]}],"completion_option":{"is_regen":false,"with_suggest":false,"need_create_conversation":true,"launch_stage":1,"is_replace":false,"is_delete":false,"message_from":0,"use_deep_think":{{thinking_enabled}},"use_auto_cot":false,"event_id":"0"},"evaluate_option":{"web_ab_params":""},"conversation_id":"0","local_conversation_id":"local_{{local_conversation}}","local_message_id":"{{local_message}}"}"#,
        responseMode: .sseDoubao,
        models: ["doubao-seed-1.6", "doubao-seed-1.6-thinking"],
        useBrowserContext: true,
        calibrated: true,
        notes: "通过内置同源 WebView 自动带字节 webmssdk/a_bogus 签名，支持快速对话与深度思考切换。"
    )
}

// MARK: - 模板渲染

public enum WebAdapterTemplate {
    /// 只做 `{{key}}` 字面替换；值由调用方先转成 JSON 安全字符串。
    public static func render(_ template: String, values: [String: String]) -> String {
        var output = template
        for (key, value) in values {
            output = output.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return output
    }

    /// 把任意文本变成能安全塞进 JSON 双引号里的形式。
    public static func jsonEscape(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count + 8)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

// MARK: - 点路径取值

public enum WebJSONPath {
    /// 支持 `a.b.0.c` 点路径，数组用数字下标。
    public static func value(in object: Any, path: String) -> Any? {
        guard !path.isEmpty else { return object }
        var current: Any = object
        for component in path.split(separator: ".") {
            if let dict = current as? [String: Any] {
                guard let next = dict[String(component)] else { return nil }
                current = next
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    public static func string(in object: Any, path: String) -> String? {
        guard let raw = value(in: object, path: path) else { return nil }
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }
}
