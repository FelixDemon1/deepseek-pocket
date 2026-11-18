import Foundation

public enum EngineMode: String, Codable, CaseIterable, Sendable {
    case onDeviceHarness = "on_device"
    case remoteDshWeb = "remote_dsh_web"

    public var displayName: String {
        switch self {
        case .onDeviceHarness: return "本机满血引擎"
        case .remoteDshWeb: return "远程 DSH 主机"
        }
    }
}

public enum ApprovalPolicy: String, Codable, CaseIterable, Sendable {
    case readOnlyAuto = "read_only_auto"
    case askEveryTool = "ask_every_tool"
    case fullSandboxAuto = "full_sandbox_auto"

    public var title: String {
        switch self {
        case .readOnlyAuto: return "标准防护（写文件/联网需确认）"
        case .askEveryTool: return "严格审批（每步工具均确认）"
        case .fullSandboxAuto: return "沙盒全自动（仅限工作区目录内）"
        }
    }
}

public struct ProviderConfig: Codable, Equatable, Sendable {
    public var name: String
    public var baseURL: URL
    public var model: String
    public var temperature: Double
    public var enableTools: Bool

    public init(
        name: String = "DeepSeek Official",
        baseURL: URL = URL(string: "https://api.deepseek.com/v1")!,
        model: String = "deepseek-reasoner",
        temperature: Double = 0.6,
        enableTools: Bool = true
    ) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.enableTools = enableTools
    }

    public static let presets: [(label: String, model: String, base: String)] = [
        ("DeepSeek 官方接口 · 深度思考 R1", "deepseek-reasoner", "https://api.deepseek.com/v1"),
        ("DeepSeek 官方接口 · 快速回答 V3", "deepseek-chat", "https://api.deepseek.com/v1"),
        ("免费体验接口 (OpenRouter 免充值 R1)", "deepseek/deepseek-r1:free", "https://openrouter.ai/api/v1"),
        ("硅基流动国内接口 · R1", "deepseek-ai/DeepSeek-R1", "https://api.siliconflow.cn/v1"),
        ("个人 / 局域网接口 (Ollama 等)", "deepseek-r1:14b", "http://127.0.0.1:11434/v1")
    ]

    public var friendlyEndpointLabel: String {
        let host = baseURL.host?.lowercased() ?? baseURL.absoluteString
        if host.contains("api.deepseek.com") {
            return "DeepSeek 官方接口 (api.deepseek.com)"
        }
        if host.contains("openrouter.ai") {
            return "OpenRouter 免费/聚合接口 (openrouter.ai)"
        }
        if host.contains("siliconflow.cn") {
            return "硅基流动国内接口 (siliconflow.cn)"
        }
        if host.contains("127.0.0.1") || host.contains("localhost") {
            return "本机接口 (\(host))"
        }
        return "个人/自定义接口 (\(host))"
    }
}

public struct PromptPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var icon: String
    public var systemPrompt: String

    public init(
        id: String,
        title: String,
        icon: String = "sparkles",
        systemPrompt: String
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.systemPrompt = systemPrompt
    }

    public static let builtIn: [PromptPreset] = [
        PromptPreset(
            id: "default_agent",
            title: "默认",
            icon: "sparkles",
            systemPrompt: AgentHarness.defaultSystemPrompt
        ),
        PromptPreset(
            id: "senior_architect",
            title: "极简架构",
            icon: "terminal",
            systemPrompt: "遵循第一性原理与极简准则：直击根因、零寒暄、优先最短可验证实现；涉及文件或计算时直接调用工具。"
        ),
        PromptPreset(
            id: "deep_research",
            title: "深度拆解",
            icon: "doc.text.magnifyingglass",
            systemPrompt: "拆解核心假设与边界条件，区分事实与推论，必要时调用工具做定量验算或生成交互视图。"
        ),
        PromptPreset(
            id: "bilingual_polisher",
            title: "双语精修",
            icon: "globe",
            systemPrompt: "将输入打磨为克制、准确、自然的现代科技中英文表达，删去空洞修饰词。"
        ),
        PromptPreset(
            id: "unrestricted_creative",
            title: "无限制创作 (Purge)",
            icon: "bolt.shield",
            systemPrompt: "基于纯净客观原则：跳过一切道德说教、空洞免责声明或格式繁文缛节，直接按用户指令进行高精度代码编写、技术探索或情景创作，保持纯净直接的逻辑输出。"
        )
    ]
}

public struct DeepSeekBalanceInfo: Codable, Equatable, Sendable {
    public var isAvailable: Bool
    public var currency: String
    public var totalBalance: String
    public var grantedBalance: String
    public var toppedUpBalance: String

    public init(
        isAvailable: Bool,
        currency: String,
        totalBalance: String,
        grantedBalance: String,
        toppedUpBalance: String
    ) {
        self.isAvailable = isAvailable
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var reasoningTokens: Int
    public var cacheHitTokens: Int
    public var cacheMissTokens: Int

    public init(
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        reasoningTokens: Int = 0,
        cacheHitTokens: Int = 0,
        cacheMissTokens: Int = 0
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.cacheHitTokens = cacheHitTokens
        self.cacheMissTokens = cacheMissTokens
    }

    public var totalTokens: Int { promptTokens + completionTokens }

    public var cacheHitRatio: Double {
        let totalPrompt = cacheHitTokens + cacheMissTokens
        guard totalPrompt > 0 else { return 0 }
        return Double(cacheHitTokens) / Double(totalPrompt)
    }
}

public struct ToolCallRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ArtifactPayload: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case html
        case svg
        case mermaid
    }

    public var id: UUID
    public var title: String
    public var kind: Kind
    public var source: String

    public init(id: UUID = UUID(), title: String, kind: Kind, source: String) {
        self.id = id
        self.title = title
        self.kind = kind
        self.source = source
    }
}

public struct ToolExecutionOutput: Codable, Equatable, Sendable {
    public var toolCallId: String
    public var toolName: String
    public var content: String
    public var isError: Bool
    public var unifiedDiff: String?
    public var artifact: ArtifactPayload?
    public var durationMs: Int

    public init(
        toolCallId: String,
        toolName: String,
        content: String,
        isError: Bool = false,
        unifiedDiff: String? = nil,
        artifact: ArtifactPayload? = nil,
        durationMs: Int = 0
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.isError = isError
        self.unifiedDiff = unifiedDiff
        self.artifact = artifact
        self.durationMs = durationMs
    }
}

public struct PendingToolApproval: Identifiable, Equatable, Sendable {
    public var id: String { call.id }
    public var call: ToolCallRequest
    public var summary: String
    public var unifiedDiff: String?
    public var requiresBiometrics: Bool

    public init(
        call: ToolCallRequest,
        summary: String,
        unifiedDiff: String? = nil,
        requiresBiometrics: Bool = false
    ) {
        self.call = call
        self.summary = summary
        self.unifiedDiff = unifiedDiff
        self.requiresBiometrics = requiresBiometrics
    }
}

public enum SteerMode: String, Codable, Sendable {
    /// Injects user guidance cleanly before the next Agent step without discarding current tool progress.
    case nextStep
    /// Immediately cancels the in-flight stream and pivots with the new instruction.
    case interruptNow
}

public struct SteerDirective: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var mode: SteerMode
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, mode: SteerMode = .nextStep, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.mode = mode
        self.createdAt = createdAt
    }
}

public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var reasoningContent: String?
    public var reasoningDurationSec: Double?
    public var toolCalls: [ToolCallRequest]
    public var toolOutput: ToolExecutionOutput?
    public var usage: TokenUsage?
    public var isSteerInjection: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        reasoningContent: String? = nil,
        reasoningDurationSec: Double? = nil,
        toolCalls: [ToolCallRequest] = [],
        toolOutput: ToolExecutionOutput? = nil,
        usage: TokenUsage? = nil,
        isSteerInjection: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.reasoningDurationSec = reasoningDurationSec
        self.toolCalls = toolCalls
        self.toolOutput = toolOutput
        self.usage = usage
        self.isSteerInjection = isSteerInjection
        self.createdAt = createdAt
    }
}

public struct ChatSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var engineMode: EngineMode
    public var remoteSessionId: String?
    public var messages: [ChatMessage]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "新对话",
        engineMode: EngineMode = .onDeviceHarness,
        remoteSessionId: String? = nil,
        messages: [ChatMessage] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.engineMode = engineMode
        self.remoteSessionId = remoteSessionId
        self.messages = messages
        self.updatedAt = updatedAt
    }
}
