import SwiftUI
import AppIntents
import DeepSeekCore
import DeepSeekUI
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

@main
struct DeepSeekGoApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootWorkspaceView(vm: viewModel)
                .onAppear {
                    #if canImport(ActivityKit) && os(iOS)
                    viewModel.onLiveActivityUpdate = { stage, active in
                        Task {
                            await LiveActivityCoordinator.shared.update(stage: stage, isRunning: active)
                        }
                    }
                    #endif
                    if CommandLine.arguments.contains("--demo") {
                        viewModel.runInteractiveShowcase()
                    } else if CommandLine.arguments.contains("--models") {
                        viewModel.requestedSheetName = "models"
                    } else if CommandLine.arguments.contains("--settings") {
                        viewModel.requestedSheetName = "settings"
                    } else if CommandLine.arguments.contains("--presets") {
                        viewModel.requestedSheetName = "presets"
                    } else if CommandLine.arguments.contains("--lift-probe") {
                        SandboxLiftProbe.log()
                    } else if CommandLine.arguments.contains("--verify-web") {
                        Task {
                            let resV3 = await viewModel.testWebAdapter(.deepSeekWeb)
                            print("[WEB-ADAPTER-VERIFY-V3] \(resV3)")
                            let resDoubao = await viewModel.testWebAdapter(.doubaoWeb)
                            print("[WEB-ADAPTER-VERIFY-DOUBAO] \(resDoubao)")
                            let resQwen = await viewModel.testWebAdapter(.qwenWeb)
                            print("[WEB-ADAPTER-VERIFY-QWEN] \(resQwen)")
                        }
                    } else if CommandLine.arguments.contains("--verify-python") {
                        // 自检：不经过模型，直接让工具层跑一段 Python（含画图写文件）
                        Task {
                            let code = "import numpy as np, matplotlib.pyplot as plt\nx = np.linspace(0, 6.28, 50)\nplt.plot(x, np.sin(x)); plt.savefig('sine.png')\nprint('mean', round(float(np.mean(np.arange(10))), 2))"
                            let data = (try? JSONSerialization.data(withJSONObject: ["code": code])) ?? Data()
                            let call = ToolCallRequest(id: "py", name: "run_python", argumentsJSON: String(decoding: data, as: UTF8.self))
                            let output = await viewModel.toolset.execute(call, firewall: viewModel.firewall)
                            print("[PYTHON-VERIFY] error=\(output.isError) ms=\(output.durationMs) files=\(output.producedFiles ?? []) | \(output.content.prefix(600))")
                            let shell = ToolCallRequest(id: "sh", name: "run_shell", argumentsJSON: #"{"command":"python3 -c \"import sys; print(sys.version.split()[0])\""}"#)
                            let second = await viewModel.toolset.execute(shell, firewall: viewModel.firewall)
                            print("[PYTHON-VERIFY-2] error=\(second.isError) ms=\(second.durationMs) | \(second.content.prefix(200))")
                        }
                    } else if CommandLine.arguments.contains("--verify-phone") {
                        // 自检：不经过模型，直接通过 PhoneRunner 打开「设置」再点进「通用」
                        Task {
                            let look = ToolCallRequest(id: "l", name: "phone_look", argumentsJSON: #"{"app":"com.apple.Preferences"}"#)
                            let first = await viewModel.toolset.execute(look, firewall: viewModel.firewall)
                            print("[PHONE-VERIFY] error=\(first.isError) | \(first.content.prefix(300).replacingOccurrences(of: "\n", with: "⏎"))")
                            let target = first.content.split(separator: "\n").first { $0.hasSuffix(" 通用") }
                            print("[PHONE-VERIFY-TARGET] \(target ?? "没找到「通用」")")
                            let number = target?.dropFirst().prefix { $0 != "]" } ?? "0"
                            let tap = ToolCallRequest(id: "d", name: "phone_do", argumentsJSON: "{\"actions\":[{\"type\":\"tap\",\"element\":\(number)}]}")
                            let second = await viewModel.toolset.execute(tap, firewall: viewModel.firewall)
                            print("[PHONE-VERIFY-2] error=\(second.isError) | \(second.content.prefix(300).replacingOccurrences(of: "\n", with: "⏎"))")
                        }
                    } else if CommandLine.arguments.contains("--verify-agent") {
                        // 真机自检：用 DeepSeek 网页版跑一个真实的多步任务，把每一步打到控制台
                        Task {
                            if viewModel.hasWebCredential(.deepSeekWeb) {
                                viewModel.activateWebAdapter(.deepSeekWeb)
                            }
                            viewModel.createNewSession()
                            // 可以在参数后面跟一句自定义任务：--verify-agent "整理一下工作区"
                            let arguments = CommandLine.arguments
                            let custom = arguments.firstIndex(of: "--verify-agent")
                                .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                                .flatMap { $0.hasPrefix("--") ? nil : $0 }
                            viewModel.sendOrSteer(text: custom ?? "先用 run_shell 执行 ls -la 看看工作区里有什么，再读 WELCOME.md，最后用一句话告诉我这个文件写了什么。")
                            var announced: String?
                            while viewModel.isStreaming {
                                if let pending = viewModel.pendingApproval, pending.id != announced {
                                    announced = pending.id
                                    print("[AGENT-VERIFY-WAIT] 等你在手机上确认：\(pending.summary)")
                                }
                                try? await Task.sleep(for: .milliseconds(500))
                            }
                            for message in viewModel.activeSession?.messages ?? [] where message.role != .system {
                                let calls = message.toolCalls.map { "\($0.name)\($0.argumentsJSON)" }.joined(separator: " ")
                                let state = message.toolOutput.map { $0.isError ? "失败" : "成功" } ?? ""
                                print("[AGENT-VERIFY] \(message.role.rawValue) \(state) \(calls) | \(message.content.prefix(200).replacingOccurrences(of: "\n", with: "⏎"))")
                            }
                            print("[AGENT-VERIFY-DONE] error=\(viewModel.errorBanner ?? "无")")
                        }
                    } else if let pendingPrompt = QuickPromptBridge.shared.consumePendingPrompt() {
                        viewModel.sendOrSteer(text: pendingPrompt)
                    }
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["deepseekpocket", "deepseekgo", "tide", "dshgo"].contains(scheme) else { return }

        // One-tap onboarding: deepseekgo://setup?base=…&key=…&model=…
        if viewModel.handleSetupURL(url) { return }

        switch url.host {
        case "demo":
            viewModel.runInteractiveShowcase()
        case "new":
            viewModel.createNewSession()
        case "ask":
            if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value, !q.isEmpty {
                viewModel.sendOrSteer(text: q)
            }
        default:
            break
        }
    }
}

// MARK: - Siri & iPhone Action Button App Intents

@MainActor
final class QuickPromptBridge {
    static let shared = QuickPromptBridge()
    private var pendingPrompt: String?

    func enqueue(_ prompt: String) {
        pendingPrompt = prompt
    }

    func consumePendingPrompt() -> String? {
        defer { pendingPrompt = nil }
        return pendingPrompt
    }
}

struct AskDeepSeekIntent: AppIntent {
    static let title: LocalizedStringResource = "向 DeepSeek Go 发起任务"
    static let description = IntentDescription("打开零遥测本机 Agent 工作区并立即填入任务。")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "任务或问题")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickPromptBridge.shared.enqueue(prompt)
        return .result()
    }
}

struct DeepSeekGoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskDeepSeekIntent(),
            phrases: [
                "用 \(.applicationName) 提问",
                "打开 \(.applicationName) 执行任务"
            ],
            shortTitle: "发起 Agent 任务",
            systemImageName: "sparkles"
        )
    }
}

// MARK: - Dynamic Island / Lock Screen Live Activity Attributes (iOS)

#if canImport(ActivityKit) && os(iOS)
public struct AgentTurnAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var stage: String
        public var isRunning: Bool
    }
    public var title: String
}

@MainActor
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()

    func update(stage: String, isRunning: Bool) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = AgentTurnAttributes.ContentState(stage: stage, isRunning: isRunning)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))

        if isRunning {
            if let active = Activity<AgentTurnAttributes>.activities.first {
                await active.update(content)
            } else {
                let attrs = AgentTurnAttributes(title: "DeepSeek Go")
                _ = try? Activity.request(attributes: attrs, content: content, pushType: nil)
            }
        } else {
            for active in Activity<AgentTurnAttributes>.activities {
                await active.end(content, dismissalPolicy: .default)
            }
        }
    }
}
#endif
