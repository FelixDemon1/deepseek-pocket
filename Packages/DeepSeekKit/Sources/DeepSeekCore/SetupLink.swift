import Foundation

/// One-tap onboarding payload: `deepseekgo://setup?base=…&key=…&model=…&name=…`
///
/// Self-hosted gateways (see `gateway/`) hand this URL out as a link or QR code so a
/// new user never types an endpoint or a token by hand. Everything carried here is
/// non-secret by design *only* in the sense that the gateway token is scoped and
/// revocable — it is still stored exclusively in the device Keychain.
public struct SetupLink: Equatable, Sendable {
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var name: String

    public static let scheme = "deepseekpocket"
    public static let host = "setup"

    public init(
        baseURL: URL,
        apiKey: String = "",
        model: String = "deepseek-chat",
        name: String = "自建网关"
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.name = name
    }

    // MARK: - Parsing

    public static func parse(_ url: URL) -> SetupLink? {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "deepseekpocket" || scheme == "deepseekgo" || scheme == "tide" || scheme == "dshgo" else { return nil }

        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let isSetup = host == Self.host
            || host == "config"
            || (host.isEmpty && (path == "/setup" || path == "/config"))
        guard isSetup else { return nil }

        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []

        func value(_ names: String...) -> String? {
            for name in names {
                if let raw = items.first(where: { $0.name.lowercased() == name })?.value {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }

        guard let baseRaw = value("base", "base_url", "endpoint"),
              let base = normalizedBaseURL(baseRaw) else { return nil }

        let model = value("model") ?? "deepseek-chat"
        let name = value("name") ?? "自建网关"

        return SetupLink(
            baseURL: base,
            apiKey: value("key", "api_key", "token") ?? "",
            model: String(model.prefix(80)),
            name: String(name.prefix(40))
        )
    }

    /// Accepts `api.example.com/v1`, `https://api.example.com/v1`, and rejects non-HTTP schemes.
    public static func normalizedBaseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            guard !lower.contains("://") else { return nil }
            text = "https://" + text
        }
        guard let url = URL(string: text),
              let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // MARK: - Encoding

    /// The shareable link a gateway operator hands out (or renders as a QR code).
    public var appURL: URL? {
        var comps = URLComponents()
        comps.scheme = Self.scheme
        comps.host = Self.host
        var items: [URLQueryItem] = [
            URLQueryItem(name: "base", value: baseURL.absoluteString),
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "name", value: name)
        ]
        if !apiKey.isEmpty {
            items.append(URLQueryItem(name: "key", value: apiKey))
        }
        comps.queryItems = items
        return comps.url
    }
}
