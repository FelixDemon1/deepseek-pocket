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

// MARK: - 项目（默认工作区 + 用户文件夹）

public struct WorkspaceBrowserSheet: View {
    @Bindable public var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingFolderImporter = false
    @State private var showingDeviceFiles = false

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ProjectFilesView(
                            rootURL: WorkspaceToolset.builtIn().rootURL,
                            title: "默认工作区",
                            projectId: nil,
                            vm: vm
                        )
                    } label: {
                        projectRow(icon: "tray.full", name: "默认工作区",
                                   detail: "没挂项目的对话都在这里 · \(vm.sessions(in: nil).count) 个对话")
                    }
                } footer: {
                    Text("默认工作区是 App 自带的沙盒目录，会出现在系统「文件」App 里。")
                        .font(.caption2)
                }

                Section("项目") {
                    if vm.projects.isEmpty {
                        Text("把任意文件夹加成项目，之后的对话就固定在那个文件夹里读写文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(vm.projects) { project in
                        if let root = vm.rootURL(for: project) {
                            NavigationLink {
                                ProjectFilesView(rootURL: root, title: project.name,
                                                projectId: project.id, vm: vm)
                            } label: {
                                projectRow(icon: "folder.fill", name: project.name,
                                           detail: "\(vm.sessions(in: project.id).count) 个对话")
                            }
                            .swipeActions {
                                Button("删除", role: .destructive) { vm.deleteProject(project.id) }
                            }
                        } else {
                            projectRow(icon: "folder.badge.questionmark", name: project.name,
                                       detail: "书签失效，请重新添加")
                        }
                    }

                    Button {
                        showingFolderImporter = true
                    } label: {
                        Label("添加项目（选择文件夹）", systemImage: "folder.badge.plus")
                    }
                }

                Section {
                    Button {
                        showingDeviceFiles = true
                    } label: {
                        Label("设备文件（实验）", systemImage: "internaldrive")
                    }
                } footer: {
                    if #available(iOS 17.0, *) {
                        Text(DeviceFilesystem.shared.appGroupAvailable
                             ? "已具备 App Group 容器，可以尝试越权浏览其他 App 的数据。"
                             : "当前签名没有 App Group 容器，越权浏览不可用（详见自检页）。")
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle("我的项目")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case let .success(urls) = result, let url = urls.first {
                    _ = vm.addProject(folderURL: url)
                }
            }
            .sheet(isPresented: $showingDeviceFiles) {
                if #available(iOS 17.0, *) {
                    DeviceFilesSheet()
                }
            }
        }
    }

    private func projectRow(icon: String, name: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(DeepSeekTheme.brandBlue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// 单个项目/默认工作区的文件列表。
public struct ProjectFilesView: View {
    public let rootURL: URL
    public let title: String
    public let projectId: UUID?
    @Bindable public var vm: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var selectedFile: URL?
    @State private var selectedContent: String = ""
    @State private var newFileName: String = ""
    @State private var showingNewFileAlert = false

    public init(rootURL: URL, title: String, projectId: UUID?, vm: AppViewModel) {
        self.rootURL = rootURL
        self.title = title
        self.projectId = projectId
        self.vm = vm
    }

    public var body: some View {
        List {
            Section {
                Button {
                    vm.createNewSession(in: projectId)
                    dismiss()
                } label: {
                    Label("在此项目中新建对话", systemImage: "plus.bubble")
                }
            }

            Section("文件 (\(files.count))") {
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
                            Text("\(size) B").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for idx in offsets { try? FileManager.default.removeItem(at: files[idx]) }
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
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    showingNewFileAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("新建文件", isPresented: $showingNewFileAlert) {
            TextField("文件名（如 笔记.md）", text: $newFileName)
            Button("创建") {
                let safe = rootURL.appendingPathComponent(newFileName)
                try? FileManager.default.createDirectory(at: safe.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: safe, options: .atomic)
                newFileName = ""
                reloadFiles()
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear { reloadFiles() }
    }

    private func reloadFiles() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let en = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles]) else {
            files = []
            return
        }
        var out: [URL] = []
        for case let url as URL in en {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(url)
            }
            if out.count >= 400 { break }
        }
        files = out.sorted { relativePath(for: $0) < relativePath(for: $1) }
    }

    private func relativePath(for url: URL) -> String {
        let prefix = rootURL.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
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
                        Button("恢复上一次的系统提示词") {
                            vm.rollbackPreset()
                        }
                    }
                }

                Section("选择一个模式") {
                    ForEach(vm.presets) { preset in
                        Button {
                            vm.selectPreset(preset)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.icon)
                                    .frame(width: 22)
                                    .foregroundStyle(.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title)
                                        .foregroundStyle(.primary)
                                    if let summary = preset.summary {
                                        Text(summary)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
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
                        Label("自定义模式", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("模式")
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
                        TextField("名称（例如：极简 Python 导师）", text: $customTitle)
                        Section("设定系统提示词内容") {
                            TextEditor(text: $customPrompt)
                                .frame(minHeight: 160)
                        }
                    }
                    .navigationTitle("新建系统提示词")
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
