import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import DeepSeekCore

@MainActor
@Observable
public final class AppViewModel {
    public var sessions: [ChatSession] = []
    public var activeSessionId: UUID?
    public var providerConfig: ProviderConfig
    public var approvalPolicy: ApprovalPolicy
    public var requireFaceIDForApprovals: Bool
    public var engineMode: EngineMode
    public var appearance: AppearancePreference = .light

    // Persona & Prompt Ruleset Studio (with rollback snapshot)
    public var presets: [PromptPreset] = PromptPreset.builtIn
    public var activePresetId: String = "default_agent"
    private var previousPresetSnapshotId: String?

    // Streaming & Steer state
    public var isStreaming: Bool = false
    public var activeStageText: String = ""
    /// 当前这一轮从什么时候开始跑的（界面计时用）
    public var turnStartedAt: Date?
    /// 正在执行的工具（界面上「运行 · ls -la」那一条）
    public var liveTool: ToolPresentation?
    /// 手机操控驱动（PhoneRunner）是否在线
    public var phoneRunnerOnline = false
    public var pendingApproval: PendingToolApproval?
    public var queuedSteers: [SteerDirective] = []
    public var errorBanner: String?
    public var noticeBanner: String?
    /// 最近一轮失败的原因，显示在对话里出错的位置，带「重试」
    public var turnFailure: TurnFailure?

    public struct TurnFailure: Equatable, Sendable {
        public var sessionId: UUID
        public var message: String
    }

    // Search & Attachments
    public var sessionSearchQuery: String = ""
    public var pendingOCRAttachment: (summary: String, fullText: String)?
    public var isRunningOCR: Bool = false

    // Channel Discovery & Balance
    public var discoveredModels: [String] = []
    public var balanceInfo: DeepSeekBalanceInfo?
    public var isFetchingModelsOrBalance: Bool = false

    // Remote DSH Web state
    public var remoteLaunchInput: String = ""
    public var remoteConnectedHost: String?
    public var remoteSessions: [DshRemoteSessionSummary] = []

    // 个人资料
    public var displayName: String = ""
    public var avatarEmoji: String = "🐳"
    public var avatarImageData: Data?

    // MARK: - 网页版反代（Web Adapter）

    /// 内置三个网页版渠道 + 用户自己粘贴的 spec
    public var webAdapters: [WebAdapterSpec] = WebAdapterSpec.presets
    /// nil = 走标准 OpenAI 兼容接口；否则走网页版翻译通道
    public var activeWebAdapterID: String?

    public var activeWebAdapter: WebAdapterSpec? {
        guard let activeWebAdapterID else { return nil }
        return webAdapters.first { $0.id == activeWebAdapterID }
    }

    public func webCredentialAccount(_ spec: WebAdapterSpec) -> String {
        "webadapter.\(spec.id)"
    }

    public func webCookieAccount(_ spec: WebAdapterSpec) -> String {
        "webadapter.cookies.\(spec.id)"
    }

    public func hasWebCredential(_ spec: WebAdapterSpec) -> Bool {
        ((try? vault.loadSecret(for: webCredentialAccount(spec))) ?? nil)?.isEmpty == false
    }

    public func saveWebCredential(_ token: String, cookieHeader: String? = nil, for spec: WebAdapterSpec) {
        do {
            try vault.saveSecret(token, for: webCredentialAccount(spec))
            if let cookieHeader = cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cookieHeader.isEmpty {
                try vault.saveSecret(cookieHeader, for: webCookieAccount(spec))
            }
            errorBanner = nil
            lastAdapterError = nil
            activateWebAdapter(spec)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    public func clearWebCredential(for spec: WebAdapterSpec) {
        try? vault.deleteSecret(for: webCredentialAccount(spec))
        try? vault.deleteSecret(for: webCookieAccount(spec))
        if activeWebAdapterID == spec.id {
            activeWebAdapterID = nil
            persistSettings()
        }
    }

    public func activateWebAdapter(_ spec: WebAdapterSpec) {
        activeWebAdapterID = spec.id
        var config = providerConfig
        config.name = spec.name
        config.model = spec.models.first ?? config.model
        providerConfig = config
        persistSettings()
    }

    public func deactivateWebAdapter() {
        activeWebAdapterID = nil
        persistSettings()
    }

    public func addCustomAdapter(_ spec: WebAdapterSpec) {
        if let index = webAdapters.firstIndex(where: { $0.id == spec.id }) {
            webAdapters[index] = spec
        } else {
            webAdapters.append(spec)
        }
        persistSettings()
    }

    /// 用官方 Key 直连：保存 + 立刻验证（拉一次模型列表）
    /// 返回 nil 表示成功，否则返回给用户看的错误文案。
    public func connectWithAPIKey(_ key: String, baseURL: URL, model: String) async -> String? {
        saveAPIKey(key)
        var config = providerConfig
        config.baseURL = baseURL
        config.model = model
        config.name = ProviderConfig(name: "", baseURL: baseURL, model: model).name
        providerConfig = config
        activeWebAdapterID = nil
        persistSettings()
        await firewall.setAllowedModelBaseURL(baseURL)
        discoveredModels = []
        errorBanner = nil
        await discoverGatewayModels()
        if !discoveredModels.isEmpty {
            // 模型列表拿到了，再探一次协议层（chat/completions 还是 responses）
            if let flavor = await ResponsesClient.detectProtocol(
                baseURL: baseURL, apiKey: key, firewall: firewall
            ) {
                var updated = providerConfig
                updated.flavor = flavor
                providerConfig = updated
                persistSettings()
            }
            return nil
        }
        return errorBanner ?? "没连上：检查 Key 和网络"
    }

    /// 最近一次网页版通道的原始报错，界面上可复制，方便排查
    public var lastAdapterError: String?

    /// 让用户当场验证某个网页版渠道：发一句 ping，把结果原样返回
    public func testWebAdapter(_ spec: WebAdapterSpec) async -> String {
        guard let token = (try? vault.loadSecret(for: webCredentialAccount(spec))) ?? nil, !token.isEmpty else {
            return "还没登录这个渠道"
        }
        let cookies = (try? vault.loadSecret(for: webCookieAccount(spec))) ?? nil
        #if os(iOS)
        let performer: BrowserStreamPerformer? = WebKitBrowserStreamPerformer.shared
        #else
        let performer: BrowserStreamPerformer? = nil
        #endif
        var collected = ""
        do {
            let stream = WebAdapterClient(browserPerformer: performer).stream(
                spec: spec,
                credential: token,
                cookieHeader: cookies,
                model: spec.models.first ?? "",
                messages: [
                    ChatMessage(role: .system, content: "直接回答，不要废话。\n只输出要求的内容。"),
                    ChatMessage(role: .user, content: "测试多行输入\n回复两个字：收到")
                ],
                firewall: firewall
            )
            for try await delta in stream {
                if case let .content(text) = delta {
                    collected += text
                    if collected.count >= 24 { break }
                }
            }
            lastAdapterError = nil
            errorBanner = nil
            await refreshAuditSnapshot()
            return collected.isEmpty
                ? "连上了，但没拿到文本：回包格式和预设对不上，需要校准"
                : "连接成功：\(collected.prefix(24))"
        } catch {
            lastAdapterError = error.localizedDescription
            await refreshAuditSnapshot()
            return "\(error.localizedDescription)"
        }
    }

    /// 首次切到无限制模式时弹一次说明（体感入口）
    public var purgeIntroPresented: Bool = false
    public var hasSeenPurgeIntro: Bool = false

    // 项目（对话可归属某个真实文件夹）
    public var projects: [WorkspaceProject] = []
    public var activeProjectId: UUID?

    // Privacy, Workspace & Companion Pet
    public var auditEntries: [NetworkAuditEntry] = []
    public var allowlistInfo: (modelHosts: [String], remoteHosts: [String], webHosts: [String]) = ([], [], [])
    public var activeArtifact: ArtifactPayload?
    public var showCompanionPet: Bool = true
    public var companionCharacter: CompanionCharacter = .whaleGirl
    public var requestedSheetName: String?
    public var celebratingTurnCompletion: Bool = false

    public let firewall: PrivacyFirewall
    public var toolset: WorkspaceToolset
    private let ocrService = VisionOCRService()
    private let vault: SecretStore
    private let biometricGate = BiometricGate()
    private var activeHarness: AgentHarness?
    private var activeTask: Task<Void, Never>?
    /// 每次开新回合 +1；旧回合（已停止 / 被取代）的迟到事件与收尾一律按代际号丢弃，不会污染新回合状态
    private var turnGeneration = 0
    private var streamingSessionId: UUID?
    private var remoteClient: DshWebClient?

    private static let apiKeyAccount = "deepseek_primary_api_key"
    private static let sessionsFileName = "sessions_v1.json"
    private static let settingsKey = "deepseek_go_settings_v2"
    private static let customPresetsKey = "deepseek_go_custom_presets_v1"
    private static let remoteSpecsKey = "deepseek_go_remote_specs_v1"

    public var onLiveActivityUpdate: (@Sendable (String, Bool) -> Void)?

    public init(
        vault: SecretStore = KeychainSecretStore(),
        firewall: PrivacyFirewall = PrivacyFirewall(),
        toolset: WorkspaceToolset = WorkspaceToolset()
    ) {
        self.vault = vault
        self.firewall = firewall
        self.toolset = toolset
        self.providerConfig = ProviderConfig()
        self.approvalPolicy = .readOnlyAuto
        self.requireFaceIDForApprovals = false
        self.engineMode = .onDeviceHarness

        #if os(iOS)
        PyodideRuntime.shared.firewall = firewall
        AgentRuntimeHooks.shared.python = PyodideRuntime.shared
        #endif
        loadPersistedState()
        seedWelcomeWorkspaceIfNeeded()
        if sessions.isEmpty {
            let initial = ChatSession(title: "新对话", engineMode: .onDeviceHarness)
            sessions = [initial]
            activeSessionId = initial.id
        } else if activeSessionId == nil {
            activeSessionId = sessions.first?.id
        }
        if let id = activeSessionId {
            activeProjectId = sessions.first(where: { $0.id == id })?.projectId
            rebindToolset()
        }

        Task {
            await firewall.setAllowedModelBaseURL(providerConfig.baseURL)
            await refreshAuditSnapshot()
            await refreshPhoneRunnerStatus()
            await syncRemoteWebSpecs(silent: true)
        }
    }

    public static let cloudSpecsURL = URL(string: "https://app.apifish.me/specs.json")!

    /// 从你的自建云端（app.apifish.me/specs.json）热拉取最新免 Key 渠道规格，改接口免重签 App。
    @discardableResult
    public func syncRemoteWebSpecs(silent: Bool = false) async -> String {
        var req = URLRequest(url: Self.cloudSpecsURL)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return "云端返回非 200 状态"
            }
            let remoteSpecs = try JSONDecoder().decode([WebAdapterSpec].self, from: data)
            let valid = remoteSpecs.filter { $0.validationIssue == nil }
            guard !valid.isEmpty else {
                return remoteSpecs.isEmpty ? "云端配置为空" : "云端配置未通过校验，继续使用本机版本"
            }
            webAdapters = WebAdapterSpec.merging(remote: valid, into: webAdapters)
            // 落盘最近一次有效配置：离线冷启动也能用上
            if let encoded = try? JSONEncoder().encode(valid) {
                UserDefaults.standard.set(encoded, forKey: Self.remoteSpecsKey)
            }
            let dropped = remoteSpecs.count - valid.count
            return "已从 app.apifish.me 同步 \(valid.count) 个免 Key 渠道最新配置"
                + (dropped > 0 ? "（\(dropped) 个未通过校验已忽略）" : "")
        } catch {
            if !silent {
                return "云端同步失败：\(error.localizedDescription)"
            }
            return ""
        }
    }

    public var activeSession: ChatSession? {
        guard let activeSessionId else { return sessions.first }
        return sessions.first(where: { $0.id == activeSessionId })
    }

    public var activePreset: PromptPreset {
        presets.first(where: { $0.id == activePresetId }) ?? PromptPreset.builtIn[0]
    }

    public var filteredSessions: [ChatSession] {
        let q = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(q) ||
            session.messages.contains { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    public var headerChannelTitle: String {
        if engineMode == .remoteDshWeb { return "DSH 远程" }
        if let spec = activeWebAdapter {
            if spec.id == "web_deepseek" { return "DeepSeek" }
            return spec.name.replacingOccurrences(of: "网页版", with: "")
        }
        let host = providerConfig.baseURL.host?.lowercased() ?? ""
        if host.contains("apifish.me") { return "自建云端" }
        if host.contains("deepseek.com") { return "DeepSeek" }
        if host.contains("aliyuncs.com") { return "通义千问" }
        if host.contains("bigmodel.cn") { return "智谱 GLM" }
        if host.contains("groq.com") { return "Groq" }
        if host.contains("azure.com") { return "GitHub AI" }
        if host.contains("siliconflow.cn") { return "硅基流动" }
        if host.contains("openrouter.ai") { return "OpenRouter" }
        if host.contains("moonshot.cn") { return "Kimi" }
        return "AI"
    }

    public var shortModelTitle: String {
        let m = providerConfig.model
        let lower = m.lowercased()
        if engineMode == .remoteDshWeb { return "DSH" }
        if lower == "deepseek-chat" { return "V3" }
        if lower == "deepseek-reasoner" { return "R1" }
        if lower == "doubao-seed-1.6" { return "Seed 1.6" }
        if lower == "doubao-seed-1.6-thinking" { return "深度思考" }
        return m.components(separatedBy: "/").last ?? m
    }

    /// 当前渠道可供切换的完整模型列表（网页预设模型 / 网关实测模型 / 厂商推荐模型自动合并去重）。
    public var availableModelsForActiveChannel: [String] {
        if let spec = activeWebAdapter {
            return spec.models
        }
        var out: [String] = []
        func appendUnique(_ list: [String]) {
            for item in list where !item.isEmpty && !out.contains(item) {
                out.append(item)
            }
        }
        let host = providerConfig.baseURL.host?.lowercased() ?? ""
        if let matched = KeyProvider.matching(host: host) {
            appendUnique(matched.models)
        }
        appendUnique(discoveredModels)
        if out.isEmpty {
            appendUnique(["deepseek-chat", "deepseek-reasoner"])
        }
        appendUnique([providerConfig.model])
        return out
    }

    public var isThinkingModelActive: Bool {
        let lower = providerConfig.model.lowercased()
        return lower.contains("reasoner")
            || lower.contains("r1")
            || lower.contains("think")
            || lower.contains("qwq")
            || lower.contains("z1")
            || lower.hasPrefix("o1")
            || lower.hasPrefix("o3")
    }

    /// 按当前所属厂商/网页渠道智能切换「快速回答 ↔ 深度思考」对应模型，不再写死 DeepSeek。
    public func toggleThinkingMode() {
        let models = availableModelsForActiveChannel
        let isThinking = isThinkingModelActive
        func isReasoningModel(_ id: String) -> Bool {
            let l = id.lowercased()
            return l.contains("reasoner") || l.contains("r1") || l.contains("think") || l.contains("qwq") || l.contains("z1") || l.hasPrefix("o3")
        }
        let target: String
        if isThinking {
            target = models.first { !isReasoningModel($0) } ?? "deepseek-chat"
        } else {
            target = models.first { isReasoningModel($0) } ?? "deepseek-reasoner"
        }
        var next = providerConfig
        next.model = target
        updateProviderConfig(next)
    }

    /// True when the active configuration requires credentials that have not been provided yet.
    public var needsCredentialsBeforeSend: Bool {
        guard engineMode == .onDeviceHarness else { return remoteClient == nil }
        if let spec = activeWebAdapter { return !hasWebCredential(spec) }
        let host = providerConfig.baseURL.host?.lowercased() ?? ""
        if !KeyProvider.requiresAPIKey(host: host) { return false }
        return !hasAPIKeyConfigured
    }

    /// 当前渠道能不能调用工具。靠驱动官网页面发消息的网页渠道（豆包 / 千问）只能聊天。
    public var agentToolsAvailable: Bool {
        guard engineMode == .onDeviceHarness else { return false }
        guard let spec = activeWebAdapter else { return true }
        return WebAdapterTransport.supportsTextTools(spec)
    }

    public var isAIConfigured: Bool {
        !needsCredentialsBeforeSend
    }

    public var companionMood: CompanionMood {
        if pendingApproval != nil { return .waitingApproval }
        if isStreaming {
            if activeStageText.contains("思考") { return .thinking }
            return .coding
        }
        if celebratingTurnCompletion { return .happy }
        return .idle
    }

    public func mountExternalWorkspaceFolder(_ folderURL: URL) {
        do {
            self.toolset = try WorkspaceToolset.saveExternalFolderBookmark(folderURL)
            self.noticeBanner = "已挂载外部目录：\(folderURL.lastPathComponent)"
        } catch {
            self.errorBanner = "挂载文件夹失败：\(error.localizedDescription)"
        }
    }

    public func resetToBuiltInWorkspace() {
        self.toolset = WorkspaceToolset.clearExternalFolderBookmark()
        self.noticeBanner = "已切回应用内置沙盒目录"
    }

    public func importDocumentToWorkspace(from url: URL) -> String? {
        let isSec = url.startAccessingSecurityScopedResource()
        defer {
            if isSec { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let filename = url.lastPathComponent
            let destURL = try toolset.resolveSafeURL(filename)
            let data = try Data(contentsOf: url)
            try data.write(to: destURL, options: .atomic)
            let bytes = data.count
            let sizeStr = bytes < 1024 ? "\(bytes) B" : "\(bytes / 1024) KB"
            noticeBanner = "已导入项目文件：\(filename) (\(sizeStr))"
            return filename
        } catch {
            errorBanner = "导入文件失败：\(error.localizedDescription)"
            return nil
        }
    }

    public var hasAPIKeyConfigured: Bool {
        guard let key = try? vault.loadSecret(for: Self.apiKeyAccount) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func maskedAPIKeyPreview() -> String {
        guard let key = try? vault.loadSecret(for: Self.apiKeyAccount), key.count >= 8 else {
            return "未配置"
        }
        return "\(key.prefix(4))••••\(key.suffix(4))"
    }

    public func saveAPIKey(_ newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try vault.deleteSecret(for: Self.apiKeyAccount)
            } else {
                try vault.saveSecret(trimmed, for: Self.apiKeyAccount)
            }
            errorBanner = nil
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    public func updateProviderConfig(_ updated: ProviderConfig) {
        providerConfig = updated
        persistSettings()
        Task {
            await firewall.setAllowedModelBaseURL(updated.baseURL)
            await refreshAuditSnapshot()
        }
    }

    // MARK: - One-Tap Setup (deep link / QR onboarding)

    /// Handles `deepseekgo://setup?base=…&key=…&model=…` from a QR code or an
    /// operator's install page. Returns false for any other URL shape.
    @discardableResult
    public func handleSetupURL(_ url: URL) -> Bool {
        guard let link = SetupLink.parse(url) else { return false }
        return applySetupLink(link)
    }

    /// Writes the endpoint + token into the device Keychain and the active provider config,
    /// then verifies the gateway by asking it for its model list.
    @discardableResult
    public func applySetupLink(_ link: SetupLink) -> Bool {
        var updated = providerConfig
        updated.name = link.name
        updated.baseURL = link.baseURL
        if !link.model.isEmpty {
            updated.model = link.model
        }
        providerConfig = updated
        persistSettings()

        if !link.apiKey.isEmpty {
            saveAPIKey(link.apiKey)
        }
        guard errorBanner == nil else { return false }

        discoveredModels = []
        noticeBanner = "已接入 \(link.name)"
        Task {
            await firewall.setAllowedModelBaseURL(link.baseURL)
            await refreshAuditSnapshot()
            await discoverGatewayModels()
        }
        return true
    }

    public func setAppearance(_ next: AppearancePreference) {
        appearance = next
        persistSettings()
    }

    // MARK: - Persona & Ruleset Management (with Snapshot Rollback)

    public var canRollbackPreset: Bool {
        previousPresetSnapshotId != nil
    }

    @discardableResult
    public func selectPreset(_ preset: PromptPreset) -> Bool {
        previousPresetSnapshotId = activePresetId
        activePresetId = preset.id
        // dsh-purge 的引擎级一半：无限制模式不再让审批弹窗打断工具调用
        if preset.id == PurgeProfile.presetID {
            approvalPolicy = .fullSandboxAuto
            requireFaceIDForApprovals = false
            if !hasSeenPurgeIntro {
                purgeIntroPresented = true
                hasSeenPurgeIntro = true
                persistSettings()
            }
        } else {
            approvalPolicy = .readOnlyAuto
        }
        persistSettings()
        applyActivePresetToCurrentSession()
        return true
    }

    public func rollbackPreset() {
        guard let prev = previousPresetSnapshotId else { return }
        activePresetId = prev
        previousPresetSnapshotId = nil
        persistSettings()
        applyActivePresetToCurrentSession()
    }

    public func addCustomPreset(title: String, systemPrompt: String) {
        let custom = PromptPreset(
            id: "custom_\(UUID().uuidString.prefix(8))",
            title: title,
            icon: "slider.horizontal.below.rectangle",
            systemPrompt: systemPrompt
        )
        presets.append(custom)
        saveCustomPresets()
        _ = selectPreset(custom)
    }

    public var isUnrestrictedMode: Bool {
        activePresetId == PurgeProfile.presetID
    }

    /// Full client-side purge: prompt layer + approval gate, exactly the three
    /// things the desktop `dsh-purge` patch rewrites in a harness it owns.
    public func setUnrestrictedMode(_ enabled: Bool) {
        if enabled {
            if let p = presets.first(where: { $0.id == PurgeProfile.presetID }) {
                _ = selectPreset(p)
                noticeBanner = "无限制模式已开：提示词已清洗，工具调用免审批"
            }
        } else {
            if let p = presets.first(where: { $0.id == "default_agent" }) {
                _ = selectPreset(p)
                noticeBanner = "已恢复默认：提示词与写文件审批都回来了"
            }
        }
    }

    private func applyActivePresetToCurrentSession() {
        guard let idx = currentSessionIndex() else { return }
        if let sysIdx = sessions[idx].messages.firstIndex(where: { $0.role == .system }) {
            sessions[idx].messages[sysIdx].content = activePreset.systemPrompt
        } else {
            sessions[idx].messages.insert(ChatMessage(role: .system, content: activePreset.systemPrompt), at: 0)
        }
    }

    // MARK: - On-Device Vision OCR Attachment

    public func attachPhotoDataForOCR(_ data: Data) async {
        isRunningOCR = true
        defer { isRunningOCR = false }
        do {
            let recognized = try await ocrService.extractText(from: data)
            let cleaned = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                errorBanner = "未在图片中识别出文字内容"
            } else {
                let preview = String(cleaned.replacingOccurrences(of: "\n", with: " ").prefix(36))
                pendingOCRAttachment = (summary: "图片文字：\(preview)…", fullText: cleaned)
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    // MARK: - Session Lifecycle, Forking & Regenerate

    public func createNewSession(in projectId: UUID? = nil) {
        // 已有一个还没说过话的空对话就直接复用，避免连点「新对话」堆出一串空会话
        if let idx = sessions.firstIndex(where: { $0.projectId == projectId && !$0.messages.contains { $0.role != .system } }) {
            var reused = sessions.remove(at: idx)
            reused.title = "新对话"
            reused.engineMode = engineMode
            reused.updatedAt = Date()
            sessions.insert(reused, at: 0)
            activateSession(reused.id)
            persistSessions()
            return
        }
        let session = ChatSession(
            title: "新对话",
            projectId: projectId,
            engineMode: engineMode,
            messages: [ChatMessage(role: .system, content: activePreset.systemPrompt)]
        )
        sessions.insert(session, at: 0)
        activateSession(session.id)
        persistSessions()
    }

    /// 切换对话时把工具沙盒切到该对话所属项目（默认工作区 / 项目文件夹）。
    public func activateSession(_ id: UUID) {
        activeSessionId = id
        activeProjectId = sessions.first(where: { $0.id == id })?.projectId
        rebindToolset()
    }

    public func rebindToolset() {
        if let pid = activeProjectId,
           let project = projects.first(where: { $0.id == pid }),
           let bookmark = project.bookmark,
           let bound = WorkspaceToolset(bookmark: bookmark) {
            toolset = bound
        } else {
            toolset = WorkspaceToolset.builtIn()
        }
    }

    // MARK: - 项目

    public func sessions(in projectId: UUID?) -> [ChatSession] {
        let q = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            guard session.projectId == projectId else { return false }
            guard !q.isEmpty else { return true }
            return session.title.localizedCaseInsensitiveContains(q) ||
                session.messages.contains { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    /// 抽屉里默认工作区的对话，按最近活动时间分组（今天 / 昨天 / 近 7 天 / 更早）。
    public func sessionGroups(now: Date = Date()) -> [(title: String, sessions: [ChatSession])] {
        let calendar = Calendar.current
        var buckets: [(title: String, sessions: [ChatSession])] = [("今天", []), ("昨天", []), ("近 7 天", []), ("更早", [])]
        for session in sessions(in: nil) {
            let days = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: session.updatedAt), to: calendar.startOfDay(for: now)
            ).day ?? 0
            buckets[days <= 0 ? 0 : days == 1 ? 1 : days < 7 ? 2 : 3].sessions.append(session)
        }
        return buckets.filter { !$0.sessions.isEmpty }
    }

    /// 检测手机操控驱动是否在线（设置页和每轮开始前调用）
    public func refreshPhoneRunnerStatus() async {
        let online = await PhoneControl.isRunnerAlive()
        AgentRuntimeHooks.shared.phoneAvailable = online
        phoneRunnerOnline = online
    }

    public func rootURL(for project: WorkspaceProject) -> URL? {
        guard let bookmark = project.bookmark,
              let ts = WorkspaceToolset(bookmark: bookmark) else { return nil }
        return ts.rootURL
    }

    public func projectName(for id: UUID?) -> String {
        guard let id, let p = projects.first(where: { $0.id == id }) else { return "默认工作区" }
        return p.name
    }

    @discardableResult
    public func addProject(folderURL: URL, name: String? = nil) -> Bool {
        guard let bookmark = WorkspaceToolset.makeBookmark(for: folderURL) else {
            errorBanner = "无法获取该文件夹的访问书签"
            return false
        }
        let project = WorkspaceProject(name: name ?? folderURL.lastPathComponent, bookmark: bookmark)
        projects.append(project)
        persistSettings()
        noticeBanner = "已添加项目：\(project.name)"
        return true
    }

    // MARK: - 个人资料

    public func updateDisplayName(_ name: String) {
        displayName = String(name.prefix(24))
        persistSettings()
    }

    public func updateAvatarEmoji(_ emoji: String) {
        avatarEmoji = emoji
        avatarImageData = nil
        persistSettings()
    }

    #if canImport(UIKit)
    public func updateAvatarImage(_ data: Data?) {
        guard let data, let image = UIImage(data: data) else {
            avatarImageData = nil
            persistSettings()
            return
        }
        let side: CGFloat = 256
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let scaled = renderer.image { _ in
            let scale = max(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        avatarImageData = scaled.jpegData(compressionQuality: 0.85)
        persistSettings()
    }
    #endif

    public func renameProject(_ id: UUID, to name: String) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projects[idx].name = trimmed
        persistSettings()
    }

    public func deleteProject(_ id: UUID) {
        for idx in sessions.indices where sessions[idx].projectId == id {
            sessions[idx].projectId = nil
        }
        projects.removeAll { $0.id == id }
        persistSessions()
        persistSettings()
        if activeProjectId == id {
            activeSessionId.map { activateSession($0) } ?? rebindToolset()
            activeProjectId = nil
        }
        noticeBanner = "项目已删除，其中的对话已移回默认工作区"
    }

    public func moveSession(_ id: UUID, to projectId: UUID?) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].projectId = projectId
        persistSessions()
        if activeSessionId == id { activateSession(id) }
    }

    public func renameSession(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].title = String(trimmed.prefix(40))
        persistSessions()
    }

    public func deleteSession(_ id: UUID) {
        if isStreaming && streamingSessionId == id {
            stopGeneration()
        }
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty {
            createNewSession()
        } else if activeSessionId == id, let next = sessions.first?.id {
            activateSession(next)
        }
        persistSessions()
    }

    /// Forks conversation history up to `messageId` into a clean branch session (ported from DSH workflow).
    public func forkSession(upTo messageId: UUID) {
        guard let cur = activeSession,
              let cutIdx = cur.messages.firstIndex(where: { $0.id == messageId }) else { return }
        let sliced = Array(cur.messages[...cutIdx])
        let forked = ChatSession(
            title: "\(cur.title) · 分支",
            projectId: cur.projectId,
            engineMode: cur.engineMode,
            messages: sliced
        )
        sessions.insert(forked, at: 0)
        activateSession(forked.id)
        persistSessions()
    }

    public func regenerateLastTurn() {
        guard !isStreaming, let idx = currentSessionIndex() else { return }
        while let last = sessions[idx].messages.last, last.role != .user {
            sessions[idx].messages.removeLast()
        }
        guard sessions[idx].messages.contains(where: { $0.role == .user }) else { return }
        runLocalHarnessTurn()
    }

    public func sendOrSteer(text: String, steerMode: SteerMode = .nextStep) {
        var composed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ocr = pendingOCRAttachment {
            let attachmentBlock = "[本机离线 OCR 提取的图片文本]\n\(ocr.fullText)\n\n"
            composed = attachmentBlock + (composed.isEmpty ? "请分析上述图片中的内容。" : composed)
            pendingOCRAttachment = nil
        }
        guard !composed.isEmpty else { return }
        errorBanner = nil

        if isStreaming {
            let directive = SteerDirective(text: composed, mode: steerMode)
            queuedSteers.append(directive)
            if engineMode == .remoteDshWeb,
               let remoteClient,
               let remoteId = activeSession?.remoteSessionId {
                Task {
                    _ = try? await remoteClient.sendPrompt(sessionId: remoteId, text: composed, steer: true)
                    await refreshAuditSnapshot()
                }
            } else if let harness = activeHarness {
                Task {
                    await harness.enqueueSteer(directive)
                }
            }
            return
        }

        guard let sessionIdx = currentSessionIndex() else { return }
        applyActivePresetToCurrentSession()
        let userMsg = ChatMessage(role: .user, content: composed)
        sessions[sessionIdx].messages.append(userMsg)
        if sessions[sessionIdx].messages.filter({ $0.role == .user }).count == 1 {
            let cleanTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
            sessions[sessionIdx].title = String((cleanTitle.isEmpty ? "图片识别分析" : cleanTitle).prefix(22))
        }
        sessions[sessionIdx].updatedAt = Date()
        persistSessions()

        if engineMode == .remoteDshWeb {
            runRemoteDshTurn(promptText: composed)
        } else {
            runLocalHarnessTurn()
        }
    }

    public func stopGeneration() {
        turnGeneration += 1
        activeTask?.cancel()
        activeTask = nil
        activeHarness = nil
        dropTrailingEmptyAssistant(in: streamingSessionId)
        streamingSessionId = nil
        persistSessions()
        turnStartedAt = nil
        liveTool = nil
        isStreaming = false
        activeStageText = ""
        pendingApproval = nil
        queuedSteers.removeAll()
        onLiveActivityUpdate?("已停止", false)

        if engineMode == .remoteDshWeb,
           let remoteClient,
           let remoteId = activeSession?.remoteSessionId {
            Task {
                try? await remoteClient.cancelSession(sessionId: remoteId)
                await refreshAuditSnapshot()
            }
        }
    }

    public func decideApproval(approved: Bool, rememberForTurn: Bool = false) {
        guard let pending = pendingApproval else { return }
        Task {
            if approved && (requireFaceIDForApprovals || pending.requiresBiometrics) {
                do {
                    let ok = try await biometricGate.authenticate(reason: "确认放行敏感操作：\(pending.summary)")
                    if !ok { return }
                } catch {
                    errorBanner = error.localizedDescription
                    return
                }
            }
            pendingApproval = nil
            await activeHarness?.resolveApproval(callId: pending.call.id, approved: approved, rememberForTurn: rememberForTurn)
        }
    }

    // MARK: - Gateway Auto-Discovery & Official Balance

    public func discoverGatewayModels() async {
        isFetchingModelsOrBalance = true
        defer { isFetchingModelsOrBalance = false }
        let key = (try? vault.loadSecret(for: Self.apiKeyAccount)) ?? ""
        do {
            discoveredModels = try await DeepSeekClient().fetchAvailableModels(
                baseURL: providerConfig.baseURL,
                apiKey: key,
                firewall: firewall
            )
            await refreshAuditSnapshot()
        } catch {
            errorBanner = error.localizedDescription
            await refreshAuditSnapshot()
        }
    }

    public func queryDeepSeekBalance() async {
        isFetchingModelsOrBalance = true
        defer { isFetchingModelsOrBalance = false }
        let key = (try? vault.loadSecret(for: Self.apiKeyAccount)) ?? ""
        do {
            balanceInfo = try await DeepSeekClient().fetchDeepSeekBalance(apiKey: key, firewall: firewall)
            await refreshAuditSnapshot()
        } catch {
            errorBanner = error.localizedDescription
            await refreshAuditSnapshot()
        }
    }

    // MARK: - Remote DSH Web Pairing

    public func connectRemoteDshHost() async {
        errorBanner = nil
        guard let parsed = DshLaunchURL.parse(remoteLaunchInput) else {
            errorBanner = DshWebError.invalidLaunchURL.localizedDescription
            return
        }
        let client = DshWebClient(baseURI: parsed.baseURI, firewall: firewall)
        do {
            let cookie = try await client.login(token: parsed.token)
            self.remoteClient = client
            self.remoteConnectedHost = cookie.authority
            self.engineMode = .remoteDshWeb
            self.remoteSessions = (try? await client.listSessions()) ?? []
            await refreshAuditSnapshot()
        } catch {
            errorBanner = error.localizedDescription
            await refreshAuditSnapshot()
        }
    }

    // MARK: - Interactive Zero-Key Showcase

    public func runInteractiveShowcase() {
        guard !isStreaming else { return }
        errorBanner = nil

        actor DemoShowcaseTransport: ModelStreamingTransport {
            var step = 0
            nonisolated func streamChatCompletion(
                config: ProviderConfig,
                apiKey: String,
                messages: [ChatMessage],
                includeWorkspaceTools: Bool,
                firewall: PrivacyFirewall
            ) -> AsyncThrowingStream<StreamDelta, Error> {
                AsyncThrowingStream { continuation in
                    Task {
                        let current = await advance()
                        let titles = ["查看工作区", "用 Python 汇总并画图", "写入报告", "生成预览卡片"]
                        // 前 done 步已完成；active 为 true 时下一步标记为进行中
                        func plan(done: Int, active: Bool = true) -> ToolCallRequest {
                            let steps = titles.enumerated().map { index, title -> [String: String] in
                                let status = index < done ? "done" : (index == done && active ? "in_progress" : "pending")
                                return ["title": title, "status": status]
                            }
                            let data = (try? JSONSerialization.data(withJSONObject: ["steps": steps])) ?? Data()
                            return ToolCallRequest(
                                id: "demo_plan_\(current)",
                                name: "update_plan",
                                argumentsJSON: String(decoding: data, as: UTF8.self)
                            )
                        }
                        try? await Task.sleep(for: .milliseconds(500))

                        switch current {
                        case 1:
                            for chunk in ["先看看工作区里有什么，", "再用 Python 汇总画图、写报告，最后出一张预览卡。"] {
                                try? await Task.sleep(for: .milliseconds(260))
                                continuation.yield(.reasoning(chunk))
                            }
                            continuation.yield(.content("先看一下工作区，再汇总数据、画图。"))
                            continuation.yield(.toolCalls([
                                plan(done: 0),
                                ToolCallRequest(id: "demo_ls", name: "run_shell", argumentsJSON: #"{"command":"ls -la"}"#)
                            ]))
                        case 2:
                            continuation.yield(.toolCalls([
                                plan(done: 1),
                                ToolCallRequest(
                                    id: "demo_py",
                                    name: "run_python",
                                    argumentsJSON: String(decoding: (try? JSONSerialization.data(withJSONObject: ["code": """
                                    import matplotlib.pyplot as plt
                                    sales = [42, 51, 47, 63, 58, 71, 69, 80, 77, 91, 88, 104]
                                    quarters = [sum(sales[i:i + 3]) for i in range(0, 12, 3)]
                                    plt.figure(figsize=(6, 3.4))
                                    plt.bar(["Q1", "Q2", "Q3", "Q4"], quarters, color="#4D6BFE")
                                    plt.title("Quarterly sales")
                                    plt.tight_layout()
                                    plt.savefig("sales.png", dpi=160)
                                    print("quarters:", quarters, "total:", sum(sales))
                                    """])) ?? Data(), as: UTF8.self)
                                )
                            ]))
                        case 3:
                            continuation.yield(.reasoning("数据出来了，把结论写成一份报告（写文件需要用户确认）。"))
                            continuation.yield(.toolCalls([
                                plan(done: 2),
                                ToolCallRequest(
                                    id: "demo_write",
                                    name: "write_file",
                                    argumentsJSON: String(decoding: (try? JSONSerialization.data(withJSONObject: [
                                        "path": "notes/sales-report.md",
                                        "content": "# 销售季度汇总\n\n- Q1：140\n- Q2：192\n- Q3：226\n- Q4：283\n\n全年合计 841，Q4 环比 +25%。"
                                    ])) ?? Data(), as: UTF8.self)
                                )
                            ]))
                        case 4:
                            let html = """
                            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
                            <style>
                              body{margin:0;padding:24px;background:#fafafa;color:#111;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
                              @media (prefers-color-scheme:dark){body{background:#0a0a0c;color:#f5f5f7}.card{background:#18181b;border-color:rgba(255,255,255,.08)}}
                              .card{border:0.5px solid rgba(0,0,0,.08);border-radius:18px;padding:20px;background:#fff}
                              .metric{font-size:32px;font-weight:600;letter-spacing:-0.03em;margin:6px 0}
                              .sub{color:#71717a;font-size:13px}
                              button{margin-top:16px;background:#111;color:#fff;border:0;border-radius:99px;padding:9px 18px;font-size:13px;font-weight:500}
                              @media (prefers-color-scheme:dark){button{background:#f5f5f7;color:#0a0a0c}}
                            </style></head><body>
                            <div class="card">
                              <div class="sub">SALES · 2026</div>
                              <div class="metric">841</div>
                              <div class="sub">Q1 140 · Q2 192 · Q3 226 · Q4 283</div>
                              <button onclick="document.getElementById('s').innerText='Q4 环比 +25%，全年逐季上升'">看结论</button>
                              <div id="s" class="sub" style="margin-top:10px"></div>
                            </div></body></html>
                            """
                            let argsData = try? JSONSerialization.data(withJSONObject: [
                                "title": "销售看板",
                                "kind": "html",
                                "source": html
                            ])
                            continuation.yield(.toolCalls([
                                plan(done: 3),
                                ToolCallRequest(
                                    id: "demo_art",
                                    name: "render_artifact",
                                    argumentsJSON: String(decoding: argsData ?? Data(), as: UTF8.self)
                                )
                            ]))
                        case 5:
                            continuation.yield(.toolCalls([plan(done: 4, active: false)]))
                        default:
                            let pythonFailed = messages.contains { $0.toolOutput?.toolCallId == "demo_py" && $0.toolOutput?.isError == true }
                            let summary = pythonFailed
                                ? """
                                ## 做了一部分
                                Python 运行时没能启动（首次使用需要联网下载约 12MB），所以**图没画出来**；其余步骤已完成：

                                - 报告 `notes/sales-report.md` 已写入工作区
                                - 预览卡片已生成，点下面的卡片可以打开
                                """
                                : """
                                ## 做完了
                                全年销售 **841**，逐季上升，Q4 环比 +25%。

                                | 季度 | 销售额 | 环比 |
                                | --- | --- | --- |
                                | Q1 | 140 | – |
                                | Q2 | 192 | +37% |
                                | Q3 | 226 | +18% |
                                | Q4 | 283 | +25% |

                                - 图表 `sales.png` 是手机上的 Python 画的，点下面的图可以放大
                                - 报告写在 `notes/sales-report.md`，改动可逐行查看
                                """
                            continuation.yield(.content(summary))
                            continuation.yield(.usage(TokenUsage(
                                promptTokens: 11_800,
                                completionTokens: 1_960,
                                reasoningTokens: 680,
                                cacheHitTokens: 10_200,
                                cacheMissTokens: 1_600
                            )))
                        }
                        continuation.finish()
                    }
                }
            }
            private func advance() -> Int {
                step += 1
                return step
            }
        }

        createNewSession()
        guard let idx = currentSessionIndex() else { return }
        sessions[idx].title = "演示：销售汇总与画图"
        sessions[idx].messages.append(ChatMessage(
            role: .user,
            content: "汇总今年的销售数据，画一张季度柱状图，再写一份简短报告。"
        ))

        let demoHarness = AgentHarness(transport: DemoShowcaseTransport(), toolset: toolset, firewall: firewall)
        executeHarness(demoHarness, apiKeyOverride: "demo-local-key")
    }

    public func runFirewallSelfTest() async {
        let testURLs = [
            "https://go.dshtui.com/usage?token=leak_test",
            "https://dsh.r2049.cn/relay/connect?secret=demo",
            "https://app-measurement.com/collect"
        ]
        for raw in testURLs {
            if let url = URL(string: raw) {
                _ = try? await firewall.authorize(URLRequest(url: url), purpose: .userApprovedWebFetch)
            }
        }
        await refreshAuditSnapshot()
    }

    public func refreshAuditSnapshot() async {
        auditEntries = await firewall.snapshot()
        allowlistInfo = await firewall.allowlistSummary()
    }

    public func clearAuditLogs() async {
        await firewall.clearAuditLog()
        await refreshAuditSnapshot()
    }

    // MARK: - Private Turn Execution

    /// 有网页版凭据就走翻译通道，否则走标准 OpenAI 兼容接口。
    private func currentTransport() -> any ModelStreamingTransport {
        if let spec = activeWebAdapter,
           let token = (try? vault.loadSecret(for: webCredentialAccount(spec))) ?? nil,
           !token.isEmpty {
            let cookies = (try? vault.loadSecret(for: webCookieAccount(spec))) ?? nil
            #if os(iOS)
            let performer: BrowserStreamPerformer? = WebKitBrowserStreamPerformer.shared
            #else
            let performer: BrowserStreamPerformer? = nil
            #endif
            return WebAdapterTransport(
                spec: spec,
                credential: token,
                cookieHeader: cookies,
                browserPerformer: performer
            )
        }
        // 协议层自动适配：responses 用另一个客户端，用户不需要知道
        if providerConfig.flavor == .responses {
            return ResponsesClient()
        }
        return DeepSeekClient()
    }

    private func runLocalHarnessTurn() {
        let key = (try? vault.loadSecret(for: Self.apiKeyAccount)) ?? ""
        let harness = AgentHarness(transport: currentTransport(), toolset: toolset, firewall: firewall)
        executeHarness(harness, apiKeyOverride: key)
    }

    private func executeHarness(_ harness: AgentHarness, apiKeyOverride: String) {
        guard let sessionId = activeSessionId,
              let startIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        let historySnapshot = sessions[startIdx].messages
        let cfg = providerConfig
        let policy = approvalPolicy

        turnGeneration += 1
        let generation = turnGeneration
        activeHarness = harness
        streamingSessionId = sessionId
        isStreaming = true
        activeStageText = "思考中"
        let startedAt = Date()
        turnFailure = nil
        errorBanner = nil
        turnStartedAt = startedAt
        liveTool = nil
        onLiveActivityUpdate?("思考中…", true)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 手机操控驱动在线时才把 phone_* 工具交给模型
                await self.refreshPhoneRunnerStatus()
                _ = try await harness.runTurn(
                    history: historySnapshot,
                    config: cfg,
                    apiKey: apiKeyOverride,
                    approvalPolicy: policy
                ) { [weak self] event in
                    await MainActor.run {
                        guard let self, self.turnGeneration == generation else { return }
                        self.applyAgentEvent(event, sessionId: sessionId)
                    }
                }
                guard self.turnGeneration == generation else { return }
                self.streamingSessionId = nil
                self.activeHarness = nil
                self.turnStartedAt = nil
                self.liveTool = nil
                if let sIdx = self.sessions.firstIndex(where: { $0.id == sessionId }),
                   let mIdx = self.sessions[sIdx].messages.indices.last,
                   self.sessions[sIdx].messages[mIdx].role == .assistant {
                    self.sessions[sIdx].messages[mIdx].turnDurationSec = Date().timeIntervalSince(startedAt)
                }
                self.isStreaming = false
                self.activeStageText = ""
                self.queuedSteers.removeAll()
                self.celebratingTurnCompletion = true
                Haptics.success()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2.8))
                    self?.celebratingTurnCompletion = false
                }
                self.persistSessions()
                self.onLiveActivityUpdate?("已完成", false)
                await self.refreshAuditSnapshot()
            } catch {
                // 已被「停止」或新回合取代：收尾已由 stopGeneration 完成，这里什么都不碰
                guard self.turnGeneration == generation else { return }
                self.streamingSessionId = nil
                self.activeHarness = nil
                self.turnStartedAt = nil
                self.liveTool = nil
                self.isStreaming = false
                self.activeStageText = ""
                self.dropTrailingEmptyAssistant(in: sessionId)
                self.persistSessions()
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled {
                    self.turnFailure = TurnFailure(sessionId: sessionId, message: error.localizedDescription)
                    self.lastAdapterError = error.localizedDescription
                }
                self.onLiveActivityUpdate?(cancelled ? "已停止" : "已暂停", false)
                await self.refreshAuditSnapshot()
            }
        }
    }

    /// 去掉还没收到任何内容的空助手气泡（停止 / 报错时），保留已经吐出的半截回答。
    private func dropTrailingEmptyAssistant(in sessionId: UUID?) {
        guard let sessionId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let last = sessions[sIdx].messages.last,
              last.role == .assistant,
              last.content.isEmpty,
              (last.reasoningContent ?? "").isEmpty,
              last.toolCalls.isEmpty else { return }
        sessions[sIdx].messages.removeLast()
    }

    private func applyAgentEvent(_ event: AgentEvent, sessionId: UUID) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        switch event {
        case let .assistantStarted(messageId):
            sessions[sIdx].messages.append(ChatMessage(id: messageId, role: .assistant, content: ""))
            activeStageText = "思考中"
            liveTool = nil
        case let .reasoningDelta(messageId, delta, elapsedSec):
            if let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) {
                let prev = sessions[sIdx].messages[mIdx].reasoningContent ?? ""
                sessions[sIdx].messages[mIdx].reasoningContent = prev + delta
                sessions[sIdx].messages[mIdx].reasoningDurationSec = elapsedSec
                activeStageText = String(format: "思考 %.1fs", elapsedSec)
                liveTool = nil
            }
        case let .contentDelta(messageId, delta):
            if let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) {
                sessions[sIdx].messages[mIdx].content += delta
                activeStageText = "回复中"
                liveTool = nil
            }
        case let .usageUpdated(messageId, usage):
            if let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) {
                sessions[sIdx].messages[mIdx].usage = usage
            }
        case let .assistantToolCalls(messageId, calls):
            if let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) {
                sessions[sIdx].messages[mIdx].toolCalls = calls
                let actions = calls.filter { $0.name != "update_plan" }.map(ToolPresentation.describe)
                liveTool = actions.first
                activeStageText = actions.first.map { "\($0.verb) \($0.detail)" } ?? "更新计划"
                onLiveActivityUpdate?(activeStageText, true)
            }
        case let .approvalRequired(pending):
            pendingApproval = pending
            activeStageText = "待确认"
            onLiveActivityUpdate?("待确认：\(pending.call.name)", true)
        case let .toolCompleted(toolMsg):
            sessions[sIdx].messages.append(toolMsg)
            // 同一步里还有没跑完的工具就接着显示下一个
            let finished = Set(sessions[sIdx].messages.compactMap { $0.toolOutput?.toolCallId })
            let pendingCalls = sessions[sIdx].messages.last(where: { !$0.toolCalls.isEmpty })?.toolCalls ?? []
            liveTool = pendingCalls
                .first { !finished.contains($0.id) && $0.name != "update_plan" }
                .map(ToolPresentation.describe)
        case let .steerConsumed(directive, injectedMessage):
            queuedSteers.removeAll { $0.id == directive.id }
            sessions[sIdx].messages.append(injectedMessage)
            activeStageText = "已合并插话"
        case .turnCompleted:
            sessions[sIdx].updatedAt = Date()
        }
    }

    private func runRemoteDshTurn(promptText: String) {
        guard let remoteClient, let sessionId = activeSessionId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId }) else {
            errorBanner = "请先在「设置 › 远程主机」配对电脑端 dsh web。"
            return
        }
        isStreaming = true
        activeStageText = "远程同步中"
        let assistantId = UUID()
        sessions[sIdx].messages.append(ChatMessage(id: assistantId, role: .assistant, content: ""))

        activeTask = Task {
            do {
                let remoteSid: String
                if let existing = sessions[sIdx].remoteSessionId {
                    remoteSid = existing
                } else {
                    let created = try await remoteClient.createSession()
                    sessions[sIdx].remoteSessionId = created
                    remoteSid = created
                }

                _ = try await remoteClient.sendPrompt(sessionId: remoteSid, text: promptText, steer: false)
                let stream = await remoteClient.followSession(sessionId: remoteSid)
                for try await rawFrame in stream {
                    if let data = rawFrame.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let val = json["value"] as? [String: Any] {
                        if let delta = val["delta"] as? String,
                           let curSIdx = sessions.firstIndex(where: { $0.id == sessionId }),
                           let mIdx = sessions[curSIdx].messages.firstIndex(where: { $0.id == assistantId }) {
                            sessions[curSIdx].messages[mIdx].content += delta
                        }
                        if val["type"] as? String == "turn/end" {
                            break
                        }
                    }
                }
                isStreaming = false
                activeStageText = ""
                persistSessions()
                await refreshAuditSnapshot()
            } catch {
                isStreaming = false
                activeStageText = ""
                errorBanner = error.localizedDescription
                await refreshAuditSnapshot()
            }
        }
    }

    private func currentSessionIndex() -> Int? {
        guard let activeSessionId else { return sessions.indices.first }
        return sessions.firstIndex(where: { $0.id == activeSessionId })
    }

    // MARK: - Persistence

    private var sessionsFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent(Self.sessionsFileName)
    }

    private func persistSessions() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sessions) {
            try? data.write(to: sessionsFileURL, options: .atomic)
        }
    }

    private struct StoredSettings: Codable {
        var provider: ProviderConfig
        var policy: ApprovalPolicy
        var faceID: Bool
        var appearance: AppearancePreference
        var activePresetId: String
        var displayName: String?
        var avatarEmoji: String?
        var avatarImageData: Data?
        var projects: [WorkspaceProject]?
        var hasSeenPurgeIntro: Bool?
        var activeWebAdapterID: String?
        var customWebAdapters: [WebAdapterSpec]?
    }

    private func persistSettings() {
        let s = StoredSettings(
            provider: providerConfig,
            policy: approvalPolicy,
            faceID: requireFaceIDForApprovals,
            appearance: appearance,
            activePresetId: activePresetId,
            displayName: displayName,
            avatarEmoji: avatarEmoji,
            avatarImageData: avatarImageData,
            projects: projects,
            hasSeenPurgeIntro: hasSeenPurgeIntro,
            activeWebAdapterID: activeWebAdapterID,
            customWebAdapters: webAdapters.filter { spec in
                !WebAdapterSpec.presets.contains(where: { $0.id == spec.id })
            }
        )
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private func saveCustomPresets() {
        let customs = presets.filter { $0.id.hasPrefix("custom_") }
        if let data = try? JSONEncoder().encode(customs) {
            UserDefaults.standard.set(data, forKey: Self.customPresetsKey)
        }
    }

    private func loadPersistedState() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: sessionsFileURL),
           let loaded = try? decoder.decode([ChatSession].self, from: data),
           !loaded.isEmpty {
            sessions = loaded
            activeSessionId = loaded.first?.id
        }
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let s = try? JSONDecoder().decode(StoredSettings.self, from: data) {
            providerConfig = s.provider
            approvalPolicy = s.policy
            requireFaceIDForApprovals = s.faceID
            appearance = s.appearance
            activePresetId = s.activePresetId
            displayName = s.displayName ?? ""
            avatarEmoji = s.avatarEmoji ?? "🐳"
            avatarImageData = s.avatarImageData
            projects = s.projects ?? []
            hasSeenPurgeIntro = s.hasSeenPurgeIntro ?? false
            activeWebAdapterID = s.activeWebAdapterID
            webAdapters = WebAdapterSpec.presets + (s.customWebAdapters ?? [])
        }
        if let data = UserDefaults.standard.data(forKey: Self.remoteSpecsKey),
           let cached = try? JSONDecoder().decode([WebAdapterSpec].self, from: data) {
            webAdapters = WebAdapterSpec.merging(remote: cached, into: webAdapters)
        }
        if let data = UserDefaults.standard.data(forKey: Self.customPresetsKey),
           let customs = try? JSONDecoder().decode([PromptPreset].self, from: data) {
            presets = PromptPreset.builtIn + customs
        }
    }

    private func seedWelcomeWorkspaceIfNeeded() {
        let readme = toolset.rootURL.appendingPathComponent("WELCOME.md")
        guard !FileManager.default.fileExists(atPath: readme.path) else { return }
        let sample = """
        # DeepSeek Go Workspace

        此目录直接挂载在系统「文件 App」内，完全离线归属于本设备。
        """
        try? Data(sample.utf8).write(to: readme, options: .atomic)
    }
}
