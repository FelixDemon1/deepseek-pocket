import SwiftUI
import DeepSeekCore

/// 「连接 AI」—— 唯一入口。分三条路，从最省事到最自由。
/// 目标：不会配置的人也能在 30 秒内让 App 能说话。
public struct ConnectAISheet: View {
    @Bindable public var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var keyDraft: String = ""
    @State private var baseDraft: String = ""
    @State private var modelDraft: String = ""
    @State private var loginSpec: WebAdapterSpec?
    @State private var isConnecting = false
    @State private var resultMessage: String?
    @State private var showAdvanced = false
    @State private var specDraft: String = ""
    @State private var specError: String?

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            List {
                currentSection
                webAdapterSection
                officialKeySection
                advancedSection
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
                WebAdapterLoginSheet(spec: spec) { token in
                    vm.saveWebCredential(token, for: spec)
                    resultMessage = "已连上 \(spec.name)"
                    loginSpec = nil
                }
            }
            #endif
            .onAppear {
                keyDraft = ""
                baseDraft = vm.providerConfig.baseURL.absoluteString
                modelDraft = vm.providerConfig.model
            }
        }
    }

    // MARK: 当前状态

    private var currentSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(vm.hasAPIKeyConfigured || vm.activeWebAdapter != nil
                          ? DeepSeekTheme.diffAdded : Color.orange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.activeWebAdapter?.name ?? vm.providerConfig.friendlyEndpointLabel)
                        .font(.subheadline.weight(.medium))
                    Text(vm.activeWebAdapter != nil ? "网页版翻译通道 · 无需 Key" : vm.providerConfig.model)
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

    // MARK: 网页版登录（免 Key）

    private var webAdapterSection: some View {
        Section {
            ForEach(vm.webAdapters) { spec in
                Button {
                    if vm.hasWebCredential(spec) {
                        vm.activateWebAdapter(spec)
                        resultMessage = "已切到 \(spec.name)"
                    } else {
                        loginSpec = spec
                    }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(spec.name)
                                    .font(.subheadline)
                                if !spec.calibrated {
                                    Text("待校准")
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(vm.hasWebCredential(spec) ? "已登录，点一下切过去" : "点这里登录网页版，自动读取")
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
                        Button("重新登录（登录过期时用）") { loginSpec = spec }
                    }
                }
            }

            Text("在官方网页版里登录一次就行，登录态会一直留在本机；App 只读自己这个网页视图，不碰别的 App。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("① 用你已有的官方账号（不用买 Key）")
        }
    }

    // MARK: 官方 Key

    private var officialKeySection: some View {
        Section {
            Link(destination: URL(string: "https://platform.deepseek.com/api_keys")!) {
                Label("去 DeepSeek 官网领一个 Key", systemImage: "arrow.up.right.square")
                    .font(.footnote)
            }

            SecureField("把 Key 粘贴在这里（sk- 开头）", text: $keyDraft)
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

            if let message = resultMessage, vm.hasAPIKeyConfigured {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("② 用官方的 Key（按用量付费，更稳）")
        } footer: {
            Text("连上后会自动读一遍可用模型，读到了才算成功。")
        }
    }

    // MARK: 高级

    private var advancedSection: some View {
        Section {
            DisclosureGroup("高级：自定义地址 / 模型", isExpanded: $showAdvanced) {
                TextField("接口地址", text: $baseDraft)
                    .font(.footnote.monospaced())
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()

                TextField("模型名称", text: $modelDraft)
                    .font(.footnote.monospaced())
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()

                if !vm.discoveredModels.isEmpty {
                    Menu("从已读到的 \(vm.discoveredModels.count) 个模型里选") {
                        ForEach(vm.discoveredModels, id: \.self) { id in
                            Button(id) { modelDraft = id }
                        }
                    }
                    .font(.footnote)
                }

                Button("保存自定义地址") {
                    guard let url = URL(string: baseDraft.trimmingCharacters(in: .whitespaces)) else {
                        resultMessage = "地址不合法"
                        return
                    }
                    var config = vm.providerConfig
                    config.baseURL = url
                    config.model = modelDraft
                    vm.updateProviderConfig(config)
                    vm.deactivateWebAdapter()
                    resultMessage = "已保存自定义地址"
                }
                .font(.footnote)
            }

            NavigationLink("粘贴自己的渠道配置（JSON）") {
                specImportView
            }
        } header: {
            Text("③ 高级")
        }
    }

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
                Text("直接粘贴 WebAdapterSpec JSON")
            } footer: {
                Text("和 gateway/spec.example.json 同一套字段：chat_url / headers / body_template / response_mode。抓到包后改这里就能接新渠道。")
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
                    specError = nil
                    resultMessage = "已加入 \(spec.name)"
                } catch {
                    specError = "解析失败：\(error.localizedDescription)"
                }
            }
        }
        .navigationTitle("导入渠道配置")
    }

    // MARK: 动作

    private func connect() async {
        isConnecting = true
        resultMessage = nil
        defer { isConnecting = false }
        let base = URL(string: baseDraft.trimmingCharacters(in: .whitespaces))
            ?? URL(string: "https://api.deepseek.com/v1")!
        let model = modelDraft.isEmpty ? "deepseek-chat" : modelDraft
        if let failure = await vm.connectWithAPIKey(keyDraft, baseURL: base, model: model) {
            resultMessage = failure
        } else {
            resultMessage = "连上了，可用 \(vm.discoveredModels.count) 个模型"
        }
    }
}
