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
    public var pendingApproval: PendingToolApproval?
    public var queuedSteers: [SteerDirective] = []
    public var errorBanner: String?
    public var noticeBanner: String?

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

    public func hasWebCredential(_ spec: WebAdapterSpec) -> Bool {
        ((try? vault.loadSecret(for: webCredentialAccount(spec))) ?? nil)?.isEmpty == false
    }

    public func saveWebCredential(_ token: String, for spec: WebAdapterSpec) {
        do {
            try vault.saveSecret(token, for: webCredentialAccount(spec))
            activateWebAdapter(spec)
        } catch {
            errorBanner = error.localizedDescription
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
        if !discoveredModels.isEmpty { return nil }
        return errorBanner ?? "没连上：检查 Key 和网络"
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
    private var remoteClient: DshWebClient?

    private static let apiKeyAccount = "deepseek_primary_api_key"
    private static let sessionsFileName = "sessions_v1.json"
    private static let settingsKey = "deepseek_go_settings_v2"
    private static let customPresetsKey = "deepseek_go_custom_presets_v1"

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

    public var shortModelTitle: String {
        let m = providerConfig.model.lowercased()
        if engineMode == .remoteDshWeb { return "DSH" }
        if m.contains("reasoner") || m.contains("r1") { return "R1" }
        if m.contains("chat") || m.contains("v3") { return "V3" }
        return providerConfig.model.components(separatedBy: "/").last ?? providerConfig.model
    }

    /// True when the active configuration requires an API key that has not been provided yet.
    public var needsCredentialsBeforeSend: Bool {
        guard engineMode == .onDeviceHarness else { return remoteClient == nil }
        let isOfficial = (providerConfig.baseURL.host?.lowercased() ?? "") == "api.deepseek.com"
        return isOfficial && !hasAPIKeyConfigured
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

    public func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty {
            createNewSession()
        } else if activeSessionId == id {
            activeSessionId = sessions.first?.id
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
            engineMode: cur.engineMode,
            messages: sliced
        )
        sessions.insert(forked, at: 0)
        activeSessionId = forked.id
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
        activeTask?.cancel()
        activeTask = nil
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

    public func decideApproval(approved: Bool) {
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
            await activeHarness?.resolveApproval(callId: pending.call.id, approved: approved)
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
                        if current == 1 {
                            let thoughts = [
                                "先在本地 JavaScriptCore 沙盒核验吞吐延迟，",
                                "再向工作区写入极简配置并生成行级 Diff 供用户确认。"
                            ]
                            for chunk in thoughts {
                                try? await Task.sleep(for: .milliseconds(140))
                                continuation.yield(.reasoning(chunk))
                            }
                            continuation.yield(.content("已准备本机基准测试与工作区配置变更，请确认以下文件写入："))
                            continuation.yield(.toolCalls([
                                ToolCallRequest(
                                    id: "demo_js_1",
                                    name: "run_javascript",
                                    argumentsJSON: #"{"code":"const samples = [14, 16, 15, 13, 15]; const p50 = samples.sort((a,b)=>a-b)[2]; ({ runtime: 'Swift 6 Native', p50Ms: p50 })"}"#
                                ),
                                ToolCallRequest(
                                    id: "demo_write_2",
                                    name: "write_file",
                                    argumentsJSON: #"{"path":"config/workspace.json","content":"{\n  \"mode\": \"minimal\",\n  \"zeroTelemetry\": true,\n  \"steer\": \"ready\"\n}"}"#
                                )
                            ]))
                        } else if current == 2 {
                            try? await Task.sleep(for: .milliseconds(120))
                            continuation.yield(.reasoning("配置已落盘，调用 render_artifact 输出极简离线预览。"))
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
                              <div class="sub">ON-DEVICE SANDBOX BENCHMARK</div>
                              <div class="metric">15.0 ms</div>
                              <div class="sub">0 Bytes Outbound Telemetry · Isolated WKWebView</div>
                              <button onclick="document.getElementById('s').innerText='Verified at ' + new Date().toLocaleTimeString()">Run Local Check</button>
                              <div id="s" class="sub" style="margin-top:10px"></div>
                            </div></body></html>
                            """
                            let argsData = try? JSONSerialization.data(withJSONObject: [
                                "title": "Sandbox Benchmark",
                                "kind": "html",
                                "source": html
                            ])
                            continuation.yield(.toolCalls([
                                ToolCallRequest(
                                    id: "demo_art_3",
                                    name: "render_artifact",
                                    argumentsJSON: String(decoding: argsData ?? Data(), as: UTF8.self)
                                )
                            ]))
                        } else {
                            let summary = """
                            验证已完成：
                            1. **本机计算**：`JavaScriptCore` 中位延迟 `15ms`，无外部运行时开销。
                            2. **工作区同步**：`config/workspace.json` 已写入 iOS「文件」目录。
                            3. **离线预览**：点击上方卡片可在断网隔离沙盒内交互验证。
                            """
                            continuation.yield(.content(summary))
                            continuation.yield(.usage(TokenUsage(
                                promptTokens: 1180,
                                completionTokens: 196,
                                reasoningTokens: 68,
                                cacheHitTokens: 1020,
                                cacheMissTokens: 160
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
        sessions[idx].title = "本机工作区与审批演示"
        sessions[idx].messages.append(ChatMessage(
            role: .user,
            content: "运行一次本机沙盒基准测试，写入配置文件并生成极简预览卡片。"
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
            return WebAdapterTransport(spec: spec, credential: token)
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

        activeHarness = harness
        isStreaming = true
        activeStageText = "思考中"
        onLiveActivityUpdate?("思考中…", true)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await harness.runTurn(
                    history: historySnapshot,
                    config: cfg,
                    apiKey: apiKeyOverride,
                    approvalPolicy: policy
                ) { [weak self] event in
                    await MainActor.run {
                        self?.applyAgentEvent(event, sessionId: sessionId)
                    }
                }
                self.isStreaming = false
                self.activeStageText = ""
                self.queuedSteers.removeAll()
                self.celebratingTurnCompletion = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2.8))
                    self?.celebratingTurnCompletion = false
                }
                self.persistSessions()
                self.onLiveActivityUpdate?("已完成", false)
                await self.refreshAuditSnapshot()
            } catch is CancellationError {
                self.isStreaming = false
                self.activeStageText = ""
            } catch {
                self.isStreaming = false
                self.activeStageText = ""
                self.errorBanner = error.localizedDescription
                self.onLiveActivityUpdate?("已暂停", false)
                await self.refreshAuditSnapshot()
            }
        }
    }

    private func applyAgentEvent(_ event: AgentEvent, sessionId: UUID) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        switch event {
        case let .assistantStarted(messageId):
            sessions[sIdx].messages.append(ChatMessage(id: messageId, role: .assistant, content: ""))
        case let .reasoningDelta(messageId, delta, elapsedSec):
            if let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) {
                let prev = sessions[sIdx].messages[mIdx].reasoningContent ?? ""
                sessions[sIdx].messages[mIdx].reasoningContent = prev + delta
                sessions[sIdx].messages[mIdx].reasoningDurationSec = elapsedSec
                activeStageText = String(format: "思考 %.1fs", elapsedSec)
            }
        case let .contentDelta(messageId, delta):
            if let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) {
                sessions[sIdx].messages[mIdx].content += delta
                activeStageText = "回复中"
            }
        case let .usageUpdated(messageId, usage):
            if let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) {
                sessions[sIdx].messages[mIdx].usage = usage
            }
        case let .assistantToolCalls(messageId, calls):
            if let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) {
                sessions[sIdx].messages[mIdx].toolCalls = calls
                let names = calls.map(\.name).joined(separator: ", ")
                activeStageText = names
                onLiveActivityUpdate?("运行 \(names)", true)
            }
        case let .approvalRequired(pending):
            pendingApproval = pending
            activeStageText = "待确认"
            onLiveActivityUpdate?("待确认：\(pending.call.name)", true)
        case let .toolCompleted(toolMsg):
            sessions[sIdx].messages.append(toolMsg)
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
