import Foundation
import Testing
@testable import DeepSeekCore

@Suite("Lifecycle & Remote Spec Hardening")
struct LifecycleHardeningTests {

    // MARK: 停止生成

    /// 只吐一个工具调用的假模型：用来把回合卡在审批门上。
    struct ToolCallingTransport: ModelStreamingTransport {
        func streamChatCompletion(
            config: ProviderConfig,
            apiKey: String,
            messages: [ChatMessage],
            includeWorkspaceTools: Bool,
            firewall: PrivacyFirewall
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.toolCalls([
                    ToolCallRequest(id: "w1", name: "write_file", argumentsJSON: #"{"path":"a.md","content":"x"}"#)
                ]))
                continuation.finish()
            }
        }
    }

    /// 永不结束的假模型：模拟上游迟迟不回包。
    struct HangingTransport: ModelStreamingTransport {
        func streamChatCompletion(
            config: ProviderConfig,
            apiKey: String,
            messages: [ChatMessage],
            includeWorkspaceTools: Bool,
            firewall: PrivacyFirewall
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.content("半截"))
            }
        }
    }

    @Test("审批等待中点停止：回合以 CancellationError 结束，不会永久挂起")
    func cancelWhileAwaitingApproval() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dsgo-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let harness = AgentHarness(transport: ToolCallingTransport(), toolset: WorkspaceToolset(rootURL: dir), firewall: PrivacyFirewall())
        let approvalShown = AsyncStream<Void>.makeStream()

        let turn = Task {
            try await harness.runTurn(
                history: [ChatMessage(role: .user, content: "写文件")],
                config: ProviderConfig(),
                apiKey: "k",
                approvalPolicy: .readOnlyAuto
            ) { event in
                if case .approvalRequired = event { approvalShown.continuation.yield() }
            }
        }
        for await _ in approvalShown.stream { break }
        turn.cancel()
        await #expect(throws: CancellationError.self) { _ = try await turn.value }
    }

    @Test("流式中点停止：不会被当作正常完成")
    func cancelMidStreamThrows() async throws {
        let harness = AgentHarness(transport: HangingTransport(), firewall: PrivacyFirewall())
        let firstDelta = AsyncStream<Void>.makeStream()
        let turn = Task {
            try await harness.runTurn(
                history: [ChatMessage(role: .user, content: "hi")],
                config: ProviderConfig(),
                apiKey: "k",
                approvalPolicy: .readOnlyAuto
            ) { event in
                if case .contentDelta = event { firstDelta.continuation.yield() }
            }
        }
        for await _ in firstDelta.stream { break }
        turn.cancel()
        await #expect(throws: CancellationError.self) { _ = try await turn.value }
    }

    // MARK: 云端规格

    @Test("内置预设全部通过合法性校验")
    func presetsAreValid() {
        for spec in WebAdapterSpec.presets {
            #expect(spec.validationIssue == nil, "\(spec.id): \(spec.validationIssue ?? "")")
        }
    }

    @Test("坏规格会被拦下")
    func invalidSpecsRejected() {
        var badBody = WebAdapterSpec.deepSeekWeb
        badBody.bodyTemplate = #"{"prompt":"{{prompt}}""#
        #expect(badBody.validationIssue != nil)

        var badURL = WebAdapterSpec.doubaoWeb
        badURL.chatURL = "not a url"
        #expect(badURL.validationIssue != nil)

        var noModels = WebAdapterSpec.qwenWeb
        noModels.models = []
        #expect(noModels.validationIssue != nil)
    }

    @Test("云端合并：覆盖内置、缺席保留内置、丢弃坏条目、保留用户自定义")
    func mergingRemoteSpecs() {
        var remoteDeepSeek = WebAdapterSpec.deepSeekWeb
        remoteDeepSeek.notes = "cloud-v2"
        var broken = WebAdapterSpec.doubaoWeb
        broken.chatURL = "::bad"
        let extra = WebAdapterSpec(
            id: "web_new", name: "新渠道", loginURL: "https://new.example.com/",
            credentialKind: .cookie, credentialKey: "sid",
            chatURL: "https://new.example.com/api/chat", headers: [:],
            bodyTemplate: #"{"q":"{{prompt}}"}"#, responseMode: .sseOpenAI, models: ["m1"]
        )
        let custom = WebAdapterSpec(
            id: "custom_mine", name: "我的", loginURL: "https://mine.example.com/",
            credentialKind: .cookie, credentialKey: "sid",
            chatURL: "https://mine.example.com/chat", headers: [:],
            bodyTemplate: "{}", responseMode: .sseOpenAI, models: ["x"]
        )

        let merged = WebAdapterSpec.merging(
            remote: [remoteDeepSeek, broken, extra],
            into: WebAdapterSpec.presets + [custom]
        )
        #expect(merged.map(\.id) == ["web_deepseek", "web_doubao", "web_qwen", "web_new", "custom_mine"])
        #expect(merged.first?.notes == "cloud-v2")
        #expect(merged.first { $0.id == "web_doubao" } == WebAdapterSpec.doubaoWeb)
    }

    @Test("缺 id 的规格生成跨启动稳定的 id")
    func stableIDForPastedSpec() throws {
        let json = #"{"chat_url":"https://x.example.com/v1/chat","body_template":"{}"}"#
        let a = try JSONDecoder().decode(WebAdapterSpec.self, from: Data(json.utf8))
        let b = try JSONDecoder().decode(WebAdapterSpec.self, from: Data(json.utf8))
        #expect(a.id == b.id)
        #expect(a.id == WebAdapterSpec.stableID(for: "https://x.example.com/v1/chat"))
        #expect(a.id.hasPrefix("custom_"))
    }

    // MARK: 网关状态码

    @Test("402 / 429 / 401 翻译成可操作的人话")
    func friendlyGatewayErrors() {
        let quota = DeepSeekClientError.httpError(statusCode: 402, message: "本 IP 今日免费额度已用尽，明日 00:00 UTC 重置")
        #expect(quota.errorDescription?.contains("免费额度已用完") == true)
        #expect(quota.errorDescription?.contains("连接 AI") == true)

        let rate = DeepSeekClientError.httpError(statusCode: 429, message: "请求过于频繁，上限 20 次/分钟")
        #expect(rate.errorDescription?.contains("请求太快") == true)

        let global = DeepSeekClientError.httpError(statusCode: 429, message: "全站今日免费额度已用尽")
        #expect(global.errorDescription?.contains("额度暂时耗尽") == true)

        let auth = DeepSeekClientError.httpError(statusCode: 401, message: "invalid key")
        #expect(auth.errorDescription?.contains("重新粘贴 Key") == true)

        #expect(DeepSeekClient.extractAPIErrorMessage(#"{"error":{"message":"额度已用尽","type":"quota"}}"#) == "额度已用尽")
    }

    // MARK: 防火墙

    @Test("并发两个不同模型域名的请求不会互相挤掉白名单")
    func firewallAtomicAuthorize() async throws {
        let firewall = PrivacyFirewall()
        let a = URL(string: "https://api.deepseek.com/v1/chat/completions")!
        let b = URL(string: "https://chat.deepseek.com/api/v0/chat/completion")!
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                let url = i.isMultiple(of: 2) ? a : b
                group.addTask {
                    try await firewall.authorize(URLRequest(url: url), purpose: .modelInference, allowingModelBase: url)
                }
            }
            try await group.waitForAll()
        }
    }
}
