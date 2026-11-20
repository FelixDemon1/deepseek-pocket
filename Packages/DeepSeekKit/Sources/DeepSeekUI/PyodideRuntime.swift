import Foundation
import WebKit
import DeepSeekCore

#if os(iOS)

// ---------------------------------------------------------------------------
// 手机上的 Python：在隐藏 WKWebView 里跑 Pyodide（CPython 的 WebAssembly 版）。
//
// iOS 不允许 App 起子进程，也不允许 App 自己做 JIT；WKWebView 的网页进程是系统给的、
// 带 JIT 的，所以 WebAssembly 在里面能全速跑。运行时文件（约 12MB）首次使用时
// 从 jsDelivr 下载，经过防火墙审计后缓存在本机，之后离线可用。
// 页面的 CSP 只允许访问我们自己的 `pyrt:` 协议，Python 代码没法自己联网。
// ---------------------------------------------------------------------------

public final class PyodideRuntime: NSObject, PythonRuntime, @unchecked Sendable {
    public static let shared = PyodideRuntime()
    static let version = "0.29.5"
    /// 单次运行上限；超时就销毁网页进程（死循环也能停下来）
    static let runTimeout: Duration = .seconds(120)
    /// 同步进 Python 文件系统的工作区上限
    static let maxFileBytes = 8 << 20
    static let maxTotalBytes = 32 << 20

    @MainActor public var firewall: PrivacyFirewall?
    @MainActor private var webView: WKWebView?
    @MainActor private var busy = false
    @MainActor private var waiters: [CheckedContinuation<Void, Never>] = []

    public func run(_ request: PythonRunRequest) async throws -> PythonRunResult {
        try await runOnMain(request)
    }

    @MainActor
    private func runOnMain(_ request: PythonRunRequest) async throws -> PythonRunResult {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()

        let toolset = request.toolset
        let files = Self.snapshot(toolset)
        let webView = ensureWebView()
        // 页面还在加载时注入的脚本会随导航一起被丢掉，先等它加载完
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(80))
        }
        let arguments: [String: Any] = [
            "files": files,
            "codeText": request.code ?? "",
            "script": request.scriptPath ?? "",
            "argv": request.args,
            "packages": request.packages
        ]

        let raw = try await evaluate(Self.runScript, arguments: arguments, in: webView)
        guard let dict = raw as? [String: Any] else {
            throw WebAdapterError.upstream("Python 运行时没有返回结果")
        }
        var written: [String] = []
        for (path, encoded) in (dict["written"] as? [String: String]) ?? [:] {
            guard let data = Data(base64Encoded: encoded), let url = try? toolset.resolveSafeURL(path) else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? data.write(to: url, options: .atomic)) != nil { written.append(path) }
        }
        for path in (dict["deleted"] as? [String]) ?? [] {
            if let url = try? toolset.resolveSafeURL(path) { try? FileManager.default.removeItem(at: url) }
        }
        return PythonRunResult(
            output: (dict["output"] as? String) ?? "",
            exitCode: (dict["code"] as? NSNumber)?.intValue ?? 1,
            writtenFiles: written.sorted()
        )
    }

    /// 带超时、可取消地执行一段 JS。超时或取消时直接丢掉 WebView，网页进程随之结束。
    @MainActor
    private func evaluate(_ script: String, arguments: [String: Any], in webView: WKWebView) async throws -> Any? {
        let box = ResumeOnce()
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.runTimeout)
            guard !Task.isCancelled else { return }
            self?.discardWebView()
            box.resume(.failure(WebAdapterError.upstream("Python 运行超过 \(Int(Self.runTimeout.components.seconds)) 秒，已强制停止")))
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSValueBox, Error>) in
                box.install(continuation)
                webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                    switch result {
                    case let .success(value): box.resume(.success(JSValueBox(value: value)))
                    case let .failure(error):
                        let detail = ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
                        box.resume(.failure(WebAdapterError.upstream("Python 运行时出错：\(detail)")))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.discardWebView()
                box.resume(.failure(CancellationError()))
            }
        }.value
    }

    @MainActor
    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PyodideSchemeHandler(owner: self), forURLScheme: "pyrt")
        let created = WKWebView(frame: .zero, configuration: configuration)
        created.load(URLRequest(url: URL(string: "pyrt://app/index.html")!))
        webView = created
        return created
    }

    @MainActor
    private func discardWebView() {
        webView?.stopLoading()
        webView = nil
    }

    /// 工作区里的文件（跳过隐藏文件和过大的文件），base64 后交给 Python 的内存文件系统。
    private static func snapshot(_ toolset: WorkspaceToolset) -> [String: String] {
        let root = toolset.rootURL.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: toolset.rootURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        var files: [String: String] = [:]
        var total = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, size <= maxFileBytes,
                  total + size <= maxTotalBytes, let data = try? Data(contentsOf: url) else { continue }
            total += size
            files[String(url.standardizedFileURL.path.dropFirst(root.count + 1))] = data.base64EncodedString()
        }
        return files
    }

    // MARK: 资源：先读本机缓存，没有再经防火墙从 CDN 下载

    static let indexHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src pyrt: 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' blob: data:">
    <script src="pyrt://app/pyodide.js"></script>
    <script>window.__boot = loadPyodide({ indexURL: "pyrt://app/" }).then(py => { window.py = py; });</script>
    </head><body></body></html>
    """

    private static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("pyodide-\(version)", isDirectory: true)
    }

    /// 运行时文件是否已经在本机（界面上用来提示「首次使用要下载」）
    public static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("pyodide.asm.wasm").path)
    }

    fileprivate func asset(_ path: String) async throws -> Data {
        guard !path.isEmpty, !path.contains(".."),
              path.allSatisfy({ $0.isLetter || $0.isNumber || "._-/+".contains($0) }) else {
            throw WebAdapterError.badSpec("非法的运行时资源路径：\(path)")
        }
        let cached = Self.cacheDirectory.appendingPathComponent(path)
        if let data = try? Data(contentsOf: cached) { return data }

        var lastError: Error = WebAdapterError.upstream("下载失败")
        for host in ["cdn.jsdelivr.net", "fastly.jsdelivr.net"] {
            guard let url = URL(string: "https://\(host)/pyodide/v\(Self.version)/full/\(path)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 90
            let started = Date()
            do {
                let firewall = await firewall
                if let firewall {
                    await firewall.approveWebFetchHostOnce(host)
                    try await firewall.authorize(request, purpose: .userApprovedWebFetch)
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                await firewall?.recordCompleted(
                    request: request, purpose: .userApprovedWebFetch, statusCode: status,
                    bytesReceived: data.count, durationMs: Int(Date().timeIntervalSince(started) * 1000),
                    note: "Python 运行时"
                )
                guard status == 200 else {
                    lastError = WebAdapterError.httpError(statusCode: status, message: "下载 Python 运行时文件 \(path) 失败")
                    continue
                }
                try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cached, options: .atomic)
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static let runScript = """
    if (!window.__boot) throw new Error("Python 运行时页面没有加载成功（首次使用需要联网下载约 12MB）");
    await window.__boot;
    const py = window.py, FS = py.FS;
    const dec = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
    const enc = bytes => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
    const rmrf = p => { for (const n of FS.readdir(p)) { if (n === "." || n === "..") continue; const f = p + "/" + n; if (FS.isDir(FS.stat(f).mode)) { rmrf(f); FS.rmdir(f); } else FS.unlink(f); } };
    try { rmrf("/workspace"); } catch (e) {}
    FS.mkdirTree("/workspace");
    for (const [path, b64] of Object.entries(files)) {
      const full = "/workspace/" + path;
      FS.mkdirTree(full.substring(0, full.lastIndexOf("/")));
      FS.writeFile(full, dec(b64));
    }
    const out = [];
    py.setStdout({ batched: s => out.push(s) });
    py.setStderr({ batched: s => out.push(s) });
    let code = 0;
    try {
      for (const name of packages) await py.loadPackage(name, { messageCallback() {}, errorCallback(m) { out.push(m); } });
      const source = script ? FS.readFile("/workspace/" + script, { encoding: "utf8" }) : codeText;
      await py.loadPackagesFromImports(source, { messageCallback() {}, errorCallback(m) { out.push(m); } });
      py.globals.set("__dsg_argv", py.toPy(argv));
      py.globals.set("__dsg_src", source);
      py.globals.set("__dsg_name", script || "<string>");
      await py.runPythonAsync(`
    import os, sys, traceback
    os.environ["MPLBACKEND"] = "Agg"
    os.chdir("/workspace")
    sys.argv = list(__dsg_argv)
    if "/workspace" not in sys.path:
        sys.path.insert(0, "/workspace")
    __dsg_code = 0
    try:
        exec(compile(__dsg_src, __dsg_name, "exec"), {"__name__": "__main__"})
    except SystemExit as e:
        __dsg_code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    except BaseException:
        traceback.print_exc()
        __dsg_code = 1
    sys.stdout.flush()
    sys.stderr.flush()
    `);
      code = py.globals.get("__dsg_code");
    } catch (e) {
      out.push(String(e));
      code = 1;
    }
    const written = {}, seen = new Set();
    (function walk(dir, rel) {
      for (const n of FS.readdir(dir)) {
        if (n === "." || n === "..") continue;
        const full = dir + "/" + n, r = rel ? rel + "/" + n : n;
        if (FS.isDir(FS.stat(full).mode)) { walk(full, r); continue; }
        seen.add(r);
        const b64 = enc(FS.readFile(full));
        if (files[r] !== b64) written[r] = b64;
      }
    })("/workspace", "");
    return { output: out.join("\\n"), code: code, written: written, deleted: Object.keys(files).filter(p => !seen.has(p)) };
    """
}

/// JS 返回的是 plist 类型（字典 / 数组 / 字符串 / 数字），只在主线程上读。
private struct JSValueBox: @unchecked Sendable {
    let value: Any?
}

/// continuation 只能恢复一次：JS 回调、超时、取消三方谁先到算谁的。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<JSValueBox, Error>?
    private var early: Result<JSValueBox, Error>?

    func install(_ continuation: CheckedContinuation<JSValueBox, Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(_ result: Result<JSValueBox, Error>) {
        lock.lock()
        guard let pending = continuation else {
            if early == nil { early = result }
            lock.unlock()
            return
        }
        continuation = nil
        early = result
        lock.unlock()
        pending.resume(with: result)
    }
}

private final class PyodideSchemeHandler: NSObject, WKURLSchemeHandler {
    private weak var owner: PyodideRuntime?
    private var live = Set<ObjectIdentifier>()

    init(owner: PyodideRuntime) { self.owner = owner }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = String(url.path.drop { $0 == "/" })
        let id = ObjectIdentifier(task)
        live.insert(id)

        func finish(_ data: Data, mime: String) {
            guard live.remove(id) != nil,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"
                  ]) else { return }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }

        if path.isEmpty || path == "index.html" {
            finish(Data(PyodideRuntime.indexHTML.utf8), mime: "text/html")
            return
        }
        let mime: String
        switch (path as NSString).pathExtension.lowercased() {
        case "wasm": mime = "application/wasm"
        case "js", "mjs": mime = "text/javascript"
        case "json": mime = "application/json"
        default: mime = "application/octet-stream"
        }
        Task { @MainActor [weak self] in
            do {
                guard let owner = self?.owner else { throw CancellationError() }
                finish(try await owner.asset(path), mime: mime)
            } catch {
                if self?.live.remove(id) != nil { task.didFailWithError(error) }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }
}

#endif
