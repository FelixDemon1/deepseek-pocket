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
    /// 豆包网页版：`{"event_type":2001,"event_data":"{\"message\":{\"content\":\"...\"}}"}`
    case sseDoubao = "sse_doubao"
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
        calibrated: Bool = false,
        notes: String = ""
    ) {
        self.sessionURL = sessionURL
        self.sessionBody = sessionBody
        self.sessionIdPath = sessionIdPath
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
}

// MARK: - 内置预设

public extension WebAdapterSpec {
    static let presets: [WebAdapterSpec] = [deepSeekWeb, qwenWeb, doubaoWeb]

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
            "Authorization": "Bearer {{token}}"
        ],
        bodyTemplate: #"{"chat_session_id":"{{session_id}}","parent_message_id":null,"prompt":"{{prompt}}","ref_file_ids":[],"thinking_enabled":false,"search_enabled":false,"stream":true}"#,
        responseMode: .sseDeepSeek,
        models: ["deepseek-chat", "deepseek-reasoner"],
        sessionURL: "https://chat.deepseek.com/api/v0/chat_session/create",
        sessionBody: #"{}"#,
        sessionIdPath: "data.biz_data.chat_session.id",
        calibrated: false,
        notes: "必须先建会话（chat_session_id 不接受 null，否则 HTTP 422）；首包给 fragments，之后是 p/o/v 增量补丁。"
    )

    static let qwenWeb = WebAdapterSpec(
        id: "web_qwen",
        name: "通义千问网页版",
        loginURL: "https://chat.qwen.ai/",
        credentialKind: .cookie,
        credentialKey: "token",
        chatURL: "https://chat.qwen.ai/api/v2/chat/completions",
        headers: [
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "Referer": "https://chat.qwen.ai/",
            "Origin": "https://chat.qwen.ai",
            "source": "web",
            "Authorization": "Bearer {{token}}"
        ],
        bodyTemplate: #"{"stream":true,"version":"0.0.1","incremental_output":true,"chat_id":null,"chat_mode":"normal","messages":{{messages_json}},"model":"{{model}}"}"#,
        responseMode: .sseOpenAI,
        models: ["qwen3-max", "qwen3-235b-a22b"],
        calibrated: false,
        notes: "回包接近 OpenAI SSE；思考过程带 phase:\"think\"，要归到 reasoning。"
    )

    static let doubaoWeb = WebAdapterSpec(
        id: "web_doubao",
        name: "豆包网页版",
        loginURL: "https://www.doubao.com/chat/",
        credentialKind: .cookie,
        credentialKey: "sessionid",
        chatURL: "https://www.doubao.com/samantha/chat/completion",
        headers: [
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "Referer": "https://www.doubao.com/chat/",
            "Origin": "https://www.doubao.com",
            "Cookie": "sessionid={{token}}"
        ],
        bodyTemplate: #"{"messages":[{"content":"{\"text\":\"{{prompt}}\"}","content_type":2001,"role":"user"}],"conversation_id":"0","local_conversation_id":"{{local_conversation}}","local_message_id":"{{local_message}}","completion_hints":[],"section_id":"","stream":true}"#,
        responseMode: .sseDoubao,
        models: ["doubao-seed-1.6"],
        calibrated: false,
        notes: "需要 local_conversation_id / local_message_id 两个随机 UUID；回包按 event_type 2001 增量。"
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
