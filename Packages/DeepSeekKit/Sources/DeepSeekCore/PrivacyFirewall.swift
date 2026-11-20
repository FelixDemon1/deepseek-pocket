import Foundation

public enum NetworkTrafficPurpose: String, Codable, Sendable {
    case modelInference = "model_inference"
    case remoteDshHost = "remote_dsh_host"
    case userApprovedWebFetch = "approved_web_fetch"
    case blockedUnapprovedHost = "blocked_unapproved"
}

public struct NetworkAuditEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var method: String
    public var scheme: String
    public var host: String
    public var path: String
    public var purpose: NetworkTrafficPurpose
    public var statusCode: Int?
    public var bytesSent: Int
    public var bytesReceived: Int
    public var durationMs: Int
    public var wasBlocked: Bool
    public var note: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: String,
        scheme: String,
        host: String,
        path: String,
        purpose: NetworkTrafficPurpose,
        statusCode: Int? = nil,
        bytesSent: Int = 0,
        bytesReceived: Int = 0,
        durationMs: Int = 0,
        wasBlocked: Bool = false,
        note: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.scheme = scheme
        self.host = host
        self.path = path
        self.purpose = purpose
        self.statusCode = statusCode
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.durationMs = durationMs
        self.wasBlocked = wasBlocked
        self.note = note
    }
}

public enum PrivacyFirewallError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case blockedDomain(host: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效请求地址，已被零遥测防火墙拦截。"
        case let .blockedDomain(host, reason):
            return "零遥测防火墙已拦截未授权连接 [\(host)]：\(reason)"
        }
    }
}

/// Zero-Telemetry Outbound Firewall & Real-Time Network Auditor.
/// Guarantees 0 bytes ever reach developer servers, analytics trackers, or unapproved third-party relays.
public actor PrivacyFirewall {
    /// Known telemetry / relay / tracker domains permanently banned by policy unless explicitly overridden by user as model base.
    public static let hardBannedTrackerSuffixes: [String] = [
        "dshtui.com",
        "dshfind.com",
        "r2049.cn",
        "google-analytics.com",
        "app-measurement.com",
        "firebaseinstallations.googleapis.com",
        "sentry.io",
        "mixpanel.com",
        "amplitude.com"
    ]

    private var allowedModelHosts: Set<String> = ["api.deepseek.com"]
    private var allowedRemoteDshHosts: Set<String> = []
    private var temporaryApprovedWebHosts: Set<String> = []
    private var entries: [NetworkAuditEntry] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 300) {
        self.maxEntries = maxEntries
    }

    public func setAllowedModelBaseURL(_ url: URL) {
        if let host = url.host?.lowercased(), !host.isEmpty {
            allowedModelHosts = [host]
        }
    }

    /// 「设白名单 + 校验」在同一次 actor 调用里完成，避免并发请求（如测速与正式对话）互相把对方的模型域名挤掉。
    public func authorize(_ request: URLRequest, purpose: NetworkTrafficPurpose, allowingModelBase base: URL) throws {
        setAllowedModelBaseURL(base)
        try authorize(request, purpose: purpose)
    }

    public func setAllowedRemoteDshBaseURL(_ url: URL?) {
        if let host = url?.host?.lowercased(), !host.isEmpty {
            allowedRemoteDshHosts = [host]
        } else {
            allowedRemoteDshHosts = []
        }
    }

    public func approveWebFetchHostOnce(_ host: String) {
        let normalized = host.lowercased()
        guard !Self.isHardBannedTracker(normalized) else { return }
        temporaryApprovedWebHosts.insert(normalized)
    }

    public static func isHardBannedTracker(_ host: String) -> Bool {
        let lower = host.lowercased()
        return hardBannedTrackerSuffixes.contains { suffix in
            lower == suffix || lower.hasSuffix(".\(suffix)")
        }
    }

    /// Validates an outbound request before a single TCP packet is opened.
    public func authorize(_ request: URLRequest, purpose: NetworkTrafficPurpose) throws {
        guard let url = request.url, let rawHost = url.host, !rawHost.isEmpty else {
            throw PrivacyFirewallError.invalidURL
        }
        let host = rawHost.lowercased()
        let scheme = (url.scheme ?? "https").lowercased()
        let safePath = Self.redactQueryAndPath(url)

        if Self.isHardBannedTracker(host) && !allowedModelHosts.contains(host) {
            appendEntry(NetworkAuditEntry(
                method: request.httpMethod ?? "GET",
                scheme: scheme,
                host: host,
                path: safePath,
                purpose: .blockedUnapprovedHost,
                bytesSent: 0,
                wasBlocked: true,
                note: "命中第三方遥测/中继黑名单"
            ))
            throw PrivacyFirewallError.blockedDomain(host: host, reason: "禁止向任何第三方统计或中继服务器发送数据")
        }

        let permitted: Bool
        switch purpose {
        case .modelInference:
            permitted = allowedModelHosts.contains(host)
        case .remoteDshHost:
            permitted = allowedRemoteDshHosts.contains(host)
        case .userApprovedWebFetch:
            permitted = temporaryApprovedWebHosts.contains(host)
        case .blockedUnapprovedHost:
            permitted = false
        }

        if !permitted {
            appendEntry(NetworkAuditEntry(
                method: request.httpMethod ?? "GET",
                scheme: scheme,
                host: host,
                path: safePath,
                purpose: .blockedUnapprovedHost,
                bytesSent: 0,
                wasBlocked: true,
                note: "不在用户授权白名单内"
            ))
            throw PrivacyFirewallError.blockedDomain(host: host, reason: "域名未在当前引擎白名单内授权")
        }
    }

    public func recordCompleted(
        request: URLRequest,
        purpose: NetworkTrafficPurpose,
        statusCode: Int?,
        bytesReceived: Int,
        durationMs: Int,
        note: String? = nil
    ) {
        guard let url = request.url, let host = url.host?.lowercased() else { return }
        appendEntry(NetworkAuditEntry(
            method: request.httpMethod ?? "GET",
            scheme: (url.scheme ?? "https").lowercased(),
            host: host,
            path: Self.redactQueryAndPath(url),
            purpose: purpose,
            statusCode: statusCode,
            bytesSent: request.httpBody?.count ?? 0,
            bytesReceived: bytesReceived,
            durationMs: durationMs,
            wasBlocked: false,
            note: note
        ))
    }

    public func snapshot() -> [NetworkAuditEntry] {
        entries
    }

    public func allowlistSummary() -> (modelHosts: [String], remoteHosts: [String], webHosts: [String]) {
        (
            allowedModelHosts.sorted(),
            allowedRemoteDshHosts.sorted(),
            temporaryApprovedWebHosts.sorted()
        )
    }

    public func clearAuditLog() {
        entries.removeAll()
    }

    public func exportAuditJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        return String(decoding: data, as: UTF8.self)
    }

    private func appendEntry(_ entry: NetworkAuditEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    /// Never logs launch tokens, API keys, or query secrets in the audit trail.
    public static func redactQueryAndPath(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty else {
            return path
        }
        let redactedKeys = items.map { item -> String in
            let lower = item.name.lowercased()
            if lower.contains("token") || lower.contains("key") || lower.contains("secret") || lower.contains("auth") {
                return "\(item.name)=[REDACTED]"
            }
            return "\(item.name)=…"
        }.joined(separator: "&")
        return "\(path)?\(redactedKeys)"
    }
}
