import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import QuickLook
#endif
import DeepSeekCore

/// 一轮助手执行。纯聊天的一轮沿用原来的消息视图；动过工具的一轮展示成 agent 轨迹：
/// 计划卡 → 一步一行的过程（可展开成终端块 / Diff）→ 最终回答 → 改动与产物。
public struct AgentTurnView: View {
    public let messages: [ChatMessage]
    public let isLive: Bool
    public let liveStatus: String?
    public let pendingApproval: PendingToolApproval?
    public let requireFaceID: Bool
    public let isLastTurn: Bool
    public let showUnrestrictedBadge: Bool
    /// 工作区根目录：用来给脚本产出的文件显示缩略图和预览
    public var workspaceRoot: URL?
    public let onApprove: (Bool) -> Void
    public var onApproveTurn: (() -> Void)?
    public let onOpenArtifact: (ArtifactPayload) -> Void
    public let onFork: (UUID) -> Void
    public let onRegenerate: () -> Void
    public let onShare: () -> Void

    @Environment(\.colorScheme) private var scheme
    /// 做完之后过程默认折叠成一行
    @State private var trajectoryExpanded = false
    @State private var openStepIDs: Set<String> = []
    @State private var openFilePath: String?
    @State private var previewURL: URL?

    public init(
        messages: [ChatMessage],
        isLive: Bool,
        liveStatus: String?,
        pendingApproval: PendingToolApproval?,
        requireFaceID: Bool,
        isLastTurn: Bool,
        showUnrestrictedBadge: Bool,
        workspaceRoot: URL? = nil,
        onApprove: @escaping (Bool) -> Void,
        onApproveTurn: (() -> Void)? = nil,
        onOpenArtifact: @escaping (ArtifactPayload) -> Void,
        onFork: @escaping (UUID) -> Void,
        onRegenerate: @escaping () -> Void,
        onShare: @escaping () -> Void
    ) {
        self.messages = messages
        self.isLive = isLive
        self.liveStatus = liveStatus
        self.pendingApproval = pendingApproval
        self.requireFaceID = requireFaceID
        self.isLastTurn = isLastTurn
        self.showUnrestrictedBadge = showUnrestrictedBadge
        self.workspaceRoot = workspaceRoot
        self.onApprove = onApprove
        self.onApproveTurn = onApproveTurn
        self.onOpenArtifact = onOpenArtifact
        self.onFork = onFork
        self.onRegenerate = onRegenerate
        self.onShare = onShare
    }

    public var body: some View {
        let turn = AgentTurn(messages: messages)
        if turn.hasToolCalls {
            agentBody(turn)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(messages) { message in
                    messageRow(message, hideReasoning: false, footnote: nil)
                }
            }
        }
    }

    private func messageRow(_ message: ChatMessage, hideReasoning: Bool, footnote: String?) -> some View {
        MessageRowView(
            message: message,
            pendingApproval: pendingApproval,
            requireFaceID: requireFaceID,
            isLastAssistant: isLastTurn && message.id == messages.last(where: { $0.role == .assistant })?.id,
            liveStatus: isLive && message.id == messages.last?.id ? liveStatus : nil,
            hideReasoning: hideReasoning,
            footnote: footnote,
            showUnrestrictedBadge: showUnrestrictedBadge,
            onApprove: onApprove,
            onOpenArtifact: onOpenArtifact,
            onFork: { onFork(message.id) },
            onRegenerate: onRegenerate,
            onShare: onShare
        )
    }

    // MARK: - Agent 轨迹

    private func agentBody(_ turn: AgentTurn) -> some View {
        let secondary = DeepSeekTheme.secondaryInk(scheme)
        let showsTrajectory = isLive || trajectoryExpanded

        return VStack(alignment: .leading, spacing: 12) {
            if !isLive {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { trajectoryExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: turn.finalMessage == nil ? "stop.circle" : "checkmark.circle")
                            .font(.system(size: 13, weight: .medium))
                        Text(summaryLine(turn))
                            .font(.system(size: 13))
                        Spacer(minLength: 8)
                        Image(systemName: trajectoryExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !turn.plan.isEmpty, showsTrajectory {
                AgentPlanCard(steps: turn.plan, isLive: isLive)
            }

            if showsTrajectory {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(turn.steps) { step in
                        stepRow(step, isLastStep: step.id == turn.steps.last?.id)
                    }
                }
            }

            if let final = turn.finalMessage {
                messageRow(final, hideReasoning: true, footnote: isLive ? nil : turn.footnote)
            }

            if !turn.changedFiles.isEmpty || !turn.artifacts.isEmpty || !turn.producedFiles.isEmpty {
                deliverablesCard(turn)
            }

            // 等确认的卡片永远放在这一轮的最下面，离手指最近
            if let pending = pendingApproval, messages.contains(where: { $0.toolCalls.contains { $0.id == pending.call.id } }) {
                ApprovalCardView(pending: pending, requireFaceID: requireFaceID, onApprove: onApprove, onApproveTurn: onApproveTurn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .quickLookPreview($previewURL)
        #endif
    }

    private func summaryLine(_ turn: AgentTurn) -> String {
        var parts = [turn.finalMessage == nil ? "已中断" : "已完成"]
        if turn.actionCount > 0 { parts.append("\(turn.actionCount) 次工具调用") }
        if let duration = turn.durationSec { parts.append(AgentTurn.formatDuration(duration)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func stepRow(_ step: AgentTurnStep, isLastStep: Bool) -> some View {
        let secondary = DeepSeekTheme.secondaryInk(scheme)
        switch step.kind {
        case let .note(text):
            SegmentedMarkdownView(rawText: text)

        case let .thinking(text, seconds):
            let open = openStepIDs.contains(step.id)
            VStack(alignment: .leading, spacing: 6) {
                Button { toggle(step.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DeepSeekTheme.brandBlue)
                            .frame(width: 18)
                        (Text("思考").fontWeight(.medium) + Text(" · \(Self.headline(text, latest: isLive && isLastStep))"))
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let seconds, seconds >= 0.1 {
                            Text(String(format: "%.1fs", seconds))
                                .font(.system(size: 11, design: .monospaced))
                        }
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if open {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(secondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(.leading, 26)
                }
            }

        case let .tool(call, output):
            let look = ToolPresentation.describe(call)
            let running = output == nil
            let waitingApproval = pendingApproval?.call.id == call.id
            let open = openStepIDs.contains(step.id) || (isLive && isLastStep && look.isCommand && !waitingApproval)
            VStack(alignment: .leading, spacing: 7) {
                Button { toggle(step.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: look.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                        (Text(look.verb).fontWeight(.medium) + Text(" · ")
                            + Text(look.detail).font(.system(size: 12.5, design: look.isCommand ? .monospaced : .default)))
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if waitingApproval {
                            Text("待确认")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                        } else if running {
                            ProgressView().controlSize(.mini)
                        } else if output?.isError == true {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(DeepSeekTheme.diffRemoved)
                        } else {
                            Image(systemName: open ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .foregroundStyle(secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if open {
                    Group {
                        if look.isCommand {
                            TerminalBlockView(
                                commandLine: look.commandLine,
                                output: output?.content,
                                isError: output?.isError == true,
                                durationMs: output?.durationMs
                            )
                        } else if let diff = output?.unifiedDiff, !diff.isEmpty {
                            DiffBlockView(diff: diff)
                        } else if let content = output?.content {
                            Text(content)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(secondary)
                                .lineLimit(12)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DeepSeekTheme.surface(scheme)))
                        }
                    }
                    .padding(.leading, 26)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if openStepIDs.contains(id) { openStepIDs.remove(id) } else { openStepIDs.insert(id) }
        }
    }

    /// 思考行的一句话摘要：正在想的时候跟着最新一行走，想完了显示第一行。
    private static func headline(_ text: String, latest: Bool) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let line = (latest ? lines.last : lines.first).map(String.init) ?? text
        return line.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 改动与产物

    private func deliverablesCard(_ turn: AgentTurn) -> some View {
        let ink = DeepSeekTheme.primaryInk(scheme)
        let secondary = DeepSeekTheme.secondaryInk(scheme)
        let added = turn.changedFiles.reduce(0) { $0 + $1.added }
        let removed = turn.changedFiles.reduce(0) { $0 + $1.removed }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: turn.changedFiles.isEmpty ? "shippingbox" : "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .medium))
                Text(turn.changedFiles.isEmpty
                     ? "交付了 \(turn.artifacts.count + turn.producedFiles.count) 个文件"
                     : "改动了 \(turn.changedFiles.count + turn.producedFiles.count) 个文件")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !turn.changedFiles.isEmpty {
                    Self.statText(added: added, removed: removed)
                }
            }
            .foregroundStyle(ink)

            ForEach(turn.changedFiles) { file in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            openFilePath = openFilePath == file.path ? nil : file.path
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 13))
                                .foregroundStyle(secondary)
                            Text((file.path as NSString).lastPathComponent)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(ink)
                                .lineLimit(1)
                            Text((file.path as NSString).deletingLastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(secondary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Self.statText(added: file.added, removed: file.removed)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if openFilePath == file.path {
                        DiffBlockView(diff: file.diff)
                    }
                }
            }

            ForEach(turn.producedFiles, id: \.self) { path in
                producedFileRow(path, ink: ink, secondary: secondary)
            }

            ForEach(turn.artifacts) { artifact in
                Button {
                    onOpenArtifact(artifact)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 13))
                            .foregroundStyle(secondary)
                        Text(artifact.title)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                        Text(artifact.kind.rawValue)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(secondary)
                        Spacer(minLength: 6)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DeepSeekTheme.brandBlue)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DeepSeekTheme.surface(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
                )
        )
    }

    @ViewBuilder
    private func producedFileRow(_ path: String, ink: Color, secondary: Color) -> some View {
        let url = workspaceRoot?.appendingPathComponent(path)
        let isImage = ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((path as NSString).pathExtension.lowercased())
        Button {
            previewURL = url
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                #if canImport(UIKit)
                if isImage, let url, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                #endif
                HStack(spacing: 8) {
                    Image(systemName: isImage ? "photo" : "doc")
                        .font(.system(size: 13))
                        .foregroundStyle(secondary)
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    Text((path as NSString).deletingLastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DeepSeekTheme.brandBlue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func statText(added: Int, removed: Int) -> Text {
        Text("+\(added)").foregroundStyle(DeepSeekTheme.diffAdded)
            + Text(removed > 0 ? "  -\(removed)" : "").foregroundStyle(DeepSeekTheme.diffRemoved)
    }
}

// MARK: - 计划卡

struct AgentPlanCard: View {
    let steps: [AgentPlanStep]
    let isLive: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let done = steps.filter { $0.status == .done }.count
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                Text("计划")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(done)/\(steps.count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
            }
            .foregroundStyle(DeepSeekTheme.primaryInk(scheme))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DeepSeekTheme.hairline(scheme))
                    Capsule().fill(DeepSeekTheme.brandBlue)
                        .frame(width: geo.size.width * CGFloat(done) / CGFloat(max(steps.count, 1)))
                }
            }
            .frame(height: 3)

            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        switch step.status {
                        case .done:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(DeepSeekTheme.diffAdded)
                        case .inProgress:
                            Image(systemName: "circle.inset.filled").foregroundStyle(DeepSeekTheme.brandBlue)
                        case .pending:
                            Image(systemName: "circle").foregroundStyle(DeepSeekTheme.secondaryInk(scheme).opacity(0.5))
                        }
                    }
                    .font(.system(size: 13))
                    Text(step.title)
                        .font(.system(size: 13.5, weight: step.status == .inProgress ? .semibold : .regular))
                        .foregroundStyle(step.status == .done
                                         ? DeepSeekTheme.secondaryInk(scheme)
                                         : DeepSeekTheme.primaryInk(scheme))
                }
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DeepSeekTheme.surface(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
                )
        )
        .animation(.snappy(duration: 0.25), value: steps)
    }
}

// MARK: - 终端块

/// 深色终端样式的命令 + 输出。深浅色模式下都保持终端的样子。
struct TerminalBlockView: View {
    let commandLine: String
    /// nil 表示命令还在跑
    let output: String?
    let isError: Bool
    let durationMs: Int?

    @State private var showAll = false
    @State private var cursorOn = true

    private static let previewLineCount = 14
    private static let background = Color(red: 0.055, green: 0.067, blue: 0.090)
    private static let chrome = Color(red: 0.090, green: 0.106, blue: 0.137)
    private static let text = Color(white: 0.86)
    private static let dim = Color(white: 0.55)
    private static let green = Color(red: 0.36, green: 0.82, blue: 0.52)
    private static let red = Color(red: 0.97, green: 0.47, blue: 0.47)

    var body: some View {
        let lines = (output ?? "").components(separatedBy: "\n")
        let visible = showAll ? lines : Array(lines.prefix(Self.previewLineCount))
        let hidden = lines.count - visible.count

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach([Color(red: 1.0, green: 0.37, blue: 0.34), Color(red: 1.0, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) { dot in
                    Circle().fill(dot.opacity(0.85)).frame(width: 7, height: 7)
                }
                Text("workspace — mini-shell")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Self.dim)
                    .padding(.leading, 4)
                Spacer()
                if output == nil {
                    Text("运行中")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Self.dim)
                } else {
                    Text((isError ? "✗ 失败" : "✓") + (durationMs.map { " \($0)ms" } ?? ""))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(isError ? Self.red : Self.green)
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = "$ \(commandLine)\n\(output ?? "")"
                        #endif
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(Self.dim)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Self.chrome)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        (Text("$ ").foregroundStyle(Self.green) + Text(commandLine).foregroundStyle(Color.white))
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        if output == nil {
                            Text(" ▍")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Self.green)
                                .opacity(cursorOn ? 1 : 0)
                                .onAppear {
                                    withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                                        cursorOn = false
                                    }
                                }
                        }
                    }
                    if let output, !output.isEmpty {
                        Text(visible.joined(separator: "\n"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(isError ? Self.red : Self.text)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
            }

            if hidden > 0 {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showAll = true }
                } label: {
                    Text("… 还有 \(hidden) 行，点按展开")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.dim)
                        .padding(.horizontal, 11)
                        .padding(.bottom, 9)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 输入框上方的实时状态条

/// 「运行 · grep -rn TODO .          0:20」—— 让用户随时知道 agent 正在干什么、干了多久。
struct LiveActivityBar: View {
    let tool: ToolPresentation?
    let fallbackText: String
    let startedAt: Date
    let waitingApproval: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let secondary = DeepSeekTheme.secondaryInk(scheme)
        HStack(spacing: 8) {
            if waitingApproval {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.mini)
            }
            if let tool {
                (Text(waitingApproval ? "等你确认" : tool.verb).fontWeight(.semibold)
                    + Text("  ")
                    + Text(tool.detail).font(.system(size: 12, design: tool.isCommand ? .monospaced : .default)))
                    .font(.system(size: 12.5))
                    .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                    .lineLimit(1)
            } else {
                Text(fallbackText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(DeepSeekTheme.surface(scheme))
                .overlay(Capsule().stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75))
        )
    }
}
