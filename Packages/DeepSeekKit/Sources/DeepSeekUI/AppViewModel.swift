import Foundation
import Observation
import SwiftUI
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

    // Privacy, Workspace & Pro Entitlement
    public var auditEntries: [NetworkAuditEntry] = []
    public var allowlistInfo: (modelHosts: [String], remoteHosts: [String], webHosts: [String]) = ([], [], [])
    public var activeArtifact: ArtifactPayload?
    public var isProUnlocked: Bool = false

    public let firewall: PrivacyFirewall
    public let toolset: WorkspaceToolset
    public let proManager: ProEntitlementManager
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
        self.proManager = ProEntitlementManager()
        self.providerConfig = ProviderConfig()
        self.approvalPolicy = .readOnlyAuto
        self.requireFaceIDForApprovals = false
        self.engineMode = .onDeviceHarness
        self.isProUnlocked = proManager.isProUnlocked

        loadPersistedState()
        seedWelcomeWorkspaceIfNeeded()
        if sessions.isEmpty {
            let initial = ChatSession(title: "新对话", engineMode: .onDeviceHarness)
            sessions = [initial]
            activeSessionId = initial.id
        } else if activeSessionId == nil {
            activeSessionId = sessions.first?.id
        }

        Task {
            await firewall.setAllowedModelBaseURL(providerConfig.baseURL)
            await proManager.refreshEntitlements()
            self.isProUnlocked = proManager.isProUnlocked
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
        if engineMode == .remoteDshWeb { return "DSH Remote" }
        if m.contains("reasoner") || m.contains("r1") { return "DeepSeek R1" }
        if m.contains("chat") || m.contains("v3") { return "DeepSeek V3" }
        return providerConfig.model.components(separatedBy: "/").last ?? providerConfig.model
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
        noticeBanner = "已接入「\(link.name)」，点「同步模型」即可开始对话"
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

    public func selectPreset(_ preset: PromptPreset) -> Bool {
        if preset.isProOnly && !isProUnlocked {
            return false
        }
        previousPresetSnapshotId = activePresetId
        activePresetId = preset.id
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

    public func addCustomPreset(title: String, subtitle: String, systemPrompt: String) {
        let custom = PromptPreset(
            id: "custom_\(UUID().uuidString.prefix(8))",
            title: title,
            subtitle: subtitle.isEmpty ? "自定义工作流指令" : subtitle,
            icon: "slider.horizontal.below.rectangle",
            systemPrompt: systemPrompt,
            isProOnly: false
        )
        presets.append(custom)
        saveCustomPresets()
        _ = selectPreset(custom)
    }

    private func applyActivePresetToCurrentSession() {
        guard let idx = currentSessionIndex() else { return }
        if let sysIdx = sessions[idx].messages.firstIndex(where: { $0.role == .system }) {
            sessions[idx].messages[sysIdx].content = activePreset.systemPrompt
        } else {
            sessions[idx].messages.insert(ChatMessage(role: .system, content: activePreset.systemPrompt), at: 0)
        }
    }

    public func togglePreviewProUnlock(_ enabled: Bool) {
        proManager.setPreviewUnlock(enabled)
        isProUnlocked = proManager.isProUnlocked
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

    public func createNewSession() {
        let session = ChatSession(
            title: "新对话",
            engineMode: engineMode,
            messages: [ChatMessage(role: .system, content: activePreset.systemPrompt)]
        )
        sessions.insert(session, at: 0)
        activeSessionId = session.id
        persistSessions()
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

    private func runLocalHarnessTurn() {
        let key = (try? vault.loadSecret(for: Self.apiKeyAccount)) ?? ""
        let harness = AgentHarness(transport: DeepSeekClient(), toolset: toolset, firewall: firewall)
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
    }

    private func persistSettings() {
        let s = StoredSettings(
            provider: providerConfig,
            policy: approvalPolicy,
            faceID: requireFaceIDForApprovals,
            appearance: appearance,
            activePresetId: activePresetId
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
