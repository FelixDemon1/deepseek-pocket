import SwiftUI
import UniformTypeIdentifiers
import WebKit
import DeepSeekCore

// MARK: - Beginner-Friendly Privacy & Network Record Sheet

public struct NetworkAuditSheet: View {
    @Bindable public var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("隐私保护状态") {
                    LabeledContent("当前仅允许连接", value: vm.providerConfig.friendlyEndpointLabel)
                        .font(.footnote)
                    Button("测试拦截第三方统计请求") {
                        Task { await vm.runFirewallSelfTest() }
                    }
                    .font(.footnote)
                }

                Section("最近联网记录 (\(vm.auditEntries.count))") {
                    if vm.auditEntries.isEmpty {
                        Text("暂无联网记录")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.auditEntries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(entry.wasBlocked ? "已拦截外部请求" : "正常连接 (\(entry.statusCode ?? 200))")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(entry.wasBlocked ? DeepSeekTheme.diffRemoved : DeepSeekTheme.diffAdded)
                                    Spacer()
                                    Text("\(entry.durationMs)ms")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(entry.host)\(entry.path)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("隐私与联网记录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !vm.auditEntries.isEmpty {
                        Button("清空") {
                            Task { await vm.clearAuditLogs() }
                        }
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

// MARK: - My Local Files Browser

public struct WorkspaceBrowserSheet: View {
    @Bindable public var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var selectedFile: URL?
    @State private var selectedContent: String = ""
    @State private var newFileName: String = ""
    @State private var showingNewFileAlert = false
    @State private var showingFolderImporter = false

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    private var toolset: WorkspaceToolset { vm.toolset }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("当前文件夹：\(toolset.rootURL.lastPathComponent)", systemImage: "folder")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button("选择手机其他文件夹") {
                            showingFolderImporter = true
                        }
                        .font(.footnote)

                        if toolset.isExternalSecurityScoped {
                            Button("恢复默认") {
                                vm.resetToBuiltInWorkspace()
                                reloadFiles()
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("文件列表 (\(files.count))") {
                    ForEach(files, id: \.path) { url in
                        Button {
                            selectedFile = url
                            selectedContent = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                        } label: {
                            HStack {
                                Text(relativePath(for: url))
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.primary)
                                Spacer()
                                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                                Text("\(size) B")
                                    .font(.caption.monospaced())
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
            .navigationTitle("我的本地文件")
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
                TextField("文件名（如 笔记.md）", text: $newFileName)
                Button("创建") {
                    if let safe = try? toolset.resolveSafeURL(newFileName) {
                        try? FileManager.default.createDirectory(at: safe.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? Data().write(to: safe, options: .atomic)
                        newFileName = ""
                        reloadFiles()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .fileImporter(
                isPresented: $showingFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case let .success(urls) = result, let picked = urls.first {
                    vm.mountExternalWorkspaceFolder(picked)
                    reloadFiles()
                }
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

// MARK: - Answering Style & Persona Sheet

public struct PersonaStudioSheet: View {
    @Bindable public var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingCustomCreator = false
    @State private var customTitle = ""
    @State private var customPrompt = ""

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            List {
                if vm.canRollbackPreset {
                    Section {
                        Button("恢复上一次的回答风格") {
                            vm.rollbackPreset()
                        }
                    }
                }

                Section("选择 AI 的回答风格") {
                    ForEach(vm.presets) { preset in
                        Button {
                            vm.selectPreset(preset)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.icon)
                                    .frame(width: 22)
                                    .foregroundStyle(.primary)
                                Text(preset.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if preset.id == vm.activePresetId {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(DeepSeekTheme.brandBlue)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showingCustomCreator = true
                    } label: {
                        Label("添加自定义回答要求", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("回答风格与角色")
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
                        TextField("风格名称（例如：温柔老师 / Python 专家）", text: $customTitle)
                        Section("告诉 AI 应该怎么回答你") {
                            TextEditor(text: $customPrompt)
                                .frame(minHeight: 160)
                        }
                    }
                    .navigationTitle("新建回答风格")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showingCustomCreator = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                vm.addCustomPreset(title: customTitle, systemPrompt: customPrompt)
                                customTitle = ""
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
                        Button("完成") { dismiss() }
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
