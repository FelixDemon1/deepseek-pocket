import SwiftUI
import PhotosUI
import DeepSeekCore

/// Unified Apple / Google Gemini Minimalist Floating Composer Capsule.
public struct SteerComposerBar: View {
    @Binding public var text: String
    @Bindable public var vm: AppViewModel
    public var onOpenWorkspace: () -> Void
    public var onOpenPresets: () -> Void

    @Environment(\.colorScheme) private var scheme
    @FocusState private var isFocused: Bool
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showPhotoPicker: Bool = false

    public init(
        text: Binding<String>,
        vm: AppViewModel,
        onOpenWorkspace: @escaping () -> Void = {},
        onOpenPresets: @escaping () -> Void = {}
    ) {
        self._text = text
        self.vm = vm
        self.onOpenWorkspace = onOpenWorkspace
        self.onOpenPresets = onOpenPresets
    }

    public var body: some View {
        let ink = DeepSeekTheme.primaryInk(scheme)
        let secondary = DeepSeekTheme.secondaryInk(scheme)
        let canvas = DeepSeekTheme.canvas(scheme)

        VStack(spacing: 8) {
            if !vm.queuedSteers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(vm.queuedSteers) { item in
                            Text("已排队补充：\(item.text)")
                                .font(.system(size: 12))
                                .foregroundStyle(secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(DeepSeekTheme.surface(scheme)))
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if let ocr = vm.pendingOCRAttachment {
                    HStack(spacing: 6) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 11, weight: .semibold))
                        Text(ocr.summary)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            vm.pendingOCRAttachment = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(canvas))
                }

                TextField(
                    vm.isStreaming ? "生成中途补充指令…" : "发消息，或让 Agent 操作工作区…",
                    text: $text,
                    axis: .vertical
                )
                .lineLimit(1...6)
                .focused($isFocused)
                .font(.system(size: 16))
                .foregroundStyle(ink)
                .padding(.horizontal, 4)
                .padding(.top, 2)

                // Clean monochrome bottom utility strip inside capsule
                HStack(spacing: 8) {
                    Menu {
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("相册截图离线识别 (Apple Vision)", systemImage: "photo")
                        }
                        Button(action: onOpenWorkspace) {
                            Label("打开本机工作区文件", systemImage: "folder")
                        }
                        Button(action: onOpenPresets) {
                            Label("指令预设：\(vm.activePreset.title)", systemImage: "slider.horizontal.3")
                        }
                        Divider()
                        Button {
                            vm.runInteractiveShowcase()
                        } label: {
                            Label("运行本机沙盒交互演示", systemImage: "play")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ink)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(canvas))
                    }

                    // Minimalist Thinking Toggle (Official DeepSeek Blue Capsule)
                    let isR1 = vm.providerConfig.model.lowercased().contains("reasoner") || vm.providerConfig.model.lowercased().contains("r1")
                    Button {
                        var next = vm.providerConfig
                        next.model = isR1 ? "deepseek-chat" : "deepseek-reasoner"
                        vm.updateProviderConfig(next)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .medium))
                            Text("深度思考 (R1)")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isR1 ? DeepSeekTheme.brandSoftFill(scheme) : Color.clear)
                        )
                        .overlay(
                            Capsule().stroke(isR1 ? DeepSeekTheme.brandBlue.opacity(0.35) : DeepSeekTheme.hairline(scheme), lineWidth: 0.8)
                        )
                        .foregroundStyle(isR1 ? DeepSeekTheme.brandBlue : secondary)
                    }
                    .buttonStyle(.plain)

                    // Minimalist Tools Toggle
                    Button {
                        var next = vm.providerConfig
                        next.enableTools.toggle()
                        vm.updateProviderConfig(next)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                                .font(.system(size: 11, weight: .medium))
                            Text("沙盒工具")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(vm.providerConfig.enableTools ? DeepSeekTheme.brandSoftFill(scheme) : Color.clear)
                        )
                        .overlay(
                            Capsule().stroke(vm.providerConfig.enableTools ? DeepSeekTheme.brandBlue.opacity(0.35) : DeepSeekTheme.hairline(scheme), lineWidth: 0.8)
                        )
                        .foregroundStyle(vm.providerConfig.enableTools ? DeepSeekTheme.brandBlue : secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if vm.isRunningOCR {
                        ProgressView()
                            .controlSize(.small)
                    } else if vm.isStreaming && !vm.activeStageText.isEmpty {
                        Text(vm.activeStageText)
                            .font(.system(size: 11))
                            .foregroundStyle(secondary)
                            .lineLimit(1)
                    }

                    // Primary Action Circle
                    if vm.isStreaming {
                        let hasDraft = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.pendingOCRAttachment != nil
                        if hasDraft {
                            Menu {
                                Button {
                                    let msg = text
                                    text = ""
                                    vm.sendOrSteer(text: msg, steerMode: .nextStep)
                                } label: {
                                    Label("当前步骤后补充", systemImage: "text.insert")
                                }
                                Button {
                                    let msg = text
                                    text = ""
                                    vm.sendOrSteer(text: msg, steerMode: .interruptNow)
                                } label: {
                                    Label("立即打断并转向", systemImage: "bolt")
                                }
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.white)
                                    .frame(width: 32, height: 32)
                                    .background(Circle().fill(DeepSeekTheme.brandBlue))
                            } primaryAction: {
                                let msg = text
                                text = ""
                                vm.sendOrSteer(text: msg, steerMode: .nextStep)
                            }
                        } else {
                            Button {
                                vm.stopGeneration()
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.white)
                                    .frame(width: 32, height: 32)
                                    .background(Circle().fill(DeepSeekTheme.brandBlue))
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        let canSend = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.pendingOCRAttachment != nil
                        Button {
                            let msg = text
                            text = ""
                            isFocused = false
                            vm.sendOrSteer(text: msg)
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(canSend ? Color.white : secondary.opacity(0.5))
                                .frame(width: 32, height: 32)
                                .background(
                                    Circle().fill(canSend ? DeepSeekTheme.brandBlue : ink.opacity(0.08))
                                )
                        }
                        .disabled(!canSend)
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(DeepSeekTheme.surface(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    await vm.attachPhotoDataForOCR(data)
                }
                selectedPhotoItem = nil
            }
        }
    }
}
