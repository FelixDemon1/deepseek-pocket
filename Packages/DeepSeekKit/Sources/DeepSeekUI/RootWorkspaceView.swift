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
                    onRequireSetup: { openSidePanel(.settings) }
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
        .preferredColorScheme(vm.appearance.colorScheme)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .modelPicker:
                geminiModelHalfSheet(scheme: scheme, ink: ink, secondary: secondary)
                    .presentationDetents([.height(370)])
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
        .onChange(of: activeSheet) { _ in endEditing() }
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
        .onChange(of: vm.requestedSheetName) { name in
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
                    openSidePanel(.settings)
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        avatarCircle(size: 34, scheme: scheme)

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
                    quietActionPill(scheme: scheme, title: "项目", icon: "folder") {
                        activeSheet = .workspace
                    }
                    quietActionPill(scheme: scheme, title: "模式", icon: "sparkles") {
                        activeSheet = .presets
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { endEditing() }
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
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { endEditing() })
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
                    openSidePanel(.settings)
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

    // MARK: - Google Gemini Mobile Navigation Drawer (slides in from the leading edge)

    private func sessionsPanel(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 用户资料 + 新建对话 + 快捷入口
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        avatarCircle(size: 38, scheme: scheme)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vm.displayName.isEmpty ? "未设置昵称" : vm.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ink)
                            Text("\(vm.activePreset.title) · \(vm.projectName(for: vm.activeSession?.projectId))")
                                .font(.caption2)
                                .foregroundStyle(secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }

                    Button {
                        vm.createNewSession()
                        closeSidePanel()
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

                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                List {
                    Section {
                        sessionRows(vm.sessions(in: nil))
                    } header: {
                        sectionHeader(icon: "bubble.left", title: "对话")
                    }

                    ForEach(vm.projects) { project in
                        Section {
                            let list = vm.sessions(in: project.id)
                            if list.isEmpty {
                                Text("还没有对话")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            sessionRows(list)
                            Button {
                                vm.createNewSession(in: project.id)
                                closeSidePanel()
                            } label: {
                                Label("在此项目中新建对话", systemImage: "plus")
                                    .font(.footnote)
                            }
                        } header: {
                            sectionHeader(icon: "folder.fill", title: project.name)
                        }
                    }

                    Section {
                        Button {
                            dismissPanelImmediately()
                            activeSheet = .workspace
                        } label: {
                            Label("管理项目…", systemImage: "folder.badge.gearshape")
                        }
                    }
                }
                .searchable(text: $vm.sessionSearchQuery, prompt: "搜索对话")
            }
            .navigationTitle("DeepSeek Pocket")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
    private func sessionRows(_ list: [ChatSession]) -> some View {
        ForEach(list) { session in
            Button {
                vm.activateSession(session.id)
                closeSidePanel()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: session.projectId == nil ? "bubble.left" : "doc.text")
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
            for idx in offsets { vm.deleteSession(list[idx].id) }
        }
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(title)
            Spacer()
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
