import Foundation
#if canImport(EventKit)
import EventKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// ---------------------------------------------------------------------------
// 手机动作：让 agent 不只是改工作区里的文件，还能替用户在手机上办事。
//
// 全部走系统公开接口（EventKit / UIPasteboard / openURL），不读屏、不模拟点按。
// 每一个动作都会离开沙盒影响到用户的真实数据，所以任何审批策略下都要用户逐次确认。
// ---------------------------------------------------------------------------

public enum DeviceTools {
    public static let names: Set<String> = [
        "create_reminder", "create_calendar_event", "get_clipboard", "set_clipboard", "open_url"
    ]

    public enum Failure: LocalizedError, Equatable {
        case invalid(String)
        case denied(String)
        case unsupported

        public var errorDescription: String? {
            switch self {
            case let .invalid(reason): return "参数无效：\(reason)"
            case let .denied(what): return "没有\(what)权限。请到「设置 › 隐私与安全性」里给 DeepSeek Pocket 打开后再试。"
            case .unsupported: return "当前设备不支持这个动作"
            }
        }
    }

    private static let dateHint = "本地时间，格式 2026-11-21 09:00"

    public static var schemas: [[String: Any]] {
        func schema(_ name: String, _ description: String, _ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
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
                "create_reminder",
                "在系统「提醒事项」里新建一条提醒（需用户确认）。",
                [
                    "title": ["type": "string", "description": "提醒标题"],
                    "due": ["type": "string", "description": "到期时间，\(dateHint)；不填则不设时间"],
                    "notes": ["type": "string", "description": "备注"]
                ],
                required: ["title"]
            ),
            schema(
                "create_calendar_event",
                "在系统「日历」里新建一个日程（需用户确认）。",
                [
                    "title": ["type": "string", "description": "日程标题"],
                    "start": ["type": "string", "description": "开始时间，\(dateHint)"],
                    "end": ["type": "string", "description": "结束时间，\(dateHint)；不填默认一小时"],
                    "location": ["type": "string", "description": "地点"],
                    "notes": ["type": "string", "description": "备注"]
                ],
                required: ["title", "start"]
            ),
            schema("get_clipboard", "读取手机剪贴板里的文本（需用户确认）。", [:], required: []),
            schema(
                "set_clipboard",
                "把一段文本放进手机剪贴板，方便用户粘贴到别的 App（需用户确认）。",
                ["text": ["type": "string", "description": "要复制的文本"]],
                required: ["text"]
            ),
            schema(
                "open_url",
                "打开一个链接或跳转到别的 App（需用户确认），支持 https、tel:、mailto:、sms:、maps: 以及各 App 的 URL Scheme。",
                ["url": ["type": "string", "description": "完整链接，例如 https://maps.apple.com/?q=咖啡 或 tel:10086"]],
                required: ["url"]
            )
        ]
    }

    /// 审批卡上的一句话：让用户一眼看清 agent 要替他做什么。
    public static func approvalSummary(name: String, args: [String: Any]) -> String {
        func text(_ key: String) -> String { (args[key] as? String) ?? "" }
        switch name {
        case "create_reminder":
            return "新建提醒事项「\(text("title"))」" + (text("due").isEmpty ? "" : " · \(text("due"))")
        case "create_calendar_event":
            let range = [text("start"), text("end")].filter { !$0.isEmpty }.joined(separator: " – ")
            return "新建日历日程「\(text("title"))」 · \(range)" + (text("location").isEmpty ? "" : " · \(text("location"))")
        case "get_clipboard":
            return "读取剪贴板里的内容并发给模型"
        case "set_clipboard":
            return "写入剪贴板：\(text("text").prefix(60))"
        case "open_url":
            return "打开 \(text("url").prefix(120))（会离开本 App）"
        default:
            return "执行手机动作 \(name)"
        }
    }

    /// 模型给的时间写法不固定，这里把常见几种都认下来，一律按本机时区理解。
    public static func parseDate(_ raw: String, calendar: Calendar = .current) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy/MM/dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        formatter.dateFormat = "yyyy-MM-dd"
        // 只给了日期：按当天上午 9 点
        return formatter.date(from: text).flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
    }

    public static func execute(name: String, args: [String: Any]) async throws -> String {
        func text(_ key: String) -> String {
            ((args[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch name {
        case "create_reminder":
            guard !text("title").isEmpty else { throw Failure.invalid("缺少 title") }
            var due: Date?
            if !text("due").isEmpty {
                guard let parsed = parseDate(text("due")) else { throw Failure.invalid("看不懂时间 \(text("due"))，请用 \(dateHint)") }
                due = parsed
            }
            return try await createReminder(title: text("title"), due: due, notes: text("notes"))

        case "create_calendar_event":
            guard !text("title").isEmpty else { throw Failure.invalid("缺少 title") }
            guard let start = parseDate(text("start")) else { throw Failure.invalid("看不懂开始时间 \(text("start"))，请用 \(dateHint)") }
            let end = parseDate(text("end")) ?? start.addingTimeInterval(3600)
            guard end > start else { throw Failure.invalid("结束时间必须晚于开始时间") }
            return try await createEvent(title: text("title"), start: start, end: end, location: text("location"), notes: text("notes"))

        case "get_clipboard":
            #if canImport(UIKit)
            let content = await MainActor.run { UIPasteboard.general.string } ?? ""
            return content.isEmpty ? "剪贴板里没有文本" : String(content.prefix(6000))
            #else
            throw Failure.unsupported
            #endif

        case "set_clipboard":
            guard !text("text").isEmpty else { throw Failure.invalid("缺少 text") }
            #if canImport(UIKit)
            let value = text("text")
            await MainActor.run { UIPasteboard.general.string = value }
            return "已复制到剪贴板（\(value.count) 字）"
            #else
            throw Failure.unsupported
            #endif

        case "open_url":
            guard let url = URL(string: text("url")), let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
                  scheme != "file", scheme != "javascript" else {
                throw Failure.invalid("链接不合法：\(text("url"))")
            }
            #if canImport(UIKit) && os(iOS)
            guard await openOnMain(url) else {
                throw Failure.invalid("系统打不开这个链接（可能没装对应的 App）：\(url.absoluteString)")
            }
            return "已打开 \(url.absoluteString)"
            #else
            throw Failure.unsupported
            #endif

        default:
            throw Failure.unsupported
        }
    }

    #if canImport(UIKit) && os(iOS)
    @MainActor
    private static func openOnMain(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
    #endif

    private static func describe(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 EEEE HH:mm"
        return formatter.string(from: date)
    }

    private static func createReminder(title: String, due: Date?, notes: String) async throws -> String {
        #if canImport(EventKit)
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else { throw Failure.denied("提醒事项") }
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.invalid("手机上没有可用的提醒事项列表") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if !notes.isEmpty { reminder.notes = notes }
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return "已在「\(list.title)」新建提醒：\(title)" + (due.map { "，\(describe($0)) 提醒" } ?? "")
        #else
        throw Failure.unsupported
        #endif
    }

    private static func createEvent(title: String, start: Date, end: Date, location: String, notes: String) async throws -> String {
        #if canImport(EventKit)
        let store = EKEventStore()
        guard (try? await store.requestWriteOnlyAccessToEvents()) == true else { throw Failure.denied("日历") }
        guard let calendar = store.defaultCalendarForNewEvents else { throw Failure.invalid("手机上没有可写入的日历") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        if !location.isEmpty { event.location = location }
        if !notes.isEmpty { event.notes = notes }
        try store.save(event, span: .thisEvent, commit: true)
        return "已添加日程：\(title)，\(describe(start)) 开始"
        #else
        throw Failure.unsupported
        #endif
    }
}
