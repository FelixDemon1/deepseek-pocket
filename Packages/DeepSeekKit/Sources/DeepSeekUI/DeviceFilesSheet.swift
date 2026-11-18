import SwiftUI
import DeepSeekCore

/// 设备文件 — browses other apps' containers through `worse_query` sandbox
/// extensions. Honest about the precondition: an App Group container has to be
/// in the provisioning profile, otherwise the container manager has nothing to
/// query and the screen says so instead of showing an empty list.
@available(iOS 17.0, *)
public struct DeviceFilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: String = ""
    @State private var entries: [DeviceEntry] = []
    @State private var errorText: String?
    @State private var opened: String?
    @State private var draft: String = ""
    @State private var showingEditor = false

    private let fs = DeviceFilesystem.shared

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    if fs.appGroupAvailable {
                        Label("已具备 App Group 容器，可以尝试越权", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(DeepSeekTheme.diffAdded)
                            .font(.footnote)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("签名里没有 App Group 容器", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.footnote.weight(.semibold))
                            Text("worse_query 要求应用先拥有一个 App Group 容器（containermanagerd 只为这个 class 签发 token）。免费个人团队签不出 App Group，需要用付费团队或企业证书重签，并在 entitlements 里声明 group.io.deepseekgo.felix。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("能力自检")
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("系统容器") {
                    ForEach(DeviceFilesystem.defaultRoots, id: \.self) { root in
                        Button {
                            open(root)
                        } label: {
                            HStack {
                                Image(systemName: fs.isUnlocked(root) ? "lock.open" : "lock")
                                    .font(.system(size: 12))
                                    .foregroundStyle(fs.isUnlocked(root) ? DeepSeekTheme.brandBlue : .secondary)
                                Text(root)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                        }
                    }
                }

                if !path.isEmpty {
                    Section(path) {
                        if entries.isEmpty {
                            Text("空目录或没有权限").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(entries) { entry in
                            Button {
                                if entry.isDirectory {
                                    open(entry.path)
                                } else {
                                    draft = fs.readText(at: entry.path) ?? "（无法以文本读取）"
                                    opened = entry.path
                                    showingEditor = true
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                                        .font(.system(size: 12))
                                        .foregroundStyle(entry.isDirectory ? DeepSeekTheme.brandBlue : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.name)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        if entry.isDirectory, let bundle = fs.ownerBundleID(ofContainer: entry.path) {
                                            Text(bundle).font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if !entry.isDirectory {
                                        Text("\(entry.size) B").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("设备文件")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !path.isEmpty {
                        Button {
                            open((path as NSString).deletingLastPathComponent)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showingEditor) {
                NavigationStack {
                    TextEditor(text: $draft)
                        .font(.system(size: 12, design: .monospaced))
                        .navigationTitle((opened as NSString?)?.lastPathComponent ?? "文件")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("保存") {
                                    if let opened { _ = fs.writeText(draft, to: opened) }
                                    showingEditor = false
                                }
                            }
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showingEditor = false }
                            }
                        }
                }
            }
        }
    }

    private func open(_ target: String) {
        errorText = fs.unlock(target)
        path = target
        entries = fs.children(of: target)
    }
}
