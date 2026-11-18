import Foundation
import JavaScriptCore

public enum WorkspaceSandboxError: LocalizedError, Equatable, Sendable {
    case pathEscapeBlocked(String)
    case invalidArguments(String)
    case targetNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .pathEscapeBlocked(path):
            return "沙盒越界拦截：路径 '\(path)' 超出应用受控工作区范围。"
        case let .invalidArguments(msg):
            return "工具参数无效：\(msg)"
        case let .targetNotFound(msg):
            return msg
        }
    }
}

/// On-device sandboxed tool suite mounted inside `Documents/Workspace` (accessible in iOS Files.app).
public struct WorkspaceToolset: Sendable {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL.resolvingSymlinksInPath()
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootURL = docs.appendingPathComponent("Workspace", isDirectory: true).resolvingSymlinksInPath()
        }
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    public static var toolSchemas: [[String: Any]] {
        [
            schema(
                name: "list_files",
                description: "列出本机 iOS 工作区目录中的文件与子目录。",
                properties: [
                    "path": ["type": "string", "description": "相对路径，留空或 '.' 表示工作区根目录"]
                ],
                required: []
            ),
            schema(
                name: "read_file",
                description: "读取工作区内文本文件内容（自动附带行号）。",
                properties: [
                    "path": ["type": "string", "description": "工作区相对文件路径"]
                ],
                required: ["path"]
            ),
            schema(
                name: "write_file",
                description: "在工作区内创建或覆写文件，自动生成 Git 风格 Diff 预览。",
                properties: [
                    "path": ["type": "string", "description": "工作区相对文件路径"],
                    "content": ["type": "string", "description": "完整文本内容"]
                ],
                required: ["path", "content"]
            ),
            schema(
                name: "edit_file",
                description: "精准替换工作区文件中的指定片段，并生成行级 Diff。",
                properties: [
                    "path": ["type": "string", "description": "工作区相对文件路径"],
                    "old_text": ["type": "string", "description": "原文件中待替换的精确片段"],
                    "new_text": ["type": "string", "description": "替换后的新片段"]
                ],
                required: ["path", "old_text", "new_text"]
            ),
            schema(
                name: "search_files",
                description: "在工作区所有文本文件中检索关键字或正则表达式。",
                properties: [
                    "query": ["type": "string", "description": "搜索词或正则"]
                ],
                required: ["query"]
            ),
            schema(
                name: "run_javascript",
                description: "在隔离的 iOS JavaScriptCore 引擎内执行数据处理、数学验算或算法脚本（零网络权限）。",
                properties: [
                    "code": ["type": "string", "description": "要执行的 JavaScript 代码，可用 console.log 或直接返回表达式"]
                ],
                required: ["code"]
            ),
            schema(
                name: "render_artifact",
                description: "在对话中生成可交互的离线沙盒预览卡片（支持 HTML 小应用、SVG 矢量图或 Mermaid 流程图）。",
                properties: [
                    "title": ["type": "string", "description": "卡片标题"],
                    "kind": ["type": "string", "enum": ["html", "svg", "mermaid"], "description": "产物类型"],
                    "source": ["type": "string", "description": "完整 HTML / SVG / Mermaid 源码"]
                ],
                required: ["title", "kind", "source"]
            ),
            schema(
                name: "fetch_webpage",
                description: "经用户单次授权并通过零遥测防火墙后，抓取指定公开网页的纯文本摘要。",
                properties: [
                    "url": ["type": "string", "description": "https:// 开头的网页地址"]
                ],
                required: ["url"]
            )
        ]
    }

    public func requiresApproval(_ call: ToolCallRequest, policy: ApprovalPolicy) -> PendingToolApproval? {
        let args = Self.parseArgs(call.argumentsJSON)
        switch policy {
        case .askEveryTool:
            return buildApproval(for: call, args: args)
        case .fullSandboxAuto:
            if call.name == "fetch_webpage" {
                return buildApproval(for: call, args: args)
            }
            return nil
        case .readOnlyAuto:
            switch call.name {
            case "write_file", "edit_file", "fetch_webpage":
                return buildApproval(for: call, args: args)
            default:
                return nil
            }
        }
    }

    private func buildApproval(for call: ToolCallRequest, args: [String: Any]) -> PendingToolApproval {
        switch call.name {
        case "write_file":
            let rel = (args["path"] as? String) ?? ""
            let newContent = (args["content"] as? String) ?? ""
            let existing = (try? resolveSafeURL(rel)).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let diff = Self.unifiedDiff(path: rel, oldText: existing, newText: newContent)
            return PendingToolApproval(
                call: call,
                summary: existing.isEmpty ? "新建文件 \(rel) (\(newContent.utf8.count) B)" : "覆写文件 \(rel)",
                unifiedDiff: diff,
                requiresBiometrics: false
            )
        case "edit_file":
            let rel = (args["path"] as? String) ?? ""
            let oldPart = (args["old_text"] as? String) ?? ""
            let newPart = (args["new_text"] as? String) ?? ""
            let existing = (try? resolveSafeURL(rel)).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? oldPart
            let updated = existing.replacingOccurrences(of: oldPart, with: newPart)
            let diff = Self.unifiedDiff(path: rel, oldText: existing, newText: updated)
            return PendingToolApproval(
                call: call,
                summary: "修改文件 \(rel)",
                unifiedDiff: diff,
                requiresBiometrics: false
            )
        case "fetch_webpage":
            let url = (args["url"] as? String) ?? ""
            return PendingToolApproval(
                call: call,
                summary: "访问外部网页 \(url)",
                unifiedDiff: nil,
                requiresBiometrics: false
            )
        default:
            return PendingToolApproval(call: call, summary: "执行工具 \(call.name)")
        }
    }

    public func execute(_ call: ToolCallRequest, firewall: PrivacyFirewall) async -> ToolExecutionOutput {
        let start = ContinuousClock.now
        let args = Self.parseArgs(call.argumentsJSON)

        do {
            switch call.name {
            case "list_files":
                let rel = (args["path"] as? String) ?? "."
                let dir = try resolveSafeURL(rel)
                let items = try FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }

                if items.isEmpty {
                    return ok(call, "工作区目录为空（路径：\(rel)）", since: start)
                }
                let lines = items.map { url -> String in
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if values?.isDirectory == true {
                        return "[DIR]  \(url.lastPathComponent)/"
                    }
                    return "[FILE] \(url.lastPathComponent) (\(values?.fileSize ?? 0) B)"
                }
                return ok(call, lines.joined(separator: "\n"), since: start)

            case "read_file":
                guard let rel = args["path"] as? String, !rel.isEmpty else {
                    throw WorkspaceSandboxError.invalidArguments("缺少 path")
                }
                let fileURL = try resolveSafeURL(rel)
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                let numbered = content
                    .components(separatedBy: "\n")
                    .enumerated()
                    .prefix(500)
                    .map { String(format: "%4d | %@", $0.offset + 1, $0.element) }
                    .joined(separator: "\n")
                return ok(call, numbered, since: start)

            case "write_file":
                guard let rel = args["path"] as? String, !rel.isEmpty,
                      let content = args["content"] as? String else {
                    throw WorkspaceSandboxError.invalidArguments("缺少 path 或 content")
                }
                let fileURL = try resolveSafeURL(rel)
                let previous = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: fileURL, options: .atomic)
                let diff = Self.unifiedDiff(path: rel, oldText: previous, newText: content)
                return ToolExecutionOutput(
                    toolCallId: call.id,
                    toolName: call.name,
                    content: "已写入 \(rel)（\(content.utf8.count) 字节）",
                    unifiedDiff: diff,
                    durationMs: Self.elapsedMs(since: start)
                )

            case "edit_file":
                guard let rel = args["path"] as? String,
                      let oldText = args["old_text"] as? String,
                      let newText = args["new_text"] as? String,
                      !oldText.isEmpty else {
                    throw WorkspaceSandboxError.invalidArguments("缺少 path / old_text / new_text")
                }
                let fileURL = try resolveSafeURL(rel)
                let existing = try String(contentsOf: fileURL, encoding: .utf8)
                guard existing.contains(oldText) else {
                    throw WorkspaceSandboxError.targetNotFound("未在 \(rel) 中找到匹配的 old_text 片段")
                }
                let updated = existing.replacingOccurrences(of: oldText, with: newText)
                try Data(updated.utf8).write(to: fileURL, options: .atomic)
                let diff = Self.unifiedDiff(path: rel, oldText: existing, newText: updated)
                return ToolExecutionOutput(
                    toolCallId: call.id,
                    toolName: call.name,
                    content: "已完成 \(rel) 的精确片段替换",
                    unifiedDiff: diff,
                    durationMs: Self.elapsedMs(since: start)
                )

            case "search_files":
                guard let query = args["query"] as? String, !query.isEmpty else {
                    throw WorkspaceSandboxError.invalidArguments("缺少 query")
                }
                let hits = searchWorkspace(query: query)
                let summary = hits.isEmpty ? "未找到匹配 '\(query)' 的内容" : hits.joined(separator: "\n")
                return ok(call, summary, since: start)

            case "run_javascript":
                guard let code = args["code"] as? String, !code.isEmpty else {
                    throw WorkspaceSandboxError.invalidArguments("缺少 code")
                }
                let output = Self.evaluateSandboxedJS(code)
                return ToolExecutionOutput(
                    toolCallId: call.id,
                    toolName: call.name,
                    content: output.text,
                    isError: output.isError,
                    durationMs: Self.elapsedMs(since: start)
                )

            case "render_artifact":
                let title = (args["title"] as? String) ?? "交互式预览"
                let kindRaw = (args["kind"] as? String) ?? "html"
                let source = (args["source"] as? String) ?? ""
                let kind = ArtifactPayload.Kind(rawValue: kindRaw) ?? .html
                let artifact = ArtifactPayload(title: title, kind: kind, source: source)
                return ToolExecutionOutput(
                    toolCallId: call.id,
                    toolName: call.name,
                    content: "已生成离线沙盒预览卡片：\(title) (\(kind.rawValue))",
                    artifact: artifact,
                    durationMs: Self.elapsedMs(since: start)
                )

            case "fetch_webpage":
                guard let rawURL = args["url"] as? String,
                      let url = URL(string: rawURL),
                      let host = url.host else {
                    throw WorkspaceSandboxError.invalidArguments("无效 URL")
                }
                await firewall.approveWebFetchHostOnce(host)
                var req = URLRequest(url: url)
                req.timeoutInterval = 20
                try await firewall.authorize(req, purpose: .userApprovedWebFetch)
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
                await firewall.recordCompleted(
                    request: req,
                    purpose: .userApprovedWebFetch,
                    statusCode: status,
                    bytesReceived: data.count,
                    durationMs: Self.elapsedMs(since: start),
                    note: "fetch_webpage"
                )
                let rawHTML = String(decoding: data.prefix(65_536), as: UTF8.self)
                let plain = Self.stripHTML(rawHTML)
                return ok(call, String(plain.prefix(6000)), since: start)

            default:
                return ToolExecutionOutput(
                    toolCallId: call.id,
                    toolName: call.name,
                    content: "未知工具：\(call.name)",
                    isError: true,
                    durationMs: Self.elapsedMs(since: start)
                )
            }
        } catch {
            return ToolExecutionOutput(
                toolCallId: call.id,
                toolName: call.name,
                content: error.localizedDescription,
                isError: true,
                durationMs: Self.elapsedMs(since: start)
            )
        }
    }

    /// Prevents `../` traversal and symlink escape outside `rootURL`.
    public func resolveSafeURL(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            throw WorkspaceSandboxError.pathEscapeBlocked(relativePath)
        }
        let cleaned = trimmed.isEmpty ? "." : trimmed
        let candidate = rootURL.appendingPathComponent(cleaned).standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        let finalURL = cleaned == "."
            ? rootURL.standardizedFileURL
            : resolvedParent.appendingPathComponent(candidate.lastPathComponent).standardizedFileURL

        let rootPath = rootURL.standardizedFileURL.path
        let targetPath = finalURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw WorkspaceSandboxError.pathEscapeBlocked(relativePath)
        }
        return finalURL
    }

    private func searchWorkspace(query: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [String] = []
        let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive])

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let rel = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            for (idx, line) in text.components(separatedBy: "\n").enumerated() {
                let matched: Bool
                if let regex {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    matched = regex.firstMatch(in: line, range: range) != nil
                } else {
                    matched = line.localizedCaseInsensitiveContains(query)
                }
                if matched {
                    results.append("\(rel):\(idx + 1): \(line.prefix(160))")
                    if results.count >= 50 { return results }
                }
            }
        }
        return results
    }

    public static func evaluateSandboxedJS(_ code: String) -> (text: String, isError: Bool) {
        guard let context = JSContext() else {
            return ("无法初始化 JavaScriptCore 沙盒", true)
        }
        var logs: [String] = []
        var jsException: String?

        context.exceptionHandler = { _, exception in
            jsException = exception?.toString() ?? "JavaScript 运行异常"
        }

        let logBlock: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() ?? []
            let line = args.map { ($0 as? JSValue)?.toString() ?? "" }.joined(separator: " ")
            logs.append(line)
        }
        context.setObject(logBlock, forKeyedSubscript: "__nativeLog" as NSString)
        context.evaluateScript("const console = { log: __nativeLog, warn: __nativeLog, error: __nativeLog };")

        let result = context.evaluateScript(code)
        if let jsException {
            return ("JS Error: \(jsException)", true)
        }
        let returnText = (result != nil && !result!.isUndefined) ? (result!.toString() ?? "") : ""
        let combined = (logs + (returnText.isEmpty ? [] : ["=> \(returnText)"])).joined(separator: "\n")
        return (combined.isEmpty ? "(执行成功，无输出)" : combined, false)
    }

    public static func unifiedDiff(path: String, oldText: String, newText: String) -> String {
        let oldLines = oldText.isEmpty ? [] : oldText.components(separatedBy: "\n")
        let newLines = newText.isEmpty ? [] : newText.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)

        var removed = Set<Int>()
        var inserted = [Int: String]()
        for change in diff {
            switch change {
            case let .remove(offset, _, _):
                removed.insert(offset)
            case let .insert(offset, element, _):
                inserted[offset] = element
            }
        }

        var lines: [String] = ["--- a/\(path)", "+++ b/\(path)"]
        var oldIdx = 0
        var newIdx = 0
        while oldIdx < oldLines.count || newIdx < newLines.count {
            if let ins = inserted[newIdx] {
                lines.append("+ \(ins)")
                newIdx += 1
            } else if removed.contains(oldIdx) {
                lines.append("- \(oldLines[oldIdx])")
                oldIdx += 1
            } else {
                if oldIdx < oldLines.count {
                    lines.append("  \(oldLines[oldIdx])")
                }
                oldIdx += 1
                newIdx += 1
            }
            if lines.count > 120 {
                lines.append("... (Diff 已折叠)")
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func stripHTML(_ html: String) -> String {
        let withoutScripts = html.replacingOccurrences(
            of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let withoutTags = withoutScripts.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        return withoutTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func ok(_ call: ToolCallRequest, _ text: String, since start: ContinuousClock.Instant) -> ToolExecutionOutput {
        ToolExecutionOutput(
            toolCallId: call.id,
            toolName: call.name,
            content: text,
            isError: false,
            durationMs: Self.elapsedMs(since: start)
        )
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: ContinuousClock.now)
        return Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func schema(
        name: String,
        description: String,
        properties: [String: [String: Any]],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ]
            ]
        ]
    }
}
