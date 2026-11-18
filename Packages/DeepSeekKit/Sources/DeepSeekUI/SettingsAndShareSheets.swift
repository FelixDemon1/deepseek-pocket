import SwiftUI
import DeepSeekCore

// MARK: - Clean Settings Sheet (Auto-Saves Key on Dismiss, Zero Slogans)

public struct SettingsAndRemoteSheet: View {
    @Bindable public var vm: AppViewModel
    public var onOpenAudit: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyDraft: String = ""
    @State private var baseURLDraft: String = ""
    @State private var modelDraft: String = ""
    @State private var showScanner: Bool = false

    public init(vm: AppViewModel, onOpenAudit: @escaping () -> Void = {}) {
        self.vm = vm
        self.onOpenAudit = onOpenAudit
    }

    public var body: some View {
        NavigationStack {
            Form {
                #if os(iOS)
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("扫码接入网关", systemImage: "qrcode.viewfinder")
                    }
                    .sheet(isPresented: $showScanner) {
                        QRScannerSheet { code in
                            if let url = URL(string: code) {
                                vm.handleSetupURL(url)
                                baseURLDraft = vm.providerConfig.baseURL.absoluteString
                                modelDraft = vm.providerConfig.model
                            }
                        }
                    }
                }
                #endif

                Section("模型") {
                    Menu("预设") {
                        ForEach(ProviderConfig.presets, id: \.label) { preset in
                            Button(preset.label) {
                                baseURLDraft = preset.base
                                modelDraft = preset.model
                                commitChanges()
                            }
                        }
                    }

                    TextField("地址", text: $baseURLDraft)
                        .font(.footnote.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()

                    HStack {
                        TextField("模型", text: $modelDraft)
                            .font(.footnote.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()

                        if !vm.discoveredModels.isEmpty {
                            Menu("\(vm.discoveredModels.count)") {
                                ForEach(vm.discoveredModels, id: \.self) { id in
                                    Button(id) {
                                        modelDraft = id
                                        commitChanges()
                                    }
                                }
                            }
                            .font(.caption.monospaced())
                        } else {
                            Button("同步") {
                                commitChanges()
                                Task { await vm.discoverGatewayModels() }
                            }
                            .font(.caption)
                        }
                    }

                    SecureField(
                        vm.hasAPIKeyConfigured ? "密钥（\(vm.maskedAPIKeyPreview())）" : "密钥",
                        text: $apiKeyDraft
                    )
                    .font(.footnote.monospaced())
                    .onSubmit { commitChanges() }

                    if let bal = vm.balanceInfo {
                        LabeledContent("余额", value: "\(bal.totalBalance) \(bal.currency)")
                            .font(.footnote.monospaced())
                    } else if vm.hasAPIKeyConfigured && baseURLDraft.contains("api.deepseek.com") {
                        Button("查余额") {
                            Task { await vm.queryDeepSeekBalance() }
                        }
                        .font(.footnote)
                    }
                }

                Section("远程 DSH") {
                    Picker("引擎", selection: $vm.engineMode) {
                        Text("本机").tag(EngineMode.onDeviceHarness)
                        Text("远程").tag(EngineMode.remoteDshWeb)
                    }

                    if vm.engineMode == .remoteDshWeb {
                        if let connected = vm.remoteConnectedHost {
                            LabeledContent("已连接", value: connected)
                                .font(.footnote.monospaced())
                        }
                        TextField("http://192.168.x.x:3080/?token=...", text: $vm.remoteLaunchInput)
                            .font(.caption.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()

                        Button("连接") {
                            Task { await vm.connectRemoteDshHost() }
                        }
                    }
                }

                Section("安全与外观") {
                    Picker("工具权限", selection: $vm.approvalPolicy) {
                        Text("写入确认").tag(ApprovalPolicy.readOnlyAuto)
                        Text("每次确认").tag(ApprovalPolicy.askEveryTool)
                        Text("工作区自动").tag(ApprovalPolicy.fullSandboxAuto)
                    }

                    Toggle("Face ID", isOn: $vm.requireFaceIDForApprovals)

                    Button {
                        commitChanges()
                        dismiss()
                        onOpenAudit()
                    } label: {
                        LabeledContent("网络审计", value: "\(vm.auditEntries.count)")
                    }
                    .foregroundStyle(.primary)

                    Picker("外观", selection: Binding(
                        get: { vm.appearance },
                        set: { vm.setAppearance($0) }
                    )) {
                        Text("浅色").tag(AppearancePreference.light)
                        Text("系统").tag(AppearancePreference.system)
                        Text("深色").tag(AppearancePreference.dark)
                    }

                    Toggle("像素鲸鱼", isOn: $vm.showCompanionPet)
                }
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        commitChanges()
                        dismiss()
                    }
                }
            }
            .onAppear {
                baseURLDraft = vm.providerConfig.baseURL.absoluteString
                modelDraft = vm.providerConfig.model
            }
        }
    }

    private func commitChanges() {
        let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            vm.saveAPIKey(trimmedKey)
            apiKeyDraft = ""
        }
        guard let url = SetupLink.normalizedBaseURL(baseURLDraft) else { return }
        var updated = vm.providerConfig
        updated.baseURL = url
        let m = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = m.isEmpty ? "deepseek-reasoner" : m
        vm.updateProviderConfig(updated)
    }
}

// MARK: - Minimalist On-Device Share Card

public struct ShareCardSheet: View {
    public let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var tempShareURL: URL?

    public init(session: ChatSession) {
        self.session = session
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardCanvas
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
                        )
                        .padding(.horizontal, 16)

                    if let url = tempShareURL {
                        ShareLink(item: url) {
                            Label("分享图片", systemImage: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DeepSeekTheme.brandBlue))
                                .foregroundStyle(Color.white)
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(DeepSeekTheme.surface(scheme).ignoresSafeArea())
            .navigationTitle("分享")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                renderShareCardImage()
            }
        }
    }

    private var cardCanvas: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                PixelCompanionView(mood: .idle, scale: 1.2)
                Text("DeepSeek Pocket")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            Divider()

            Text(session.title)
                .font(.system(size: 18, weight: .semibold))

            ForEach(session.messages.filter { $0.role == .user || ($0.role == .assistant && !$0.content.isEmpty) }.suffix(4)) { msg in
                VStack(alignment: .leading, spacing: 4) {
                    Text(msg.role == .user ? "You" : "DeepSeek")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(msg.content.prefix(380))
                        .font(.system(size: 14))
                        .lineSpacing(3)
                }
            }
        }
        .padding(22)
        .frame(width: 350)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }

    @MainActor
    private func renderShareCardImage() {
        let renderer = ImageRenderer(content: cardCanvas)
        renderer.scale = 3.0
        #if canImport(UIKit)
        if let uiImage = renderer.uiImage, let png = uiImage.pngData() {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-pocket-share.png")
            try? png.write(to: out, options: .atomic)
            tempShareURL = out
        }
        #endif
    }
}
