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
        guard url.scheme == "deepseekgo" || url.scheme == "dshgo" else { return }

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
