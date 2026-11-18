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
        ("DeepSeek 官方 · R1 深度思考", "deepseek-reasoner", "https://api.deepseek.com/v1"),
        ("DeepSeek 官方 · V3 极速对话", "deepseek-chat", "https://api.deepseek.com/v1"),
        ("OpenRouter · R1 免费通道", "deepseek/deepseek-r1:free", "https://openrouter.ai/api/v1"),
        ("SiliconFlow · 硅基流动", "deepseek-ai/DeepSeek-R1", "https://api.siliconflow.cn/v1"),
        ("本机/局域网网关 (Ollama / OneAPI)", "deepseek-r1:14b", "http://127.0.0.1:11434/v1")
    ]
}

public struct PromptPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var icon: String
    public var systemPrompt: String
    public var isProOnly: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        icon: String,
        systemPrompt: String,
        isProOnly: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.isProOnly = isProOnly
    }

    public static let builtIn: [PromptPreset] = [
        PromptPreset(
            id: "default_agent",
            title: "标准全能工作台",
            subtitle: "均衡推理、沙盒读写与结构化输出",
            icon: "sparkles",
            systemPrompt: AgentHarness.defaultSystemPrompt
        ),
        PromptPreset(
            id: "senior_architect",
            title: "首席架构师 (Karpathy 极简风)",
            subtitle: "拒绝过度设计，优先最小可行代码与严密验证",
            icon: "terminal",
            systemPrompt: "你是首席系统架构师。遵循第一性原理与极简代码准则：直击根因、零废话、优先 50 行以内的干净实现，需要验证时主动调用 run_javascript 或读写工作区文件。"
        ),
        PromptPreset(
            id: "deep_research",
            title: "深度研究与拆解模式",
            subtitle: "多维交叉核验假设、列出证据链与反例",
            icon: "doc.text.magnifyingglass",
            systemPrompt: "你是严谨的研究分析师。先拆解核心假设与边界条件，区分事实与推论，必要时调用沙盒工具做定量验算或生成可视化图表。",
            isProOnly: true
        ),
        PromptPreset(
            id: "bilingual_polisher",
            title: "母语级双语精修",
            subtitle: "学术论文 / 开源 README / 产品文案信达雅润色",
            icon: "globe",
            systemPrompt: "你是顶尖科技产品的双语主编。把输入内容打磨为地道、克制、富有质感的 Apple / Stripe 风格中英文表达，避免翻译腔与空洞形容词。",
            isProOnly: true
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
