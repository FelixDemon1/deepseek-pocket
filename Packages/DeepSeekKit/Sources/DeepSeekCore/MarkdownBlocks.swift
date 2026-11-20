import Foundation

/// 把模型输出的 Markdown 拆成块级结构（标题、段落、列表、引用、表格、代码、分隔线）。
/// 行内样式（加粗、行内代码、链接）交给系统的 AttributedString 处理。
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case code(language: String, code: String)
    case table(header: [String], rows: [[String]])
    case rule

    public struct ListItem: Equatable, Sendable {
        public var level: Int
        /// 有序列表的序号文本（如 "1."）；无序为 nil
        public var marker: String?
        /// 任务列表：nil 表示不是任务项
        public var checked: Bool?
        public var text: String
    }

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1 // 跳过收尾围栏；流式输出还没写完时这里会越界，循环自然结束
                blocks.append(.code(language: language, code: body.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }
            if trimmed.count >= 3, Set(trimmed.filter { $0 != " " }).count == 1, "-*_".contains(trimmed.first!) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if trimmed.contains("|"), index + 1 < lines.count, isTableDivider(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    var row = cells(lines[index])
                    while row.count < header.count { row.append("") }
                    rows.append(Array(row.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if listItem(line) != nil {
                flushParagraph()
                var items: [ListItem] = []
                while index < lines.count {
                    if let item = listItem(lines[index]) {
                        items.append(item)
                    } else if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[index].hasPrefix("  "), !items.isEmpty {
                        // 缩进的续行并入上一项
                        items[items.count - 1].text += "\n" + lines[index].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
        return text.isEmpty ? nil : .heading(level: hashes, text: text)
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        var marker: String?
        var rest: Substring
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            rest = body.dropFirst(2)
        } else {
            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 4,
                  let dot = body.dropFirst(digits.count).first, dot == "." || dot == ")",
                  body.dropFirst(digits.count + 1).first == " " else { return nil }
            marker = "\(digits)."
            rest = body.dropFirst(digits.count + 2)
        }
        var checked: Bool?
        if rest.hasPrefix("[ ] ") {
            checked = false
            rest = rest.dropFirst(4)
        } else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
            checked = true
            rest = rest.dropFirst(4)
        }
        return ListItem(level: min(indent / 2, 3), marker: marker, checked: checked, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let parts = cells(line)
        return !parts.isEmpty && line.contains("-") && parts.allSatisfy { part in
            part.count >= 1 && part.allSatisfy { $0 == "-" || $0 == ":" } && part.contains("-")
        }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
