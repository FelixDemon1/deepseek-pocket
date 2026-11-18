import SwiftUI
import DeepSeekCore

public struct MessageRowView: View {
    public let message: ChatMessage
    public let pendingApproval: PendingToolApproval?
    public let requireFaceID: Bool
    public let isLastAssistant: Bool
    public let onApprove: (Bool) -> Void
    public let onOpenArtifact: (ArtifactPayload) -> Void
    public let onFork: () -> Void
    public let onRegenerate: () -> Void
    public let onShare: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var reasoningExpanded: Bool = false
    @State private var toolDetailExpanded: Bool = false

    public init(
        message: ChatMessage,
        pendingApproval: PendingToolApproval?,
        requireFaceID: Bool,
        isLastAssistant: Bool = false,
        onApprove: @escaping (Bool) -> Void,
        onOpenArtifact: @escaping (ArtifactPayload) -> Void,
        onFork: @escaping () -> Void = {},
        onRegenerate: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {}
    ) {
        self.message = message
        self.pendingApproval = pendingApproval
        self.requireFaceID = requireFaceID
        self.isLastAssistant = isLastAssistant
        self.onApprove = onApprove
        self.onOpenArtifact = onOpenArtifact
        self.onFork = onFork
        self.onRegenerate = onRegenerate
        self.onShare = onShare
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
            }
        }
    }

    // MARK: - Frameless Editorial Assistant Section

    private var assistantSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                thinkingDisclosure(reasoning)
            }

            if !message.content.isEmpty {
                SegmentedMarkdownView(rawText: message.content)
            }

            if !message.toolCalls.isEmpty {
                ForEach(message.toolCalls) { call in
                    if let pending = pendingApproval, pending.call.id == call.id {
                        approvalCard(pending)
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

                    if let usage = message.usage {
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

    // MARK: - Clean Monochrome Approval Card

    private func approvalCard(_ pending: PendingToolApproval) -> some View {
        let ink = DeepSeekTheme.primaryInk(scheme)

        return VStack(alignment: .leading, spacing: 12) {
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
                        Text("允许")
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

public struct SegmentedMarkdownView: View {
    public let rawText: String
    @Environment(\.colorScheme) private var scheme

    public init(rawText: String) {
        self.rawText = rawText
    }

    private enum Segment: Identifiable {
        case prose(id: Int, text: String)
        case code(id: Int, lang: String, code: String)

        var id: Int {
            switch self {
            case let .prose(id, _), let .code(id, _, _): return id
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parseSegments(rawText)) { seg in
                switch seg {
                case let .prose(_, text):
                    if let attr = try? AttributedString(
                        markdown: text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attr)
                            .font(.system(size: 16))
                            .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    } else {
                        Text(text)
                            .font(.system(size: 16))
                            .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                case let .code(_, lang, code):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(lang.isEmpty ? "text" : lang)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                            Spacer()
                            Button {
                                copyCode(code)
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(DeepSeekTheme.hairline(scheme).opacity(0.45))

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                                .padding(12)
                                .textSelection(.enabled)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DeepSeekTheme.surface(scheme)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75))
                }
            }
        }
    }

    private func parseSegments(_ input: String) -> [Segment] {
        let parts = input.components(separatedBy: "```")
        var out: [Segment] = []
        for (index, part) in parts.enumerated() {
            if index.isMultiple(of: 2) {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    out.append(.prose(id: index, text: trimmed))
                }
            } else {
                let lines = part.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
                out.append(.code(id: index, lang: lang, code: body))
            }
        }
        return out
    }

    private func copyCode(_ str: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = str
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
        #endif
    }
}
