import SwiftUI
import WebKit
import DeepSeekCore

#if os(iOS)

/// 在我们自己的 WKWebView 里登录官方网页版，登录完自动或手动读自己的 localStorage / cookie。
/// 这里没有 MITM、没有 hook 别人的进程：读的是本 App 自己这个 webview 的数据。
public struct WebAdapterLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let spec: WebAdapterSpec
    public let clearExistingOnAppear: Bool
    public var onCredential: (String, String?) -> Void

    @State private var status: String = "在下方登录官网账号，登录成功后会自动接入（也可点右上角手动读取）"
    @State private var isReading = false
    @State private var didFinish = false
    @State private var initialTokenSnapshot: String?
    @State private var store = WKWebsiteDataStore.default()

    public init(
        spec: WebAdapterSpec,
        clearExistingOnAppear: Bool = false,
        onCredential: @escaping (String, String?) -> Void
    ) {
        self.spec = spec
        self.clearExistingOnAppear = clearExistingOnAppear
        self.onCredential = onCredential
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)

                WebView(
                    urlString: spec.loginURL,
                    dataStore: store,
                    clearKeyOnStart: clearExistingOnAppear ? spec.credentialKey : nil
                )
                .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(spec.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isReading ? "读取中…" : "读取登录状态") {
                        Task { await harvest(manual: true) }
                    }
                    .disabled(isReading)
                }
            }
            .task {
                // 全局桥接快照可能还残留着上一次打开的别的站点，先清空再读，避免误判「已登录」
                WebBridgeRegistry.shared.snapshot = [:]
                WebBridgeRegistry.shared.currentURL = ""
                if clearExistingOnAppear {
                    await Self.clearCookies(store: store, host: spec.loginURL)
                } else {
                    let ls = await Self.readLocalStorage(store: store)
                    let ck = await Self.readCookies(store: store, host: spec.loginURL)
                    initialTokenSnapshot = WebCredentialParser.extract(spec: spec, localStorage: ls, cookies: ck)
                }

                // 自动轮询：一旦用户在网页里完成登录跳离登录页并写入凭据，自动接入无需再手动找按钮
                while !Task.isCancelled && !didFinish {
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard !Task.isCancelled && !didFinish else { break }
                    let currentPath = WebBridgeRegistry.shared.currentURL.lowercased()
                    let onSignInPage = currentPath.contains("sign_in") || currentPath.contains("/login")
                    let ls = await Self.readLocalStorage(store: store)
                    let ck = await Self.readCookies(store: store, host: spec.loginURL)
                    if let token = WebCredentialParser.extract(spec: spec, localStorage: ls, cookies: ck) {
                        let isNewToken = (initialTokenSnapshot == nil) || (token != initialTokenSnapshot)
                        if !onSignInPage && (isNewToken || !clearExistingOnAppear) {
                            didFinish = true
                            let cookieHdr = WebCredentialParser.cookieHeader(from: ck)
                            status = "已自动读取登录态，正在验证…"
                            onCredential(token, cookieHdr)
                            dismiss()
                            break
                        }
                    }
                }
            }
        }
    }

    private func harvest(manual: Bool) async {
        guard !didFinish else { return }
        isReading = true
        defer { isReading = false }
        status = "正在读取…"

        let localStorage = await Self.readLocalStorage(store: store)
        let cookies = await Self.readCookies(store: store, host: spec.loginURL)

        if let token = WebCredentialParser.extract(spec: spec, localStorage: localStorage, cookies: cookies) {
            didFinish = true
            let cookieHdr = WebCredentialParser.cookieHeader(from: cookies)
            status = "读到了，长度 \(token.count)"
            onCredential(token, cookieHdr)
            dismiss()
        } else if manual {
            let hint = spec.credentialKind == .localStorage
                ? "没找到登录凭据（\(spec.credentialKey)），请先在下方网页完成登录"
                : "没找到登录 Cookie（\(spec.credentialKey)），请先在下方网页完成登录"
            status = hint
        }
    }

    @MainActor
    private static func readLocalStorage(store: WKWebsiteDataStore) async -> [String: String] {
        WebBridgeRegistry.shared.snapshot
    }

    private static func clearCookies(store: WKWebsiteDataStore, host: String) async {
        let hostName = URL(string: host)?.host ?? host
        let cookies = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { all in
                continuation.resume(returning: all)
            }
        }
        for cookie in cookies {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if hostName.hasSuffix(domain) || domain.hasSuffix(hostName) {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    store.httpCookieStore.delete(cookie) { cont.resume() }
                }
            }
        }
    }

    private static func readCookies(store: WKWebsiteDataStore, host: String) async -> [String: String] {
        let hostName = URL(string: host)?.host ?? host
        let cookies = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { all in
                continuation.resume(returning: all)
            }
        }
        var out: [String: String] = [:]
        for cookie in cookies {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if hostName.hasSuffix(domain) || domain.hasSuffix(hostName) {
                out[cookie.name] = cookie.value
            }
        }
        return out
    }
}

/// 保存当前 WKWebView 注入桥接出来的 localStorage 快照与当前 URL。
@MainActor
final class WebBridgeRegistry {
    static let shared = WebBridgeRegistry()
    var snapshot: [String: String] = [:]
    var currentURL: String = ""
}

struct WebView: UIViewRepresentable {
    let urlString: String
    let dataStore: WKWebsiteDataStore
    var clearKeyOnStart: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let controller = WKUserContentController()
        if let clearKey = clearKeyOnStart {
            let clearScript = "try { localStorage.removeItem(\"\(clearKey)\"); } catch (e) {}"
            controller.addUserScript(WKUserScript(source: clearScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let script = """
        (function() {
          function dump() {
            var out = { "__url__": String(location.href || "") };
            try { for (var i = 0; i < localStorage.length; i++) { var k = localStorage.key(i); out[k] = localStorage.getItem(k); } } catch (e) {}
            window.webkit.messageHandlers.dshBridge.postMessage(out);
          }
          dump();
          setInterval(dump, 1200);
        })();
        """
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(context.coordinator, name: "dshBridge")
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            var out: [String: String] = [:]
            var urlText = ""
            for (key, value) in dict {
                if key == "__url__", let u = value as? String {
                    urlText = u
                } else if let text = value as? String {
                    out[key] = text
                }
            }
            WebBridgeRegistry.shared.currentURL = urlText
            WebBridgeRegistry.shared.snapshot = out
        }
    }
}

// MARK: - 隐藏同源 WKWebView 真实环境流式执行器（专治字节 shark_admin/a_bogus 与阿里 AWSC 签名）

public final class WebKitBrowserStreamPerformer: NSObject, BrowserStreamPerformer, @unchecked Sendable {
    public static let shared = WebKitBrowserStreamPerformer()

    /// 触发发送后多久没有任何回包行就判定卡死（未登录 / 人机验证 / 页面改版）。
    static let firstLineTimeout: Duration = .seconds(45)
    /// 已经开始出字后，两行之间允许的最长静默（长思考也会持续吐帧）。
    static let idleTimeout: Duration = .seconds(90)
    /// 冷启动加载页面的上限；超时也继续往下走，由首包看门狗兜底。
    static let pageLoadTimeout: Duration = .seconds(25)

    @MainActor private var webViews: [String: WKWebView] = [:]
    @MainActor private var loadReady: [String: Bool] = [:]
    @MainActor private var streamContinuations: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]
    @MainActor private var streamSpecIDs: [String: String] = [:]
    @MainActor private var lastActivity: [String: ContinuousClock.Instant] = [:]
    @MainActor private var sawFirstLine: Set<String> = []
    /// 已经收到上游结束标记（豆包 2003 / [DONE] / event: close）的流：调用方随后主动断开不算「用户停止」
    @MainActor private var endedNaturally: Set<String> = []
    /// 同一渠道共用一个隐藏页面、一个 `window.__dshActiveSid`，必须串行，否则后发的会把先发的流「挤丢」。
    @MainActor private var busySpecs: Set<String> = []
    @MainActor private var specWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private override init() {
        super.init()
    }

    public func streamRawLines(
        spec: WebAdapterSpec,
        request: URLRequest,
        prompt: String,
        thinkingEnabled: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let sid = UUID().uuidString.lowercased()
            let task = Task { @MainActor in
                await self.acquire(spec.id)
                self.streamContinuations[sid] = continuation
                self.streamSpecIDs[sid] = spec.id
                do {
                    try Task.checkCancellation()
                    let wv = try await self.ensureWebViewReady(for: spec)
                    self.lastActivity[sid] = .now
                    // 驱动脚本要跑几秒；期间点停止也要立刻让页面放弃本轮（含兜底直发）
                    try await withTaskCancellationHandler {
                        try await self.triggerStream(
                            in: wv,
                            sid: sid,
                            spec: spec,
                            request: request,
                            prompt: prompt,
                            thinkingEnabled: thinkingEnabled
                        )
                    } onCancel: {
                        Task { @MainActor in self.abortPageStream(sid: sid, specID: spec.id) }
                    }
                    try await self.watch(sid: sid, specID: spec.id)
                } catch {
                    if error is CancellationError, !self.endedNaturally.contains(sid) {
                        self.abortPageStream(sid: sid, specID: spec.id)
                    }
                    self.finish(sid: sid, error: error)
                }
                self.forget(sid: sid)
                self.release(spec.id)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: 串行闸

    @MainActor
    private func acquire(_ specID: String) async {
        guard busySpecs.contains(specID) else {
            busySpecs.insert(specID)
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            specWaiters[specID, default: []].append(cont)
        }
    }

    @MainActor
    private func release(_ specID: String) {
        if var waiters = specWaiters[specID], !waiters.isEmpty {
            let next = waiters.removeFirst()
            specWaiters[specID] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            busySpecs.remove(specID)
        }
    }

    // MARK: 看门狗

    @MainActor
    private func watch(sid: String, specID: String) async throws {
        while streamContinuations[sid] != nil {
            try await Task.sleep(for: .milliseconds(500))
            guard let last = lastActivity[sid] else { continue }
            let limit = sawFirstLine.contains(sid) ? Self.idleTimeout : Self.firstLineTimeout
            if ContinuousClock.now - last > limit {
                let seconds = Int(limit.components.seconds)
                abortPageStream(sid: sid, specID: specID)
                evictWebView(specID: specID)
                finish(sid: sid, error: WebAdapterError.upstream(
                    sawFirstLine.contains(sid)
                        ? "网页通道连续 \(seconds) 秒没有新内容，已自动重置隐藏网页，请重发。"
                        : "网页通道 \(seconds) 秒没有响应（可能登录已失效或出现了人机验证），已自动重置隐藏网页；请重发，仍失败就到「连接 AI」长按该渠道重新登录。"
                ))
                return
            }
        }
    }

    @MainActor
    private func finish(sid: String, error: Error?) {
        guard let cont = streamContinuations.removeValue(forKey: sid) else { return }
        if let error { cont.finish(throwing: error) } else { cont.finish() }
    }

    @MainActor
    private func forget(sid: String) {
        streamContinuations.removeValue(forKey: sid)
        streamSpecIDs.removeValue(forKey: sid)
        lastActivity.removeValue(forKey: sid)
        sawFirstLine.remove(sid)
        endedNaturally.remove(sid)
    }

    private static func isTerminalLine(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        return compact.contains("\"event_type\":2003")
            || compact.contains("[DONE]")
            || compact.hasPrefix("event:close")
    }

    /// 用户点停止 / 看门狗超时：让页面停止这一轮生成，并让兜底直发脚本不再补发。
    @MainActor
    private func abortPageStream(sid: String, specID: String) {
        guard !endedNaturally.contains(sid), let wv = webViews[specID] else { return }
        wv.evaluateJavaScript("""
        (function() {
          if (window.__dshActiveSid === "\(sid)") window.__dshActiveSid = null;
          var b = document.querySelector('[data-testid="chat_input_local_break_button"]');
          if (b) { try { b.click(); } catch (e) {} }
        })();
        """, completionHandler: nil)
    }

    /// 丢弃某渠道的隐藏 WebView，下次请求重新冷启动（含预热）。
    @MainActor
    private func evictWebView(specID: String) {
        if let wv = webViews.removeValue(forKey: specID) {
            wv.navigationDelegate = nil
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "dshStream")
            wv.stopLoading()
            wv.removeFromSuperview()
        }
        loadReady.removeValue(forKey: specID)
    }

    @MainActor
    private func ensureWebViewReady(for spec: WebAdapterSpec) async throws -> WKWebView {
        if let existing = webViews[spec.id], loadReady[spec.id] == true {
            attachToWindowIfNeeded(existing)
            return existing
        }

        let wv: WKWebView
        if let existing = webViews[spec.id] {
            wv = existing
        } else {
            guard let pageURL = URL(string: spec.loginURL) else {
                throw WebAdapterError.badSpec("loginURL 不合法：\(spec.loginURL)")
            }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let ucc = WKUserContentController()
            ucc.addUserScript(WKUserScript(
                source: Self.fetchInterceptorScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            ucc.add(WeakScriptRelay(owner: self), name: "dshStream")
            config.userContentController = ucc

            let created = WKWebView(frame: CGRect(x: -2400, y: -2400, width: 1280, height: 800), configuration: config)
            created.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            created.alpha = 0.01
            created.isUserInteractionEnabled = false
            created.navigationDelegate = self
            webViews[spec.id] = created
            loadReady[spec.id] = false
            attachToWindowIfNeeded(created)
            created.load(URLRequest(url: pageURL))
            wv = created
        }

        // 可取消的加载等待（带上限），不再用无法取消的 continuation 挂死
        let loadStarted = ContinuousClock.now
        while loadReady[spec.id] != true, ContinuousClock.now - loadStarted < Self.pageLoadTimeout {
            try await Task.sleep(for: .milliseconds(200))
        }

        // 等前端框架与输入组件挂载就绪（优先精确匹配豆包 chat_input_input）
        for _ in 0..<32 {
            try Task.checkCancellation()
            let ready = (try? await wv.evaluateJavaScript(
                """
                Boolean(document.readyState === 'complete' && (
                  document.querySelector('[data-testid="chat_input_input"]:not([disabled])') ||
                  document.querySelector('textarea:not([disabled]), [contenteditable="true"]')
                ))
                """
            ) as? Bool) ?? false
            if ready {
                // 首次冷启动给字节 webmssdk / TTVerifyCenter 留足初始化 fp 与 xmst 签名钩子的时间
                try? await Task.sleep(for: .milliseconds(1600))
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return wv
    }

    @MainActor
    private func attachToWindowIfNeeded(_ webView: WKWebView) {
        guard webView.superview == nil else { return }
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first
        keyWindow?.addSubview(webView)
    }

    @MainActor
    private func triggerStream(
        in webView: WKWebView,
        sid: String,
        spec: WebAdapterSpec,
        request: URLRequest,
        prompt: String,
        thinkingEnabled: Bool
    ) async throws {
        let matchPath = URL(string: spec.chatURL)?.path ?? "/chat/completion"
        let fallbackURL = request.url?.absoluteString ?? spec.chatURL
        let fallbackBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var filteredHeaders: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            let lower = k.lowercased()
            if lower == "cookie" || lower == "origin" || lower == "referer" || lower == "user-agent" {
                continue
            }
            filteredHeaders[k] = v
        }
        let headersData = (try? JSONSerialization.data(withJSONObject: filteredHeaders)) ?? Data("{}".utf8)
        let headersJSON = String(decoding: headersData, as: UTF8.self)

        let args: [String: Any] = [
            "sid": sid,
            "specId": spec.id,
            "prompt": prompt,
            "matchPath": matchPath,
            "fallbackURL": fallbackURL,
            "fallbackHeadersJSON": headersJSON,
            "fallbackBody": fallbackBody
        ]

        _ = try await webView.callAsyncJavaScript(
            Self.driveAndFallbackScript,
            arguments: args,
            in: nil,
            contentWorld: .page
        )
    }

    @MainActor
    fileprivate func handleScriptMessage(_ dict: [String: Any]) {
        guard let sid = dict["id"] as? String,
              let kind = dict["kind"] as? String else { return }
        switch kind {
        case "line":
            if let text = dict["text"] as? String, let cont = streamContinuations[sid] {
                lastActivity[sid] = .now
                sawFirstLine.insert(sid)
                if Self.isTerminalLine(text) { endedNaturally.insert(sid) }
                cont.yield(text)
            }
        case "eof":
            finish(sid: sid, error: nil)
        case "error":
            let msg = (dict["text"] as? String) ?? "网页通道执行异常"
            if dict["fallback"] as? Bool == true {
                // 页面自己没发出去、我们的兜底直发又缺官网签名：原始 404/403 对用户毫无意义
                finish(sid: sid, error: WebAdapterError.upstream(
                    "网页没有自动发出这条消息（可能登录已过期、弹出了验证，或官网改版），兜底直发也被拒绝（\(msg.prefix(120))）。请到「连接 AI」长按该渠道重新登录后重试。"
                ))
            } else {
                finish(sid: sid, error: WebAdapterError.upstream(msg))
            }
        default:
            break
        }
    }

    private static let fetchInterceptorScript = """
    (function() {
      if (window.__dshTapInstalled) return;
      window.__dshTapInstalled = true;
      window.__dshActiveSid = null;
      window.__dshCapturedSid = null;
      window.__dshMatchPath = "";

      function isChatEndpoint(u, method) {
        if (!u) return false;
        if (method && String(method).toUpperCase() !== "POST") return false;
        if (u.indexOf("/snap") !== -1 || u.indexOf("/stop") !== -1 || u.indexOf("/history") !== -1 || u.indexOf("/list") !== -1 || u.indexOf("/delete") !== -1 || u.indexOf("/feedback") !== -1) {
          return false;
        }
        if (u.indexOf("/samantha/chat/completion") !== -1) return true;
        if (u.indexOf("/alice/message/stream") !== -1) return true;
        if (u.indexOf("/api/v2/chat") !== -1) return true;
        if (u.indexOf("/dialog/conversation") !== -1 && u.indexOf("getTaskState") === -1) return true;
        if (window.__dshMatchPath && u.indexOf(window.__dshMatchPath) !== -1) return true;
        return false;
      }

      function post(msg) {
        try { window.webkit.messageHandlers.dshStream.postMessage(msg); } catch (e) {}
      }

      const rawFetch = window.fetch;
      window.fetch = async function(...args) {
        let reqUrl = "";
        let reqMethod = "POST";
        try {
          if (typeof args[0] === "string") {
            reqUrl = args[0];
            reqMethod = (args[1] && args[1].method) ? args[1].method : "GET";
          } else if (args[0] && args[0].url) {
            reqUrl = String(args[0].url);
            reqMethod = args[0].method || ((args[1] && args[1].method) ? args[1].method : "POST");
          }
        } catch (e) {}
        const sid = window.__dshActiveSid;
        const matched = Boolean(sid && isChatEndpoint(reqUrl, reqMethod));
        if (matched) {
          window.__dshCapturedSid = sid;
        }
        try {
          const resp = await rawFetch.apply(this, args);
          if (matched) {
            if (!resp.ok) {
              const errTxt = await resp.clone().text().catch(() => "");
              post({ id: sid, kind: "error", fallback: window.__dshFallbackSid === sid, text: "HTTP " + resp.status + ": " + errTxt.slice(0, 360) });
            } else if (resp.body) {
              const clone = resp.clone();
              (async () => {
                const reader = clone.body.getReader();
                const decoder = new TextDecoder("utf-8");
                let buf = "";
                try {
                  while (true) {
                    const { value, done } = await reader.read();
                    if (done) break;
                    buf += decoder.decode(value, { stream: true });
                    let nl;
                    while ((nl = buf.indexOf("\\n")) !== -1) {
                      const line = buf.slice(0, nl);
                      buf = buf.slice(nl + 1);
                      if (line.trim().length > 0) {
                        post({ id: sid, kind: "line", text: line });
                      }
                    }
                  }
                  if (buf.trim().length > 0) {
                    post({ id: sid, kind: "line", text: buf });
                  }
                  if (window.__dshActiveSid === sid) window.__dshActiveSid = null;
                  post({ id: sid, kind: "eof" });
                } catch (e) {
                  if (window.__dshActiveSid === sid) window.__dshActiveSid = null;
                  post({ id: sid, kind: "error", text: String(e) });
                }
              })();
            }
          }
          return resp;
        } catch (err) {
          if (matched) {
            if (window.__dshActiveSid === sid) window.__dshActiveSid = null;
            post({ id: sid, kind: "error", text: String(err) });
          }
          throw err;
        }
      };
    })();
    """

    private static let driveAndFallbackScript = """
    window.__dshActiveSid = sid;
    window.__dshCapturedSid = null;
    window.__dshMatchPath = matchPath;
    window.__dshTurnCount = (window.__dshTurnCount || 0) + 1;

    // 如果上一轮还在生成，先点中断按钮避免发送钮处于禁用态
    const breakBtn = document.querySelector('[data-testid="chat_input_local_break_button"]');
    if (breakBtn) {
      try { breakBtn.click(); await new Promise(r => setTimeout(r, 200)); } catch (e) {}
    }

    if (window.__dshTurnCount > 1) {
      const newChatBtn = document.querySelector('[data-testid="create_conversation_button"], [class*="newChat"], [class*="new-chat"]');
      if (newChatBtn) {
        try { newChatBtn.click(); await new Promise(r => setTimeout(r, 250)); } catch (e) {}
      }
    }

    function findComposer() {
      const exact = document.querySelector('[data-testid="chat_input_input"]:not([disabled])');
      if (exact) return exact;
      const candidates = Array.from(document.querySelectorAll('textarea:not([disabled]), [contenteditable="true"]'));
      for (const item of candidates) {
        const r = item.getBoundingClientRect();
        if (r.width > 80 && r.height > 14) return item;
      }
      return candidates[0] || null;
    }

    let el = null;
    for (let i = 0; i < 20; i++) {
      el = findComposer();
      if (el) break;
      await new Promise(r => setTimeout(r, 200));
    }

    if (el) {
      el.focus();
      if (el.tagName === "TEXTAREA") {
        const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")?.set;
        if (setter) setter.call(el, prompt);
        else el.value = prompt;
        // 直接调 React 18 挂载在 DOM 节点上的真实 __reactProps$.onChange，100% 触发受控状态更新（支持任意多行文本）
        const reactPropKey = Object.keys(el).find(k => k.startsWith("__reactProps$"));
        if (reactPropKey && el[reactPropKey] && typeof el[reactPropKey].onChange === "function") {
          try { el[reactPropKey].onChange({ target: el, currentTarget: el }); } catch (e) {}
        }
        el.dispatchEvent(new InputEvent("input", { bubbles: true, data: prompt, inputType: "insertText" }));
      } else {
        document.execCommand("selectAll", false, null);
        document.execCommand("insertText", false, prompt);
      }

      await new Promise(r => setTimeout(r, 220));

      // 优先直接点发送按钮或其 __reactProps$.onClick（多行文本用 Enter 某些富文本会换行而不发送）
      const sendEl = document.querySelector('[data-testid="chat_input_send_button"] button:not([disabled])')
        || document.querySelector('[data-testid="chat_input_send_button"]')
        || document.querySelector('[class*="sendBtn"]:not([disabled]), [class*="send-btn"]:not([disabled])');
      if (sendEl) {
        const spKey = Object.keys(sendEl).find(k => k.startsWith("__reactProps$"));
        if (spKey && sendEl[spKey] && typeof sendEl[spKey].onClick === "function") {
          try { sendEl[spKey].onClick({ preventDefault(){}, stopPropagation(){} }); } catch (e) {}
        }
        try { sendEl.click(); } catch (e) {}
      }

      await new Promise(r => setTimeout(r, 350));
      if (window.__dshCapturedSid !== sid) {
        const enterOpts = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true };
        el.dispatchEvent(new KeyboardEvent("keydown", enterOpts));
      }
    }

    // 兜底：此时页面内 webmssdk 已完成初始化，双层转义后的 fallbackBody 走同源 window.fetch 自动挂 a_bogus
    await new Promise(r => setTimeout(r, 1500));
    if (window.__dshActiveSid === sid && window.__dshCapturedSid !== sid) {
      window.__dshFallbackSid = sid;
      const hdrs = JSON.parse(fallbackHeadersJSON || "{}");
      window.fetch(fallbackURL, {
        method: "POST",
        credentials: "include",
        headers: hdrs,
        body: fallbackBody
      }).catch(err => {
        try {
          window.webkit.messageHandlers.dshStream.postMessage({ id: sid, kind: "error", text: String(err) });
        } catch (e) {}
      });
    }
    """
}

extension WebKitBrowserStreamPerformer: WKNavigationDelegate {
    @MainActor
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        markLoaded(webView)
    }

    @MainActor
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        markLoaded(webView)
    }

    @MainActor
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        markLoaded(webView)
    }

    /// WebContent 进程被系统回收（内存压力 / 长时间后台）后页面是一片空白：丢弃并让在途流立即失败，下次自动重建。
    @MainActor
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let id = webViews.first(where: { $0.value === webView })?.key else { return }
        evictWebView(specID: id)
        for (sid, specID) in streamSpecIDs where specID == id {
            finish(sid: sid, error: WebAdapterError.upstream("网页通道被系统回收了，已自动重建，请重发这条消息。"))
        }
    }

    @MainActor
    private func markLoaded(_ webView: WKWebView) {
        guard let id = webViews.first(where: { $0.value === webView })?.key else { return }
        loadReady[id] = true
    }
}

private final class WeakScriptRelay: NSObject, WKScriptMessageHandler {
    weak var owner: WebKitBrowserStreamPerformer?
    init(owner: WebKitBrowserStreamPerformer) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        Task { @MainActor [weak owner] in
            owner?.handleScriptMessage(dict)
        }
    }
}

#endif
