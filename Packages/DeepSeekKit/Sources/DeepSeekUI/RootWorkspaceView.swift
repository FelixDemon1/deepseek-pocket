import SwiftUI
import DeepSeekCore

/// Linear / Apple Notes Minimalist Workspace Shell.
/// Zero slogans, zero secondary labels, single-enum modal routing.
public struct RootWorkspaceView: View {
    public enum ActiveSheet: String, Identifiable {
        case sessions, workspace, presets, settings, audit, share, scanner
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
                header(ink: ink, secondary: secondary)

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
                    onOpenScanner: { activeSheet = .scanner },
                    onRequireSetup: { activeSheet = .settings }
                )
            }
        }
        .preferredColorScheme(vm.appearance.colorScheme)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .sessions:
                sessionsSheet
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
            case .scanner:
                #if os(iOS)
                QRScannerSheet { code in
                    if let url = URL(string: code) {
                        vm.handleSetupURL(url)
                    }
                }
                #else
                EmptyView()
                #endif
            }
        }
        .sheet(item: $vm.activeArtifact) { artifact in
            ArtifactSandboxSheet(artifact: artifact)
        }
    }

    // MARK: - Header (Apple Notes / Linear Purity: Single-Line, Zero Subtitles)

    private func header(ink: Color, secondary: Color) -> some View {
        HStack(spacing: 12) {
            Button {
                activeSheet = .sessions
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(ink)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
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
                        if vm.providerConfig.model == preset.model && vm.providerConfig.baseURL.absoluteString == preset.base {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
                Divider()
                Button {
                    activeSheet = .settings
                } label: {
                    Label("设置", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(vm.shortModelTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            Spacer()

            if vm.showCompanionPet && !(vm.activeSession?.messages.filter { $0.role != .system }.isEmpty ?? true) {
                PixelCompanionView(mood: vm.companionMood, scale: 1.35)
            }

            Button {
                vm.createNewSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(ink)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Body (Pure Canvas, Zero Slogans)

    @ViewBuilder
    private func chatBody(scheme: ColorScheme, ink: Color, secondary: Color) -> some View {
        let visibleMessages = (vm.activeSession?.messages ?? []).filter { $0.role != .system }
        if visibleMessages.isEmpty {
            VStack(spacing: 24) {
                Spacer()

                if vm.showCompanionPet {
                    PixelCompanionView(mood: vm.companionMood, scale: 3.6)
                }

                HStack(spacing: 8) {
                    quietActionPill(scheme: scheme, title: "演示", icon: "play") {
                        vm.runInteractiveShowcase()
                    }
                    quietActionPill(scheme: scheme, title: "工作区", icon: "folder") {
                        activeSheet = .workspace
                    }
                    #if os(iOS)
                    quietActionPill(scheme: scheme, title: "扫码", icon: "qrcode") {
                        activeSheet = .scanner
                    }
                    #endif
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

    // MARK: - Apple-Notes-Style Clean Sidebar

    private var sessionsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        activeSheet = .workspace
                    } label: {
                        Label("工作区", systemImage: "folder")
                    }
                    Button {
                        activeSheet = .presets
                    } label: {
                        HStack {
                            Label("规则", systemImage: "slider.horizontal.3")
                            Spacer()
                            Text(vm.activePreset.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        activeSheet = .settings
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }

                Section {
                    ForEach(vm.filteredSessions) { session in
                        Button {
                            vm.activeSessionId = session.id
                            activeSheet = nil
                        } label: {
                            HStack {
                                Text(session.title)
                                    .font(.subheadline.weight(session.id == vm.activeSessionId ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                if session.id == vm.activeSessionId {
                                    Circle()
                                        .fill(DeepSeekTheme.brandBlue)
                                        .frame(width: 6, height: 6)
                                }
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
            .searchable(text: $vm.sessionSearchQuery, prompt: "搜索")
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
}
