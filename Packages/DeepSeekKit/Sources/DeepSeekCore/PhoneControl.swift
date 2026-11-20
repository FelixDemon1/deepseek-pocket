import Foundation
#if canImport(UIKit)
import UIKit
#endif

// ---------------------------------------------------------------------------
// 手机操控：通过 PhoneRunner（见仓库 PhoneRunner/README.md）看屏幕、点按、输入。
//
// 每次操作的流程：切到目标 App → 执行动作 → 读取屏幕 → 回到本 App。
// 这样模型思考、用户确认都发生在本 App 里，不需要后台保活。
// ---------------------------------------------------------------------------

public enum PhoneControl {
    public static let toolNames: Set<String> = ["phone_look", "phone_do"]
    public static let endpoint = URL(string: "http://127.0.0.1:28467")!

    public static var schemas: [[String: Any]] {
        func schema(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": ["type": "object", "properties": properties, "required": required]
                ]
            ]
        }
        return [
            schema(
                "phone_look",
                "看手机上某个 App 当前的屏幕，返回带编号的界面元素（按钮、文字、输入框等）。给 app 就先打开那个 App（bundle id，例如 com.apple.Preferences 设置、com.apple.reminders 提醒事项、com.apple.mobilesafari Safari、com.apple.Maps 地图、com.apple.mobilenotes 备忘录）；不给则看上一次操作的 App。",
                ["app": ["type": "string", "description": "要打开的 App 的 bundle id"]],
                required: []
            ),
            schema(
                "phone_do",
                "在手机上依次执行一组动作，然后返回新的屏幕元素。元素编号来自最近一次 phone_look / phone_do 的结果，屏幕变化后要用新编号。每次操作完会自动回到本 App，目标 App 留在后台保持原状。付款、删除、发送消息这类不可撤销的动作，先停下来问用户。",
                [
                    "actions": [
                        "type": "array",
                        "description": "动作列表。每项的 type 取值：launch（app）、tap（element 或 x,y）、long_press（element 或 x,y）、type（text，enter=true 表示输完回车；要先点中输入框）、swipe（direction: up/down/left/right，up 表示手指上滑看下面的内容）、back（返回上一页）、home、wait（seconds）",
                        "items": ["type": "object"]
                    ]
                ],
                required: ["actions"]
            )
        ]
    }

    public static func approvalSummary(name: String, args: [String: Any]) -> String {
        if name == "phone_look" {
            let app = (args["app"] as? String) ?? ""
            return app.isEmpty ? "查看手机当前屏幕，并把屏幕上的文字发给模型" : "打开 \(app) 并把屏幕上的文字发给模型"
        }
        let actions = (args["actions"] as? [[String: Any]]) ?? []
        let steps = actions.prefix(6).map { action -> String in
            switch (action["type"] as? String) ?? "" {
            case "launch": return "打开 \((action["app"] as? String) ?? "")"
            case "tap": return (action["element"] as? NSNumber).map { "点按 [\($0)]" } ?? "点按屏幕"
            case "long_press": return "长按"
            case "type": return "输入「\(((action["text"] as? String) ?? "").prefix(24))」"
            case "swipe": return "滑动"
            case "back": return "返回"
            case "home": return "回主屏幕"
            case "wait": return "等待"
            case let other: return other
            }
        }
        return "操作手机：" + steps.joined(separator: " → ") + (actions.count > 6 ? " …" : "")
    }

    public static func isRunnerAlive() async -> Bool {
        var request = URLRequest(url: endpoint.appendingPathComponent("status"))
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["ok"] as? Bool == true
    }

    public static func execute(name: String, args: [String: Any]) async throws -> String {
        var body: [String: Any] = ["returnTo": Bundle.main.bundleIdentifier ?? ""]
        let path: String
        if name == "phone_look" {
            path = "look"
            body["app"] = (args["app"] as? String) ?? ""
        } else {
            guard let actions = args["actions"] as? [[String: Any]], !actions.isEmpty else {
                throw WorkspaceSandboxError.invalidArguments("actions 不能为空")
            }
            path = "do"
            body["actions"] = actions
        }
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 操作期间本 App 会被切到后台几秒，申请后台时间把这次请求等完
        #if canImport(UIKit) && os(iOS)
        let background = await UIApplication.shared.beginBackgroundTask(withName: "phone-control")
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(background) } }
        #endif

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw WorkspaceSandboxError.targetNotFound(
                "手机操控驱动没有在运行。需要在电脑上启动 PhoneRunner（见 PhoneRunner/README.md）后再试。"
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkspaceSandboxError.targetNotFound("手机操控驱动返回了看不懂的内容")
        }
        if let error = object["error"] as? String {
            throw WorkspaceSandboxError.targetNotFound(error)
        }
        return render(object)
    }

    /// 把驱动返回的屏幕内容排成模型好读的文本。
    static func render(_ object: [String: Any]) -> String {
        var lines: [String] = []
        for entry in (object["log"] as? [String]) ?? [] { lines.append("· \(entry)") }
        let screen = object["screen"] as? [String: Any]
        var header = "前台 App：\((object["app"] as? String) ?? "未知")"
        if let w = screen?["w"], let h = screen?["h"] { header += "（屏幕 \(w)×\(h) 点）" }
        if object["keyboard"] as? Bool == true { header += "，键盘已弹出" }
        lines.append(header)
        let elements = (object["elements"] as? [[String: Any]]) ?? []
        if elements.isEmpty { lines.append("（屏幕上没有读到可识别的元素）") }
        for element in elements {
            var line = "[\(element["n"] ?? "?")] \((element["type"] as? String) ?? "") \((element["label"] as? String) ?? "")"
            if let value = element["value"] as? String { line += " = \(value)" }
            if element["disabled"] as? Bool == true { line += "（不可用）" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
