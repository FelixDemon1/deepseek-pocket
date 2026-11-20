import Foundation

// ---------------------------------------------------------------------------
// 工作区内的迷你 Shell。
//
// iOS 不允许 App 起子进程，所以这里不是 Linux，而是用 Swift 实现的一小组常用命令，
// 所有路径都经过 `WorkspaceToolset.resolveSafeURL`，出不了工作区。
// 支持：管道 `|`、顺序 `;`、短路 `&&`、重定向 `>` `>>`、引号与通配符。
// ---------------------------------------------------------------------------

public struct MiniShell: Sendable {
    public struct Result: Equatable, Sendable {
        public var output: String
        public var exitCode: Int
    }

    public static let supportedCommands = [
        "pwd", "cd", "ls", "cat", "head", "tail", "wc", "grep", "find", "echo",
        "sort", "uniq", "date", "mkdir", "touch", "cp", "mv", "rm"
    ]
    static let mutatingCommands: Set<String> = ["mkdir", "touch", "cp", "mv", "rm"]
    static let outputLimit = 8000

    private struct Token: Equatable {
        var text: String
        var quoted = false
        var isOperator = false
    }

    private struct Stage {
        var argv: [Token] = []
        var redirect: (path: String, append: Bool)?
    }

    private struct Pipeline {
        var stages: [Stage] = [Stage()]
        var needsPreviousSuccess = false
    }

    private struct Failure: Error {
        var message: String
        var code = 1
    }

    private let toolset: WorkspaceToolset

    public init(toolset: WorkspaceToolset) {
        self.toolset = toolset
    }

    /// 会改动工作区的命令行（写操作需要用户确认）。解析不了的一律按「会改动」处理。
    public static func isMutating(_ commandLine: String) -> Bool {
        guard let pipelines = try? parse(commandLine) else { return true }
        return pipelines.contains { pipeline in
            pipeline.stages.contains { stage in
                stage.redirect != nil || mutatingCommands.contains(stage.argv.first?.text ?? "")
            }
        }
    }

    /// 单条命令（没有管道、重定向、&&）拆出来的参数；否则返回 nil。
    public static func simpleArgv(_ commandLine: String) -> [String]? {
        guard let pipelines = try? parse(commandLine), pipelines.count == 1,
              pipelines[0].stages.count == 1, pipelines[0].stages[0].redirect == nil else { return nil }
        return pipelines[0].stages[0].argv.map(\.text)
    }

    public func run(_ commandLine: String) -> Result {
        let pipelines: [Pipeline]
        do {
            pipelines = try Self.parse(commandLine)
        } catch {
            return Result(output: "mini-shell: \((error as? Failure)?.message ?? "命令解析失败")", exitCode: 2)
        }

        var cwd = ""
        var pieces: [String] = []
        var lastCode = 0
        for pipeline in pipelines {
            if pipeline.needsPreviousSuccess && lastCode != 0 { break }
            var stream = ""
            for stage in pipeline.stages {
                do {
                    let result = try execute(stage.argv, stdin: stream, cwd: &cwd)
                    stream = result.output
                    lastCode = result.exitCode
                    if let redirect = stage.redirect {
                        try write(stream, to: redirect.path, append: redirect.append, cwd: cwd)
                        stream = ""
                    }
                } catch {
                    let failure = (error as? Failure) ?? Failure(message: error.localizedDescription)
                    stream = failure.message
                    lastCode = failure.code
                    break
                }
            }
            if !stream.isEmpty { pieces.append(stream) }
        }

        var output = pieces.joined(separator: "\n")
        if output.count > Self.outputLimit {
            output = String(output.prefix(Self.outputLimit)) + "\n…（输出过长已截断，可用 head / grep 缩小范围）"
        }
        return Result(output: output, exitCode: lastCode)
    }

    // MARK: 解析

    private static func parse(_ line: String) throws -> [Pipeline] {
        let tokens = try tokenize(line)
        var pipelines = [Pipeline()]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.isOperator else {
                pipelines[pipelines.count - 1].stages[pipelines[pipelines.count - 1].stages.count - 1].argv.append(token)
                continue
            }
            switch token.text {
            case "|":
                pipelines[pipelines.count - 1].stages.append(Stage())
            case "&&", ";":
                pipelines.append(Pipeline(needsPreviousSuccess: token.text == "&&"))
            default:
                guard index < tokens.count, !tokens[index].isOperator else {
                    throw Failure(message: "重定向 \(token.text) 后面缺少文件名", code: 2)
                }
                let last = pipelines[pipelines.count - 1].stages.count - 1
                pipelines[pipelines.count - 1].stages[last].redirect = (tokens[index].text, token.text == ">>")
                index += 1
            }
        }
        let cleaned = pipelines.filter { !$0.stages.allSatisfy(\.argv.isEmpty) }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.stages.allSatisfy { !$0.argv.isEmpty } }) else {
            throw Failure(message: "空命令", code: 2)
        }
        return cleaned
    }

    private static func tokenize(_ line: String) throws -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var hasCurrent = false
        var quoted = false
        var quote: Character?
        var characters = Array(line)[...]

        func flush() {
            if hasCurrent { tokens.append(Token(text: current, quoted: quoted)) }
            current = ""
            hasCurrent = false
            quoted = false
        }

        while let character = characters.popFirst() {
            if let active = quote {
                if character == active {
                    quote = nil
                } else if character == "\\", active == "\"", let next = characters.first, "\"\\$`".contains(next) {
                    current.append(characters.removeFirst())
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                quoted = true
                hasCurrent = true
            case "\\":
                if let next = characters.popFirst() {
                    current.append(next)
                    hasCurrent = true
                }
            case " ", "\t":
                flush()
            case "\n", ";":
                flush()
                tokens.append(Token(text: ";", isOperator: true))
            case "|":
                flush()
                tokens.append(Token(text: "|", isOperator: true))
            case "&":
                guard characters.first == "&" else { throw Failure(message: "不支持后台运行符 &", code: 2) }
                characters.removeFirst()
                flush()
                tokens.append(Token(text: "&&", isOperator: true))
            case ">":
                flush()
                if characters.first == ">" {
                    characters.removeFirst()
                    tokens.append(Token(text: ">>", isOperator: true))
                } else {
                    tokens.append(Token(text: ">", isOperator: true))
                }
            default:
                current.append(character)
                hasCurrent = true
            }
        }
        guard quote == nil else { throw Failure(message: "引号没有闭合", code: 2) }
        flush()
        return tokens
    }

    // MARK: 路径

    private func url(_ argument: String, cwd: String) throws -> URL {
        guard !argument.hasPrefix("/"), !argument.hasPrefix("~") else {
            throw Failure(message: "\(argument): 只能访问工作区内的相对路径")
        }
        do {
            return try toolset.resolveSafeURL(cwd.isEmpty ? argument : "\(cwd)/\(argument)")
        } catch {
            throw Failure(message: "\(argument): \(error.localizedDescription)")
        }
    }

    private func relativePath(_ url: URL) -> String {
        let root = toolset.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root ? "" : String(path.dropFirst(root.count + 1))
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    private func readText(_ argument: String, cwd: String) throws -> String {
        let target = try url(argument, cwd: cwd)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw Failure(message: "\(argument): 没有这个文件或目录")
        }
        guard !isDirectory(target) else { throw Failure(message: "\(argument): 是一个目录") }
        guard let text = try? String(contentsOf: target, encoding: .utf8) else {
            throw Failure(message: "\(argument): 不是 UTF-8 文本文件")
        }
        return text
    }

    private func write(_ text: String, to argument: String, append: Bool, cwd: String) throws {
        let target = try url(argument, cwd: cwd)
        let payload = text.isEmpty ? "" : text + "\n"
        let existing = append ? ((try? String(contentsOf: target, encoding: .utf8)) ?? "") : ""
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((existing + payload).utf8).write(to: target, options: .atomic)
        } catch {
            throw Failure(message: "\(argument): \(error.localizedDescription)")
        }
    }

    private func children(of directory: URL, includeHidden: Bool) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: includeHidden ? [] : [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw Failure(message: error.localizedDescription)
        }
    }

    /// 只展开最后一段路径里的 `*` `?`；没匹配到就保留原样（和 sh 的默认行为一致）。
    private func expandGlobs(_ argv: [Token], cwd: String) -> [String] {
        var out = [argv[0].text]
        for token in argv.dropFirst() {
            guard !token.quoted, token.text.contains(where: { $0 == "*" || $0 == "?" }),
                  !token.text.hasPrefix("-") else {
                out.append(token.text)
                continue
            }
            let parts = token.text.split(separator: "/", omittingEmptySubsequences: false)
            let directoryPart = parts.dropLast().joined(separator: "/")
            let pattern = String(parts.last ?? "")
            guard let directory = try? url(directoryPart.isEmpty ? "." : directoryPart, cwd: cwd),
                  let entries = try? children(of: directory, includeHidden: pattern.hasPrefix(".")) else {
                out.append(token.text)
                continue
            }
            let matches = entries.map(\.lastPathComponent).filter { fnmatch(pattern, $0, 0) == 0 }
            out += matches.isEmpty
                ? [token.text]
                : matches.map { directoryPart.isEmpty ? $0 : "\(directoryPart)/\($0)" }
        }
        return out
    }

    // MARK: 命令

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var all = text.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        return all
    }

    /// 拆出 `-abc` 形式的开关与其余位置参数。
    private static func split(_ arguments: [String]) -> (flags: Set<Character>, rest: [String]) {
        var flags = Set<Character>()
        var rest: [String] = []
        for argument in arguments {
            if argument.count > 1, argument.hasPrefix("-"), !argument.dropFirst().contains(where: \.isNumber) {
                flags.formUnion(argument.dropFirst())
            } else {
                rest.append(argument)
            }
        }
        return (flags, rest)
    }

    private func execute(_ argv: [Token], stdin: String, cwd: inout String) throws -> Result {
        let expanded = expandGlobs(argv, cwd: cwd)
        let name = expanded[0]
        let arguments = Array(expanded.dropFirst())
        let workingDirectory = cwd
        func done(_ text: String, code: Int = 0) -> Result { Result(output: text, exitCode: code) }
        func input(_ files: [String]) throws -> String {
            files.isEmpty ? stdin : try files.map { try readText($0, cwd: workingDirectory) }.joined(separator: "\n")
        }

        switch name {
        case "pwd":
            return done("/workspace" + (cwd.isEmpty ? "" : "/\(cwd)"))

        case "cd":
            let target = try url(arguments.first ?? ".", cwd: cwd)
            guard isDirectory(target) else { throw Failure(message: "cd: \(arguments.first ?? ""): 不是目录") }
            cwd = relativePath(target)
            return done("")

        case "echo":
            return done(arguments.filter { $0 != "-n" }.joined(separator: " "))

        case "date":
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss EEEE"
            formatter.locale = Locale(identifier: "zh_CN")
            return done(formatter.string(from: Date()))

        case "ls":
            let (flags, rest) = Self.split(arguments)
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            func describe(_ item: URL) -> String {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let directory = values?.isDirectory == true
                let label = item.lastPathComponent + (directory ? "/" : "")
                guard flags.contains("l") else { return label }
                let size = String(values?.fileSize ?? 0)
                let padding = String(repeating: " ", count: max(0, 8 - size.count))
                let date = values?.contentModificationDate.map(formatter.string(from:)) ?? "-"
                return "\(directory ? "d" : "-")  \(padding)\(directory ? "-" : size)  \(date)  \(label)"
            }
            var blocks: [String] = []
            for target in rest.isEmpty ? ["."] : rest {
                let location = try url(target, cwd: cwd)
                guard FileManager.default.fileExists(atPath: location.path) else {
                    throw Failure(message: "ls: \(target): 没有这个文件或目录")
                }
                let listing = isDirectory(location)
                    ? try children(of: location, includeHidden: flags.contains("a")).map(describe).joined(separator: "\n")
                    : describe(location)
                blocks.append(rest.count > 1 ? "\(target):\n\(listing)" : listing)
            }
            return done(blocks.joined(separator: "\n\n"))

        case "cat":
            return done(Self.lines(try input(arguments)).joined(separator: "\n"))

        case "head", "tail":
            var count = 10
            var files: [String] = []
            var iterator = arguments.makeIterator()
            while let argument = iterator.next() {
                if argument == "-n", let value = iterator.next(), let parsed = Int(value) {
                    count = parsed
                } else if argument.hasPrefix("-n"), let parsed = Int(argument.dropFirst(2)) {
                    count = parsed
                } else if argument.hasPrefix("-"), let parsed = Int(argument.dropFirst()) {
                    count = parsed
                } else {
                    files.append(argument)
                }
            }
            let all = Self.lines(try input(files))
            let picked = name == "head" ? Array(all.prefix(max(0, count))) : Array(all.suffix(max(0, count)))
            return done(picked.joined(separator: "\n"))

        case "wc":
            let (flags, rest) = Self.split(arguments)
            func count(_ text: String, label: String?) -> String {
                let lineCount = Self.lines(text).count
                let wordCount = text.split(whereSeparator: \.isWhitespace).count
                let byteCount = text.utf8.count
                let numbers: [Int]
                if flags.contains("l") { numbers = [lineCount] }
                else if flags.contains("w") { numbers = [wordCount] }
                else if flags.contains("c") { numbers = [byteCount] }
                else { numbers = [lineCount, wordCount, byteCount] }
                return (numbers.map(String.init) + (label.map { [$0] } ?? [])).joined(separator: " ")
            }
            if rest.isEmpty { return done(count(stdin, label: nil)) }
            return done(try rest.map { count(try readText($0, cwd: workingDirectory), label: $0) }.joined(separator: "\n"))

        case "sort":
            let (flags, rest) = Self.split(arguments)
            var all = Self.lines(try input(rest))
            all.sort { flags.contains("n") ? (Double($0) ?? 0) < (Double($1) ?? 0) : $0 < $1 }
            if flags.contains("u") { all = all.reduce(into: []) { if $0.last != $1 { $0.append($1) } } }
            if flags.contains("r") { all.reverse() }
            return done(all.joined(separator: "\n"))

        case "uniq":
            let (flags, rest) = Self.split(arguments)
            var groups: [(line: String, count: Int)] = []
            for line in Self.lines(try input(rest)) {
                if groups.last?.line == line {
                    groups[groups.count - 1].count += 1
                } else {
                    groups.append((line, 1))
                }
            }
            return done(groups.map { flags.contains("c") ? "\($0.count) \($0.line)" : $0.line }.joined(separator: "\n"))

        case "grep":
            let (flags, rest) = Self.split(arguments)
            guard let pattern = rest.first else { throw Failure(message: "grep: 缺少搜索词", code: 2) }
            let options: NSRegularExpression.Options = flags.contains("i") ? [.caseInsensitive] : []
            let regex = (try? NSRegularExpression(pattern: pattern, options: options))
                ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: options))
            func matches(_ line: String) -> Bool {
                let found = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                return found != flags.contains("v")
            }
            var sources: [(label: String?, text: String)] = []
            let targets = Array(rest.dropFirst())
            if targets.isEmpty && !flags.contains("r") {
                sources = [(nil, stdin)]
            } else {
                var files: [String] = []
                for target in targets.isEmpty ? ["."] : targets {
                    let location = try url(target, cwd: cwd)
                    if isDirectory(location) {
                        guard flags.contains("r") else { throw Failure(message: "grep: \(target): 是一个目录（加 -r 递归搜索）", code: 2) }
                        files += try walk(location, display: target == "." ? "" : target).filter { !$0.directory }.map(\.display)
                    } else {
                        files.append(target)
                    }
                }
                let labelled = files.count > 1 || flags.contains("r")
                sources = files.compactMap { file in
                    (try? readText(file, cwd: workingDirectory)).map { (labelled ? file : nil, $0) }
                }
            }
            var output: [String] = []
            var total = 0
            for source in sources {
                var hits: [String] = []
                for (number, line) in Self.lines(source.text).enumerated() where matches(line) {
                    hits.append((flags.contains("n") ? "\(number + 1):" : "") + line)
                }
                total += hits.count
                let prefix = source.label.map { "\($0):" } ?? ""
                if flags.contains("l") {
                    if !hits.isEmpty { output.append(source.label ?? "(stdin)") }
                } else if flags.contains("c") {
                    output.append(prefix + String(hits.count))
                } else {
                    output += hits.map { prefix + $0 }
                }
            }
            return done(output.joined(separator: "\n"), code: total > 0 ? 0 : 1)

        case "find":
            var start = "."
            var namePattern: String?
            var type: String?
            var iterator = arguments.makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "-name": namePattern = iterator.next()
                case "-type": type = iterator.next()
                default: start = argument
                }
            }
            let root = try url(start, cwd: cwd)
            guard isDirectory(root) else { throw Failure(message: "find: \(start): 不是目录") }
            let entries = try walk(root, display: start).filter { entry in
                if let type, (type == "d") != entry.directory { return false }
                if let namePattern, fnmatch(namePattern, (entry.display as NSString).lastPathComponent, 0) != 0 { return false }
                return true
            }
            return done(entries.prefix(500).map(\.display).joined(separator: "\n"))

        case "mkdir":
            let (flags, rest) = Self.split(arguments)
            guard !rest.isEmpty else { throw Failure(message: "mkdir: 缺少目录名", code: 2) }
            for target in rest {
                let location = try url(target, cwd: cwd)
                do {
                    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: flags.contains("p"))
                } catch {
                    throw Failure(message: "mkdir: \(target): \(error.localizedDescription)")
                }
            }
            return done("")

        case "touch":
            guard !arguments.isEmpty else { throw Failure(message: "touch: 缺少文件名", code: 2) }
            for target in arguments {
                let location = try url(target, cwd: cwd)
                if FileManager.default.fileExists(atPath: location.path) {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: location.path)
                } else if !FileManager.default.createFile(atPath: location.path, contents: Data()) {
                    throw Failure(message: "touch: \(target): 无法创建")
                }
            }
            return done("")

        case "cp", "mv":
            let (flags, rest) = Self.split(arguments)
            guard rest.count >= 2, let last = rest.last else { throw Failure(message: "\(name): 需要源路径和目标路径", code: 2) }
            let destination = try url(last, cwd: cwd)
            let intoDirectory = isDirectory(destination)
            guard rest.count == 2 || intoDirectory else { throw Failure(message: "\(name): 目标 \(last) 不是目录") }
            for source in rest.dropLast() {
                let from = try url(source, cwd: cwd)
                guard FileManager.default.fileExists(atPath: from.path) else {
                    throw Failure(message: "\(name): \(source): 没有这个文件或目录")
                }
                guard from.standardizedFileURL.path != toolset.rootURL.standardizedFileURL.path else {
                    throw Failure(message: "\(name): 不能移动或复制整个工作区")
                }
                if name == "cp", isDirectory(from), !flags.contains("r"), !flags.contains("R") {
                    throw Failure(message: "cp: \(source) 是目录（加 -r 复制目录）")
                }
                let target = intoDirectory ? destination.appendingPathComponent(from.lastPathComponent) : destination
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    if name == "cp" {
                        try FileManager.default.copyItem(at: from, to: target)
                    } else {
                        try FileManager.default.moveItem(at: from, to: target)
                    }
                } catch {
                    throw Failure(message: "\(name): \(source): \(error.localizedDescription)")
                }
            }
            return done("")

        case "rm":
            let (flags, rest) = Self.split(arguments)
            guard !rest.isEmpty else { throw Failure(message: "rm: 缺少路径", code: 2) }
            for target in rest {
                let location = try url(target, cwd: cwd)
                guard location.standardizedFileURL.path != toolset.rootURL.standardizedFileURL.path else {
                    throw Failure(message: "rm: 拒绝删除整个工作区")
                }
                guard FileManager.default.fileExists(atPath: location.path) else {
                    if flags.contains("f") { continue }
                    throw Failure(message: "rm: \(target): 没有这个文件或目录")
                }
                if isDirectory(location), !flags.contains("r"), !flags.contains("R") {
                    throw Failure(message: "rm: \(target) 是目录（加 -r 删除目录）")
                }
                do {
                    try FileManager.default.removeItem(at: location)
                } catch {
                    throw Failure(message: "rm: \(target): \(error.localizedDescription)")
                }
            }
            return done("")

        default:
            throw Failure(
                message: "mini-shell: \(name): 不支持的命令。可用：\(Self.supportedCommands.joined(separator: " "))",
                code: 127
            )
        }
    }

    private func walk(_ directory: URL, display: String) throws -> [(display: String, directory: Bool)] {
        var out: [(String, Bool)] = []
        for item in try children(of: directory, includeHidden: false) {
            let label = display.isEmpty ? item.lastPathComponent : "\(display)/\(item.lastPathComponent)"
            let nested = isDirectory(item)
            out.append((label, nested))
            if nested { out += try walk(item, display: label) }
            if out.count > 2000 { break }
        }
        return out
    }
}
