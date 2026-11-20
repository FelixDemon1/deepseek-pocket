import Network
import XCTest

// ---------------------------------------------------------------------------
// PhoneRunner：一个不会结束的 UI 测试，在手机本机回环地址上开一个小 HTTP 服务，
// 让 DeepSeek Pocket 里的 agent 能「看屏幕、点按、输入、开 App」。
//
// XCUITest 是 Apple 给自动化测试用的公开接口，只有由 Xcode / xcodebuild 启动的
// 测试进程才有这个权限，所以需要从 Mac 启动一次（见 PhoneRunner/README.md）。
// 服务只监听 127.0.0.1，测试进程一结束就没了。
// ---------------------------------------------------------------------------

final class PhoneRunnerUITests: XCTestCase {
    private var lastIssue: String?
    private var currentBundleID: String?
    private var lastFrames: [Int: CGRect] = [:]
    private var listener: NWListener?
    /// 上一次操作完已经切回调用方：系统上报的前台状态有延迟，不能只靠它判断
    private var awayFromTarget = false

    override func record(_ issue: XCTIssue) {
        // XCUITest 用「记录失败」报告点不到、输不进之类的问题；这里收下来回给调用方，不让测试中断
        lastIssue = issue.compactDescription
    }

    func testServe() throws {
        continueAfterFailure = true
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: 28467)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receive(on: connection, buffer: Data())
        }
        listener.start(queue: .main)
        self.listener = listener
        while true {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
        }
    }

    // MARK: HTTP

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                let body = self.route(path: request.path, body: request.body)
                let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(payload)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private static func parse(_ buffer: Data) -> (path: String, body: [String: Any])? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let length = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let bodyData = buffer[headerEnd.upperBound...]
        guard bodyData.count >= length else { return nil }
        let body = (try? JSONSerialization.jsonObject(with: bodyData.prefix(length)) as? [String: Any]) ?? [:]
        return (String(parts[1]), body)
    }

    private func route(path: String, body: [String: Any]) -> [String: Any] {
        switch path {
        case "/status":
            return ["ok": true, "version": 1]
        case "/look":
            if let app = body["app"] as? String, !app.isEmpty { launch(app) } else { bringTargetToFront() }
            Thread.sleep(forTimeInterval: 0.5)
            let result = look()
            returnToCaller(body)
            return result
        case "/do":
            bringTargetToFront()
            let result = perform(body)
            returnToCaller(body)
            return result
        default:
            return ["error": "unknown path \(path)"]
        }
    }

    // MARK: 看

    private static let springboard = "com.apple.springboard"

    private func foregroundBundleID() -> String {
        if let currentBundleID, XCUIApplication(bundleIdentifier: currentBundleID).state == .runningForeground {
            return currentBundleID
        }
        return Self.springboard
    }

    private func foregroundApp() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: foregroundBundleID())
    }

    /// 调用方（DeepSeek Pocket）每次操作完都会回到前台，所以动手之前先把目标 App 切回来；
    /// 还没有目标时回到主屏幕。
    private func bringTargetToFront() {
        if let currentBundleID {
            let app = XCUIApplication(bundleIdentifier: currentBundleID)
            if awayFromTarget || app.state != .runningForeground {
                awayFromTarget = false
                app.activate()
                _ = app.wait(for: .runningForeground, timeout: 5)
                // 切换动画没结束时点按会落空
                Thread.sleep(forTimeInterval: 0.8)
            }
        } else {
            XCUIDevice.shared.press(.home)
        }
    }

    private func returnToCaller(_ body: [String: Any]) {
        if let returnTo = body["returnTo"] as? String, !returnTo.isEmpty {
            let caller = XCUIApplication(bundleIdentifier: returnTo)
            caller.activate()
            _ = caller.wait(for: .runningForeground, timeout: 5)
            awayFromTarget = true
        }
    }

    private func launch(_ bundleID: String) {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 5)
        currentBundleID = bundleID
        awayFromTarget = false
    }

    private static func name(_ type: XCUIElement.ElementType) -> String? {
        switch type {
        case .button: return "按钮"
        case .cell: return "行"
        case .staticText: return "文字"
        case .textField, .secureTextField, .searchField, .textView: return "输入框"
        case .switch, .toggle: return "开关"
        case .link: return "链接"
        case .image: return "图片"
        case .icon: return "图标"
        case .tab: return "标签"
        case .slider: return "滑块"
        case .menuItem: return "菜单项"
        case .navigationBar: return "导航栏"
        case .alert: return "弹窗"
        case .other: return "区域"
        default: return nil
        }
    }

    private func look() -> [String: Any] {
        let bundleID = foregroundBundleID()
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let screen = XCUIApplication(bundleIdentifier: Self.springboard).frame
        lastFrames = [:]
        guard let root = try? app.snapshot() else {
            return ["error": "读不到屏幕内容（App 可能正在切换，稍后重试）"]
        }
        var elements: [[String: Any]] = []
        var keyboardVisible = false

        func visit(_ node: XCUIElementSnapshot, inherited: String) {
            if node.elementType == .keyboard {
                keyboardVisible = true
                return
            }
            let label = [node.label, node.title, node.placeholderValue ?? "", node.identifier]
                .first { !$0.isEmpty } ?? ""
            let value = (node.value as? String) ?? ""
            let frame = node.frame
            var passedDown = inherited
            if let typeName = Self.name(node.elementType), elements.count < 150,
               !(label.isEmpty && value.isEmpty), label != inherited || !value.isEmpty,
               !(node.elementType == .image && !inherited.isEmpty),
               !label.hasPrefix("chevron"), label != "PLACARD",
               frame.width > 1, frame.height > 1, screen.intersects(frame) {
                let number = elements.count + 1
                lastFrames[number] = frame
                var item: [String: Any] = [
                    "n": number, "type": typeName, "label": String(label.prefix(80)),
                    "x": Int(frame.midX), "y": Int(frame.midY)
                ]
                if !value.isEmpty, value != label { item["value"] = String(value.prefix(80)) }
                if !node.isEnabled { item["disabled"] = true }
                elements.append(item)
                passedDown = label
            }
            for child in node.children { visit(child, inherited: passedDown) }
        }
        visit(root, inherited: "")

        return [
            "app": bundleID,
            "screen": ["w": Int(screen.width), "h": Int(screen.height)],
            "keyboard": keyboardVisible,
            "elements": elements
        ]
    }

    // MARK: 做

    private func perform(_ body: [String: Any]) -> [String: Any] {
        var log: [String] = []
        for action in (body["actions"] as? [[String: Any]]) ?? [] {
            lastIssue = nil
            let type = (action["type"] as? String) ?? ""
            let app = foregroundApp()
            func point() -> CGPoint? {
                if let number = (action["element"] as? NSNumber)?.intValue {
                    return lastFrames[number].map { CGPoint(x: $0.midX, y: $0.midY) }
                }
                if let x = (action["x"] as? NSNumber)?.doubleValue, let y = (action["y"] as? NSNumber)?.doubleValue {
                    return CGPoint(x: x, y: y)
                }
                return nil
            }
            func coordinate(_ p: CGPoint) -> XCUICoordinate {
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y))
            }
            var failure: String?
            switch type {
            case "launch":
                if let bundleID = action["app"] as? String, !bundleID.isEmpty { launch(bundleID) } else { failure = "缺少 app" }
            case "tap":
                if let p = point() { coordinate(p).tap() } else { failure = "找不到要点的位置（元素编号只对最近一次屏幕有效）" }
            case "long_press":
                if let p = point() { coordinate(p).press(forDuration: 1.0) } else { failure = "找不到要长按的位置" }
            case "type":
                let text = (action["text"] as? String) ?? ""
                app.typeText(text + ((action["enter"] as? Bool) == true ? "\n" : ""))
            case "swipe":
                let frame = app.frame
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let distance = frame.height * 0.3
                let end: CGPoint
                switch (action["direction"] as? String) ?? "up" {
                case "down": end = CGPoint(x: center.x, y: center.y + distance)
                case "left": end = CGPoint(x: center.x - frame.width * 0.35, y: center.y)
                case "right": end = CGPoint(x: center.x + frame.width * 0.35, y: center.y)
                default: end = CGPoint(x: center.x, y: center.y - distance)
                }
                coordinate(center).press(forDuration: 0.05, thenDragTo: coordinate(end))
            case "back":
                let frame = app.frame
                coordinate(CGPoint(x: 1, y: frame.midY)).press(forDuration: 0.05, thenDragTo: coordinate(CGPoint(x: frame.width * 0.7, y: frame.midY)))
            case "home":
                XCUIDevice.shared.press(.home)
                currentBundleID = nil
            case "wait":
                Thread.sleep(forTimeInterval: min(max((action["seconds"] as? NSNumber)?.doubleValue ?? 1, 0), 5))
            default:
                failure = "不认识的动作 \(type)"
            }
            if let problem = failure ?? lastIssue {
                log.append("\(type)：失败（\(problem.prefix(160))），后面的动作没有执行")
                break
            }
            log.append("\(type)：已执行")
        }
        Thread.sleep(forTimeInterval: 0.7)
        var result = look()
        result["log"] = log
        return result
    }
}
