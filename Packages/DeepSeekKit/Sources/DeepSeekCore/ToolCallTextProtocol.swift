import Foundation

// ---------------------------------------------------------------------------
// 文本式工具调用协议。
//
// 网页版通道只有一个纯文本输入框，没有原生 function calling。这里约定一种
// 模型能稳定遵守的写法：需要调用工具时输出
//
//     ```tool
//     {"name": "read_file", "arguments": {"path": "a.md"}}
//     ```
//
// 本机把这种代码块从正文流里截出来，翻译成 `StreamDelta.toolCalls`，
// 后面的审批、执行、结果回填都复用 AgentHarness 现成的那一套。
// ---------------------------------------------------------------------------

public enum ToolCallTextProtocol {
    static let openMarker = "```tool"
    static let closeMarker = "\n```"

    /// 拼进提示词的工具说明书，由工具 schema 生成，新增工具不用改这里。
    public static func manual(schemas: [[String: Any]]) -> String {
        let lines = schemas.compactMap { schema -> String? in
            guard let function = schema["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            let description = (function["description"] as? String) ?? ""
            let parameters = function["parameters"] as? [String: Any]
            let properties = (parameters?["properties"] as? [String: [String: Any]]) ?? [:]
            let required = Set((parameters?["required"] as? [String]) ?? [])
            let params = properties.keys.sorted().map { key -> String in
                let hint = (properties[key]?["description"] as? String) ?? ""
                return "\(key)\(required.contains(key) ? "*" : "")（\(hint)）"
            }.joined(separator: "，")
            return "- \(name)：\(description)" + (params.isEmpty ? "" : " 参数：\(params)")
        }
        return """
        [可用工具]
        你运行在用户的手机上，可以调用下面的本机工具来真正完成任务，而不是只给建议。
        需要调用时，输出如下代码块（一个代码块一次调用，可以连续输出多个），然后立刻停止，等待工具结果：
        ```tool
        {"name": "工具名", "arguments": {"参数名": "参数值"}}
        ```
        规则：
        1. 代码块里必须是合法 JSON；字符串里的换行写成 \\n，引号写成 \\"。
        2. 不要自己编造工具结果，结果会在下一步由本机给你。
        3. 普通问答不需要工具时直接回答，不要输出 tool 代码块。
        4. 带 * 的参数必填。
        工具列表：
        \(lines.joined(separator: "\n"))
        """
    }

    /// 把一次助手发起的工具调用写回成协议文本（回填历史时用）。
    public static func render(calls: [ToolCallRequest]) -> String {
        calls.map { call in
            let escapedName = WebAdapterTemplate.jsonEscape(call.name)
            let arguments = call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON
            return "\(openMarker)\n{\"name\": \"\(escapedName)\", \"arguments\": \(arguments)}\n```"
        }.joined(separator: "\n")
    }

    /// 包一层：正文里的工具代码块不外露，流结束时作为 `.toolCalls` 发出。
    public static func wrap(
        _ upstream: AsyncThrowingStream<StreamDelta, Error>
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var filter = ToolCallTextFilter()
                do {
                    for try await delta in upstream {
                        guard case let .content(text) = delta else {
                            continuation.yield(delta)
                            continue
                        }
                        let visible = filter.feed(text)
                        if !visible.isEmpty { continuation.yield(.content(visible)) }
                    }
                    let end = filter.finish()
                    if !end.text.isEmpty { continuation.yield(.content(end.text)) }
                    if !end.calls.isEmpty { continuation.yield(.toolCalls(end.calls)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 解析一个代码块里的内容；模型常把多行文本直接写进字符串（非法 JSON），这里做一次容错修复。
    static func parseCalls(_ body: String) -> [ToolCallRequest]? {
        guard let start = body.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = body.lastIndex(where: { $0 == "}" || $0 == "]" }),
              start < end else { return nil }
        let candidate = String(body[start...end])
        let object = (try? JSONSerialization.jsonObject(with: Data(candidate.utf8)))
            ?? (try? JSONSerialization.jsonObject(with: Data(escapingRawControlCharacters(candidate).utf8)))
        let items: [[String: Any]]
        if let dict = object as? [String: Any] {
            items = [dict]
        } else if let list = object as? [[String: Any]] {
            items = list
        } else {
            return nil
        }
        let calls = items.compactMap { item -> ToolCallRequest? in
            guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                return nil
            }
            let rawArguments = item["arguments"] ?? item["parameters"] ?? [String: Any]()
            let argumentsJSON: String
            if let text = rawArguments as? String {
                argumentsJSON = text.isEmpty ? "{}" : text
            } else if let dict = rawArguments as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
                argumentsJSON = String(decoding: data, as: UTF8.self)
            } else {
                argumentsJSON = "{}"
            }
            return ToolCallRequest(
                id: "txt_\(UUID().uuidString.prefix(8).lowercased())",
                name: name,
                argumentsJSON: argumentsJSON
            )
        }
        return calls.isEmpty ? nil : calls
    }

    /// 把字符串字面量内部的裸换行 / 制表符转义掉，其余原样保留。
    static func escapingRawControlCharacters(_ json: String) -> String {
        var out = ""
        out.reserveCapacity(json.count + 16)
        var inString = false
        var escaped = false
        for character in json {
            if inString {
                if escaped {
                    escaped = false
                    out.append(character)
                } else if character == "\\" {
                    escaped = true
                    out.append(character)
                } else if character == "\"" {
                    inString = false
                    out.append(character)
                } else if character == "\n" {
                    out += "\\n"
                } else if character == "\r" {
                    out += "\\r"
                } else if character == "\t" {
                    out += "\\t"
                } else {
                    out.append(character)
                }
            } else {
                if character == "\"" { inString = true }
                out.append(character)
            }
        }
        return out
    }
}

/// 流式过滤器：一边放行正文，一边截留工具代码块。
public struct ToolCallTextFilter: Sendable {
    private var buffer = ""
    private var capturing = false
    private var calls: [ToolCallRequest] = []

    public init() {}

    public mutating func feed(_ chunk: String) -> String {
        buffer += chunk
        var visible = ""
        while true {
            if capturing {
                guard let closed = Self.closeBlock(buffer) else { break }
                calls.append(contentsOf: closed.calls)
                buffer = closed.rest
                capturing = false
            } else if let marker = buffer.range(of: ToolCallTextProtocol.openMarker) {
                visible += buffer[..<marker.lowerBound]
                // 丢掉标记所在行的剩余部分（兼容 ```tool_call / ```tool_code 这类写法）
                let afterMarker = buffer[marker.upperBound...]
                if let newline = afterMarker.firstIndex(of: "\n") {
                    buffer = String(afterMarker[newline...])
                    capturing = true
                } else {
                    buffer = String(buffer[marker.lowerBound...])
                    break
                }
            } else {
                let keep = Self.partialMarkerLength(at: buffer)
                visible += buffer.dropLast(keep)
                buffer = String(buffer.suffix(keep))
                break
            }
        }
        // 发起调用之后模型再写的话多半是在脑补结果，不展示也不进历史
        return calls.isEmpty ? visible : ""
    }

    public mutating func finish() -> (text: String, calls: [ToolCallRequest]) {
        var tail = ""
        if capturing {
            // 模型漏写了收尾的 ```：整段当作一个代码块再试一次
            if let parsed = ToolCallTextProtocol.parseCalls(buffer) {
                calls.append(contentsOf: parsed)
            } else {
                tail = ToolCallTextProtocol.openMarker + buffer
            }
        } else {
            tail = buffer
        }
        buffer = ""
        capturing = false
        let found = calls
        calls = []
        return (found.isEmpty ? tail : "", found)
    }

    /// 字符串里可能出现字面的 ```，所以逐个尝试收尾位置，取第一个能解析成功的。
    private static func closeBlock(_ text: String) -> (calls: [ToolCallRequest], rest: String)? {
        var searchStart = text.startIndex
        while let fence = text.range(of: ToolCallTextProtocol.closeMarker, range: searchStart..<text.endIndex) {
            if let parsed = ToolCallTextProtocol.parseCalls(String(text[..<fence.lowerBound])) {
                return (parsed, String(text[fence.upperBound...]))
            }
            searchStart = fence.upperBound
        }
        return nil
    }

    /// 缓冲区末尾有多少个字符可能是开始标记的前半截（要留着等下一个分片）。
    private static func partialMarkerLength(at text: String) -> Int {
        let marker = ToolCallTextProtocol.openMarker
        for length in stride(from: min(marker.count - 1, text.count), to: 0, by: -1)
        where text.hasSuffix(marker.prefix(length)) {
            return length
        }
        return 0
    }
}
