import Foundation
import Testing
@testable import DeepSeekCore

@Suite("DeepSeekCore Security, Engine & Protocol Tests")
struct DeepSeekCoreTests {

    @Test("Zero-Telemetry Firewall blocks banned tracker & unapproved hosts while redacting secrets")
    func privacyFirewallBlocksTelemetryAndRedactsTokens() async throws {
        let firewall = PrivacyFirewall()
        await firewall.setAllowedModelBaseURL(URL(string: "https://api.deepseek.com/v1")!)

        // 1. Allowed model request passes
        let okReq = URLRequest(url: URL(string: "https://api.deepseek.com/v1/chat/completions")!)
        try await firewall.authorize(okReq, purpose: .modelInference)
        await firewall.recordCompleted(request: okReq, purpose: .modelInference, statusCode: 200, bytesReceived: 512, durationMs: 42)

        // 2. Third-party telemetry / relay domains (`go.dshtui.com`, `dsh.r2049.cn`) are hard-blocked
        let telemetryReq = URLRequest(url: URL(string: "https://go.dshtui.com/usage?token=secret123")!)
        await #expect(throws: PrivacyFirewallError.self) {
            try await firewall.authorize(telemetryReq, purpose: .userApprovedWebFetch)
        }

        let relayReq = URLRequest(url: URL(string: "https://dsh.r2049.cn/api/pair?key=abc")!)
        await #expect(throws: PrivacyFirewallError.self) {
            try await firewall.authorize(relayReq, purpose: .remoteDshHost)
        }

        // 3. Audit trail records blocked attempts and redacts query tokens
        let log = await firewall.snapshot()
        #expect(log.count == 3)
        #expect(log.filter(\.wasBlocked).count == 2)
        #expect(!log.description.contains("secret123"))
        #expect(log.contains { $0.path.contains("token=[REDACTED]") })
    }

    @Test("SSE parser assembles DeepSeek R1 reasoning, content, multi-chunk tool calls & KV cache hit stats")
    func sseParserHandlesReasonerAndToolCalls() {
        var assembler = SSECompletionAssembler()
        let lines = [
            #"data: {"choices":[{"delta":{"reasoning_content":"先检查"}}]}"#,
            #"data: {"choices":[{"delta":{"reasoning_content":"工作区文件"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"正在读取配置..."}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_01","function":{"name":"read_","arguments":"{\"pa"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"file","arguments":"th\":\"README.md\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":120,"prompt_cache_hit_tokens":800,"prompt_cache_miss_tokens":200,"completion_tokens_details":{"reasoning_tokens":50}}}"#,
            "data: [DONE]"
        ]

        var reasoning = ""
        var content = ""
        var calls: [ToolCallRequest] = []
        var usage: TokenUsage?

        for line in lines {
            for delta in assembler.feed(line: line) {
                switch delta {
                case let .reasoning(r): reasoning += r
                case let .content(c): content += c
                case let .toolCalls(tc): calls = tc
                case let .usage(u): usage = u
                }
            }
        }

        #expect(reasoning == "先检查工作区文件")
        #expect(content == "正在读取配置...")
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_01")
        #expect(calls[0].name == "read_file")
        #expect(calls[0].argumentsJSON == #"{"path":"README.md"}"#)
        #expect(usage?.cacheHitTokens == 800)
        #expect(usage?.reasoningTokens == 50)
        #expect(usage?.cacheHitRatio == 0.8)
    }

    @Test("DeepSeek R1 payload preserves reasoning_content only inside active tool-call turn")
    func reasonerPayloadFollowsDeepSeekR1Contract() {
        let config = ProviderConfig(model: "deepseek-reasoner")
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "第一轮问题"),
            ChatMessage(
                role: .assistant,
                content: "第一轮回答",
                reasoningContent: "旧思考不应重发",
                toolCalls: [ToolCallRequest(id: "old", name: "list_files", argumentsJSON: "{}")]
            ),
            ChatMessage(role: .user, content: "第二轮问题"),
            ChatMessage(
                role: .assistant,
                content: "",
                reasoningContent: "当前回合思考必须保留",
                toolCalls: [ToolCallRequest(id: "cur", name: "read_file", argumentsJSON: #"{"path":"a.txt"}"#)]
            ),
            ChatMessage(
                role: .tool,
                content: "hello",
                toolOutput: ToolExecutionOutput(toolCallId: "cur", toolName: "read_file", content: "hello")
            )
        ]

        let payload = DeepSeekClient.buildRequestPayload(config: config, messages: messages, tools: [])
        let wire = payload["messages"] as? [[String: Any]] ?? []
        #expect(wire.count == 5)
        #expect(wire[1]["reasoning_content"] == nil)
        #expect(wire[3]["reasoning_content"] as? String == "当前回合思考必须保留")
        #expect(payload["temperature"] == nil)
    }

    @Test("Sandboxed WorkspaceToolset blocks ../ escape, generates unified diffs, and runs isolated JS")
    func workspaceSandboxAndTools() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dsgo-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tools = WorkspaceToolset(rootURL: tempDir)
        let firewall = PrivacyFirewall()

        // 1. Escape blocked
        #expect(throws: WorkspaceSandboxError.self) {
            _ = try tools.resolveSafeURL("../../etc/passwd")
        }
        #expect(throws: WorkspaceSandboxError.self) {
            _ = try tools.resolveSafeURL("/etc/hosts")
        }

        // 2. Write + Edit + Unified Diff
        let writeOut = await tools.execute(
            ToolCallRequest(id: "1", name: "write_file", argumentsJSON: #"{"path":"src/app.swift","content":"let a = 1\nlet b = 2"}"#),
            firewall: firewall
        )
        #expect(!writeOut.isError)
        #expect(writeOut.unifiedDiff?.contains("+ let a = 1") == true)

        let editOut = await tools.execute(
            ToolCallRequest(id: "2", name: "edit_file", argumentsJSON: #"{"path":"src/app.swift","old_text":"let b = 2","new_text":"let b = 42"}"#),
            firewall: firewall
        )
        #expect(!editOut.isError)
        #expect(editOut.unifiedDiff?.contains("- let b = 2") == true)
        #expect(editOut.unifiedDiff?.contains("+ let b = 42") == true)

        // 3. JavaScriptCore sandboxed eval
        let jsOut = await tools.execute(
            ToolCallRequest(id: "3", name: "run_javascript", argumentsJSON: #"{"code":"console.log('sum'); [1,2,3,4].reduce((a,b)=>a+b, 0)"}"#),
            firewall: firewall
        )
        #expect(!jsOut.isError)
        #expect(jsOut.content.contains("sum"))
        #expect(jsOut.content.contains("=> 10"))
    }

    @Test("AgentHarness executes multi-step tools, pauses on approval gate, and consumes Mid-Turn Steer")
    func agentHarnessApprovalAndSteer() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dsgo-agent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        actor MockTransport: ModelStreamingTransport {
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
                        let current = await nextStep()
                        if current == 1 {
                            continuation.yield(.reasoning("准备创建文件"))
                            continuation.yield(.toolCalls([
                                ToolCallRequest(id: "c1", name: "write_file", argumentsJSON: #"{"path":"note.md","content":"Hello"}"#)
                            ]))
                        } else {
                            let sawSteer = messages.contains { $0.isSteerInjection && $0.content.contains("改成中文总结") }
                            continuation.yield(.content(sawSteer ? "已按插话指令用中文完成总结。" : "Done"))
                        }
                        continuation.finish()
                    }
                }
            }
            private func nextStep() -> Int {
                step += 1
                return step
            }
        }

        let firewall = PrivacyFirewall()
        let harness = AgentHarness(
            transport: MockTransport(),
            toolset: WorkspaceToolset(rootURL: tempDir),
            firewall: firewall
        )

        let appended = try await harness.runTurn(
            history: [ChatMessage(role: .user, content: "帮我写个笔记")],
            config: ProviderConfig(),
            apiKey: "sk-test",
            approvalPolicy: .readOnlyAuto
        ) { event in
            if case let .approvalRequired(pending) = event {
                // Simulate user queuing a Mid-Turn Steer AND approving the write!
                await harness.enqueueSteer(SteerDirective(text: "顺便改成中文总结", mode: .nextStep))
                await harness.resolveApproval(callId: pending.call.id, approved: true)
            }
        }

        #expect(appended.contains { $0.role == .tool && $0.toolOutput?.isError == false })
        #expect(appended.contains { $0.isSteerInjection })
        #expect(appended.last?.content == "已按插话指令用中文完成总结。")
    }

    @Test("DshWebClient parses launch URLs, Set-Cookie headers, and Typert server-response envelopes")
    func dshWebWireProtocol() throws {
        let parsed = DshLaunchURL.parse("dsh web: http://192.168.1.20:3080/?token=tok_live_9988")
        #expect(parsed?.baseURI.absoluteString == "http://192.168.1.20:3080")
        #expect(parsed?.token == "tok_live_9988")

        let cookie = DshWebClient.parseAuthCookie(
            "dsh-auth-x9A2=v1.payload.sig; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict",
            authority: "192.168.1.20:3080"
        )
        #expect(cookie?.name == "dsh-auth-x9A2")
        #expect(cookie?.value == "v1.payload.sig")

        let responseJSON = #"{"type":"server-response","rpcId":"rpc-1","result":{"ok":true,"value":{"sessionId":"sess_42"}}}"#
        let value = try DshWebClient.decodeServerResponseEnvelope(
            data: Data(responseJSON.utf8),
            expectedRpcId: "rpc-1",
            endpoint: "session/create"
        ) as? [String: Any]
        #expect(value?["sessionId"] as? String == "sess_42")
    }

    @Test("AX workspaceSummary injects live file index and deepseekpocket://setup parses cleanly")
    func axWorkspaceIndexAndPocketScheme() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dspocket-ax-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tools = WorkspaceToolset(rootURL: tempDir)
        let firewall = PrivacyFirewall()
        _ = await tools.execute(
            ToolCallRequest(id: "w1", name: "write_file", argumentsJSON: #"{"path":"docs/spec.md","content":"ok"}"#),
            firewall: firewall
        )
        #expect(tools.workspaceSummary() == "docs/spec.md")

        let url = try #require(URL(string: "deepseekpocket://setup?base=https://gw.example.com/v1&model=deepseek-reasoner"))
        let parsed = try #require(SetupLink.parse(url))
        #expect(parsed.baseURL.absoluteString == "https://gw.example.com/v1")
        #expect(parsed.model == "deepseek-reasoner")
    }
}
