import Foundation

/// 各家「官方 API Key」的入口信息。用户不会自己找网址，所以这里写死。
public struct KeyProvider: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let defaultModel: String
    public let keyPage: String
    public let note: String

    public init(id: String, name: String, baseURL: String, defaultModel: String, keyPage: String, note: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.keyPage = keyPage
        self.note = note
    }

    public static let all: [KeyProvider] = [
        KeyProvider(
            id: "deepseek", name: "DeepSeek 官方",
            baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat",
            keyPage: "https://platform.deepseek.com/api_keys",
            note: "便宜，中文好，注册就送一点额度"
        ),
        KeyProvider(
            id: "siliconflow", name: "硅基流动",
            baseURL: "https://api.siliconflow.cn/v1", defaultModel: "deepseek-ai/DeepSeek-V3",
            keyPage: "https://cloud.siliconflow.cn/account/ak",
            note: "国内直连快，注册送额度，模型多"
        ),
        KeyProvider(
            id: "openrouter", name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1", defaultModel: "deepseek/deepseek-chat",
            keyPage: "https://openrouter.ai/keys",
            note: "海外聚合，有免费模型，需要能上外网"
        ),
        KeyProvider(
            id: "zhipu", name: "智谱 GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "glm-4-flash",
            keyPage: "https://bigmodel.cn/usercenter/apikeys",
            note: "glm-4-flash 长期免费"
        ),
        KeyProvider(
            id: "moonshot", name: "月之暗面 Kimi",
            baseURL: "https://api.moonshot.cn/v1", defaultModel: "moonshot-v1-8k",
            keyPage: "https://platform.moonshot.cn/console/api-keys",
            note: "长文本强，注册送额度"
        )
    ]
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

    /// 首页/连接页的赞助位，按需填充；空数组时整块 UI 不出现。
    public static let active: [SponsoredChannel] = []
}
