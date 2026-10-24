import Foundation
import OSLog
import PhotosCore
import StoreKit
import SwiftUI

/// Native StoreKit merchandising for optional, repeatable tips.
///
/// Tips do not unlock content or features. StoreKit supplies localized product names, descriptions,
/// and prices from App Store Connect.
public struct TipJarView: View {
    private let productIdentifiers: [String]
    @State private var products: [Product] = []
    @State private var productLoadState = ProductLoadState.loading

    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        let identifier = bundleIdentifier ?? Self.fallbackBundleIdentifier
        productIdentifiers = TipJarProduct.identifiers(bundleIdentifier: identifier)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("settings.tip_jar_help"))
                .font(.footnote)
                .foregroundStyle(ProtonColor.textWeak)

            storeContent
        }
        .task { await loadProducts() }
    }

    @ViewBuilder
    private var storeContent: some View {
        switch productLoadState {
        case .loading:
            ProgressSpinner()
                .frame(maxWidth: .infinity, alignment: .center)
        case .loaded:
            StoreView(products: products) { product in
                Image(systemName: iconName(for: product.id))
                    .foregroundStyle(ProtonColor.primary)
            }
            .productViewStyle(.compact)
            .storeButton(.hidden, for: .restorePurchases, .cancellation)
            .onInAppPurchaseCompletion { product, result in
                await handlePurchaseCompletion(product: product, result: result)
            }
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("settings.tip_jar_unavailable"))
                    .font(.footnote)
                    .foregroundStyle(ProtonColor.textWeak)
                RetryButton(.compact) { Task { await loadProducts() } }
            }
        }
    }

    @MainActor
    private func loadProducts() async {
        productLoadState = .loading
        do {
            let loaded = try await Product.products(for: productIdentifiers)
            let productsByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            let availableProductIdentifiers = TipJarProductAvailability.orderedAvailableIdentifiers(
                expected: productIdentifiers,
                returned: Array(productsByID.keys)
            )
            let missingProductIdentifiers = productIdentifiers.filter { productsByID[$0] == nil }
            guard !availableProductIdentifiers.isEmpty else {
                Self.logger.error(
                    "StoreKit did not return configured products: \(missingProductIdentifiers.joined(separator: ", "), privacy: .public)"
                )
                products = []
                productLoadState = .unavailable
                return
            }
            if !missingProductIdentifiers.isEmpty {
                Self.logger.warning(
                    "StoreKit did not return some configured products: \(missingProductIdentifiers.joined(separator: ", "), privacy: .public)"
                )
            }
            products = availableProductIdentifiers.compactMap { productsByID[$0] }
            productLoadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("StoreKit product request failed: \(String(describing: error), privacy: .public)")
            products = []
            productLoadState = .unavailable
        }
    }

    private func iconName(for productIdentifier: String) -> String {
        if productIdentifier.hasSuffix(".extra_large") { return "heart.square.fill" }
        if productIdentifier.hasSuffix(".large") { return "heart.circle.fill" }
        if productIdentifier.hasSuffix(".medium") { return "heart.fill" }
        return "heart"
    }

    @MainActor
    private func handlePurchaseCompletion(
        product: Product,
        result: Result<Product.PurchaseResult, any Error>
    ) async {
        guard productIdentifiers.contains(product.id),
            case .success(let purchaseResult) = result,
            case .success(let verificationResult) = purchaseResult,
            case .verified(let transaction) = verificationResult,
            TipJarPurchaseEligibility.accepts(
                productIdentifier: product.id,
                transactionProductIdentifier: transaction.productID,
                allowedProductIdentifiers: productIdentifiers
            )
        else { return }

        TipJarCelebrationCoordinator.shared.celebrate()
        await transaction.finish()
    }

    private static let fallbackBundleIdentifier = "at.oncloud.encryptedmemories"
    private static let logger = Logger(subsystem: fallbackBundleIdentifier, category: "StoreKit")

    private enum ProductLoadState {
        case loading
        case loaded
        case unavailable
    }
}

enum TipJarProductAvailability {
    static func orderedAvailableIdentifiers(expected: [String], returned: [String]) -> [String] {
        let returnedIdentifiers = Set(returned)
        return expected.filter(returnedIdentifiers.contains)
    }
}

enum TipJarPurchaseEligibility {
    static func accepts(
        productIdentifier: String,
        transactionProductIdentifier: String,
        allowedProductIdentifiers: [String]
    ) -> Bool {
        allowedProductIdentifiers.contains(productIdentifier)
            && transactionProductIdentifier == productIdentifier
    }
}

/// Finishes verified tip transactions and ignores every transaction owned by another feature.
public actor TipJarTransactionProcessor {
    public static let shared = TipJarTransactionProcessor()

    private var updateTask: Task<Void, Never>?

    public func start(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard updateTask == nil else { return }
        let identifier = bundleIdentifier ?? Self.fallbackBundleIdentifier
        updateTask = Task {
            for await result in StoreKit.Transaction.updates {
                await Self.finishVerifiedTip(result, bundleIdentifier: identifier)
            }
        }
    }

    private static func finishVerifiedTip(
        _ result: VerificationResult<StoreKit.Transaction>,
        bundleIdentifier: String
    ) async {
        guard case .verified(let transaction) = result,
            TipJarProduct.contains(transaction.productID, bundleIdentifier: bundleIdentifier)
        else { return }

        // A tip has no digital entitlement to persist or unlock. Verification completes delivery.
        await transaction.finish()
    }

    private static let fallbackBundleIdentifier = "at.oncloud.encryptedmemories"
}
