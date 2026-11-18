import SwiftUI
import DeepSeekCore

// MARK: - Minimalist Settings, Auto-Model Discovery, Balance & Remote Pairing

public struct SettingsAndRemoteSheet: View {
    @Bindable public var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyDraft: String = ""
    @State private var baseURLDraft: String = ""
    @State private var modelDraft: String = ""
    @State private var savedToast: Bool = false
    @State private var showScanner: Bool = false

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("外观与引擎") {
                    Picker("主题风格", selection: Binding(
                        get: { vm.appearance },
                        set: { vm.setAppearance($0) }
                    )) {
                        ForEach(AppearancePreference.allCases, id: \.self) { item in
                            Text(item.label).tag(item)
                        }
                    }

                    Picker("执行引擎", selection: $vm.engineMode) {
                        ForEach(EngineMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Toggle("显示像素伙伴「小潮」", isOn: $vm.showCompanionPet)
                }

                Section {
                    #if os(iOS)
                    Button {
                        showScanner = true
                    } label: {
                        Label("扫码一键接入（网关二维码）", systemImage: "qrcode.viewfinder")
                            .font(.footnote.weight(.medium))
                    }
                    .sheet(isPresented: $showScanner) {
                        QRScannerSheet { code in
                            if let url = URL(string: code) {
                                vm.handleSetupURL(url)
                            }
                        }
                    }
                    #endif

                    Menu("快速选择服务商 / 免费通道") {
                        ForEach(ProviderConfig.presets, id: \.label) { preset in
                            Button(preset.label) {
                                baseURLDraft = preset.base
                                modelDraft = preset.model
                                commitProviderChanges()
                            }
                        }
                    }

                    TextField("API Base URL (支持任意 OpenAI 兼容网关)", text: $baseURLDraft)
                        .font(.footnote.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()

                    HStack {
                        TextField("模型名称", text: $modelDraft)
                            .font(.footnote.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()

                        if !vm.discoveredModels.isEmpty {
                            Menu("已探测 (\(vm.discoveredModels.count))") {
                                ForEach(vm.discoveredModels, id: \.self) { id in
                                    Button(id) {
                                        modelDraft = id
                                        commitProviderChanges()
                                    }
                                }
                            }
                            .font(.caption)
                        }
                    }

                    Button {
                        commitProviderChanges()
                        Task { await vm.discoverGatewayModels() }
                    } label: {
                        HStack {
                            Text("自动探测网关可用模型 (/v1/models)")
                            if vm.isFetchingModelsOrBalance {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                        .font(.footnote)
                    }
                } header: {
                    Text("模型路由（支持官方 / OpenRouter 免费 R1 / 自建网关）")
                }

                Section {
                    LabeledContent("已存凭据", value: vm.maskedAPIKeyPreview())
                        .font(.footnote.monospaced())

                    SecureField("填入 API Key（锁入本机 Keychain）", text: $apiKeyDraft)
                        .font(.footnote.monospaced())

                    Button(savedToast ? "已安全写入钥匙串 ✓" : "保存 API Key") {
                        vm.saveAPIKey(apiKeyDraft)
                        apiKeyDraft = ""
                        savedToast = true
                    }
                    .font(.footnote.weight(.medium))
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let bal = vm.balanceInfo {
                        LabeledContent("DeepSeek 账户余额", value: "\(bal.totalBalance) \(bal.currency)")
                            .font(.footnote.monospaced())
                    }

                    Button("查询 DeepSeek 官方账户余额") {
                        Task { await vm.queryDeepSeekBalance() }
                    }
                    .font(.footnote)
                    .disabled(!vm.hasAPIKeyConfigured)
                } header: {
                    Text("硬件钥匙串凭据与余额")
                }

                Section("本机沙盒安全门禁") {
                    Picker("审批策略", selection: $vm.approvalPolicy) {
                        ForEach(ApprovalPolicy.allCases, id: \.self) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    Toggle("写文件与联网要求 Face ID 验证", isOn: $vm.requireFaceIDForApprovals)
                }

                Section {
                    if let connected = vm.remoteConnectedHost {
                        LabeledContent("当前连接", value: connected)
                            .font(.footnote.monospaced())
                    }
                    TextField("dsh web: http://192.168.x.x:3080/?token=...", text: $vm.remoteLaunchInput)
                        .font(.caption.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                    Button("直连电脑端 dsh web（零第三方中继）") {
                        Task { await vm.connectRemoteDshHost() }
                    }
                    .font(.footnote.weight(.medium))
                } header: {
                    Text("远程 DeepSeek Harness")
                }
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        commitProviderChanges()
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

    private func commitProviderChanges() {
        guard let url = URL(string: baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host != nil else { return }
        var updated = vm.providerConfig
        updated.baseURL = url
        let m = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = m.isEmpty ? "deepseek-reasoner" : m
        vm.updateProviderConfig(updated)
    }
}

// MARK: - Compliant StoreKit 2 Pro Membership Sheet (Apple Minimalist Style)

public struct ProPaywallSheet: View {
    @Bindable public var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        let ink = DeepSeekTheme.primaryInk(scheme)
        let canvas = DeepSeekTheme.canvas(scheme)

        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 12)

                MinimalBrandMark(size: 56)

                VStack(spacing: 8) {
                    Text("Tide Pro")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(ink)
                    Text("纯本地专业生产力套件 · 一次买断或按月订阅")
                        .font(.subheadline)
                        .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                }

                VStack(alignment: .leading, spacing: 14) {
                    featureRow(icon: "slider.horizontal.below.rectangle", title: "解锁全部深度研究与专业角色规则集", sub: "支持无限自定义 .rules 工作流与一键快照回滚")
                    featureRow(icon: "arrow.triangle.branch", title: "无限对话分支 (Fork) 与高清无水印分享卡", sub: "在任意推理节点平行探索多种代码架构方案")
                    featureRow(icon: "laptopcomputer.and.iphone", title: "多主机 dsh web 快速切换与网关自动探测", sub: "无缝管理家里 Mac、公司工作站与云端开发机")
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(DeepSeekTheme.surface(scheme))
                )
                .padding(.horizontal, 20)

                Spacer()

                VStack(spacing: 12) {
                    if vm.proManager.products.isEmpty {
                        Button {
                            vm.togglePreviewProUnlock(!vm.isProUnlocked)
                            dismiss()
                        } label: {
                            Text(vm.isProUnlocked ? "已开启 Pro 预览权限（点击可关闭）" : "解锁 Pro 完整体验 · ¥18 / 月（开发预览直通）")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ink))
                                .foregroundStyle(canvas)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(vm.proManager.products, id: \.id) { product in
                            Button {
                                Task {
                                    if (try? await vm.proManager.purchase(product)) == true {
                                        vm.isProUnlocked = true
                                        dismiss()
                                    }
                                }
                            } label: {
                                Text("\(product.displayName) · \(product.displayPrice)")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ink))
                                    .foregroundStyle(canvas)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button("恢复购买 (StoreKit 2)") {
                        Task {
                            try? await vm.proManager.restorePurchases()
                            vm.isProUnlocked = vm.proManager.isProUnlocked
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .background(canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func featureRow(icon: String, title: String, sub: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Editorial Minimalist On-Device Share Card

public struct ShareCardSheet: View {
    public let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var tempShareURL: URL?

    public init(session: ChatSession) {
        self.session = session
    }

    public var body: some View {
        let ink = DeepSeekTheme.primaryInk(scheme)
        let canvas = DeepSeekTheme.canvas(scheme)

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardCanvas
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
                        )
                        .padding(.horizontal, 16)

                    if let url = tempShareURL {
                        ShareLink(item: url) {
                            Label("导出高清分享长图", systemImage: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ink))
                                .foregroundStyle(canvas)
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
                MinimalBrandMark(size: 28)
                Text("Tide")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("0 Telemetry")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(session.title)
                .font(.system(size: 18, weight: .semibold))

            ForEach(session.messages.filter { $0.role == .user || ($0.role == .assistant && !$0.content.isEmpty) }.suffix(4)) { msg in
                VStack(alignment: .leading, spacing: 4) {
                    Text(msg.role == .user ? "提问" : "回答")
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
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-go-share.png")
            try? png.write(to: out, options: .atomic)
            tempShareURL = out
        }
        #endif
    }
}
