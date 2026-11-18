import SwiftUI
import PhotosUI
import DeepSeekCore

/// Linear / Apple Notes Minimalist Composer Capsule.
public struct SteerComposerBar: View {
    @Binding public var text: String
    @Bindable public var vm: AppViewModel
    public var onOpenWorkspace: () -> Void
    public var onOpenPresets: () -> Void
    public var onOpenScanner: () -> Void
    public var onRequireSetup: () -> Void

    @Environment(\.colorScheme) private var scheme
    @FocusState private var isFocused: Bool
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showPhotoPicker: Bool = false

    public init(
        text: Binding<String>,
        vm: AppViewModel,
        onOpenWorkspace: @escaping () -> Void = {},
        onOpenPresets: @escaping () -> Void = {},
        onOpenScanner: @escaping () -> Void = {},
        onRequireSetup: @escaping () -> Void = {}
    ) {
        self._text = text
        self.vm = vm
        self.onOpenWorkspace = onOpenWorkspace
        self.onOpenPresets = onOpenPresets
        self.onOpenScanner = onOpenScanner
        self.onRequireSetup = onRequireSetup
    }

    public var body: some View {
        let ink = DeepSeekTheme.primaryInk(scheme)
        let secondary = DeepSeekTheme.secondaryInk(scheme)
        let canvas = DeepSeekTheme.canvas(scheme)

        VStack(spacing: 6) {
            if !vm.queuedSteers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(vm.queuedSteers) { item in
                            Text(item.text)
                                .font(.system(size: 12))
                                .foregroundStyle(secondary)
                                .lineLimit(1)
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
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                        Text(ocr.summary)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            vm.pendingOCRAttachment = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(canvas))
                }

                TextField(
                    vm.isStreaming ? "补充…" : "发消息",
                    text: $text,
                    axis: .vertical
                )
                .lineLimit(1...6)
                .focused($isFocused)
                .font(.system(size: 16))
                .foregroundStyle(ink)
                .padding(.horizontal, 4)
                .padding(.top, 2)

                HStack(spacing: 8) {
                    Menu {
                        Button { showPhotoPicker = true } label: {
                            Label("图片", systemImage: "photo")
                        }
                        Button(action: onOpenWorkspace) {
                            Label("文件", systemImage: "folder")
                        }
                        Button(action: onOpenPresets) {
                            Label("规则", systemImage: "slider.horizontal.3")
                        }
                        #if os(iOS)
                        Button(action: onOpenScanner) {
                            Label("扫码", systemImage: "qrcode")
                        }
                        #endif
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(canvas))
                    }

                    let isR1 = vm.providerConfig.model.lowercased().contains("reasoner") || vm.providerConfig.model.lowercased().contains("r1")
                    toggleChip(title: "R1", icon: "sparkles", active: isR1, scheme: scheme, secondary: secondary) {
                        var next = vm.providerConfig
                        next.model = isR1 ? "deepseek-chat" : "deepseek-reasoner"
                        vm.updateProviderConfig(next)
                    }

                    toggleChip(title: "工具", icon: "terminal", active: vm.providerConfig.enableTools, scheme: scheme, secondary: secondary) {
                        var next = vm.providerConfig
                        next.enableTools.toggle()
                        vm.updateProviderConfig(next)
                    }

                    Spacer()

                    if vm.isRunningOCR {
                        ProgressView().controlSize(.small)
                    }

                    actionButton(ink: ink, secondary: secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(DeepSeekTheme.surface(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
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

    private func toggleChip(
        title: String,
        icon: String,
        active: Bool,
        scheme: ColorScheme,
        secondary: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(active ? DeepSeekTheme.brandSoftFill(scheme) : Color.clear))
            .overlay(
                Capsule().stroke(active ? DeepSeekTheme.brandBlue.opacity(0.3) : DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
            )
            .foregroundStyle(active ? DeepSeekTheme.brandBlue : secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionButton(ink: Color, secondary: Color) -> some View {
        let hasDraft = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.pendingOCRAttachment != nil
        if vm.isStreaming {
            if hasDraft {
                Menu {
                    Button {
                        let msg = text
                        text = ""
                        vm.sendOrSteer(text: msg, steerMode: .nextStep)
                    } label: {
                        Label("下一步合并", systemImage: "text.insert")
                    }
                    Button {
                        let msg = text
                        text = ""
                        vm.sendOrSteer(text: msg, steerMode: .interruptNow)
                    } label: {
                        Label("立即转向", systemImage: "bolt")
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 30, height: 30)
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
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(DeepSeekTheme.brandBlue))
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                if vm.needsCredentialsBeforeSend {
                    onRequireSetup()
                    return
                }
                let msg = text
                text = ""
                isFocused = false
                vm.sendOrSteer(text: msg)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hasDraft ? Color.white : secondary.opacity(0.45))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(hasDraft ? DeepSeekTheme.brandBlue : ink.opacity(0.07)))
            }
            .disabled(!hasDraft)
            .buttonStyle(.plain)
        }
    }
}
