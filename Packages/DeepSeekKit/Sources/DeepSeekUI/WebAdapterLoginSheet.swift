import SwiftUI
import WebKit
import DeepSeekCore

#if os(iOS)

/// 在我们自己的 WKWebView 里登录官方网页版，登录完读自己的 localStorage / cookie。
/// 这里没有 MITM、没有 hook 别人的进程：读的是本 App 自己这个 webview 的数据。
public struct WebAdapterLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let spec: WebAdapterSpec
    public var onCredential: (String) -> Void

    @State private var status: String = "登录完成后点右上角「读取登录状态」"
    @State private var isReading = false
    @State private var store = WKWebsiteDataStore.default()

    public init(spec: WebAdapterSpec, onCredential: @escaping (String) -> Void) {
        self.spec = spec
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

                WebView(urlString: spec.loginURL, dataStore: store)
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
                        Task { await harvest() }
                    }
                    .disabled(isReading)
                }
            }
        }
    }

    private func harvest() async {
        isReading = true
        defer { isReading = false }
        status = "正在读取…"

        let localStorage = await Self.readLocalStorage(store: store)
        let cookies = await Self.readCookies(store: store, host: spec.loginURL)

        if let token = WebCredentialParser.extract(spec: spec, localStorage: localStorage, cookies: cookies) {
            status = "读到了，长度 \(token.count)"
            onCredential(token)
            dismiss()
        } else {
            let hint = spec.credentialKind == .localStorage
                ? "没找到 localStorage[\(spec.credentialKey)]，确认已经登录成功"
                : "没找到 cookie[\(spec.credentialKey)]，确认已经登录成功"
            status = hint
        }
    }

    @MainActor
    private static func readLocalStorage(store: WKWebsiteDataStore) async -> [String: String] {
        // 用一个临时 webview 读不出来（跨源），所以走已有的会话：见 WebView 的 bridge 回调。
        WebBridgeRegistry.shared.snapshot
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

/// 只为了让上面那段读 localStorage 拿到最新快照。
@MainActor
final class WebBridgeRegistry {
    static let shared = WebBridgeRegistry()
    var snapshot: [String: String] = [:]
}

struct WebView: UIViewRepresentable {
    let urlString: String
    let dataStore: WKWebsiteDataStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let controller = WKUserContentController()
        let script = """
        (function() {
          function dump() {
            var out = {};
            try { for (var i = 0; i < localStorage.length; i++) { var k = localStorage.key(i); out[k] = localStorage.getItem(k); } } catch (e) {}
            window.webkit.messageHandlers.dshBridge.postMessage(out);
          }
          dump();
          setInterval(dump, 1500);
        })();
        """
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(context.coordinator, name: "dshBridge")
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
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
            for (key, value) in dict {
                if let text = value as? String { out[key] = text }
            }
            WebBridgeRegistry.shared.snapshot = out
        }
    }
}

#endif
