import SwiftUI
import DeepSeekCore

public struct MessageRowView: View {
    public let message: ChatMessage
    public let pendingApproval: PendingToolApproval?
    public let requireFaceID: Bool
    public let isLastAssistant: Bool
    /// 正在生成且还没收到任何内容时的占位提示（如「正在连接 豆包网页版…」）
    public let liveStatus: String?
    /// agent 轮里思考过程已经在轨迹中展示，最终回答不再重复
    public let hideReasoning: Bool
    /// 代替 token 用量显示的页脚（如「23 秒 · 4 步 · 3.4 万 tokens」）
    public let footnote: String?
    public let showUnrestrictedBadge: Bool
    public let onApprove: (Bool) -> Void
    public let onOpenArtifact: (ArtifactPayload) -> Void
    public let onFork: () -> Void
    public let onRegenerate: () -> Void
    public let onShare: () -> Void
    public var onEditUser: ((String) -> Void)?

    @Environment(\.colorScheme) private var scheme
    @State private var reasoningExpanded: Bool = false
    @State private var toolDetailExpanded: Bool = false

    public init(
        message: ChatMessage,
        pendingApproval: PendingToolApproval?,
        requireFaceID: Bool,
        isLastAssistant: Bool = false,
        liveStatus: String? = nil,
        hideReasoning: Bool = false,
        footnote: String? = nil,
        showUnrestrictedBadge: Bool = false,
        onApprove: @escaping (Bool) -> Void,
        onOpenArtifact: @escaping (ArtifactPayload) -> Void,
        onFork: @escaping () -> Void = {},
        onRegenerate: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onEditUser: ((String) -> Void)? = nil
    ) {
        self.message = message
        self.pendingApproval = pendingApproval
        self.requireFaceID = requireFaceID
        self.isLastAssistant = isLastAssistant
        self.liveStatus = liveStatus
        self.hideReasoning = hideReasoning
        self.footnote = footnote
        self.showUnrestrictedBadge = showUnrestrictedBadge
        self.onApprove = onApprove
        self.onOpenArtifact = onOpenArtifact
        self.onFork = onFork
        self.onRegenerate = onRegenerate
        self.onShare = onShare
        self.onEditUser = onEditUser
    }

    public var body: some View {
        switch message.role {
        case .system:
            EmptyView()
        case .user:
            userBubble
        case .assistant:
            assistantSection
        case .tool:
            compactToolRow
        }
    }

    // MARK: - Minimalist Neutral User Pill (ChatGPT / Gemini Style)

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 52)
            VStack(alignment: .trailing, spacing: 4) {
                if message.isSteerInjection {
                    Text("中途补充")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                }
                Text(message.content)
                    .font(.system(size: 16))
                    .lineSpacing(3)
                    .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(DeepSeekTheme.userBubble(scheme))
                    )
                    #if os(iOS)
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
                    #endif
                    .contextMenu {
                        Button {
                            copyText(message.content)
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        if let onEditUser {
                            Button {
                                onEditUser(message.content)
                            } label: {
                                Label("重新编辑", systemImage: "pencil")
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Frameless Editorial Assistant Section

    private var assistantSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let liveStatus,
               message.content.isEmpty,
               hideReasoning || (message.reasoningContent ?? "").isEmpty,
               message.toolCalls.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(liveStatus)
                        .font(.system(size: 14))
                        .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }

            if !hideReasoning, let reasoning = message.reasoningContent, !reasoning.isEmpty {
                thinkingDisclosure(reasoning)
            }

            if !message.content.isEmpty {
                SegmentedMarkdownView(rawText: message.content)
            }

            if !message.toolCalls.isEmpty {
                ForEach(message.toolCalls) { call in
                    if let pending = pendingApproval, pending.call.id == call.id {
                        ApprovalCardView(pending: pending, requireFaceID: requireFaceID, onApprove: onApprove)
                    }
                }
            }

            if !message.content.isEmpty {
                HStack(spacing: 16) {
                    Button {
                        copyText(message.content)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }

                    if isLastAssistant {
                        Button(action: onRegenerate) {
                            Image(systemName: "arrow.clockwise")
                        }
                    }

                    Button(action: onFork) {
                        Image(systemName: "arrow.triangle.branch")
                    }

                    Button(action: onShare) {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Spacer()

                    if showUnrestrictedBadge {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.shield")
                                .font(.system(size: 10, weight: .semibold))
                            Text("无限制")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(DeepSeekTheme.brandBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DeepSeekTheme.brandSoftFill(scheme)))
                    }

                    if let footnote, !footnote.isEmpty {
                        Text(footnote)
                            .font(.system(size: 11))
                    } else if let usage = message.usage {
                        Text(usageLabel(usage))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usageLabel(_ usage: TokenUsage) -> String {
        if usage.cacheHitTokens > 0 {
            return "\(usage.totalTokens) tok · 缓存 \(Int(usage.cacheHitRatio * 100))%"
        }
        return "\(usage.totalTokens) tok"
    }

    private func thinkingDisclosure(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    reasoningExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DeepSeekTheme.brandBlue)
                    Text(
                        message.reasoningDurationSec != nil
                            ? String(format: "%.1fs", message.reasoningDurationSec!)
                            : "…"
                    )
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Image(systemName: reasoningExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
            }
            .buttonStyle(.plain)

            if reasoningExpanded {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                    .lineSpacing(4)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(DeepSeekTheme.hairline(scheme))
                            .frame(width: 1.5)
                    }
            }
        }
    }

    // MARK: - Whisper-Quiet Compact Tool Row & Clean Artifact Card

    private var compactToolRow: some View {
        let out = message.toolOutput
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    toolDetailExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: (out?.isError == true) ? "exclamationmark.circle" : "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(out?.toolName ?? "tool")")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text("· \(out?.durationMs ?? 0)ms")
                        .font(.system(size: 12))
                    Image(systemName: toolDetailExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(DeepSeekTheme.surface(scheme)))
            }
            .buttonStyle(.plain)

            if toolDetailExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                        .lineLimit(10)

                    if let diff = out?.unifiedDiff, !diff.isEmpty {
                        DiffBlockView(diff: diff)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DeepSeekTheme.surface(scheme))
                )
            }

            if let artifact = out?.artifact {
                Button {
                    onOpenArtifact(artifact)
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(DeepSeekTheme.primaryInk(scheme).opacity(0.08))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Image(systemName: "macwindow")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                            )
                        Text(artifact.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DeepSeekTheme.surface(scheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func copyText(_ str: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = str
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
        #endif
    }
}

/// 工具调用等待用户确认时的卡片：说明要做什么，附带 Diff，允许 / 取消。
public struct ApprovalCardView: View {
    public let pending: PendingToolApproval
    public let requireFaceID: Bool
    public let onApprove: (Bool) -> Void
    public let onApproveTurn: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    public init(
        pending: PendingToolApproval,
        requireFaceID: Bool,
        onApprove: @escaping (Bool) -> Void,
        onApproveTurn: (() -> Void)? = nil
    ) {
        self.pending = pending
        self.requireFaceID = requireFaceID
        self.onApprove = onApprove
        self.onApproveTurn = onApproveTurn
    }

    public var body: some View {
        let ink = DeepSeekTheme.primaryInk(scheme)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ink)
                Text(pending.summary)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ink)
                Spacer()
            }

            if let diff = pending.unifiedDiff, !diff.isEmpty {
                DiffBlockView(diff: diff)
            }

            HStack(spacing: 10) {
                Button {
                    onApprove(true)
                } label: {
                    HStack(spacing: 6) {
                        if requireFaceID {
                            Image(systemName: "faceid")
                        }
                        Text(pending.allowsTurnGrant ? "只允许这一步" : "允许")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DeepSeekTheme.brandBlue))
                    .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)

                Button {
                    onApprove(false)
                } label: {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 1)
                        )
                        .foregroundStyle(ink)
                }
                .buttonStyle(.plain)
            }

            // 真机实测：一轮手机操作要确认很多次，小字链接容易漏看，任务就卡在那里——做成和「允许」同级的按钮
            if pending.allowsTurnGrant, let onApproveTurn {
                Button(action: onApproveTurn) {
                    Text("本轮都允许（后面的步骤不再问）")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DeepSeekTheme.brandSoftFill(scheme))
                        )
                        .foregroundStyle(DeepSeekTheme.brandBlue)
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
}

public struct DiffBlockView: View {
    public let diff: String
    @Environment(\.colorScheme) private var scheme

    public init(diff: String) {
        self.diff = diff
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(bg(for: line))
                }
            }
            .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DeepSeekTheme.canvas(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
                )
        )
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+ ") { return DeepSeekTheme.diffAdded }
        if line.hasPrefix("- ") { return DeepSeekTheme.diffRemoved }
        return DeepSeekTheme.secondaryInk(scheme)
    }

    private func bg(for line: String) -> Color {
        if line.hasPrefix("+ ") { return DeepSeekTheme.diffAdded.opacity(0.09) }
        if line.hasPrefix("- ") { return DeepSeekTheme.diffRemoved.opacity(0.09) }
        return .clear
    }
}
