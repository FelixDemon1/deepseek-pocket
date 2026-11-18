import SwiftUI
import DeepSeekCore

/// Google Gemini Mobile-inspired Minimalist Workspace Shell.
public struct RootWorkspaceView: View {
    public enum ActiveSheet: String, Identifiable {
        case sessions, modelPicker, workspace, presets, settings, audit, share
        public var id: String { rawValue }
    }

    @Bindable public var vm: AppViewModel
    @Environment(\.colorScheme) private var systemScheme

    @State private var draftText: String = ""
    @State private var activeSheet: ActiveSheet?

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
                geminiHeader(scheme: scheme, ink: ink, secondary: secondary)

                if let banner = vm.errorBanner ?? vm.noticeBanner {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(vm.errorBanner != nil ? DeepSeekTheme.diffRemoved : DeepSeekTheme.brandBlue)
                            .frame(width: 6, height: 6)
                        Text(banner)
                            .font(.system(size: 13))
                            .foregroundStyle(ink)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            vm.errorBanner = nil
                            vm.noticeBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(DeepSeekTheme.surface(scheme))
                }

                chatBody(scheme: scheme, ink: ink, secondary: secondary)

                SteerComposerBar(
                    text: $draftText,
                    vm: vm,
                    onOpenWorkspace: { activeSheet = .workspace },
                    onOpenPresets: { activeSheet = .presets },
                    onRequireSetup: { activeSheet = .settings }
                )
            }
        }
        .preferredColorScheme(vm.appearance.colorScheme)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .sessions:
                geminiDrawerSheet(scheme: scheme, ink: ink, secondary: secondary)
            case .modelPicker:
                geminiModelHalfSheet(scheme: scheme, ink: ink, secondary: secondary)
                    .presentationDetents([.height(370)])
                    .presentationDragIndicator(.visible)
            case .workspace:
                WorkspaceBrowserSheet(vm: vm)
            case .presets:
                PersonaStudioSheet(vm: vm)
            case .settings:
                SettingsAndRemoteSheet(vm: vm, onOpenAudit: { activeSheet = .audit })
            case .audit:
                NetworkAuditSheet(vm: vm)
            case .share:
                if let session = vm.activeSession {
                    ShareCardSheet(session: session)
                }
            }
        }
        .sheet(item: $vm.activeArtifact) { artifact in
            ArtifactSandboxSheet(artifact: artifact)
        }
        .onAppear {
            if let name = vm.requestedSheetName {
                switch name {
                case "models": activeSheet = .modelPicker
                case "settings": activeSheet = .settings
                case "presets": activeSheet = .presets
                case "drawer": activeSheet = .sessions
                default: break
                }
                vm.requestedSheetName = nil
            }
        }
        .onChange(of: vm.requestedSheetName) { name in
            guard let name else { return }
            switch name {
            case "models": activeSheet = .modelPicker
            case "settings": activeSheet = .settings
            case "presets": activeSheet = .presets
            case "drawer": activeSheet = .sessions
            default: break
            }
            vm.requestedSheetName = nil
        }
    }

    // MARK: - Google Gemini Mobile Top Navigation Bar

    private func geminiHeader(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        HStack(spacing: 10) {
            // Left: Gemini staggered menu icon -> opens History & Navigation Drawer
            Button {
                activeSheet = .sessions
            } label: {
                VStack(alignment: .leading, spacing: 4.5) {
                    Capsule()
                        .fill(ink)
                        .frame(width: 18, height: 1.8)
                    Capsule()
                        .fill(ink.opacity(0.75))
                        .frame(width: 13, height: 1.8)
                }
                .frame(width: 36, height: 36)
                .background(Circle().fill(DeepSeekTheme.surface(scheme)))
            }
            .buttonStyle(.plain)

            Spacer()

            // Center: Gemini-style Model Switcher Pill -> opens bottom half-sheet
            Button {
                activeSheet = .modelPicker
            } label: {
                HStack(spacing: 5) {
                    Text("DeepSeek")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ink)
                    Text(vm.shortModelTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DeepSeekTheme.brandBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DeepSeekTheme.brandSoftFill(scheme)))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Spacer()

            // Right: Gemini New Chat + Profile/Settings Avatar Circle
            HStack(spacing: 8) {
                if !(vm.activeSession?.messages.filter { $0.role != .system }.isEmpty ?? true) {
                    Button {
                        vm.createNewSession()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ink)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(DeepSeekTheme.surface(scheme)))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    activeSheet = .settings
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Circle()
                            .fill(DeepSeekTheme.brandSoftFill(scheme))
                            .frame(width: 34, height: 34)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(DeepSeekTheme.brandBlue)
                            )

                        Circle()
                            .fill(vm.hasAPIKeyConfigured ? DeepSeekTheme.diffAdded : Color.orange)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(DeepSeekTheme.canvas(scheme), lineWidth: 1.5))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Body

    @ViewBuilder
    private func chatBody(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        let visibleMessages = (vm.activeSession?.messages ?? []).filter { $0.role != .system }
        if visibleMessages.isEmpty {
            VStack(spacing: 22) {
                Spacer()

                PixelCompanionView(mood: vm.companionMood, character: .whale, scale: 3.4)

                HStack(spacing: 8) {
                    quietActionPill(scheme: scheme, title: "体验演示", icon: "play") {
                        vm.runInteractiveShowcase()
                    }
                    quietActionPill(scheme: scheme, title: "本地文件", icon: "folder") {
                        activeSheet = .workspace
                    }
                    quietActionPill(scheme: scheme, title: "回答风格", icon: "sparkles") {
                        activeSheet = .presets
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
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
                                onShare: { activeSheet = .share }
                            )
                            .id(msg.id)
                        }
                        Color.clear.frame(height: 12).id("__bottom__")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
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

    private func quietActionPill(scheme: ColorScheme, title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(DeepSeekTheme.surface(scheme))
                    .overlay(Capsule().stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Google Gemini Mobile Bottom Half-Sheet Model Switcher

    private func geminiModelHalfSheet(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择对话模型")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ink)
                Spacer()
                Button("接口设置") {
                    activeSheet = .settings
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DeepSeekTheme.brandBlue)
            }
            .padding(.top, 18)

            VStack(spacing: 8) {
                geminiModelOptionRow(
                    scheme: scheme,
                    title: "DeepSeek R1 · 深度思考",
                    subtitle: "适合写代码、复杂推理与多步任务（官方 API）",
                    selected: vm.providerConfig.model == "deepseek-reasoner" && vm.providerConfig.baseURL.host == "api.deepseek.com"
                ) {
                    var next = vm.providerConfig
                    next.baseURL = URL(string: "https://api.deepseek.com/v1")!
                    next.model = "deepseek-reasoner"
                    vm.updateProviderConfig(next)
                    activeSheet = nil
                }

                geminiModelOptionRow(
                    scheme: scheme,
                    title: "DeepSeek V3 · 快速回答",
                    subtitle: "日常对话响应更快（官方 API）",
                    selected: vm.providerConfig.model == "deepseek-chat" && vm.providerConfig.baseURL.host == "api.deepseek.com"
                ) {
                    var next = vm.providerConfig
                    next.baseURL = URL(string: "https://api.deepseek.com/v1")!
                    next.model = "deepseek-chat"
                    vm.updateProviderConfig(next)
                    activeSheet = nil
                }

                geminiModelOptionRow(
                    scheme: scheme,
                    title: "免费体验通道 (OpenRouter R1)",
                    subtitle: "无需充值即可免费使用 R1 推理模型",
                    selected: vm.providerConfig.baseURL.host?.contains("openrouter.ai") == true
                ) {
                    var next = vm.providerConfig
                    next.baseURL = URL(string: "https://openrouter.ai/api/v1")!
                    next.model = "deepseek/deepseek-r1:free"
                    vm.updateProviderConfig(next)
                    activeSheet = nil
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .background(DeepSeekTheme.canvas(scheme).ignoresSafeArea())
    }

    private func geminiModelOptionRow(
        scheme: ColorScheme,
        title: String,
        subtitle: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(DeepSeekTheme.secondaryInk(scheme))
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? DeepSeekTheme.brandBlue : DeepSeekTheme.secondaryInk(scheme).opacity(0.4))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? DeepSeekTheme.brandSoftFill(scheme) : DeepSeekTheme.surface(scheme))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Google Gemini Mobile Navigation Drawer Sheet

    private func geminiDrawerSheet(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Gemini-style Top New Chat Pill + Quick Features
                VStack(spacing: 10) {
                    Button {
                        vm.createNewSession()
                        activeSheet = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                            Text("发起新对话")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(DeepSeekTheme.brandBlue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            Capsule().fill(DeepSeekTheme.brandSoftFill(scheme))
                        )
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        drawerFeatureChip(scheme: scheme, title: "我的本地文件", icon: "folder") {
                            activeSheet = .workspace
                        }
                        drawerFeatureChip(scheme: scheme, title: "回答风格：\(vm.activePreset.title)", icon: "sparkles") {
                            activeSheet = .presets
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                List {
                    Section("近期对话") {
                        ForEach(vm.filteredSessions) { session in
                            Button {
                                vm.activeSessionId = session.id
                                activeSheet = nil
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "bubble.left")
                                        .font(.system(size: 13))
                                        .foregroundStyle(session.id == vm.activeSessionId ? DeepSeekTheme.brandBlue : .secondary)
                                    Text(session.title)
                                        .font(.subheadline.weight(session.id == vm.activeSessionId ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                            }
                        }
                        .onDelete { offsets in
                            let list = vm.filteredSessions
                            for idx in offsets {
                                vm.deleteSession(list[idx].id)
                            }
                        }
                    }
                }
                .searchable(text: $vm.sessionSearchQuery, prompt: "搜索历史对话")
            }
            .navigationTitle("DeepSeek Pocket")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { activeSheet = nil }
                }
            }
        }
    }

    private func drawerFeatureChip(scheme: ColorScheme, title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DeepSeekTheme.surface(scheme))
            )
        }
        .buttonStyle(.plain)
    }
}
