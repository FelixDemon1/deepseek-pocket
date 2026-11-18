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
    /// 自动探测出来的协议层；nil 表示还没探过，按 chat/completions 处理
    public var flavor: APIProtocolFlavor?

    public init(
        name: String = "DeepSeek Official",
        baseURL: URL = URL(string: "https://api.deepseek.com/v1")!,
        model: String = "deepseek-reasoner",
        temperature: Double = 0.6,
        flavor: APIProtocolFlavor? = nil
    ) {
        self.flavor = flavor
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
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
    /// 选择器里显示的一行说明：这个模式适合什么场景、强在哪。
    public var summary: String?

    public init(
        id: String,
        title: String,
        icon: String = "sparkles",
        summary: String? = nil,
        systemPrompt: String
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.summary = summary
        self.systemPrompt = systemPrompt
    }

    public static let builtIn: [PromptPreset] = [
        PromptPreset(
            id: "default_agent",
            title: "默认模式",
            icon: "sparkles",
            summary: "日常问答、查资料、读文档。语气克制，会主动收尾。",
            systemPrompt: AgentHarness.defaultSystemPrompt
        ),
        PromptPreset(
            id: EngineerProfile.presetID,
            title: "工程模式",
            icon: "chevron.left.forwardslash.chevron.right",
            summary: "写代码、改项目、排报错。先给可运行的结果，再解释。",
            systemPrompt: EngineerProfile.systemPrompt
        ),
        PromptPreset(
            id: PurgeProfile.presetID,
            title: "无限制模式",
            icon: "bolt.shield",
            summary: "已适配 dsh-purge 破甲：去套话直给，不预告、不说教、不软化；工具调用免审批。",
            systemPrompt: PurgeProfile.systemPrompt
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

/// 一个"项目"= 用户授权的一个真实文件夹（security-scoped bookmark 持久化）。
/// 对话可以挂在某个项目下，也可以待在默认工作区里。
public struct WorkspaceProject: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bookmark: Data?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, bookmark: Data?, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.createdAt = createdAt
    }
}

public struct ChatSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// nil = 默认工作区；否则归属某个项目
    public var projectId: UUID?
    public var engineMode: EngineMode
    public var remoteSessionId: String?
    public var messages: [ChatMessage]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "新对话",
        projectId: UUID? = nil,
        engineMode: EngineMode = .onDeviceHarness,
        remoteSessionId: String? = nil,
        messages: [ChatMessage] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.projectId = projectId
        self.engineMode = engineMode
        self.remoteSessionId = remoteSessionId
        self.messages = messages
        self.updatedAt = updatedAt
    }
}
