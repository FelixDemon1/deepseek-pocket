import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import DeepSeekCore

/// 助手回答的正文：标题、列表、引用、表格、代码块都按块渲染，观感向 ChatGPT / Claude 手机端看齐。
public struct SegmentedMarkdownView: View {
    public let rawText: String
    @Environment(\.colorScheme) private var scheme

    public init(rawText: String) {
        self.rawText = rawText
    }

    public var body: some View {
        let blocks = MarkdownBlock.parse(rawText)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ink: Color { DeepSeekTheme.primaryInk(scheme) }
    private var secondary: Color { DeepSeekTheme.secondaryInk(scheme) }

    /// 行内 Markdown → AttributedString；行内代码加等宽字体和底色。
    private func inline(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: 14.5, design: .monospaced)
            attributed[run.range].backgroundColor = DeepSeekTheme.hairline(scheme).opacity(0.55)
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = DeepSeekTheme.brandBlue
        }
        return attributed
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(.system(size: level == 1 ? 22 : level == 2 ? 19 : 17, weight: .semibold))
                .foregroundStyle(ink)
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)

        case let .paragraph(text):
            Text(inline(text))
                .font(.system(size: 16))
                .foregroundStyle(ink)
                .lineSpacing(5)
                .textSelection(.enabled)

        case let .list(items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? DeepSeekTheme.brandBlue : secondary)
                            } else if let marker = item.marker {
                                Text(marker).monospacedDigit().foregroundStyle(secondary)
                            } else {
                                Text(item.level == 0 ? "•" : "◦").foregroundStyle(secondary)
                            }
                        }
                        .font(.system(size: 15, weight: .medium))
                        .frame(minWidth: 16, alignment: .trailing)
                        Text(inline(item.text))
                            .font(.system(size: 16))
                            .foregroundStyle(ink)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }

        case let .quote(text):
            Text(inline(text))
                .font(.system(size: 15.5))
                .foregroundStyle(secondary)
                .lineSpacing(4)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(DeepSeekTheme.brandBlue.opacity(0.45)).frame(width: 3)
                }
                .textSelection(.enabled)

        case .rule:
            Rectangle().fill(DeepSeekTheme.hairline(scheme)).frame(height: 1).padding(.vertical, 2)

        case let .table(header, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                        }
                    }
                    .background(DeepSeekTheme.surface(scheme))
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Rectangle().fill(DeepSeekTheme.hairline(scheme)).frame(height: 0.75)
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell))
                                    .font(.system(size: 14))
                                    .foregroundStyle(ink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
                )
            }

        case let .code(language, code):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(language.isEmpty ? "text" : language)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(secondary)
                    Spacer()
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = code
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DeepSeekTheme.hairline(scheme).opacity(0.45))

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(ink)
                        .padding(12)
                        .textSelection(.enabled)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DeepSeekTheme.surface(scheme)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75))
        }
    }
}
