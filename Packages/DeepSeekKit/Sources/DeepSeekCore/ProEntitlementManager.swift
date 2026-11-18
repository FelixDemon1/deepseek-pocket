import Foundation
import StoreKit

/// Compliant App Store monetization layer built on Apple `StoreKit 2`.
/// Unlocks Pro local productivity features (custom workflow rulesets, multi-host profiles, unlimited presets) with 0 server cost.
@MainActor
public final class ProEntitlementManager {
    public static let productIDs: [String] = [
        "io.deepseekgo.ios.pro.monthly",
        "io.deepseekgo.ios.pro.lifetime"
    ]

    public private(set) var products: [Product] = []
    public private(set) var isProUnlocked: Bool

    private static let localDevOverrideKey = "deepseek_go_pro_preview_unlocked"

    public init() {
        self.isProUnlocked = UserDefaults.standard.bool(forKey: Self.localDevOverrideKey)
    }

    public func refreshEntitlements() async {
        for await verification in Transaction.currentEntitlements {
            if case let .verified(tx) = verification,
               Self.productIDs.contains(tx.productID),
               tx.revocationDate == nil {
                isProUnlocked = true
                return
            }
        }
        if let fetched = try? await Product.products(for: Self.productIDs) {
            products = fetched.sorted { $0.price < $1.price }
        }
    }

    public func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case let .success(.verified(tx)):
            await tx.finish()
            isProUnlocked = true
            return true
        default:
            return false
        }
    }

    public func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    /// Allows testing the Pro workflow locally in Simulator / Xcode debug builds before App Store Connect SKU setup.
    public func setPreviewUnlock(_ enabled: Bool) {
        isProUnlocked = enabled
        UserDefaults.standard.set(enabled, forKey: Self.localDevOverrideKey)
    }
}
