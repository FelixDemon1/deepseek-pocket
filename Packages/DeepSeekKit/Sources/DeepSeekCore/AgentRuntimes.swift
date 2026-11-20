import Foundation

// ---------------------------------------------------------------------------
// 需要平台能力的运行时（Python、手机操控）由 App 层实现，在这里登记给工具层用。
// Core 本身不依赖 WebKit / XCTest，macOS 上的单测也就不需要它们。
// ---------------------------------------------------------------------------

public struct PythonRunRequest: Sendable {
    /// 直接执行的代码；与 `scriptPath` 二选一
    public var code: String?
    /// 工作区内的脚本相对路径
    public var scriptPath: String?
    public var args: [String]
    /// 运行前先装好的包（`pip install` 用）
    public var packages: [String]
    public var toolset: WorkspaceToolset

    public init(code: String? = nil, scriptPath: String? = nil, args: [String] = [], packages: [String] = [], toolset: WorkspaceToolset) {
        self.code = code
        self.scriptPath = scriptPath
        self.args = args
        self.packages = packages
        self.toolset = toolset
    }
}

public struct PythonRunResult: Sendable, Equatable {
    public var output: String
    public var exitCode: Int
    /// 这次运行新建或改动的工作区文件（相对路径）
    public var writtenFiles: [String]

    public init(output: String, exitCode: Int, writtenFiles: [String] = []) {
        self.output = output
        self.exitCode = exitCode
        self.writtenFiles = writtenFiles
    }
}

public protocol PythonRuntime: Sendable {
    func run(_ request: PythonRunRequest) async throws -> PythonRunResult
}

public final class AgentRuntimeHooks: @unchecked Sendable {
    public static let shared = AgentRuntimeHooks()
    private let lock = NSLock()
    private var pythonRuntime: (any PythonRuntime)?
    private var phoneReady = false

    public var python: (any PythonRuntime)? {
        get { lock.withLock { pythonRuntime } }
        set { lock.withLock { pythonRuntime = newValue } }
    }

    /// 手机操控驱动（PhoneRunner）当前是否在线；在线时才把 phone_* 工具交给模型。
    public var phoneAvailable: Bool {
        get { lock.withLock { phoneReady } }
        set { lock.withLock { phoneReady = newValue } }
    }
}

public enum PythonCommand {
    /// 把 `python3 a.py 1 2`、`python3 -c "print(1)"`、`pip install numpy` 这类命令行翻译成运行请求；不是 Python 命令返回 nil。
    public static func request(fromShell commandLine: String, toolset: WorkspaceToolset) -> PythonRunRequest? {
        guard let argv = MiniShell.simpleArgv(commandLine), let name = argv.first else { return nil }
        let rest = Array(argv.dropFirst())
        switch name {
        case "python", "python3":
            if rest.first == "-c", rest.count >= 2 {
                return PythonRunRequest(code: rest[1], args: ["-c"] + rest.dropFirst(2), toolset: toolset)
            }
            guard let script = rest.first, !script.hasPrefix("-") else { return nil }
            return PythonRunRequest(scriptPath: script, args: rest, toolset: toolset)
        case "pip", "pip3":
            guard rest.first == "install" else { return nil }
            let packages = rest.dropFirst().filter { !$0.hasPrefix("-") }
            guard !packages.isEmpty else { return nil }
            return PythonRunRequest(code: "print('已安装：\(packages.joined(separator: " "))')", packages: Array(packages), toolset: toolset)
        default:
            return nil
        }
    }
}
