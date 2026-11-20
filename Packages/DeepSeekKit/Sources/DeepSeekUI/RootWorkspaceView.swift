import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import DeepSeekCore

/// Google Gemini Mobile-inspired Minimalist Workspace Shell.
public struct RootWorkspaceView: View {
    public enum ActiveSheet: String, Identifiable {
        case modelPicker, workspace, presets, audit, share, connectAI
        public var id: String { rawValue }
    }

    /// Gemini mobile never pushes these from the bottom — history slides in from the
    /// leading edge and account/settings slides in from the trailing edge.
    public enum SidePanel: String, Equatable {
        case sessions, settings
    }

    @Bindable public var vm: AppViewModel
    @Environment(\.colorScheme) private var systemScheme

    @State private var draftText: String = ""
    @State private var activeSheet: ActiveSheet?
    @State private var activeSide: SidePanel?
    /// 0 = fully closed, 1 = fully open. Driven directly by the finger while dragging.
    @State private var panelProgress: CGFloat = 0
    @State private var containerWidth: CGFloat = 393
    @State private var dragStartProgress: CGFloat = 0
    @State private var dragAnchorX: CGFloat = 0
    @State private var isDraggingDrawer = false
    @State private var isDraggingScrim = false
    /// 是否跟随最新输出自动滚到底；用户手动上滑阅读时为 false，并出现「回到底部」按钮
    @State private var followsBottom = true
    @State private var modelQuery: String = ""
    @State private var renamingSession: ChatSession?
    @State private var renameDraft: String = ""

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
                    let isError = vm.errorBanner != nil
                    HStack(spacing: 8) {
                        Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(isError ? DeepSeekTheme.diffRemoved : DeepSeekTheme.diffAdded)
                        Text(banner)
                            .font(.system(size: 13))
                            .foregroundStyle(ink)
                            .lineLimit(3)
                        Spacer(minLength: 6)
                        if isError {
                            Button("复制") {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = banner
                                #endif
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(secondary)
                            .buttonStyle(.plain)
                        }
                        Button {
                            vm.errorBanner = nil
                            vm.noticeBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DeepSeekTheme.surface(scheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75)
                            )
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: banner) {
                        // 普通提示几秒后自己收起；报错留着等用户看完
                        guard !isError else { return }
                        try? await Task.sleep(for: .seconds(3.5))
                        if vm.noticeBanner == banner { vm.noticeBanner = nil }
                    }
                }

                chatBody(scheme: scheme, ink: ink, secondary: secondary)

                SteerComposerBar(
                    text: $draftText,
                    vm: vm,
                    onOpenWorkspace: { activeSheet = .workspace },
                    onOpenPresets: { activeSheet = .presets },
                    onRequireSetup: { activeSheet = .connectAI }
                )
            }
        }
        .overlay {
            sidePanelLayer(scheme: scheme, ink: ink, secondary: secondary)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newWidth in containerWidth = newWidth }
            }
        }
        .simultaneousGesture(drawerGesture)
        .tint(DeepSeekTheme.brandBlue)
        .animation(.snappy(duration: 0.25), value: vm.errorBanner ?? vm.noticeBanner)
        .preferredColorScheme(vm.appearance.colorScheme)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .modelPicker:
                geminiModelHalfSheet(scheme: scheme, ink: ink, secondary: secondary)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .connectAI:
                ConnectAISheet(vm: vm)
            case .workspace:
                WorkspaceBrowserSheet(vm: vm)
            case .presets:
                PersonaStudioSheet(vm: vm)
            case .audit:
                NetworkAuditSheet(vm: vm)
            case .share:
                if let session = vm.activeSession {
                    ShareCardSheet(session: session)
                }
            }
        }
        .onChange(of: activeSheet) { _, _ in endEditing() }
        .sheet(isPresented: $vm.purgeIntroPresented) {
            PurgeIntroSheet { sample in
                draftText = sample
                vm.purgeIntroPresented = false
            }
        }
        .sheet(item: $vm.activeArtifact) { artifact in
            ArtifactSandboxSheet(artifact: artifact)
        }
        .onAppear {
            if let name = vm.requestedSheetName {
                switch name {
                case "models": activeSheet = .modelPicker
                case "settings": openSidePanel(.settings)
                case "connect": activeSheet = .connectAI
            case "presets": activeSheet = .presets
                case "drawer": openSidePanel(.sessions)
                default: break
                }
                vm.requestedSheetName = nil
            }
        }
        .onChange(of: vm.requestedSheetName) { _, name in
            guard let name else { return }
            switch name {
            case "models": activeSheet = .modelPicker
            case "settings": openSidePanel(.settings)
            case "connect": activeSheet = .connectAI
            case "presets": activeSheet = .presets
            case "drawer": openSidePanel(.sessions)
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
                openSidePanel(.sessions)
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
                activeSheet = vm.isAIConfigured ? .modelPicker : .connectAI
            } label: {
                HStack(spacing: 5) {
                    Text(vm.headerChannelTitle)
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
                    openSidePanel(.settings)
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        avatarCircle(size: 34, scheme: scheme)

                        Circle()
                            .fill(vm.isAIConfigured ? DeepSeekTheme.diffAdded : Color.orange)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        PixelCompanionView(mood: vm.companionMood, character: .whale, scale: 2.6)
                        Text(greeting)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(ink)
                        Text("交给我去做，或者随便聊聊。")
                            .font(.system(size: 16))
                            .foregroundStyle(secondary)
                    }
                    .padding(.top, 36)

                    if !vm.isAIConfigured {
                        Button {
                            activeSheet = .connectAI
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "bolt.horizontal.circle.fill")
                                    .font(.system(size: 22))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("先连接 AI")
                                        .font(.system(size: 15, weight: .semibold))
                                    Text("登录网页版免 Key，或粘贴任一厂商的 API Key")
                                        .font(.system(size: 12))
                                        .opacity(0.85)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DeepSeekTheme.brandBlue))
                        }
                        .buttonStyle(.plain)
                    }

                    if vm.isAIConfigured && !vm.agentToolsAvailable {
                        Label("当前渠道只能聊天。要让我动手做事（文件、Python、提醒、操作手机），请切到 DeepSeek 网页版或任一 API Key。", systemImage: "info.circle")
                            .font(.system(size: 12.5))
                            .foregroundStyle(secondary)
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(suggestions, id: \.title) { item in
                            Button {
                                draftText = item.prompt
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(DeepSeekTheme.brandBlue)
                                    Text(item.title)
                                        .font(.system(size: 14.5, weight: .semibold))
                                        .foregroundStyle(ink)
                                    Text(item.subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                                .padding(13)
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
                    }

                    HStack(spacing: 8) {
                        quietActionPill(scheme: scheme, title: "看演示", icon: "play") {
                            vm.runInteractiveShowcase()
                        }
                        quietActionPill(scheme: scheme, title: "项目", icon: "folder") {
                            activeSheet = .workspace
                        }
                        quietActionPill(scheme: scheme, title: "模式", icon: "sparkles") {
                            activeSheet = .presets
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { endEditing() }
        } else {
            let lastAssistantId = visibleMessages.last(where: { $0.role == .assistant })?.id
            let timeline = ChatTimelineItem.build(from: visibleMessages)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 22) {
                        ForEach(timeline) { item in
                            switch item {
                            case let .user(message):
                                MessageRowView(
                                    message: message,
                                    pendingApproval: nil,
                                    requireFaceID: false,
                                    onApprove: { _ in },
                                    onOpenArtifact: { _ in },
                                    onEditUser: { text in draftText = text }
                                )
                            case let .turn(_, messages):
                                AgentTurnView(
                                    messages: messages,
                                    isLive: vm.isStreaming && item.id == timeline.last?.id,
                                    liveStatus: liveStatusText,
                                    pendingApproval: vm.pendingApproval,
                                    requireFaceID: vm.requireFaceIDForApprovals,
                                    isLastTurn: messages.contains { $0.id == lastAssistantId },
                                    showUnrestrictedBadge: vm.isUnrestrictedMode,
                                    workspaceRoot: vm.toolset.rootURL,
                                    onApprove: { allowed in
                                        Haptics.tap()
                                        vm.decideApproval(approved: allowed)
                                    },
                                    onApproveTurn: { vm.decideApproval(approved: true, rememberForTurn: true) },
                                    onOpenArtifact: { art in vm.activeArtifact = art },
                                    onFork: { messageId in vm.forkSession(upTo: messageId) },
                                    onRegenerate: { vm.regenerateLastTurn() },
                                    onShare: { activeSheet = .share }
                                )
                            }
                        }
                        if let failure = vm.turnFailure, failure.sessionId == vm.activeSessionId, !vm.isStreaming {
                            turnFailureCard(failure.message, scheme: scheme, ink: ink, secondary: secondary)
                        }
                        Color.clear.frame(height: 12).id("__bottom__")
                            .onAppear {
                                // iOS 17 兜底：滑回底部即恢复跟随（iOS 18+ 由滚动阶段精确判定）
                                if #available(iOS 18.0, macOS 15.0, *) {} else { followsBottom = true }
                            }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { endEditing() })
                .modifier(BottomFollowTracker(follows: $followsBottom))
                .onChange(of: visibleMessages.count) { _, _ in
                    // 自己刚发出的消息总是拉回底部并恢复跟随；其余情况尊重用户的阅读位置
                    if visibleMessages.last?.role == .user { followsBottom = true }
                    guard followsBottom else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
                .onChange(of: streamingFootprint(visibleMessages.last)) { _, _ in
                    guard followsBottom else { return }
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
                .onChange(of: vm.turnFailure) { _, failure in
                    guard failure != nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
                .onChange(of: vm.pendingApproval?.id) { _, pendingID in
                    // 审批卡必须出现在眼前：按钮被挡住的话整轮任务就卡在那里
                    guard pendingID != nil else { return }
                    followsBottom = true
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
                .onChange(of: vm.activeSessionId) { _, _ in
                    followsBottom = true
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
                .overlay(alignment: .bottom) {
                    if !followsBottom {
                        Button {
                            followsBottom = true
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("__bottom__", anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(ink)
                                .frame(width: 36, height: 36)
                                .background(
                                    Circle()
                                        .fill(DeepSeekTheme.surface(scheme))
                                        .overlay(Circle().stroke(DeepSeekTheme.hairline(scheme), lineWidth: 0.75))
                                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("回到底部")
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: followsBottom)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "夜深了" : hour < 11 ? "早上好" : hour < 13 ? "中午好" : hour < 18 ? "下午好" : "晚上好"
        return vm.displayName.isEmpty ? part : "\(part)，\(vm.displayName)"
    }

    private var suggestions: [(icon: String, title: String, subtitle: String, prompt: String)] {
        var items: [(icon: String, title: String, subtitle: String, prompt: String)] = [
            ("folder.badge.gearshape", "整理工作区", "看看有哪些文件，写一份索引",
             "看看工作区里有哪些文件，按用途整理一下，并写一份索引 notes/index.md。"),
            ("chart.bar.xaxis", "用 Python 画图", "生成数据、汇总、出图",
             "用 Python 生成一组 12 个月的示例销售数据，按季度汇总，并画一张柱状图存成 sales.png。"),
            ("bell.badge", "设个提醒", "写进系统的提醒事项",
             "明天上午 9 点提醒我给妈妈打电话。")
        ]
        if vm.phoneRunnerOnline {
            items.append(("hand.tap", "操作手机", "打开别的 App 帮我点",
                          "打开「设置」，进入「通用 › 关于本机」，告诉我这台手机的系统版本。"))
        } else {
            items.append(("macwindow", "做个小工具", "生成可交互的预览卡片",
                          "做一个番茄钟的交互小页面，能开始、暂停和重置。"))
        }
        return items
    }

    private func turnFailureCard(_ message: String, scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(DeepSeekTheme.diffRemoved)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button {
                    Haptics.tap()
                    vm.regenerateLastTurn()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(DeepSeekTheme.brandBlue))
                }
                Button {
                    activeSheet = .connectAI
                } label: {
                    Text("连接设置")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().stroke(DeepSeekTheme.hairline(scheme), lineWidth: 1))
                }
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = message
                    #endif
                    vm.noticeBanner = "已复制报错内容"
                } label: {
                    Text("复制")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DeepSeekTheme.diffRemoved.opacity(scheme == .dark ? 0.14 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DeepSeekTheme.diffRemoved.opacity(0.25), lineWidth: 0.75)
                )
        )
    }

    /// 流式期间正文 / 思考 / 工具卡片任何一项增长都算「有新内容」
    private func streamingFootprint(_ message: ChatMessage?) -> Int {
        guard let message else { return 0 }
        return message.content.utf8.count &+ (message.reasoningContent?.utf8.count ?? 0) &* 31 &+ message.toolCalls.count &* 7919
    }

    private var liveStatusText: String {
        if vm.activeStageText == "思考中", let spec = vm.activeWebAdapter {
            return "正在连接 \(spec.name)…"
        }
        return vm.activeStageText.isEmpty ? "思考中…" : "\(vm.activeStageText)…"
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
        let channelDesc = vm.activeWebAdapter?.name ?? vm.providerConfig.friendlyEndpointLabel
        let allModels = vm.availableModelsForActiveChannel
        let query = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = query.isEmpty ? allModels : allModels.filter {
            $0.localizedCaseInsensitiveContains(query) || Self.friendlyModelTitle($0).localizedCaseInsensitiveContains(query)
        }
        // 网页版渠道的模型是固定映射，不接受自定义 ID
        let allowsCustomID = vm.activeWebAdapter == nil
        let canUseCustom = allowsCustomID && !query.isEmpty && !query.contains(" ") && !allModels.contains(query)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选择模型")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ink)
                    Text("当前渠道：\(channelDesc)")
                        .font(.system(size: 12))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
                Spacer()
                if vm.activeWebAdapter == nil && vm.hasAPIKeyConfigured {
                    Button {
                        Task { await vm.discoverGatewayModels() }
                    } label: {
                        if vm.isFetchingModelsOrBalance {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("刷新列表")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(secondary)
                        }
                    }
                    .padding(.trailing, 6)
                }
                Button("更换渠道") {
                    activeSheet = .connectAI
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DeepSeekTheme.brandBlue)
            }
            .padding(.top, 18)

            if allowsCustomID || allModels.count > 6 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(secondary)
                    TextField(allowsCustomID ? "搜索，或直接输入模型 ID" : "搜索模型", text: $modelQuery)
                        .font(.system(size: 14))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .submitLabel(.done)
                        .onSubmit {
                            if canUseCustom { selectModel(query) }
                        }
                    if !modelQuery.isEmpty {
                        Button {
                            modelQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DeepSeekTheme.surface(scheme)))
            }

            ScrollView {
                VStack(spacing: 8) {
                    if canUseCustom {
                        geminiModelOptionRow(
                            scheme: scheme,
                            title: "使用自定义模型「\(query)」",
                            subtitle: "列表里没有也能用：按渠道文档填写完整模型 ID",
                            selected: false
                        ) {
                            selectModel(query)
                        }
                    }
                    if models.isEmpty && !canUseCustom {
                        Text("没有匹配「\(query)」的模型")
                            .font(.system(size: 13))
                            .foregroundStyle(secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                    ForEach(models, id: \.self) { modelID in
                        geminiModelOptionRow(
                            scheme: scheme,
                            title: Self.friendlyModelTitle(modelID),
                            subtitle: modelID,
                            selected: vm.providerConfig.model == modelID
                        ) {
                            selectModel(modelID)
                        }
                    }

                    geminiModelOptionRow(
                        scheme: scheme,
                        title: "连接或切换其他 AI 渠道…",
                        subtitle: "免 Key 网页版（DeepSeek / 豆包 / 千问）· 各大厂商 API Key · 云端网关",
                        selected: false
                    ) {
                        activeSheet = .connectAI
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 20)
        .background(DeepSeekTheme.canvas(scheme).ignoresSafeArea())
        .onAppear { modelQuery = "" }
    }

    private func selectModel(_ modelID: String) {
        var next = vm.providerConfig
        next.model = modelID
        vm.updateProviderConfig(next)
        modelQuery = ""
        activeSheet = nil
    }

    private static func friendlyModelTitle(_ modelID: String) -> String {
        switch modelID {
        case "deepseek-chat": return "DeepSeek V3 · 快速回答"
        case "deepseek-reasoner": return "DeepSeek R1 · 深度思考"
        case "doubao-seed-1.6": return "豆包 Seed 1.6 · 快速回答"
        case "doubao-seed-1.6-thinking": return "豆包 Seed 1.6 · 深度思考"
        case "qwen3-max", "qwen-max": return "Qwen Max · 旗舰主力"
        case "qwen-plus": return "Qwen Plus · 均衡高速"
        case "qwen-turbo": return "Qwen Turbo · 极速轻量"
        case "qwq-32b", "qwq-plus": return "QwQ · 深度推理模型"
        case "glm-4-flash": return "GLM-4-Flash · 免费极速"
        case "glm-z1-flash": return "GLM-Z1-Flash · 免费深度推理"
        default: return modelID
        }
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

    // MARK: - 历史抽屉：搜索 + 新对话在上，按时间分组的会话居中，账号与设置在底部

    private func sessionsPanel(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(secondary)
                    TextField("搜索对话", text: $vm.sessionSearchQuery)
                        .font(.system(size: 15))
                        .autocorrectionDisabled()
                    if !vm.sessionSearchQuery.isEmpty {
                        Button {
                            vm.sessionSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Capsule().fill(DeepSeekTheme.surface(scheme)))

                Button {
                    Haptics.tap()
                    vm.createNewSession()
                    closeSidePanel()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ink)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(DeepSeekTheme.surface(scheme)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新对话")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            List {
                let groups = vm.sessionGroups()
                if groups.isEmpty && vm.projects.isEmpty {
                    Text(vm.sessionSearchQuery.isEmpty ? "还没有对话" : "没有找到相关对话")
                        .font(.system(size: 14))
                        .foregroundStyle(secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(groups, id: \.title) { group in
                    Section {
                        sessionRows(group.sessions, scheme: scheme)
                    } header: {
                        sectionHeader(icon: nil, title: group.title)
                    }
                }

                ForEach(vm.projects) { project in
                    Section {
                        sessionRows(vm.sessions(in: project.id), scheme: scheme)
                        Button {
                            vm.createNewSession(in: project.id)
                            closeSidePanel()
                        } label: {
                            Label("在此项目中新建对话", systemImage: "plus")
                                .font(.system(size: 14))
                                .foregroundStyle(secondary)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } header: {
                        sectionHeader(icon: "folder.fill", title: project.name)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 40)

            Rectangle().fill(DeepSeekTheme.hairline(scheme)).frame(height: 0.75)
            HStack(spacing: 10) {
                Button {
                    openSidePanel(.settings)
                } label: {
                    HStack(spacing: 10) {
                        avatarCircle(size: 36, scheme: scheme)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vm.displayName.isEmpty ? "设置昵称" : vm.displayName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(ink)
                                .lineLimit(1)
                            Text("\(vm.headerChannelTitle) · \(vm.activePreset.title)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    dismissPanelImmediately()
                    activeSheet = .workspace
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 16))
                        .foregroundStyle(ink)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("管理项目")

                Button {
                    openSidePanel(.settings)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(ink)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(DeepSeekTheme.canvas(scheme))
        .alert("重命名对话", isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField("对话标题", text: $renameDraft)
            Button("保存") {
                if let session = renamingSession {
                    vm.renameSession(session.id, to: renameDraft)
                }
                renamingSession = nil
            }
            Button("取消", role: .cancel) { renamingSession = nil }
        }
    }

    // MARK: - Edge Side Panels (interactive, finger-tracked)

    @ViewBuilder
    private func sidePanelLayer(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        if let side = activeSide {
            let width = panelWidth(for: side)

            ZStack(alignment: side == .sessions ? .leading : .trailing) {
                Color.black
                    .opacity(0.32 * panelProgress)
                    .ignoresSafeArea()
                    .onTapGesture { closeSidePanel() }
                    .gesture(scrimDragGesture)

                sidePanelContent(for: side, scheme: scheme, ink: ink, secondary: secondary)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(DeepSeekTheme.canvas(scheme))
                    .shadow(
                        color: .black.opacity(0.18),
                        radius: 24,
                        x: side == .sessions ? 12 : -12,
                        y: 0
                    )
                    .offset(x: panelOffset(for: side, width: width))
            }
        }
    }

    private func panelWidth(for side: SidePanel) -> CGFloat {
        side == .sessions
            ? min(containerWidth * 0.86, 330)
            : min(containerWidth * 0.94, 400)
    }

    private func panelOffset(for side: SidePanel, width: CGFloat) -> CGFloat {
        // leading panel slides in from -width, trailing panel from +width
        side == .sessions
            ? (panelProgress - 1) * width
            : (1 - panelProgress) * width
    }

    @ViewBuilder
    private func sidePanelContent(for side: SidePanel, scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        switch side {
        case .sessions:
            sessionsPanel(scheme: scheme, ink: ink, secondary: secondary)
        case .settings:
            SettingsAndRemoteSheet(
                vm: vm,
                onOpenAudit: {
                    dismissPanelImmediately()
                    activeSheet = .audit
                },
                onClose: { closeSidePanel() }
            )
        }
    }

    /// 全局收起键盘：不依赖哪个子视图持有 FocusState。
    private func endEditing() {
        #if canImport(UIKit) && os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        #endif
    }

    private func openSidePanel(_ side: SidePanel) {
        endEditing()
        if activeSide == side {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { panelProgress = 1 }
            return
        }
        let wasClosed = activeSide == nil
        activeSide = side
        if wasClosed {
            panelProgress = 0
            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) { panelProgress = 1 }
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { panelProgress = 1 }
        }
    }

    private func closeSidePanel() {
        withAnimation(.easeOut(duration: 0.22)) { panelProgress = 0 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            if panelProgress == 0 { activeSide = nil }
        }
    }

    private func dismissPanelImmediately() {
        activeSide = nil
        panelProgress = 0
    }

    /// One gesture serves opening (edge swipe) and closing (swipe the panel away),
    /// because both are just `progress = start + translation * direction / width`.
    private var drawerGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                // 面板已经打开时，这里什么都不做：关不关由"点页外遮罩"决定，
                // 不再劫持面板内部的横向滑动（列表左滑删除要用）。
                guard activeSide == nil else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                if !isDraggingDrawer {
                    guard abs(dx) > 14, abs(dx) > abs(dy) * 1.6 else { return }
                    if value.startLocation.x <= 28 {
                        activeSide = .sessions
                    } else if value.startLocation.x >= containerWidth - 28 {
                        activeSide = .settings
                    } else {
                        return
                    }
                    panelProgress = 0
                    isDraggingDrawer = true
                    dragStartProgress = 0
                    dragAnchorX = dx
                }

                guard let side = activeSide else { return }
                let dir: CGFloat = side == .sessions ? 1 : -1
                let width = panelWidth(for: side)
                let next = dragStartProgress + ((dx - dragAnchorX) * dir) / width
                panelProgress = min(max(next, 0), 1)
            }
            .onEnded { value in
                defer { isDraggingDrawer = false }
                guard isDraggingDrawer, let side = activeSide else { return }
                let dir: CGFloat = side == .sessions ? 1 : -1
                let width = panelWidth(for: side)
                let travelled = value.predictedEndTranslation.width - dragAnchorX
                let projected = min(max(dragStartProgress + (travelled * dir) / width, 0), 1)
                dragStartProgress = 0
                if projected > 0.5 {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { panelProgress = 1 }
                } else {
                    closeSidePanel()
                }
            }
    }

    /// 只有点在"页外遮罩"上拖，才会把面板推回去。
    private var scrimDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard let side = activeSide else { return }
                if !isDraggingScrim {
                    isDraggingScrim = true
                    dragStartProgress = panelProgress
                    dragAnchorX = value.translation.width
                }
                let dir: CGFloat = side == .sessions ? 1 : -1
                let width = panelWidth(for: side)
                let next = dragStartProgress + ((value.translation.width - dragAnchorX) * dir) / width
                panelProgress = min(max(next, 0), 1)
            }
            .onEnded { value in
                defer { isDraggingScrim = false }
                guard isDraggingScrim, let side = activeSide else { return }
                let dir: CGFloat = side == .sessions ? 1 : -1
                let width = panelWidth(for: side)
                let travelled = value.predictedEndTranslation.width - dragAnchorX
                let projected = min(max(dragStartProgress + (travelled * dir) / width, 0), 1)
                dragStartProgress = 0
                if projected > 0.5 {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { panelProgress = 1 }
                } else {
                    closeSidePanel()
                }
            }
    }

    @ViewBuilder
    private func avatarCircle(size: CGFloat, scheme: ColorScheme) -> some View {
        ZStack {
            Circle().fill(DeepSeekTheme.brandSoftFill(scheme))
            avatarGlyph(size: size)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    #if canImport(UIKit)
    @ViewBuilder
    private func avatarGlyph(size: CGFloat) -> some View {
        if let data = vm.avatarImageData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            emojiOrPerson(size: size)
        }
    }
    #else
    @ViewBuilder
    private func avatarGlyph(size: CGFloat) -> some View {
        emojiOrPerson(size: size)
    }
    #endif

    @ViewBuilder
    private func emojiOrPerson(size: CGFloat) -> some View {
        #if canImport(UIKit)
        if let icon = UIImage(named: "AvatarDefault") {
            Image(uiImage: icon)
                .resizable()
                .scaledToFill()
        } else {
            fallbackAvatarIcon(size: size)
        }
        #else
        fallbackAvatarIcon(size: size)
        #endif
    }

    @ViewBuilder
    private func fallbackAvatarIcon(size: CGFloat) -> some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(DeepSeekTheme.brandBlue)
    }

    @ViewBuilder
    private func sessionRows(_ list: [ChatSession], scheme: ColorScheme) -> some View {
        ForEach(list) { session in
            let active = session.id == vm.activeSessionId
            Button {
                vm.activateSession(session.id)
                closeSidePanel()
            } label: {
                HStack(spacing: 8) {
                    Text(session.title)
                        .font(.system(size: 15, weight: active ? .semibold : .regular))
                        .foregroundStyle(DeepSeekTheme.primaryInk(scheme))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(active ? DeepSeekTheme.brandSoftFill(scheme) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .contextMenu {
                Button {
                    renameDraft = session.title
                    renamingSession = session
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                if !vm.projects.isEmpty || session.projectId != nil {
                    Menu {
                        if session.projectId != nil {
                            Button("默认工作区") { vm.moveSession(session.id, to: nil) }
                        }
                        ForEach(vm.projects.filter { $0.id != session.projectId }) { project in
                            Button(project.name) { vm.moveSession(session.id, to: project.id) }
                        }
                    } label: {
                        Label("移到项目", systemImage: "folder")
                    }
                }
                Button(role: .destructive) {
                    vm.deleteSession(session.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .onDelete { offsets in
            for idx in offsets { vm.deleteSession(list[idx].id) }
        }
    }

    private func sectionHeader(icon: String?, title: String) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            }
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 6)
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

/// 判定用户是否在手动上翻阅读：iOS 18+ 用滚动阶段精确判定（手指按住即暂停跟随，松手后按是否贴底恢复）；
/// iOS 17 用下拉手势兜底，滑回底部时由底部锚点的 onAppear 恢复。
private struct BottomFollowTracker: ViewModifier {
    @Binding var follows: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase, context in
                switch phase {
                case .interacting:
                    follows = false
                case .idle:
                    let geometry = context.geometry
                    follows = geometry.visibleRect.maxY >= geometry.contentSize.height - 80
                default:
                    break
                }
            }
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { value in
                    if value.translation.height > 12 { follows = false }
                }
            )
        }
    }
}
