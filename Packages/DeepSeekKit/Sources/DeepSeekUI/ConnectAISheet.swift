import SwiftUI
import DeepSeekCore

/// 「连接 AI」—— 唯一入口。三条路，从最省事到最自由。
/// 目标：不会配置的人也能在 30 秒内让 App 能说话。
public struct ConnectAISheet: View {
    @Bindable public var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var keyDraft: String = ""
    @State private var baseDraft: String = ""
    @State private var modelDraft: String = ""
    @State private var loginSpec: WebAdapterSpec?
    @State private var clearBeforeLogin = false
    @State private var isConnecting = false
    @State private var resultMessage: String?
    @State private var providerID: String = KeyProvider.all[0].id
    @State private var showAdvanced = false
    @State private var specDraft: String = ""
    @State private var specError: String?

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    private var provider: KeyProvider {
        KeyProvider.all.first { $0.id == providerID } ?? KeyProvider.all[0]
    }

    public var body: some View {
        NavigationStack {
            List {
                currentSection
                officialAccountSection
                officialKeySection
                moreChannelsSection
                errorSection
            }
            .navigationTitle("连接 AI")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            #if os(iOS)
            .sheet(item: $loginSpec) { spec in
                WebAdapterLoginSheet(spec: spec, clearExistingOnAppear: clearBeforeLogin) { token, cookieHeader in
                    vm.saveWebCredential(token, cookieHeader: cookieHeader, for: spec)
                    resultMessage = "已读到凭据，正在测试连接…"
                    loginSpec = nil
                    clearBeforeLogin = false
                    Task {
                        resultMessage = await vm.testWebAdapter(spec)
                    }
                }
            }
            #endif
            .onAppear {
                keyDraft = ""
                if let matched = KeyProvider.matching(host: vm.providerConfig.baseURL.host ?? "") {
                    providerID = matched.id
                }
                baseDraft = vm.providerConfig.baseURL.absoluteString
                modelDraft = vm.providerConfig.model
                if let spec = vm.activeWebAdapter { baseDraft = spec.chatURL }
            }
        }
    }

    // MARK: 当前状态

    private var currentSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(isConfigured ? DeepSeekTheme.diffAdded : Color.orange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.activeWebAdapter?.name ?? vm.providerConfig.friendlyEndpointLabel)
                        .font(.subheadline.weight(.medium))
                    Text(vm.activeWebAdapter != nil
                         ? "官方账号通道 · 不用 Key"
                         : "\(vm.providerConfig.model) · \(vm.providerConfig.flavor?.displayName ?? "chat/completions")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let message = resultMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("现在用的是")
        }
    }

    private var isConfigured: Bool {
        vm.isAIConfigured
    }

    // MARK: ① 登录官方账号

    private var officialAccountSection: some View {
        Section {
            ForEach(vm.webAdapters) { spec in
                Button {
                    if vm.hasWebCredential(spec) {
                        vm.activateWebAdapter(spec)
                        resultMessage = "已切到 \(spec.name)，正在测试…"
                        Task { resultMessage = await vm.testWebAdapter(spec) }
                    } else {
                        clearBeforeLogin = false
                        loginSpec = spec
                    }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(spec.name).font(.subheadline)
                                if spec.calibrated {
                                    Text("推荐 · 免 Key")
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(DeepSeekTheme.diffAdded.opacity(0.15)))
                                        .foregroundStyle(DeepSeekTheme.diffAdded)
                                } else {
                                    Text("实验性")
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(vm.hasWebCredential(spec) ? "已登录，点一下立即使用" : "点这里登录官网账号，自动接入无需买 Key")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if vm.activeWebAdapterID == spec.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(DeepSeekTheme.brandBlue)
                        } else {
                            Image(systemName: vm.hasWebCredential(spec) ? "arrow.right.circle" : "person.crop.circle.badge.plus")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    if vm.hasWebCredential(spec) {
                        Button("再测一次") {
                            Task { resultMessage = await vm.testWebAdapter(spec) }
                        }
                        Button("重新登录（登录过期时用）") {
                            clearBeforeLogin = true
                            loginSpec = spec
                        }
                        Button("退出此账号", role: .destructive) {
                            vm.clearWebCredential(for: spec)
                            resultMessage = "已清除 \(spec.name) 登录凭据"
                        }
                    }
                }
            }

            Button {
                Task {
                    resultMessage = "正在从云端同步渠道配置…"
                    resultMessage = await vm.syncRemoteWebSpecs(silent: false)
                }
            } label: {
                Label("从云端热更新免 Key 渠道配置（app.apifish.me）", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
            }

            Text("小白首选「DeepSeek 网页版」或「豆包网页版」：登录一次免买 Key；长按渠道可重新测速或切换账号。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("① 登录官方账号（免费 · 不用买 Key）")
        }
    }

    // MARK: ② 官方 API Key

    private var officialKeySection: some View {
        Section {
            Menu {
                ForEach(KeyProvider.all) { item in
                    Button {
                        providerID = item.id
                        baseDraft = item.baseURL
                        modelDraft = item.defaultModel
                    } label: {
                        if item.id == providerID {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("厂商")
                    Spacer()
                    Text(provider.name)
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
            }

            Menu {
                let candidateModels: [String] = {
                    var list = provider.models
                    if KeyProvider.matching(host: vm.providerConfig.baseURL.host ?? "")?.id == provider.id {
                        for m in vm.discoveredModels where !list.contains(m) {
                            list.append(m)
                        }
                    }
                    return list
                }()
                ForEach(candidateModels, id: \.self) { m in
                    Button {
                        modelDraft = m
                        if vm.activeWebAdapter == nil,
                           KeyProvider.matching(host: vm.providerConfig.baseURL.host ?? "")?.id == provider.id {
                            var updated = vm.providerConfig
                            updated.model = m
                            vm.updateProviderConfig(updated)
                            resultMessage = "已切换模型：\(m)"
                        }
                    } label: {
                        if m == (modelDraft.isEmpty ? provider.defaultModel : modelDraft) {
                            Label(m, systemImage: "checkmark")
                        } else {
                            Text(m)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("默认模型（可自由切换）")
                    Spacer()
                    Text(modelDraft.isEmpty ? provider.defaultModel : modelDraft)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
            }

            Text(provider.note)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: provider.keyPage)!) {
                Label("去 \(provider.name) 领 Key", systemImage: "arrow.up.right.square")
                    .font(.footnote)
            }

            SecureField("把 Key 粘贴在这里", text: $keyDraft)
                .font(.footnote.monospaced())
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            Button {
                Task { await connect() }
            } label: {
                HStack {
                    Text(isConnecting ? "正在验证…" : "连接并验证")
                    Spacer()
                    if isConnecting { ProgressView().controlSize(.mini) }
                }
            }
            .disabled(isConnecting || keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("② 使用官方 API Key（按用量付费，更稳）")
        } footer: {
            Text("连上后会自动读模型列表、自动判断接口协议，读到了才算成功。")
        }
    }

    // MARK: ③ 更多渠道

    private var moreChannelsSection: some View {
        Section {
            Text("这里给「中转站」和「自己搭的网关」用：别人给你一个地址（可能还有一串口令），填进去就能用。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(SponsoredChannel.active) { channel in
                Button {
                    if let url = URL(string: channel.setupLink) {
                        vm.handleSetupURL(url)
                        resultMessage = "已导入 \(channel.name)"
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name).font(.subheadline)
                        Text(channel.blurb).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            DisclosureGroup("我有中转站 / 自建网关的地址", isExpanded: $showAdvanced) {
                labeledField(
                    title: "① 接口地址",
                    hint: "中转站给你的那个网址，一般以 /v1 结尾。不是请求头，也不是模型名。",
                    placeholder: "https://xxx.com/v1"
                ) {
                    TextField("https://xxx.com/v1", text: $baseDraft)
                        .font(.footnote.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                }

                labeledField(
                    title: "② 模型名称（可不填）",
                    hint: "填模型 id 用的，比如 gpt-4o-mini、deepseek-chat。不知道就留空，连上后自动挑一个。",
                    placeholder: "留空即可"
                ) {
                    TextField("留空即可", text: $modelDraft)
                        .font(.footnote.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }

                labeledField(
                    title: "③ 令牌 / 口令（可不填）",
                    hint: "对方给你的那串 key，通常以 sk- 开头。没有就留空。",
                    placeholder: "sk-..."
                ) {
                    SecureField("sk-...", text: $keyDraft)
                        .font(.footnote.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }

                if !vm.discoveredModels.isEmpty {
                    Menu("从已读到的 \(vm.discoveredModels.count) 个模型里选") {
                        ForEach(vm.discoveredModels, id: \.self) { id in
                            Button(id) { modelDraft = id }
                        }
                    }
                    .font(.footnote)
                }

                Button("保存并使用") {
                    saveCustomEndpoint()
                }
                .font(.footnote)
            }

            NavigationLink("粘贴渠道配置（进阶，JSON）") {
                specImportView
            }
            .font(.footnote)
        } header: {
            Text("③ 更多渠道（中转站 / 自建）")
        } footer: {
            Text("普通用户用上面 ① ② 就够了。这里放的是别人给你的接口地址，或者你自己搭的。")
        }
    }

    // MARK: 报错

    @ViewBuilder
    private var errorSection: some View {
        if let error = vm.lastAdapterError {
            Section {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Button("复制报错") {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = error
                    #endif
                    resultMessage = "已复制"
                }
                .font(.footnote)
            } header: {
                Text("最近一次失败原因")
            } footer: {
                Text("把这段发给我，就能定位是凭据、签名还是回包格式的问题。")
            }
        }
    }

    // MARK: 渠道配置导入

    private var specImportView: some View {
        Form {
            Section {
                TextEditor(text: $specDraft)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 200)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                Text("粘贴 WebAdapterSpec JSON")
            } footer: {
                Text("字段和 gateway/spec.example.json 一致：chat_url / headers / body_template / response_mode。抓到包改这里就能接新渠道。")
            }

            if let specError {
                Text(specError).font(.caption2).foregroundStyle(.red)
            }

            Button("解析并加入渠道列表") {
                specError = nil
                guard let data = specDraft.data(using: .utf8) else { return }
                do {
                    let spec = try JSONDecoder().decode(WebAdapterSpec.self, from: data)
                    vm.addCustomAdapter(spec)
                    resultMessage = "已加入 \(spec.name)"
                } catch {
                    specError = "解析失败：\(error.localizedDescription)"
                }
            }
        }
        .navigationTitle("导入渠道配置")
    }

    // MARK: 小工具

    @ViewBuilder
    private func labeledField<Content: View>(
        title: String,
        hint: String,
        placeholder: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            content()
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: 动作

    private func connect() async {
        isConnecting = true
        resultMessage = nil
        defer { isConnecting = false }
        let base = URL(string: provider.baseURL) ?? URL(string: "https://api.deepseek.com/v1")!
        let model = modelDraft.isEmpty ? provider.defaultModel : modelDraft
        if let failure = await vm.connectWithAPIKey(keyDraft, baseURL: base, model: model) {
            resultMessage = failure
        } else {
            resultMessage = "连上了，可用 \(vm.discoveredModels.count) 个模型"
        }
    }

    private func saveCustomEndpoint() {
        guard let url = URL(string: baseDraft.trimmingCharacters(in: .whitespaces)) else {
            resultMessage = "地址不合法"
            return
        }
        var config = vm.providerConfig
        config.baseURL = url
        if !modelDraft.isEmpty { config.model = modelDraft }
        vm.updateProviderConfig(config)
        if !keyDraft.isEmpty { vm.saveAPIKey(keyDraft) }
        vm.deactivateWebAdapter()
        resultMessage = "已保存，试着发一条消息"
        Task { await vm.discoverGatewayModels() }
    }
}
