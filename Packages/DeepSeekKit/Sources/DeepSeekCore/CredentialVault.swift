import Foundation
import LocalAuthentication
import Security

public protocol SecretStore: Sendable {
    func saveSecret(_ value: String, for account: String) throws
    func loadSecret(for account: String) throws -> String?
    func deleteSecret(for account: String) throws
}

public enum VaultError: LocalizedError, Sendable {
    case keychainFailure(OSStatus)
    case biometricFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .keychainFailure(status):
            return "安全钥匙串访问失败 (OSStatus: \(status))"
        case let .biometricFailed(reason):
            return "生物识别未通过：\(reason)"
        }
    }
}

/// Hardware-backed Keychain store bound strictly to this device (`WhenUnlockedThisDeviceOnly`).
/// Secrets never leave the device via iCloud or unencrypted iTunes/Finder backups.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "io.deepseekgo.ios.vault") {
        self.service = service
    }

    public func saveSecret(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        try deleteSecret(for: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultError.keychainFailure(status)
        }
    }

    public func loadSecret(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw VaultError.keychainFailure(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteSecret(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychainFailure(status)
        }
    }
}

/// In-memory vault used in unit tests and ephemeral preview sessions.
public actor InMemorySecretStore: SecretStore {
    private let lock = NSLock()
    private nonisolated(unsafe) var storage: [String: String] = [:]

    public init() {}

    public nonisolated func saveSecret(_ value: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = value
    }

    public nonisolated func loadSecret(for account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    public nonisolated func deleteSecret(for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}

public struct BiometricGate: Sendable {
    public init() {}

    public func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            // Simulator or device without passcode configured: surface clear error if strict, else allow in simulator debug.
            #if targetEnvironment(simulator)
            return true
            #else
            throw VaultError.biometricFailed(authError?.localizedDescription ?? "设备未启用 Face ID 或锁屏密码")
            #endif
        }
        return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}
