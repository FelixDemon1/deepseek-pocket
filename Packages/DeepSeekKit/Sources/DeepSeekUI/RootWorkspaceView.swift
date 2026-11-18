import SwiftUI
import DeepSeekCore

/// Pure Apple / Google / Linear Minimalist Workspace Shell.
public struct RootWorkspaceView: View {
    @Bindable public var vm: AppViewModel
    @Environment(\.colorScheme) private var systemScheme

    @State private var draftText: String = ""
    @State private var showSessionsSheet: Bool = false
    @State private var showAuditSheet: Bool = false
    @State private var showWorkspaceSheet: Bool = false
    @State private var showPresetsSheet: Bool = false
    @State private var showSettingsSheet: Bool = false
    @State private var showProSheet: Bool = false
    @State private var showShareSheet: Bool = false

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    private var effectiveScheme: ColorScheme {
        vm.appearance.colorScheme ?? systemScheme
    }

    public var body: some View {
        let scheme = effectiveScheme
        let ink = DeepSeekTheme.primaryInk(scheme)
        let secondary = DeepSeekTheme.secondaryInk(scheme)
        let canvas = DeepSeekTheme.canvas(scheme)

        ZStack {
            canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                minimalHeader(scheme: scheme, ink: ink, secondary: secondary)

                if let notice = vm.noticeBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(DeepSeekTheme.brandBlue)
                        Text(notice)
                            .font(.system(size: 13))
                            .foregroundStyle(ink)
                        Spacer()
                        Button {
                            vm.noticeBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(DeepSeekTheme.surface(scheme))
                }

                if let banner = vm.errorBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                        Text(banner)
                            .font(.system(size: 13))
                        Spacer()
                        Button {
                            vm.errorBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(DeepSeekTheme.surface(scheme))
                }

                chatBody(scheme: scheme, ink: ink, secondary: secondary)

                SteerComposerBar(
                    text: $draftText,
                    vm: vm,
                    onOpenWorkspace: { showWorkspaceSheet = true },
                    onOpenPresets: { showPresetsSheet = true }
                )
            }
        }
        .preferredColorScheme(vm.appearance.colorScheme)
        .sheet(isPresented: $showSessionsSheet) {
            sessionsDrawerSheet
        }
        .sheet(isPresented: $showAuditSheet) {
            NetworkAuditSheet(vm: vm)
        }
        .sheet(isPresented: $showWorkspaceSheet) {
            WorkspaceBrowserSheet(toolset: vm.toolset)
        }
        .sheet(isPresented: $showPresetsSheet) {
            PersonaStudioSheet(vm: vm, onShowProPaywall: { showProSheet = true })
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsAndRemoteSheet(vm: vm)
        }
        .sheet(isPresented: $showProSheet) {
            ProPaywallSheet(vm: vm)
        }
        .sheet(isPresented: $showShareSheet) {
            if let session = vm.activeSession {
                ShareCardSheet(session: session)
            }
        }
        .sheet(item: $vm.activeArtifact) { artifact in
            ArtifactSandboxSheet(artifact: artifact)
        }
    }

    // MARK: - Whisper-Quiet ChatGPT / Gemini Centered Minimal Header

    private func minimalHeader(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        HStack {
            Button {
                showSessionsSheet = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Section("快速切换模型与渠道") {
                    ForEach(ProviderConfig.presets, id: \.label) { preset in
                        Button {
                            if let url = URL(string: preset.base) {
                                var next = vm.providerConfig
                                next.baseURL = url
                                next.model = preset.model
                                vm.updateProviderConfig(next)
                                vm.engineMode = .onDeviceHarness
                            }
                        } label: {
                            Text(preset.label)
                        }
                    }
                }
                Section("引擎与安全") {
                    Button {
                        showPresetsSheet = true
                    } label: {
                        Label("指令预设：\(vm.activePreset.title)", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        showAuditSheet = true
                    } label: {
                        Label("零遥测网络审计 (\(vm.auditEntries.count))", systemImage: "checkmark.shield")
                    }
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Label("模型网关与远程 DSH 设置", systemImage: "gearshape")
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Text(vm.shortModelTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ink)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(secondary)
                    }
                    Text("\(vm.engineMode == .onDeviceHarness ? "本机沙盒" : "远程主机") · 0 遥测")
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                }
            }

            Spacer()

            Button {
                vm.createNewSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Editorial Empty State & Clean Stream

    @ViewBuilder
    private func chatBody(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        let visibleMessages = (vm.activeSession?.messages ?? []).filter { $0.role != .system }
        if visibleMessages.isEmpty {
            emptyEditorialView(scheme: scheme, ink: ink, secondary: secondary)
        } else {
            let lastAssistantId = visibleMessages.last(where: { $0.role == .assistant })?.id
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 22) {
                        ForEach(visibleMessages) { msg in
                            MessageRowView(
                                message: msg,
                                pendingApproval: vm.pendingApproval,
                                requireFaceID: vm.requireFaceIDForApprovals,
                                isLastAssistant: msg.id == lastAssistantId,
                                onApprove: { allowed in vm.decideApproval(approved: allowed) },
                                onOpenArtifact: { art in vm.activeArtifact = art },
                                onFork: { vm.forkSession(upTo: msg.id) },
                                onRegenerate: { vm.regenerateLastTurn() },
                                onShare: { showShareSheet = true }
                            )
                            .id(msg.id)
                        }
                        Color.clear.frame(height: 12).id("__bottom__")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                }
                .onChange(of: visibleMessages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
                .onChange(of: visibleMessages.last?.content) { _, _ in
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
        }
    }

    private func emptyEditorialView(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 48)

                VStack(spacing: 14) {
                    MinimalBrandMark(size: 46)

                    Text("有什么可以帮你？")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(ink)
                        .tracking(-0.3)
                }

                // 2x2 Minimal Hairline Suggestion Grid (Google Gemini / ChatGPT Minimalist Style)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    minimalChip(
                        scheme: scheme,
                        title: "沙盒工作流演示",
                        subtitle: "免填 Key 预览思考与审批",
                        action: { vm.runInteractiveShowcase() }
                    )
                    minimalChip(
                        scheme: scheme,
                        title: "整理工作区代码",
                        subtitle: "读取文件并输出 Diff",
                        action: { vm.sendOrSteer(text: "列出本机工作区文件，读取 WELCOME.md 并起草一份精简的开发计划 PLAN.md。") }
                    )
                    minimalChip(
                        scheme: scheme,
                        title: "构建可交互小工具",
                        subtitle: "在离线沙盒渲染 HTML",
                        action: { vm.sendOrSteer(text: "调用 render_artifact 生成一个极简黑白风格的番茄钟与任务计时器。") }
                    )
                    minimalChip(
                        scheme: scheme,
                        title: "切换指令与规则",
                        subtitle: vm.activePreset.title,
                        action: { showPresetsSheet = true }
                    )
                }
                .padding(.horizontal, 16)

                if !vm.hasAPIKeyConfigured {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Text("连接 API Key、免费 R1 通道或自建网关")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 24)
            }
        }
    }

    private func minimalChip(scheme: ColorScheme, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DeepSeekTheme.surface(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Minimalist Navigation Drawer (Search + Sessions + Presets + Audit + Pro + Settings)

    private var sessionsDrawerSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showSessionsSheet = false
                        showPresetsSheet = true
                    } label: {
                        Label("指令与规则预设（\(vm.activePreset.title)）", systemImage: "slider.horizontal.3")
                    }

                    Button {
                        showSessionsSheet = false
                        showWorkspaceSheet = true
                    } label: {
                        Label("本机工作区文件", systemImage: "folder")
                    }

                    Button {
                        showSessionsSheet = false
                        showAuditSheet = true
                    } label: {
                        Label("零遥测网络审计", systemImage: "checkmark.shield")
                    }

                    Button {
                        showSessionsSheet = false
                        showProSheet = true
                    } label: {
                        HStack {
                            Label("DeepSeek Go Pro", systemImage: "sparkles.square.filled.on.square")
                            Spacer()
                            Text(vm.isProUnlocked ? "已激活" : "升级")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        showSessionsSheet = false
                        showSettingsSheet = true
                    } label: {
                        Label("设置与网关渠道", systemImage: "gearshape")
                    }
                }

                Section("历史对话") {
                    ForEach(vm.filteredSessions) { session in
                        Button {
                            vm.activeSessionId = session.id
                            showSessionsSheet = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title)
                                        .font(.subheadline.weight(session.id == vm.activeSessionId ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                    Text("\(session.messages.filter { $0.role != .system }.count) 条消息")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if session.id == vm.activeSessionId {
                                    Circle()
                                        .fill(Color.primary)
                                        .frame(width: 6, height: 6)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let currentList = vm.filteredSessions
                        for idx in offsets {
                            vm.deleteSession(currentList[idx].id)
                        }
                    }
                }
            }
            .searchable(text: $vm.sessionSearchQuery, prompt: "搜索历史对话与消息")
            .navigationTitle("DeepSeek Go")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSessionsSheet = false }
                }
            }
        }
    }
}
