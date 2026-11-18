import Foundation

public struct DeviceEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int
}

/// Browses paths outside this app's sandbox by holding `worse_query` sandbox
/// extensions open. Every directory level needs its own extension, so `open()`
/// lifts one path and caches the handle.
@available(iOS 17.0, *)
public final class DeviceFilesystem: @unchecked Sendable {
    public static let shared = DeviceFilesystem()

    /// Paths this process can currently read.
    public static let defaultRoots: [String] = [
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Data/PluginKitPlugin",
        "/var/mobile/Containers/Data/InternalDaemon",
        "/var/mobile/Containers/Shared/AppGroup",
        "/var/containers/Data/System",
        "/var/containers/Shared/SystemGroup"
    ]

    private let lock = NSLock()
    private var handles: [String: Int64] = [:]

    public init() {}

    public var appGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SandboxLift.appGroupID) != nil
    }

    /// Lifts `path` (idempotent). Returns nil on success, or a reason on failure.
    @discardableResult
    public func unlock(_ path: String) -> String? {
        lock.lock()
        let already = handles[path]
        lock.unlock()
        if already != nil { return nil }

        let report = SandboxLift.shared.lift(path)
        if report.ok {
            lock.lock(); handles[path] = report.handle; lock.unlock()
            return nil
        }
        switch report.code {
        case -1: return "没有 App Group 容器（签名缺 com.apple.security.application-groups）"
        case -2: return "containermanagerd 接口不可用（系统版本不支持）"
        case -5: return "容器管理器拒绝了查询"
        case -6: return "内核没有签发 sandbox extension"
        default: return report.note.isEmpty ? "失败 code \(report.code)" : report.note
        }
    }

    public func isUnlocked(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return handles[path] != nil
    }

    public func children(of path: String) -> [DeviceEntry] {
        if let reason = unlock(path) {
            _ = reason
            return []
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.compactMap { name -> DeviceEntry? in
            let full = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { return nil }
            let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int) ?? 0
            return DeviceEntry(id: full, name: name, path: full, isDirectory: isDir.boolValue, size: size ?? 0)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
    }

    /// Bundle id of another app's container, read from its MCM metadata plist.
    /// Only works after that container has been unlocked.
    public func ownerBundleID(ofContainer path: String) -> String? {
        let metadata = (path as NSString).appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        guard let data = FileManager.default.contents(atPath: metadata),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }

    public func readText(at path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        _ = unlock(parent)
        guard let data = FileManager.default.contents(atPath: path), data.count < 2_000_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func writeText(_ text: String, to path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        _ = unlock(parent)
        return (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    public func lockAll() {
        lock.lock()
        let all = handles
        handles.removeAll()
        lock.unlock()
        for (_, h) in all { SandboxLift.shared.release(h) }
    }
}
