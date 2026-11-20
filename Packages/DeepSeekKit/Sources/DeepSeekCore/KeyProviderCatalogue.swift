import Foundation

/// 各家「官方 API Key」的入口信息与可选模型清单。
public struct KeyProvider: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let defaultModel: String
    public let models: [String]
    public let keyPage: String
    public let note: String

    public init(
        id: String,
        name: String,
        baseURL: String,
        defaultModel: String,
        models: [String] = [],
        keyPage: String,
        note: String
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.models = models.isEmpty ? [defaultModel] : models
        self.keyPage = keyPage
        self.note = note
    }

    public static let all: [KeyProvider] = [
        KeyProvider(
            id: "deepseek", name: "DeepSeek 官方",
            baseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-chat",
            models: ["deepseek-chat", "deepseek-reasoner"],
            keyPage: "https://platform.deepseek.com/api_keys",
            note: "便宜，中文强，支持 V3 快速对话与 R1 深度思考"
        ),
        KeyProvider(
            id: "qwen", name: "阿里云百炼（通义千问官方）",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-max",
            models: ["qwen-max", "qwen-plus", "qwen-turbo", "qwq-plus", "qwen-coder-plus", "deepseek-v3", "deepseek-r1"],
            keyPage: "https://bailian.console.aliyun.com/?apiKey=1#/api-key",
            note: "阿里官方 OpenAI 兼容口，新开通送百万免费额度，千问全系模型可随便切"
        ),
        KeyProvider(
            id: "zhipu", name: "智谱 GLM（含免费模型）",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            defaultModel: "glm-4-flash",
            models: ["glm-4-flash", "glm-z1-flash", "glm-4-plus", "glm-4-air", "glm-4-long"],
            keyPage: "https://bigmodel.cn/usercenter/apikeys",
            note: "国内直连稳定，glm-4-flash 与 glm-z1-flash（推理）长期免费"
        ),
        KeyProvider(
            id: "siliconflow", name: "硅基流动",
            baseURL: "https://api.siliconflow.cn/v1",
            defaultModel: "deepseek-ai/DeepSeek-V3",
            models: [
                "deepseek-ai/DeepSeek-V3",
                "deepseek-ai/DeepSeek-R1",
                "Qwen/Qwen3-235B-A22B",
                "Qwen/QwQ-32B",
                "Qwen/Qwen2.5-7B-Instruct",
                "THUDM/GLM-4-9B-0414"
            ],
            keyPage: "https://cloud.siliconflow.cn/account/ak",
            note: "国内直连快，注册送额度，聚合 DeepSeek / Qwen / GLM 多模型（含小尺寸免费模型）"
        ),
        KeyProvider(
            id: "groq", name: "Groq（免费极速）",
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "llama-3.3-70b-versatile",
            models: [
                "llama-3.3-70b-versatile",
                "deepseek-r1-distill-llama-70b",
                "qwen-qwq-32b",
                "gemma2-9b-it"
            ],
            keyPage: "https://console.groq.com/keys",
            note: "海外免费额度大、出字极快，需能访问外网"
        ),
        KeyProvider(
            id: "github", name: "GitHub Models（免费）",
            baseURL: "https://models.inference.ai.azure.com",
            defaultModel: "gpt-4o-mini",
            models: ["gpt-4o-mini", "gpt-4o", "o3-mini", "DeepSeek-R1"],
            keyPage: "https://github.com/settings/tokens",
            note: "有 GitHub 账号建一个无权限 Personal Access Token 即可免费用"
        ),
        KeyProvider(
            id: "openrouter", name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "deepseek/deepseek-chat",
            models: [
                "deepseek/deepseek-chat",
                "deepseek/deepseek-r1",
                "deepseek/deepseek-r1:free",
                "qwen/qwen3-235b-a22b:free",
                "google/gemini-2.5-flash"
            ],
            keyPage: "https://openrouter.ai/keys",
            note: "海外聚合，带 :free 后缀的模型免充值可用"
        ),
        KeyProvider(
            id: "moonshot", name: "月之暗面 Kimi",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "kimi-k2-0711-preview",
            models: ["kimi-k2-0711-preview", "moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"],
            keyPage: "https://platform.moonshot.cn/console/api-keys",
            note: "长文本强，注册送额度"
        )
    ]

    public static func matching(host: String) -> KeyProvider? {
        let lower = host.lowercased()
        guard !lower.isEmpty else { return nil }
        return all.first { item in
            guard let h = URL(string: item.baseURL)?.host?.lowercased() else { return false }
            return lower == h || lower.hasSuffix(".\(h)")
        }
    }

    /// 判断某个域名是否属于必须携带 API Key 的商业云厂商（避免未填 Key 时裸发报 HTTP 401）。
    public static func requiresAPIKey(host: String) -> Bool {
        if matching(host: host) != nil { return true }
        let lower = host.lowercased()
        return lower == "api.openai.com" || lower == "api.anthropic.com"
    }
}

/// 中转站 / 自建网关的推荐位。现在留空，以后可以按需放赞助渠道。
public struct SponsoredChannel: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let blurb: String
    public let setupLink: String

    public init(id: String, name: String, blurb: String, setupLink: String) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.setupLink = setupLink
    }

    /// 首页/连接页的自建网关快捷位（已对接用户的 app.apifish.me 云端网关）。
    public static let active: [SponsoredChannel] = [
        SponsoredChannel(
            id: "apifish_cloud",
            name: "自建云端网关（app.apifish.me）",
            blurb: "已部署在你的 Azure 服务器，在服务器填入上游 Key 后即可零配置开放给所有小白用户",
            setupLink: "deepseekgo://setup?base=https%3A%2F%2Fapp.apifish.me%2Fv1&model=deepseek-chat&name=%E8%87%AA%E5%BB%BA%E4%BA%91%E7%AB%AF%E7%BD%91%E5%85%B3"
        )
    ]
}
