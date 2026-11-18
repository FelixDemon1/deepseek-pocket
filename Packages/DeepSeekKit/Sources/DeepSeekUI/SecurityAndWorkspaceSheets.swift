import SwiftUI
import WebKit
import DeepSeekCore

// MARK: - Minimalist Network Audit & Zero-Telemetry Sheet

public struct NetworkAuditSheet: View {
    @Bindable public var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("零遥测防火墙运行中", systemImage: "checkmark.shield")
                            .font(.subheadline.weight(.semibold))
                        Text("0 字节发往任何开发者服务器或统计平台。所有出站请求按域名白名单拦截，URL 内的令牌自动脱敏。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button {
                            Task { await vm.runFirewallSelfTest() }
                        } label: {
                            Text("模拟拦截第三方统计与中继请求")
                                .font(.footnote.weight(.medium))
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("安全边界")
                }

                Section("白名单主机") {
                    LabeledContent("模型接口", value: vm.allowlistInfo.modelHosts.joined(separator: ", "))
                        .font(.footnote)
                    LabeledContent("远程 DSH", value: vm.allowlistInfo.remoteHosts.isEmpty ? "未配对" : vm.allowlistInfo.remoteHosts.joined(separator: ", "))
                        .font(.footnote)
                }

                Section("出站与阻断记录 (\(vm.auditEntries.count))") {
                    if vm.auditEntries.isEmpty {
                        Text("启动至今 0 次网络请求")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.auditEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.wasBlocked ? "已拦截" : "\(entry.statusCode ?? 200)")
                                        .font(.caption2.monospaced().weight(.semibold))
                                        .foregroundStyle(entry.wasBlocked ? DeepSeekTheme.diffRemoved : DeepSeekTheme.diffAdded)
                                    Text("\(entry.method) \(entry.host)")
                                        .font(.caption.monospaced())
                                    Spacer()
                                    Text("\(entry.durationMs) ms")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("网络与隐私审计")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清空") {
                        Task { await vm.clearAuditLogs() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await vm.refreshAuditSnapshot()
            }
        }
    }
}

// MARK: - Minimalist iOS Files.app Workspace Browser

public struct WorkspaceBrowserSheet: View {
    public let toolset: WorkspaceToolset
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var selectedFile: URL?
    @State private var selectedContent: String = ""
    @State private var newFileName: String = ""
    @State private var showingNewFileAlert = false

    public init(toolset: WorkspaceToolset) {
        self.toolset = toolset
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("已挂载至系统「文件 App › 我的 iPhone › DeepSeek Go › Workspace」，可与外部编辑器双向同步。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("文件 (\(files.count))") {
                    ForEach(files, id: \.path) { url in
                        Button {
                            selectedFile = url
                            selectedContent = (try? String(contentsOf: url, encoding: .utf8)) ?? "(空文件或二进制文件)"
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.primary)
                                Text(relativePath(for: url))
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.primary)
                                Spacer()
                                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                                Text("\(size) B")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            try? FileManager.default.removeItem(at: files[idx])
                        }
                        reloadFiles()
                    }
                }

                if let file = selectedFile {
                    Section(relativePath(for: file)) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(selectedContent)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("本机工作区")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showingNewFileAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("新建文件", isPresented: $showingNewFileAlert) {
                TextField("例如 notes/plan.md", text: $newFileName)
                Button("创建") {
                    if let safe = try? toolset.resolveSafeURL(newFileName) {
                        try? FileManager.default.createDirectory(at: safe.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? Data("# \(newFileName)\n".utf8).write(to: safe, options: .atomic)
                        newFileName = ""
                        reloadFiles()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .onAppear(perform: reloadFiles)
        }
    }

    private func reloadFiles() {
        guard let enumerator = FileManager.default.enumerator(
            at: toolset.rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var found: [URL] = []
        for case let u as URL in enumerator {
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.append(u)
            }
        }
        files = found.sorted { $0.path < $1.path }
    }

    private func relativePath(for url: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(of: toolset.rootURL.standardizedFileURL.path + "/", with: "")
    }
}

// MARK: - Persona & Ruleset Studio (with 1-Click Snapshot Rollback)

public struct PersonaStudioSheet: View {
    @Bindable public var vm: AppViewModel
    public var onShowProPaywall: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showingCustomCreator = false
    @State private var customTitle = ""
    @State private var customSubtitle = ""
    @State private var customPrompt = ""

    public init(vm: AppViewModel, onShowProPaywall: @escaping () -> Void) {
        self.vm = vm
        self.onShowProPaywall = onShowProPaywall
    }

    public var body: some View {
        NavigationStack {
            List {
                if vm.canRollbackPreset {
                    Section {
                        Button {
                            vm.rollbackPreset()
                        } label: {
                            Label("一键回滚至切换前的指令快照", systemImage: "arrow.uturn.backward")
                                .font(.footnote.weight(.medium))
                        }
                    }
                }

                Section("工作流与角色指令集") {
                    ForEach(vm.presets) { preset in
                        Button {
                            if vm.selectPreset(preset) {
                                dismiss()
                            } else {
                                dismiss()
                                onShowProPaywall()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: 28)
                                    .foregroundStyle(.primary)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(preset.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if preset.isProOnly && !vm.isProUnlocked {
                                            Text("PRO")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.primary.opacity(0.1)))
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                    Text(preset.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if preset.id == vm.activePresetId {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section {
                    Button {
                        showingCustomCreator = true
                    } label: {
                        Label("新建自定义系统规则 (.rules)", systemImage: "plus")
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("指令与规则预设")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showingCustomCreator) {
                NavigationStack {
                    Form {
                        TextField("预设名称（如 Swift 并发专家）", text: $customTitle)
                        TextField("简短说明", text: $customSubtitle)
                        Section("System Prompt 规则正文") {
                            TextEditor(text: $customPrompt)
                                .frame(minHeight: 140)
                        }
                    }
                    .navigationTitle("新建规则预设")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showingCustomCreator = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                vm.addCustomPreset(title: customTitle, subtitle: customSubtitle, systemPrompt: customPrompt)
                                customTitle = ""
                                customSubtitle = ""
                                customPrompt = ""
                                showingCustomCreator = false
                            }
                            .disabled(customTitle.trimmingCharacters(in: .whitespaces).isEmpty || customPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Locked-Down Zero-Network WKWebView Artifact Sandbox

public struct ArtifactSandboxSheet: View {
    public let artifact: ArtifactPayload
    @Environment(\.dismiss) private var dismiss

    public init(artifact: ArtifactPayload) {
        self.artifact = artifact
    }

    public var body: some View {
        NavigationStack {
            OfflineSandboxedWebView(html: wrappedHTML)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(artifact.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }

    private var wrappedHTML: String {
        let csp = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: blob:;">"#
        switch artifact.kind {
        case .html:
            if artifact.source.lowercased().contains("<head") {
                return artifact.source.replacingOccurrences(of: "<head>", with: "<head>\(csp)", options: .caseInsensitive)
            }
            return "<!doctype html><html><head>\(csp)<meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='font-family:-apple-system,sans-serif;padding:16px'>\(artifact.source)</body></html>"
        case .svg:
            return "<!doctype html><html><head>\(csp)<meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh'>\(artifact.source)</body></html>"
        case .mermaid:
            return "<!doctype html><html><head>\(csp)<meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='font-family:SFMono-Regular,monospace;padding:20px'><pre>\(artifact.source)</pre></body></html>"
        }
    }
}

#if os(iOS)
private struct OfflineSandboxedWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
#else
private struct OfflineSandboxedWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: cfg)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
#endif
