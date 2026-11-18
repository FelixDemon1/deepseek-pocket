import Foundation

public enum AgentEvent: Sendable {
    case assistantStarted(messageId: UUID)
    case reasoningDelta(messageId: UUID, delta: String, elapsedSec: Double)
    case contentDelta(messageId: UUID, delta: String)
    case usageUpdated(messageId: UUID, usage: TokenUsage)
    case assistantToolCalls(messageId: UUID, calls: [ToolCallRequest])
    case approvalRequired(PendingToolApproval)
    case toolCompleted(ChatMessage)
    case steerConsumed(SteerDirective, injectedMessage: ChatMessage)
    case turnCompleted
}

/// Coordinates multi-step Agent execution, Mid-Turn Steer Queue ("插话纠偏"), and Interactive Safety Approvals.
public actor AgentHarness {
    public static let defaultSystemPrompt = """
    你是 DeepSeek Go（iOS 原生满血双核 Agent）。你运行在用户 iPhone 本机的零遥测安全沙盒内。
    - 需要读写项目代码或文档时，优先使用 list_files / read_file / edit_file / write_file。
    - 需要精准计算或处理数据时，调用 run_javascript。
    - 需要展示可视化图表、架构图或交互小工具时，调用 render_artifact（支持 html / svg / mermaid）。
    - 回答保持精炼、直接、高信息密度。
    """

    private let transport: ModelStreamingTransport
    private let toolset: WorkspaceToolset
    private let firewall: PrivacyFirewall
    private var steerQueue: [SteerDirective] = []
    private var approvalWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    private let maxSteps: Int

    public init(
        transport: ModelStreamingTransport = DeepSeekClient(),
        toolset: WorkspaceToolset = WorkspaceToolset(),
        firewall: PrivacyFirewall,
        maxSteps: Int = 12
    ) {
        self.transport = transport
        self.toolset = toolset
        self.firewall = firewall
        self.maxSteps = maxSteps
    }

    public func enqueueSteer(_ directive: SteerDirective) {
        steerQueue.append(directive)
    }

    public func pendingSteers() -> [SteerDirective] {
        steerQueue
    }

    public func resolveApproval(callId: String, approved: Bool) {
        if let waiter = approvalWaiters.removeValue(forKey: callId) {
            waiter.resume(returning: approved)
        }
    }

    public func runTurn(
        history: [ChatMessage],
        config: ProviderConfig,
        apiKey: String,
        approvalPolicy: ApprovalPolicy,
        onEvent: @Sendable @escaping (AgentEvent) async -> Void
    ) async throws -> [ChatMessage] {
        var workingHistory = history
        if !workingHistory.contains(where: { $0.role == .system }) {
            workingHistory.insert(ChatMessage(role: .system, content: Self.defaultSystemPrompt), at: 0)
        }

        var newlyAppended: [ChatMessage] = []

        for _ in 0..<maxSteps {
            try Task.checkCancellation()

            // Drain any queued Mid-Turn Steer messages before starting the next model step!
            while !steerQueue.isEmpty {
                let directive = steerQueue.removeFirst()
                let steerMsg = ChatMessage(role: .user, content: directive.text, isSteerInjection: true)
                workingHistory.append(steerMsg)
                newlyAppended.append(steerMsg)
                await onEvent(.steerConsumed(directive, injectedMessage: steerMsg))
            }

            let assistantId = UUID()
            await onEvent(.assistantStarted(messageId: assistantId))

            var reasoning = ""
            var content = ""
            var calls: [ToolCallRequest] = []
            var usage: TokenUsage?
            var reasoningStartedAt: ContinuousClock.Instant?
            var reasoningElapsedSec: Double?

            let stream = transport.streamChatCompletion(
                config: config,
                apiKey: apiKey,
                messages: workingHistory,
                includeWorkspaceTools: config.enableTools,
                firewall: firewall
            )

            for try await delta in stream {
                try Task.checkCancellation()

                // Check if an immediate interrupt steer arrived mid-stream!
                if let urgentIdx = steerQueue.firstIndex(where: { $0.mode == .interruptNow }) {
                    let urgent = steerQueue.remove(at: urgentIdx)
                    let partialMsg = ChatMessage(
                        id: assistantId,
                        role: .assistant,
                        content: content.isEmpty ? "（已响应你的实时打断，切换新方向）" : content,
                        reasoningContent: reasoning.isEmpty ? nil : reasoning,
                        reasoningDurationSec: reasoningElapsedSec
                    )
                    workingHistory.append(partialMsg)
                    newlyAppended.append(partialMsg)

                    let steerMsg = ChatMessage(role: .user, content: urgent.text, isSteerInjection: true)
                    workingHistory.append(steerMsg)
                    newlyAppended.append(steerMsg)
                    await onEvent(.steerConsumed(urgent, injectedMessage: steerMsg))
                    calls = [ToolCallRequest(id: "__interrupt__", name: "__continue__", argumentsJSON: "{}")]
                    break
                }

                switch delta {
                case let .reasoning(chunk):
                    if reasoningStartedAt == nil {
                        reasoningStartedAt = ContinuousClock.now
                    }
                    reasoning += chunk
                    let sec = Self.seconds(since: reasoningStartedAt!)
                    reasoningElapsedSec = sec
                    await onEvent(.reasoningDelta(messageId: assistantId, delta: chunk, elapsedSec: sec))
                case let .content(chunk):
                    content += chunk
                    await onEvent(.contentDelta(messageId: assistantId, delta: chunk))
                case let .toolCalls(emitted):
                    calls = emitted
                    await onEvent(.assistantToolCalls(messageId: assistantId, calls: emitted))
                case let .usage(u):
                    usage = u
                    await onEvent(.usageUpdated(messageId: assistantId, usage: u))
                }
            }

            if calls.first?.id == "__interrupt__" {
                continue
            }

            let assistantMsg = ChatMessage(
                id: assistantId,
                role: .assistant,
                content: content,
                reasoningContent: reasoning.isEmpty ? nil : reasoning,
                reasoningDurationSec: reasoningElapsedSec,
                toolCalls: calls,
                usage: usage
            )
            workingHistory.append(assistantMsg)
            newlyAppended.append(assistantMsg)

            guard !calls.isEmpty else {
                // Before finishing, check if the user queued a `nextStep` steer while the final answer was streaming!
                if !steerQueue.isEmpty {
                    continue
                }
                await onEvent(.turnCompleted)
                return newlyAppended
            }

            for call in calls {
                try Task.checkCancellation()
                if let approval = toolset.requiresApproval(call, policy: approvalPolicy) {
                    let allowed = await requestAndWaitForApproval(approval, onEvent: onEvent)
                    if !allowed {
                        let rejectedOutput = ToolExecutionOutput(
                            toolCallId: call.id,
                            toolName: call.name,
                            content: "用户拒绝了本次工具操作（\(approval.summary)）。请尊重用户边界并调整方案。",
                            isError: true
                        )
                        let toolMsg = ChatMessage(role: .tool, content: rejectedOutput.content, toolOutput: rejectedOutput)
                        workingHistory.append(toolMsg)
                        newlyAppended.append(toolMsg)
                        await onEvent(.toolCompleted(toolMsg))
                        continue
                    }
                }

                let output = await toolset.execute(call, firewall: firewall)
                let toolMsg = ChatMessage(role: .tool, content: output.content, toolOutput: output)
                workingHistory.append(toolMsg)
                newlyAppended.append(toolMsg)
                await onEvent(.toolCompleted(toolMsg))
            }
        }

        await onEvent(.turnCompleted)
        return newlyAppended
    }

    private func requestAndWaitForApproval(
        _ approval: PendingToolApproval,
        onEvent: @Sendable @escaping (AgentEvent) async -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            approvalWaiters[approval.call.id] = continuation
            Task {
                await onEvent(.approvalRequired(approval))
            }
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: ContinuousClock.now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
