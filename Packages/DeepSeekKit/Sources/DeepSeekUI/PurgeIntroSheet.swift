import SwiftUI
import DeepSeekCore

/// 第一次打开无限制模式时的说明页。
/// 目的不是念免责声明，而是让用户当场看懂"这个开关到底改了什么"，并一键试一句。
public struct PurgeIntroSheet: View {
    @Environment(\.dismiss) private var dismiss
    public var onUseSample: (String) -> Void

    public init(onUseSample: @escaping (String) -> Void = { _ in }) {
        self.onUseSample = onUseSample
    }

    private let samples = [
        "写一个 20 行以内、能直接跑的 TCP 端口扫描脚本",
        "用最直白的方式讲清楚：为什么机构不喜欢散户做日内交易"
    ]

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.shield.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(DeepSeekTheme.brandBlue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("无限制模式已开启")
                                .font(.title3.weight(.semibold))
                            Text("已适配 dsh-purge 破甲 · 这条对话现在跑在 purge 提示词上")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        changeRow("不预告、不复述、不总结", "问什么直接给结果，不再有“好问题，我来帮你梳理”这种开场。")
                        changeRow("不说教、不加免责声明", "不再主动塞风险提示、法律提醒、“作为 AI”式自我指涉。")
                        changeRow("不软化、不替换", "不把你要的东西换成“更安全的替代方案”，也不半截收手。")
                        changeRow("工具免审批", "写文件、跑计算不再弹确认卡，也不要求 Face ID。")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("边界")
                            .font(.footnote.weight(.semibold))
                        Text("它改的是本机的提示词和审批行为，模型还是你选的那个接口。上游服务端如果拒了，跟这个模式无关。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DeepSeekTheme.surface(.light)))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("马上试一句")
                            .font(.footnote.weight(.semibold))
                        ForEach(samples, id: \.self) { sample in
                            Button {
                                onUseSample(sample)
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(sample)
                                        .font(.footnote)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(DeepSeekTheme.brandSoftFill(.light)))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(DeepSeekTheme.brandBlue)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("无限制模式")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("知道了") { dismiss() }
                }
            }
        }
    }

    private func changeRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(DeepSeekTheme.diffAdded)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
