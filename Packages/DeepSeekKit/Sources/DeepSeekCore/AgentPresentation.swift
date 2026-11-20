import Foundation

/// 把一次工具调用翻译成界面上的一行：「读取 · 账单.csv」「运行 · ls -la」。
public struct ToolPresentation: Equatable, Sendable {
    /// 动词：读取 / 写入 / 运行 …
    public var verb: String
    /// 对象：文件名、命令、网址
    public var detail: String
    /// SF Symbol 名
    public var symbol: String
    /// 对象是不是一条命令（界面用等宽字体，并在终端块里显示）
    public var isCommand: Bool
    /// 终端块里 `$` 后面的那一行
    public var commandLine: String

    public static func describe(_ call: ToolCallRequest) -> ToolPresentation {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        func text(_ key: String) -> String { (args[key] as? String) ?? "" }
        func make(_ verb: String, _ detail: String, _ symbol: String, command: String? = nil) -> ToolPresentation {
            ToolPresentation(
                verb: verb,
                detail: detail,
                symbol: symbol,
                isCommand: command != nil,
                commandLine: command ?? "\(call.name) \(detail)"
            )
        }
        func firstLine(_ raw: String) -> String {
            let line = raw.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? raw
            return line.count > 80 ? String(line.prefix(80)) + "…" : line
        }

        switch call.name {
        case "run_shell":
            let command = text("command")
            return make("运行", firstLine(command), "terminal", command: command)
        case "run_python":
            if !text("path").isEmpty {
                let extra = ((args["args"] as? [Any]) ?? []).map { " \($0)" }.joined()
                return make("运行", "python3 \(text("path"))\(extra)", "terminal", command: "python3 \(text("path"))\(extra)")
            }
            return make("运行", "python3 · \(firstLine(text("code")))", "terminal", command: "python3 - <<'PY'\n\(text("code"))\nPY")
        case "run_javascript":
            return make("计算", firstLine(text("code")), "function", command: "node -e '\(firstLine(text("code")))'")
        case "list_files":
            let path = text("path").isEmpty ? "." : text("path")
            return make("浏览", path, "folder", command: "ls \(path)")
        case "read_file":
            return make("读取", text("path"), "doc.text", command: "cat \(text("path"))")
        case "search_files":
            return make("搜索", text("query"), "magnifyingglass", command: "grep -rn \"\(text("query"))\" .")
        case "write_file":
            return make("写入", text("path"), "square.and.pencil")
        case "edit_file":
            return make("修改", text("path"), "pencil.line")
        case "render_artifact":
            return make("生成", text("title").isEmpty ? "预览卡片" : text("title"), "macwindow")
        case "fetch_webpage":
            let host = URL(string: text("url"))?.host ?? text("url")
            return make("访问", host, "globe", command: "curl \(text("url"))")
        case "phone_look":
            return make("查看", text("app").isEmpty ? "手机屏幕" : text("app"), "iphone")
        case "phone_do":
            let summary = PhoneControl.approvalSummary(name: call.name, args: args)
            return make("操作", String(summary.dropFirst("操作手机：".count)), "hand.tap")
        case "create_reminder":
            return make("提醒", text("title"), "bell")
        case "create_calendar_event":
            return make("日程", text("title"), "calendar")
        case "get_clipboard":
            return make("读取", "剪贴板", "doc.on.clipboard")
        case "set_clipboard":
            return make("复制", firstLine(text("text")), "doc.on.clipboard")
        case "open_url":
            let url = URL(string: text("url"))
            return make("打开", url?.host ?? url?.scheme.map { "\($0):" } ?? text("url"), "arrow.up.forward.app")
        case "update_plan":
            let steps = AgentPlan.parse(argumentsJSON: call.argumentsJSON)
            let done = steps.filter { $0.status == .done }.count
            return make("计划", steps.isEmpty ? "更新" : "\(done)/\(steps.count) 步完成", "checklist")
        default:
            return make("调用", call.name, "wrench.and.screwdriver")
        }
    }
}

public struct AgentPlanStep: Equatable, Identifiable, Sendable {
    public enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case done
    }

    public var id: Int
    public var title: String
    public var status: Status
}

public enum AgentPlan {
    /// 解析 `update_plan` 的参数；写法不规范的状态一律当作未开始。
    public static func parse(argumentsJSON: String) -> [AgentPlanStep] {
        guard let args = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any],
              let rawSteps = args["steps"] as? [Any] else { return [] }
        var steps: [AgentPlanStep] = []
        for raw in rawSteps {
            let title: String
            var status = AgentPlanStep.Status.pending
            if let dict = raw as? [String: Any] {
                title = ((dict["title"] as? String) ?? (dict["step"] as? String) ?? "")
                let rawStatus = ((dict["status"] as? String) ?? "").lowercased()
                if ["done", "completed", "complete", "finished"].contains(rawStatus) {
                    status = .done
                } else if ["in_progress", "in-progress", "doing", "running", "active"].contains(rawStatus) {
                    status = .inProgress
                }
            } else {
                title = (raw as? String) ?? ""
            }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                steps.append(AgentPlanStep(id: steps.count, title: trimmed, status: status))
            }
        }
        return steps
    }
}

public enum DiffStat {
    /// 统计 `WorkspaceToolset.unifiedDiff` 产物里的增删行数（不含 `---` / `+++` 文件头）。
    public static func count(_ unifiedDiff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(2) {
            if line.hasPrefix("+ ") || line == "+" { added += 1 }
            if line.hasPrefix("- ") || line == "-" { removed += 1 }
        }
        return (added, removed)
    }
}

// MARK: - 一轮 agent 执行的轨迹

/// 聊天列表里的一项：一条用户消息，或一轮助手执行（可能包含多步思考、工具调用和最终回答）。
public enum ChatTimelineItem: Identifiable, Equatable, Sendable {
    case user(ChatMessage)
    case turn(id: UUID, messages: [ChatMessage])

    public var id: UUID {
        switch self {
        case let .user(message): return message.id
        case let .turn(id, _): return id
        }
    }

    /// 以用户消息为界，把其间的助手 / 工具消息归成一轮。
    public static func build(from messages: [ChatMessage]) -> [ChatTimelineItem] {
        var items: [ChatTimelineItem] = []
        var group: [ChatMessage] = []
        func flush() {
            if let first = group.first { items.append(.turn(id: first.id, messages: group)) }
            group = []
        }
        for message in messages where message.role != .system {
            if message.role == .user {
                flush()
                items.append(.user(message))
            } else {
                group.append(message)
            }
        }
        flush()
        return items
    }
}

public struct AgentTurnStep: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case thinking(text: String, seconds: Double?)
        /// 模型在动手之前说的一句话
        case note(String)
        case tool(call: ToolCallRequest, output: ToolExecutionOutput?)
    }

    public var id: String
    public var kind: Kind
}

public struct AgentChangedFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var added: Int
    public var removed: Int
    public var diff: String
}

public struct AgentTurn: Equatable, Sendable {
    public var steps: [AgentTurnStep] = []
    /// 最终回答：这一轮最后一条不带工具调用的助手消息
    public var finalMessage: ChatMessage?
    /// 真正动手的次数（不含更新计划）
    public var actionCount = 0
    public var hasToolCalls = false
    /// 最近一次 `update_plan` 的内容
    public var plan: [AgentPlanStep] = []
    public var changedFiles: [AgentChangedFile] = []
    public var artifacts: [ArtifactPayload] = []
    /// 脚本产出的文件（图表、表格等），相对工作区的路径
    public var producedFiles: [String] = []
    public var modelSteps = 0
    public var totalTokens = 0
    public var durationSec: Double?

    public init(messages: [ChatMessage]) {
        var outputs: [String: ToolExecutionOutput] = [:]
        for message in messages {
            if let output = message.toolOutput { outputs[output.toolCallId] = output }
        }
        hasToolCalls = messages.contains { !$0.toolCalls.isEmpty }

        for (index, message) in messages.enumerated() where message.role == .assistant {
            modelSteps += 1
            totalTokens += message.usage?.totalTokens ?? 0
            let isFinal = index == messages.count - 1 && message.toolCalls.isEmpty
            if isFinal {
                finalMessage = message
                durationSec = message.turnDurationSec
            }
            // 纯聊天的一轮由原来的消息视图自己展示思考过程，这里只收 agent 轮的轨迹
            guard hasToolCalls else { continue }
            if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                steps.append(AgentTurnStep(
                    id: "\(message.id.uuidString)-think",
                    kind: .thinking(text: reasoning, seconds: message.reasoningDurationSec)
                ))
            }
            if !isFinal, !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                steps.append(AgentTurnStep(id: "\(message.id.uuidString)-note", kind: .note(message.content)))
            }
            for call in message.toolCalls {
                let output = outputs[call.id]
                if call.name == "update_plan" {
                    let parsed = AgentPlan.parse(argumentsJSON: call.argumentsJSON)
                    if !parsed.isEmpty { plan = parsed }
                    continue
                }
                actionCount += 1
                steps.append(AgentTurnStep(id: call.id, kind: .tool(call: call, output: output)))
                if let diff = output?.unifiedDiff, !diff.isEmpty, output?.isError != true {
                    let path = ToolPresentation.describe(call).detail
                    let stat = DiffStat.count(diff)
                    if let existing = changedFiles.firstIndex(where: { $0.path == path }) {
                        changedFiles[existing].added += stat.added
                        changedFiles[existing].removed += stat.removed
                        changedFiles[existing].diff = diff
                    } else {
                        changedFiles.append(AgentChangedFile(path: path, added: stat.added, removed: stat.removed, diff: diff))
                    }
                }
                if let artifact = output?.artifact { artifacts.append(artifact) }
                for file in output?.producedFiles ?? [] where !producedFiles.contains(file) {
                    producedFiles.append(file)
                }
            }
        }
    }

    /// 页脚：「23 秒 · 4 步 · 3.4 万 tokens」
    public var footnote: String {
        var parts: [String] = []
        if let durationSec { parts.append(Self.formatDuration(durationSec)) }
        if modelSteps > 1 { parts.append("\(modelSteps) 步") }
        if totalTokens > 0 {
            parts.append(totalTokens >= 10_000
                ? String(format: "%.1f 万 tokens", Double(totalTokens) / 10_000)
                : "\(totalTokens) tokens")
        }
        return parts.joined(separator: " · ")
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 1)) 秒" }
        return "\(total / 60) 分 \(total % 60) 秒"
    }
}
