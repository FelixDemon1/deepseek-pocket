import Foundation
import Testing
@testable import DeepSeekCore

@Suite("Agent Capability (工具协议 / 迷你 Shell / 计划)")
struct AgentCapabilityTests {

    // MARK: 文本式工具调用协议

    private func run(_ chunks: [String]) -> (text: String, calls: [ToolCallRequest]) {
        var filter = ToolCallTextFilter()
        var text = ""
        for chunk in chunks { text += filter.feed(chunk) }
        let end = filter.finish()
        return (text + end.text, end.calls)
    }

    @Test("普通回答原样放行，含普通代码块也不误判")
    func plainAnswerPassesThrough() {
        let answer = "结论如下：\n```swift\nlet a = 1\n```\n完。"
        let out = run(answer.map(String.init))
        #expect(out.text == answer)
        #expect(out.calls.isEmpty)
    }

    @Test("工具代码块被截留并解析，标记被切在分片边界也不漏")
    func toolBlockAcrossChunkBoundaries() throws {
        let out = run(["我先看看文件。\n``", "`to", "ol\n{\"name\": \"read_", "file\", \"arguments\": {\"path\": \"a.md\"}}\n`", "``\n"])
        #expect(out.text == "我先看看文件。\n")
        let call = try #require(out.calls.first)
        #expect(call.name == "read_file")
        #expect(call.argumentsJSON == #"{"path":"a.md"}"#)
    }

    @Test("连续多个工具块都能取到；调用之后模型脑补的结果被丢弃")
    func multipleCallsAndHallucinatedTailDropped() {
        let text = """
        ```tool
        {"name": "list_files", "arguments": {}}
        ```
        ```tool
        {"name": "read_file", "arguments": {"path": "b.txt"}}
        ```
        工具结果：文件内容是 xxx（这是模型编的）
        """
        let out = run([text])
        #expect(out.calls.map(\.name) == ["list_files", "read_file"])
        #expect(out.text.isEmpty)
    }

    @Test("字符串里有裸换行和字面 ``` 的 write_file 也能修复解析")
    func rawNewlinesAndInnerFenceRepaired() throws {
        let text = "```tool\n{\"name\": \"write_file\", \"arguments\": {\"path\": \"README.md\", \"content\": \"# 标题\n\n```bash\nls\n```\n完\"}}\n```"
        let out = run([text])
        let call = try #require(out.calls.first)
        let args = try #require(try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        #expect(args["content"] as? String == "# 标题\n\n```bash\nls\n```\n完")
    }

    @Test("漏写收尾围栏时在流结束处补救；完全解析不了的内容不会被吞掉")
    func missingCloseFenceAndGarbage() {
        let recovered = run(["```tool\n{\"name\": \"run_shell\", \"arguments\": {\"command\": \"ls\"}}"])
        #expect(recovered.calls.first?.name == "run_shell")

        let garbage = run(["```tool\n这不是 JSON"])
        #expect(garbage.calls.isEmpty)
        #expect(garbage.text.contains("这不是 JSON"))
    }

    @Test("说明书覆盖全部工具；只有直连渠道开放工具")
    func manualAndChannelGate() {
        let manual = ToolCallTextProtocol.manual(schemas: WorkspaceToolset.toolSchemas)
        for schema in WorkspaceToolset.toolSchemas {
            let name = ((schema["function"] as? [String: Any])?["name"] as? String) ?? "?"
            #expect(manual.contains("- \(name)："), "说明书缺少 \(name)")
        }
        #expect(WebAdapterTransport.supportsTextTools(.deepSeekWeb))
        #expect(!WebAdapterTransport.supportsTextTools(.doubaoWeb))
        #expect(!WebAdapterTransport.supportsTextTools(.qwenWeb))
    }

    @Test("agent 形态的提示词带上任务、已执行步骤与工具结果")
    func agentFlattenCarriesSteps() {
        let call = ToolCallRequest(id: "c1", name: "read_file", argumentsJSON: #"{"path":"a.md"}"#)
        let messages = [
            ChatMessage(role: .system, content: "系统提示"),
            ChatMessage(role: .user, content: "上一个问题"),
            ChatMessage(role: .assistant, content: "上一个回答"),
            ChatMessage(role: .user, content: "总结 a.md"),
            ChatMessage(role: .assistant, content: "先读文件", toolCalls: [call]),
            ChatMessage(role: .tool, content: "   1 | hello", toolOutput: ToolExecutionOutput(toolCallId: "c1", toolName: "read_file", content: "   1 | hello"))
        ]
        let prompt = WebAdapterClient.flatten(messages, toolManual: "[可用工具]…")
        #expect(prompt.contains("[当前任务]\n总结 a.md"))
        #expect(prompt.contains("用户：上一个问题"))
        #expect(prompt.contains(#"{"name": "read_file", "arguments": {"path":"a.md"}}"#))
        #expect(prompt.contains("工具结果（read_file，成功）：\n   1 | hello"))
        #expect(prompt.contains("[下一步]"))
        // 不带说明书时保持原有纯聊天形态
        #expect(WebAdapterClient.flatten([ChatMessage(role: .user, content: "你好")]) == "你好")
    }

    /// 只会输出文本的假网页模型：第一步发工具块，拿到结果后给最终回答。
    struct TextOnlyModel: ModelStreamingTransport {
        func streamChatCompletion(
            config: ProviderConfig,
            apiKey: String,
            messages: [ChatMessage],
            includeWorkspaceTools: Bool,
            firewall: PrivacyFirewall
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            let toolResult = messages.last(where: { $0.role == .tool })?.content
            let raw = AsyncThrowingStream<StreamDelta, Error> { continuation in
                if let toolResult {
                    continuation.yield(.content("文件里写的是：\(toolResult.contains("hello") ? "hello" : "?")"))
                } else {
                    continuation.yield(.content("我来读一下。\n```tool\n{\"name\": \"read_file\","))
                    continuation.yield(.content(" \"arguments\": {\"path\": \"note.md\"}}\n```"))
                }
                continuation.finish()
            }
            return ToolCallTextProtocol.wrap(raw)
        }
    }

    @Test("端到端：纯文本模型经协议驱动 Harness 真正执行工具并给出最终回答")
    func textProtocolDrivesHarness() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dsgo-textproto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello".utf8).write(to: dir.appendingPathComponent("note.md"))

        let harness = AgentHarness(transport: TextOnlyModel(), toolset: WorkspaceToolset(rootURL: dir), firewall: PrivacyFirewall())
        let appended = try await harness.runTurn(
            history: [ChatMessage(role: .user, content: "note.md 里写了什么")],
            config: ProviderConfig(),
            apiKey: "",
            approvalPolicy: .readOnlyAuto
        ) { _ in }

        #expect(appended.first?.content == "我来读一下。\n")
        #expect(appended.first?.toolCalls.first?.name == "read_file")
        #expect(appended.contains { $0.role == .tool && $0.toolOutput?.isError == false })
        #expect(appended.last?.content == "文件里写的是：hello")
    }

    // MARK: 迷你 Shell

    private func makeWorkspace() throws -> (toolset: WorkspaceToolset, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dsgo-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("apple\nbanana\nTODO: cherry\napple\n".utf8).write(to: dir.appendingPathComponent("fruits.txt"))
        try Data("let a = 1 // TODO: rename\nlet b = 2\n".utf8).write(to: dir.appendingPathComponent("src/main.swift"))
        try Data("# 说明\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        return (WorkspaceToolset(rootURL: dir), { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("只读命令：ls / cat / head / wc / grep -rn / find / 管道 / 通配符")
    func shellReadOnlyCommands() throws {
        let (toolset, cleanup) = try makeWorkspace()
        defer { cleanup() }
        let shell = MiniShell(toolset: toolset)

        #expect(shell.run("ls").output == "README.md\nfruits.txt\nsrc/")
        #expect(shell.run("cat fruits.txt | head -n 2").output == "apple\nbanana")
        #expect(shell.run("wc -l fruits.txt").output == "4 fruits.txt")
        #expect(shell.run("grep -rn TODO .").output == "fruits.txt:3:TODO: cherry\nsrc/main.swift:1:let a = 1 // TODO: rename")
        #expect(shell.run("find . -name '*.swift'").output == "./src/main.swift")
        #expect(shell.run("cat fruits.txt | sort | uniq -c").output == "1 TODO: cherry\n2 apple\n1 banana")
        #expect(shell.run("ls *.md").output == "README.md")
        #expect(shell.run("cd src && pwd && ls").output == "/workspace/src\nmain.swift")

        let miss = shell.run("grep nothing fruits.txt")
        #expect(miss.exitCode == 1)
        #expect(miss.output.isEmpty)
    }

    @Test("写命令：mkdir / 重定向 / cp / mv / rm，且 && 在失败后短路")
    func shellMutatingCommands() throws {
        let (toolset, cleanup) = try makeWorkspace()
        defer { cleanup() }
        let shell = MiniShell(toolset: toolset)

        #expect(shell.run("mkdir -p notes/2026 && echo \"第一行\" > notes/2026/a.txt && echo 第二行 >> notes/2026/a.txt").exitCode == 0)
        #expect(shell.run("cat notes/2026/a.txt").output == "第一行\n第二行")
        #expect(shell.run("cp fruits.txt notes && mv notes/fruits.txt notes/f.txt && ls notes").output == "2026/\nf.txt")
        #expect(shell.run("rm notes").exitCode == 1)
        #expect(shell.run("rm -r notes && ls").output == "README.md\nfruits.txt\nsrc/")

        let chained = shell.run("cat missing.txt && echo 不该出现")
        #expect(chained.exitCode == 1)
        #expect(!chained.output.contains("不该出现"))
    }

    @Test("出不了工作区：绝对路径、../ 越界、删除根目录、未知命令都被拒绝")
    func shellStaysInsideWorkspace() throws {
        let (toolset, cleanup) = try makeWorkspace()
        defer { cleanup() }
        let shell = MiniShell(toolset: toolset)

        #expect(shell.run("cat /etc/passwd").exitCode != 0)
        #expect(shell.run("cat ../../etc/passwd").exitCode != 0)
        #expect(shell.run("echo x > ../escape.txt").exitCode != 0)
        #expect(shell.run("rm -rf .").exitCode != 0)
        #expect(shell.run("cd .. && ls").exitCode != 0)
        #expect(shell.run("curl https://example.com").exitCode == 127)
        #expect(shell.run("echo 'oops").exitCode == 2)
        #expect(FileManager.default.fileExists(atPath: toolset.rootURL.appendingPathComponent("fruits.txt").path))
    }

    @Test("审批：只读命令自动放行，写命令与重定向要确认，计划永不打断")
    func approvalRulesForNewTools() throws {
        let (toolset, cleanup) = try makeWorkspace()
        defer { cleanup() }
        func shellCall(_ command: String) -> ToolCallRequest {
            let data = try! JSONSerialization.data(withJSONObject: ["command": command])
            return ToolCallRequest(id: "s", name: "run_shell", argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(toolset.requiresApproval(shellCall("ls -la | head"), policy: .readOnlyAuto) == nil)
        #expect(toolset.requiresApproval(shellCall("grep -rn TODO ."), policy: .readOnlyAuto) == nil)
        #expect(toolset.requiresApproval(shellCall("rm -r src"), policy: .readOnlyAuto)?.summary == "执行命令 $ rm -r src")
        #expect(toolset.requiresApproval(shellCall("echo hi > a.txt"), policy: .readOnlyAuto) != nil)
        #expect(toolset.requiresApproval(shellCall("ls && mv a b"), policy: .readOnlyAuto) != nil)
        #expect(toolset.requiresApproval(shellCall("echo 'unterminated"), policy: .readOnlyAuto) != nil)
        #expect(toolset.requiresApproval(shellCall("rm -r src"), policy: .fullSandboxAuto) == nil)

        let plan = ToolCallRequest(id: "p", name: "update_plan", argumentsJSON: #"{"steps":[{"title":"a","status":"pending"}]}"#)
        #expect(toolset.requiresApproval(plan, policy: .askEveryTool) == nil)
    }

    @Test("run_shell 与 update_plan 经工具层执行：退出码映射成成功/失败")
    func newToolsExecuteThroughToolset() async throws {
        let (toolset, cleanup) = try makeWorkspace()
        defer { cleanup() }
        let firewall = PrivacyFirewall()

        let ok = await toolset.execute(ToolCallRequest(id: "1", name: "run_shell", argumentsJSON: #"{"command":"wc -l fruits.txt"}"#), firewall: firewall)
        #expect(ok.content == "4 fruits.txt")
        #expect(!ok.isError)

        let failed = await toolset.execute(ToolCallRequest(id: "2", name: "run_shell", argumentsJSON: #"{"command":"cat nope.txt"}"#), firewall: firewall)
        #expect(failed.isError)

        let plan = await toolset.execute(
            ToolCallRequest(id: "3", name: "update_plan", argumentsJSON: #"{"steps":[{"title":"看文件","status":"done"},{"title":"写总结","status":"in_progress"},{"title":"收尾","status":"pending"}]}"#),
            firewall: firewall
        )
        #expect(plan.content == "计划已更新：1/3 步完成，当前：写总结")

        let empty = await toolset.execute(ToolCallRequest(id: "4", name: "update_plan", argumentsJSON: #"{"steps":[]}"#), firewall: firewall)
        #expect(empty.isError)
    }

    // MARK: 展示

    @Test("工具调用翻译成一行人话，命令类带终端命令行")
    func toolPresentationLines() {
        let shell = ToolPresentation.describe(ToolCallRequest(id: "1", name: "run_shell", argumentsJSON: #"{"command":"grep -rn TODO . | head"}"#))
        #expect(shell.verb == "运行")
        #expect(shell.detail == "grep -rn TODO . | head")
        #expect(shell.isCommand)

        let read = ToolPresentation.describe(ToolCallRequest(id: "2", name: "read_file", argumentsJSON: #"{"path":"账单-10月.csv"}"#))
        #expect(read.verb == "读取")
        #expect(read.detail == "账单-10月.csv")
        #expect(read.commandLine == "cat 账单-10月.csv")

        let write = ToolPresentation.describe(ToolCallRequest(id: "3", name: "write_file", argumentsJSON: #"{"path":"a.md","content":"x"}"#))
        #expect(write.verb == "写入")
        #expect(!write.isCommand)

        let plan = ToolPresentation.describe(ToolCallRequest(id: "4", name: "update_plan", argumentsJSON: #"{"steps":[{"title":"a","status":"completed"},"b"]}"#))
        #expect(plan.detail == "1/2 步完成")

        #expect(ToolPresentation.describe(ToolCallRequest(id: "5", name: "mystery", argumentsJSON: "not json")).verb == "调用")
    }

    @Test("Diff 统计不把文件头算进增删行")
    func diffStatCountsBodyOnly() {
        let diff = WorkspaceToolset.unifiedDiff(path: "a.txt", oldText: "1\n2\n3", newText: "1\n二\n3\n4")
        let stat = DiffStat.count(diff)
        #expect(stat.added == 2)
        #expect(stat.removed == 1)
    }

    @Test("旧版本存下的消息（没有 turnDurationSec 字段）仍能解码")
    func legacyMessagesStillDecode() throws {
        let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","content":"hi","toolCalls":[],"isSteerInjection":false,"createdAt":0}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
        #expect(message.content == "hi")
        #expect(message.turnDurationSec == nil)
    }

    // MARK: 轨迹

    @Test("时间线以用户消息为界分轮；纯聊天轮不产生轨迹")
    func timelineGroupsTurns() {
        let messages = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "你好"),
            ChatMessage(role: .assistant, content: "你好！", reasoningContent: "打个招呼"),
            ChatMessage(role: .user, content: "整理文件")
        ]
        let items = ChatTimelineItem.build(from: messages)
        #expect(items.count == 3)
        guard case let .turn(_, group) = items[1] else {
            Issue.record("第二项应该是一轮助手执行")
            return
        }
        let turn = AgentTurn(messages: group)
        #expect(!turn.hasToolCalls)
        #expect(turn.steps.isEmpty)
        #expect(turn.finalMessage?.content == "你好！")
    }

    @Test("agent 轮：思考 / 说明 / 工具步骤按序展开，计划取最新，文件改动与页脚汇总")
    func agentTurnTrajectory() {
        let planA = ToolCallRequest(id: "p1", name: "update_plan", argumentsJSON: #"{"steps":[{"title":"看","status":"in_progress"},{"title":"写","status":"pending"}]}"#)
        let shell = ToolCallRequest(id: "t1", name: "run_shell", argumentsJSON: #"{"command":"ls"}"#)
        let planB = ToolCallRequest(id: "p2", name: "update_plan", argumentsJSON: #"{"steps":[{"title":"看","status":"done"},{"title":"写","status":"in_progress"}]}"#)
        let write = ToolCallRequest(id: "t2", name: "write_file", argumentsJSON: #"{"path":"out/sum.md","content":"a\nb"}"#)
        let diff = WorkspaceToolset.unifiedDiff(path: "out/sum.md", oldText: "", newText: "a\nb")
        var final = ChatMessage(role: .assistant, content: "做好了。", usage: TokenUsage(promptTokens: 9000, completionTokens: 3000))
        final.turnDurationSec = 23.4
        let group = [
            ChatMessage(role: .assistant, content: "先看看有什么。", reasoningContent: "得先列目录", reasoningDurationSec: 1.2,
                        toolCalls: [planA, shell], usage: TokenUsage(promptTokens: 20000, completionTokens: 2000)),
            ChatMessage(role: .tool, content: "计划已更新", toolOutput: ToolExecutionOutput(toolCallId: "p1", toolName: "update_plan", content: "计划已更新")),
            ChatMessage(role: .tool, content: "a.txt", toolOutput: ToolExecutionOutput(toolCallId: "t1", toolName: "run_shell", content: "a.txt", durationMs: 3)),
            ChatMessage(role: .assistant, content: "", toolCalls: [planB, write]),
            ChatMessage(role: .tool, content: "已写入", toolOutput: ToolExecutionOutput(toolCallId: "t2", toolName: "write_file", content: "已写入", unifiedDiff: diff)),
            final
        ]
        let turn = AgentTurn(messages: group)

        #expect(turn.hasToolCalls)
        #expect(turn.actionCount == 2)
        #expect(turn.steps.map(\.id).count == 4)
        if case let .thinking(text, seconds) = turn.steps[0].kind {
            #expect(text == "得先列目录")
            #expect(seconds == 1.2)
        } else { Issue.record("第一步应是思考") }
        #expect(turn.steps[1].kind == .note("先看看有什么。"))
        if case let .tool(call, output) = turn.steps[2].kind {
            #expect(call.id == "t1")
            #expect(output?.content == "a.txt")
        } else { Issue.record("第三步应是命令") }
        #expect(turn.plan.map(\.status) == [.done, .inProgress])
        #expect(turn.changedFiles == [AgentChangedFile(path: "out/sum.md", added: 2, removed: 0, diff: diff)])
        #expect(turn.finalMessage?.content == "做好了。")
        #expect(turn.footnote == "23 秒 · 3 步 · 3.4 万 tokens")
    }

    @Test("进行中的一轮（最后一条还在等工具结果）没有最终回答，工具输出为空")
    func liveTurnHasNoFinalAnswer() {
        let shell = ToolCallRequest(id: "t1", name: "run_shell", argumentsJSON: #"{"command":"ls"}"#)
        let turn = AgentTurn(messages: [ChatMessage(role: .assistant, content: "", toolCalls: [shell])])
        #expect(turn.finalMessage == nil)
        if case let .tool(_, output) = turn.steps.first?.kind {
            #expect(output == nil)
        } else { Issue.record("应有一条运行中的命令") }
    }

    // MARK: 手机动作

    @Test("手机动作在任何审批策略下都要确认，摘要说清要做什么")
    func deviceActionsAlwaysNeedApproval() {
        let toolset = WorkspaceToolset(rootURL: FileManager.default.temporaryDirectory)
        let reminder = ToolCallRequest(id: "r", name: "create_reminder", argumentsJSON: #"{"title":"买牛奶","due":"2026-11-21 09:00"}"#)
        let open = ToolCallRequest(id: "o", name: "open_url", argumentsJSON: #"{"url":"tel:10086"}"#)
        for policy in ApprovalPolicy.allCases {
            #expect(toolset.requiresApproval(reminder, policy: policy)?.summary == "新建提醒事项「买牛奶」 · 2026-11-21 09:00")
            #expect(toolset.requiresApproval(open, policy: policy)?.summary == "打开 tel:10086（会离开本 App）")
        }
        #expect(ToolPresentation.describe(reminder).verb == "提醒")
        #expect(ToolPresentation.describe(open).detail == "tel:")
    }

    @Test("时间解析：常见写法都按本机时区理解，只给日期按上午 9 点")
    func deviceDateParsing() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func parts(_ raw: String) -> [Int]? {
            DeviceTools.parseDate(raw, calendar: calendar).map {
                let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
                return [c.year!, c.month!, c.day!, c.hour!, c.minute!]
            }
        }
        #expect(parts("2026-11-21 09:30") == [2026, 11, 21, 9, 30])
        #expect(parts("2026-11-21T15:00") == [2026, 11, 21, 15, 0])
        #expect(parts("2026-11-21T15:00:00") == [2026, 11, 21, 15, 0])
        #expect(parts("2026-11-21") == [2026, 11, 21, 9, 0])
        #expect(parts("2026-11-21T07:00:00Z") == [2026, 11, 21, 15, 0])
        #expect(parts("明天上午") == nil)
    }

    @Test("参数不对时在碰系统接口之前就报错，并告诉模型正确写法")
    func deviceActionValidation() async {
        let toolset = WorkspaceToolset(rootURL: FileManager.default.temporaryDirectory)
        let firewall = PrivacyFirewall()
        let noTitle = await toolset.execute(ToolCallRequest(id: "1", name: "create_reminder", argumentsJSON: "{}"), firewall: firewall)
        #expect(noTitle.isError)
        let badTime = await toolset.execute(
            ToolCallRequest(id: "2", name: "create_calendar_event", argumentsJSON: #"{"title":"开会","start":"明天下午三点"}"#),
            firewall: firewall
        )
        #expect(badTime.isError)
        #expect(badTime.content.contains("2026-11-21 09:00"))
        let badURL = await toolset.execute(ToolCallRequest(id: "3", name: "open_url", argumentsJSON: #"{"url":"javascript:alert(1)"}"#), firewall: firewall)
        #expect(badURL.isError)
    }

    /// 记录收到的系统提示词，然后直接结束。
    actor PromptRecorder: ModelStreamingTransport {
        var systemPrompt = ""
        nonisolated func streamChatCompletion(
            config: ProviderConfig,
            apiKey: String,
            messages: [ChatMessage],
            includeWorkspaceTools: Bool,
            firewall: PrivacyFirewall
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    await self.record(messages.first { $0.role == .system }?.content ?? "")
                    continuation.yield(.content("ok"))
                    continuation.finish()
                }
            }
        }
        private func record(_ text: String) { systemPrompt = text }
    }

    @Test("Harness 把当前时间告诉模型；纯聊天网页渠道发出去之前会把它剥掉")
    func deviceContextInjectedAndStripped() async throws {
        let recorder = PromptRecorder()
        let harness = AgentHarness(transport: recorder, toolset: WorkspaceToolset(rootURL: FileManager.default.temporaryDirectory), firewall: PrivacyFirewall())
        _ = try await harness.runTurn(
            history: [ChatMessage(role: .user, content: "明天九点提醒我开会")],
            config: ProviderConfig(), apiKey: "", approvalPolicy: .readOnlyAuto
        ) { _ in }
        let prompt = await recorder.systemPrompt
        #expect(prompt.contains("<device_context>现在是 20"))

        let flattened = WebAdapterClient.flatten([
            ChatMessage(role: .system, content: prompt),
            ChatMessage(role: .user, content: "你好")
        ])
        #expect(!flattened.contains("device_context"))
        #expect(!flattened.contains("workspace_files"))
    }

    // MARK: Python 与手机操控

    struct FakePython: PythonRuntime {
        func run(_ request: PythonRunRequest) async throws -> PythonRunResult {
            let what = request.scriptPath.map { "script=\($0)" } ?? "code=\(request.code ?? "")"
            return PythonRunResult(
                output: "\(what) argv=\(request.args) pkgs=\(request.packages)",
                exitCode: request.code == "boom" ? 1 : 0,
                writtenFiles: request.code == "plot" ? ["chart.png"] : []
            )
        }
    }

    @Test("python3 / pip 命令行被翻译成运行请求；其余命令不受影响")
    func pythonCommandRouting() throws {
        let (toolset, cleanup) = try makeWorkspace()
        defer { cleanup() }
        let script = try #require(PythonCommand.request(fromShell: "python3 make.py 账单.csv --top 3", toolset: toolset))
        #expect(script.scriptPath == "make.py")
        #expect(script.args == ["make.py", "账单.csv", "--top", "3"])
        let inline = try #require(PythonCommand.request(fromShell: #"python3 -c "print('a b')""#, toolset: toolset))
        #expect(inline.code == "print('a b')")
        #expect(PythonCommand.request(fromShell: "pip install numpy pandas", toolset: toolset)?.packages == ["numpy", "pandas"])
        #expect(PythonCommand.request(fromShell: "ls -la", toolset: toolset) == nil)
        #expect(PythonCommand.request(fromShell: "python3 a.py | head", toolset: toolset) == nil)
        #expect(PythonCommand.request(fromShell: "python3", toolset: toolset) == nil)
    }

    @Test("run_python 经工具层执行：产出文件带回、退出码映射、脚本不存在提前报错、没有运行时明确失败")
    func runPythonThroughToolset() async throws {
        var (toolset, cleanup) = try makeWorkspace()
        defer { cleanup() }
        let firewall = PrivacyFirewall()
        toolset.python = FakePython()

        let plot = await toolset.execute(ToolCallRequest(id: "1", name: "run_python", argumentsJSON: #"{"code":"plot"}"#), firewall: firewall)
        #expect(!plot.isError)
        #expect(plot.producedFiles == ["chart.png"])
        #expect(plot.content.contains("[已写入工作区：chart.png]"))

        let boom = await toolset.execute(ToolCallRequest(id: "2", name: "run_python", argumentsJSON: #"{"code":"boom"}"#), firewall: firewall)
        #expect(boom.isError)

        let viaShell = await toolset.execute(ToolCallRequest(id: "3", name: "run_shell", argumentsJSON: #"{"command":"python3 src/main.swift 1"}"#), firewall: firewall)
        #expect(viaShell.content.contains("script=src/main.swift"))

        let missing = await toolset.execute(ToolCallRequest(id: "4", name: "run_python", argumentsJSON: #"{"path":"nope.py"}"#), firewall: firewall)
        #expect(missing.isError)
        #expect(missing.content.contains("nope.py"))

        toolset.python = nil
        let none = await toolset.execute(ToolCallRequest(id: "5", name: "run_python", argumentsJSON: #"{"code":"1"}"#), firewall: firewall)
        #expect(none.isError)

        // Python 能改工作区文件：标准防护下要确认，沙盒全自动下放行
        let call = ToolCallRequest(id: "6", name: "run_python", argumentsJSON: #"{"code":"print(1)"}"#)
        #expect(toolset.requiresApproval(call, policy: .readOnlyAuto)?.unifiedDiff == "print(1)")
        #expect(toolset.requiresApproval(call, policy: .fullSandboxAuto) == nil)
        let shell = ToolCallRequest(id: "7", name: "run_shell", argumentsJSON: #"{"command":"python3 a.py"}"#)
        #expect(toolset.requiresApproval(shell, policy: .readOnlyAuto) != nil)
    }

    @Test("手机操控：任何策略下都要确认且可本轮授权；屏幕内容排成带编号的文本")
    func phoneControlApprovalAndRendering() {
        let toolset = WorkspaceToolset(rootURL: FileManager.default.temporaryDirectory)
        let action = ToolCallRequest(
            id: "p", name: "phone_do",
            argumentsJSON: #"{"actions":[{"type":"launch","app":"com.apple.Preferences"},{"type":"tap","element":8},{"type":"type","text":"你好"}]}"#
        )
        for policy in ApprovalPolicy.allCases {
            let approval = toolset.requiresApproval(action, policy: policy)
            #expect(approval?.summary == "操作手机：打开 com.apple.Preferences → 点按 [8] → 输入「你好」")
            #expect(approval?.allowsTurnGrant == true)
        }
        #expect(ToolPresentation.describe(action).verb == "操作")

        let text = PhoneControl.render([
            "app": "com.apple.Preferences", "screen": ["w": 440, "h": 956], "keyboard": true,
            "log": ["tap：已执行"],
            "elements": [
                ["n": 1, "type": "按钮", "label": "通用"],
                ["n": 2, "type": "开关", "label": "飞行模式", "value": "0", "disabled": true]
            ]
        ])
        #expect(text == "· tap：已执行\n前台 App：com.apple.Preferences（屏幕 440×956 点），键盘已弹出\n[1] 按钮 通用\n[2] 开关 飞行模式 = 0（不可用）")
    }

    /// 连续发起两次手机操作的假模型。
    actor TwoPhoneSteps: ModelStreamingTransport {
        var step = 0
        nonisolated func streamChatCompletion(
            config: ProviderConfig, apiKey: String, messages: [ChatMessage],
            includeWorkspaceTools: Bool, firewall: PrivacyFirewall
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    let current = await self.next()
                    if current <= 2 {
                        continuation.yield(.toolCalls([ToolCallRequest(id: "ph\(current)", name: "phone_look", argumentsJSON: "{}")]))
                    } else {
                        continuation.yield(.content("完成"))
                    }
                    continuation.finish()
                }
            }
        }
        private func next() -> Int { step += 1; return step }
    }

    @Test("「本轮都允许」之后同一轮不再询问；下一轮重新询问")
    func turnGrantSkipsLaterApprovals() async throws {
        let harness = AgentHarness(transport: TwoPhoneSteps(), toolset: WorkspaceToolset(rootURL: FileManager.default.temporaryDirectory), firewall: PrivacyFirewall())
        let asked = Counter()
        _ = try await harness.runTurn(
            history: [ChatMessage(role: .user, content: "打开设置")],
            config: ProviderConfig(), apiKey: "", approvalPolicy: .fullSandboxAuto
        ) { event in
            if case let .approvalRequired(pending) = event {
                await asked.bump()
                await harness.resolveApproval(callId: pending.call.id, approved: true, rememberForTurn: true)
            }
        }
        #expect(await asked.value == 1)
    }

    actor Counter {
        var value = 0
        func bump() { value += 1 }
    }

    // MARK: Markdown

    @Test("Markdown 拆块：标题 / 段落 / 嵌套与有序列表 / 任务项 / 引用 / 表格 / 代码 / 分隔线")
    func markdownBlocks() {
        let source = """
        ## 结论
        10 月一共花了 **¥6,842**：
        第二行

        - 房租 ¥3,200
          - 占 46.8%
        1. 第一步
        2. [x] 做完了
        > 提示：仅供参考
        ---
        | 类别 | 金额 |
        | --- | ---: |
        | 餐饮 | 1486 |
        | 交通 |
        ```python
        print("# 不是标题")
        - 也不是列表
        ```
        收尾
        """
        let blocks = MarkdownBlock.parse(source)
        #expect(blocks == [
            .heading(level: 2, text: "结论"),
            .paragraph("10 月一共花了 **¥6,842**：\n第二行"),
            .list([
                .init(level: 0, marker: nil, checked: nil, text: "房租 ¥3,200"),
                .init(level: 1, marker: nil, checked: nil, text: "占 46.8%"),
                .init(level: 0, marker: "1.", checked: nil, text: "第一步"),
                .init(level: 0, marker: "2.", checked: true, text: "做完了")
            ]),
            .quote("提示：仅供参考"),
            .rule,
            .table(header: ["类别", "金额"], rows: [["餐饮", "1486"], ["交通", ""]]),
            .code(language: "python", code: "print(\"# 不是标题\")\n- 也不是列表"),
            .paragraph("收尾")
        ])
    }

    @Test("Markdown：流式输出到一半（代码块没收尾、表格只有表头）不崩也不丢字")
    func markdownStreamingPartial() {
        #expect(MarkdownBlock.parse("看代码：\n```swift\nlet a = 1") == [.paragraph("看代码："), .code(language: "swift", code: "let a = 1")])
        #expect(MarkdownBlock.parse("| a | b |") == [.paragraph("| a | b |")])
        #expect(MarkdownBlock.parse("#标签 不是标题\n2026.11 不是列表") == [.paragraph("#标签 不是标题\n2026.11 不是列表")])
        #expect(MarkdownBlock.parse("") == [])
    }
}
