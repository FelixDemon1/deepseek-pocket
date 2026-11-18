import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif
import DeepSeekCore

// MARK: - Beginner-Friendly Account & Settings Sheet (Google Gemini Mobile Style)

public struct SettingsAndRemoteSheet: View {
    @Bindable public var vm: AppViewModel
    public var onOpenAudit: () -> Void
    /// When the sheet is hosted inside a side panel there is no presentation to
    /// dismiss, so the host supplies its own close handler.
    public var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyDraft: String = ""
    @State private var baseURLDraft: String = ""
    @State private var modelDraft: String = ""
    @State private var showCustomEndpoint: Bool = false
    @State private var showScanner: Bool = false
    @State private var avatarItem: PhotosPickerItem?

    public init(
        vm: AppViewModel,
        onOpenAudit: @escaping () -> Void = {},
        onClose: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.onOpenAudit = onOpenAudit
        self.onClose = onClose
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var profileAvatar: some View {
        ZStack {
            Circle().fill(DeepSeekTheme.brandSoftFill(.light)).frame(width: 54, height: 54)
            profileAvatarContent
        }
    }

    @ViewBuilder
    private var emojiAvatar: some View {
        #if canImport(UIKit)
        if let icon = UIImage(named: "AvatarDefault") {
            Image(uiImage: icon).resizable().scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.fill").font(.system(size: 24))
        }
        #else
        Image(systemName: "person.fill").font(.system(size: 24))
        #endif
    }

    #if canImport(UIKit)
    @ViewBuilder
    private var profileAvatarContent: some View {
        if let data = vm.avatarImageData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(Circle())
        } else {
            emojiAvatar
        }
    }
    #else
    @ViewBuilder
    private var profileAvatarContent: some View { emojiAvatar }
    #endif

    public var body: some View {
        NavigationStack {
            Form {
                Section("个人资料") {
                    HStack(spacing: 14) {
                        profileAvatar
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("昵称", text: Binding(
                                get: { vm.displayName },
                                set: { vm.updateDisplayName($0) }
                            ))
                            .font(.subheadline.weight(.medium))
                            Text("只保存在本机，用于顶部头像与抽屉抬头")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        Label("从相册选择头像", systemImage: "photo")
                    }

                    #if canImport(UIKit)
                    if vm.avatarImageData != nil {
                        Button("恢复默认头像（App 图标）") {
                            vm.updateAvatarImage(nil)
                        }
                        .font(.footnote)
                    }
                    #endif
                }

                Section("接口与账号（选择你要使用的 AI 来源）") {
                    LabeledContent("当前使用", value: vm.providerConfig.friendlyEndpointLabel)
                        .font(.footnote)

                    Menu("一键切换常用接口") {
                        ForEach(ProviderConfig.presets, id: \.label) { preset in
                            Button(preset.label) {
                                baseURLDraft = preset.base
                                modelDraft = preset.model
                                commitChanges()
                            }
                        }
                    }

                    SecureField(
                        vm.hasAPIKeyConfigured ? "已填密钥（\(vm.maskedAPIKeyPreview())，可输入新密钥覆盖）" : "在此粘贴你的 API 密钥 (sk-...)",
                        text: $apiKeyDraft
                    )
                    .font(.footnote.monospaced())
                    .onSubmit { commitChanges() }

                    if let bal = vm.balanceInfo {
                        LabeledContent("DeepSeek 官方账户余额", value: "\(bal.totalBalance) \(bal.currency)")
                            .font(.footnote)
                    } else if vm.hasAPIKeyConfigured && baseURLDraft.contains("api.deepseek.com") {
                        Button("查询 DeepSeek 账户余额") {
                            Task { await vm.queryDeepSeekBalance() }
                        }
                        .font(.footnote)
                    }

                    #if os(iOS)
                    Button {
                        showScanner = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("扫码自动填入朋友分享的接口", systemImage: "qrcode.viewfinder")
                                .font(.footnote.weight(.medium))
                            Text("扫描朋友或团队提供的接口配置二维码，免手打自动填好地址和密钥")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
                    #endif

                    DisclosureGroup("自定义个人接口地址与模型名称", isExpanded: $showCustomEndpoint) {
                        TextField("接口地址（如 https://api.deepseek.com/v1）", text: $baseURLDraft)
                            .font(.footnote.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .autocorrectionDisabled()

                        HStack {
                            TextField("模型名称（如 deepseek-reasoner）", text: $modelDraft)
                                .font(.footnote.monospaced())
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .autocorrectionDisabled()

                            if !vm.discoveredModels.isEmpty {
                                Menu("可选 (\(vm.discoveredModels.count))") {
                                    ForEach(vm.discoveredModels, id: \.self) { id in
                                        Button(id) {
                                            modelDraft = id
                                            commitChanges()
                                        }
                                    }
                                }
                                .font(.caption)
                            } else {
                                Button("获取列表") {
                                    commitChanges()
                                    Task { await vm.discoverGatewayModels() }
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .font(.footnote)
                }

                Section("对话框宠物与外观") {
                    Picker("输入框上方宠物", selection: $vm.companionCharacter) {
                        ForEach(CompanionCharacter.allCases, id: \.self) { item in
                            Text(item.label).tag(item)
                        }
                    }

                    Picker("界面颜色", selection: Binding(
                        get: { vm.appearance },
                        set: { vm.setAppearance($0) }
                    )) {
                        Text("经典白蓝").tag(AppearancePreference.light)
                        Text("跟随手机系统").tag(AppearancePreference.system)
                        Text("深邃夜间").tag(AppearancePreference.dark)
                    }
                }

                Section("连接我的电脑（可选高级功能）") {
                    Picker("运行位置", selection: $vm.engineMode) {
                        Text("在手机本机运行").tag(EngineMode.onDeviceHarness)
                        Text("连接电脑端运行").tag(EngineMode.remoteDshWeb)
                    }

                    if vm.engineMode == .remoteDshWeb {
                        if let connected = vm.remoteConnectedHost {
                            LabeledContent("已连电脑", value: connected)
                                .font(.footnote.monospaced())
                        }
                        TextField("粘贴电脑端启动地址 http://192.168.x.x:3080/?token=...", text: $vm.remoteLaunchInput)
                            .font(.caption.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()

                        Button("连接电脑") {
                            Task { await vm.connectRemoteDshHost() }
                        }
                    }
                }

                Section("安全与隐私保护") {
                    Picker("AI 修改项目文件前", selection: $vm.approvalPolicy) {
                        Text("每次先让我确认（推荐）").tag(ApprovalPolicy.readOnlyAuto)
                        Text("所有操作都让我确认").tag(ApprovalPolicy.askEveryTool)
                        Text("在当前文件夹内自动完成").tag(ApprovalPolicy.fullSandboxAuto)
                    }

                    Toggle("修改文件时要求 Face ID 面容验证", isOn: $vm.requireFaceIDForApprovals)

                    Button {
                        commitChanges()
                        close()
                        onOpenAudit()
                    } label: {
                        LabeledContent("查看隐私与联网记录", value: "仅直连所选接口")
                            .font(.footnote)
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("开源 · 仅供技术交流")
                            .font(.footnote.weight(.semibold))
                        Text("本项目以 MIT 协议开源，用于 iOS 本地 Agent、提示词工程与沙箱机制的技术研究与交流。作者只提供代码，不提供任何服务、内容或数据；软件的使用方式、接入的接口、输入输出的内容，全部由使用者自行决定并自行承担，与作者无关。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("本项目与 DeepSeek、Apple 均无隶属关系，未获其背书。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    Link(destination: URL(string: "https://github.com/FelixDemon1/deepseek-pocket")!) {
                        LabeledContent("GitHub", value: "FelixDemon1/deepseek-pocket")
                            .font(.footnote)
                    }

                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .font(.footnote)
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("账号与设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        commitChanges()
                        close()
                    }
                }
            }
            .onAppear {
                baseURLDraft = vm.providerConfig.baseURL.absoluteString
                modelDraft = vm.providerConfig.model
            }
            .onChange(of: avatarItem) {
                guard let item = avatarItem else { return }
                #if canImport(UIKit)
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        vm.updateAvatarImage(data)
                    }
                    avatarItem = nil
                }
                #endif
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
                            Label("保存或发送分享长图", systemImage: "square.and.arrow.up")
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
            .navigationTitle("分享对话")
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
                PixelCompanionView(mood: .happy, character: .whale, scale: 1.2)
                Text("DeepSeek Pocket")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            Divider()

            Text(session.title)
                .font(.system(size: 18, weight: .semibold))

            ForEach(session.messages.filter { $0.role == .user || ($0.role == .assistant && !$0.content.isEmpty) }.suffix(4)) { msg in
                VStack(alignment: .leading, spacing: 4) {
                    Text(msg.role == .user ? "提问" : "DeepSeek")
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
