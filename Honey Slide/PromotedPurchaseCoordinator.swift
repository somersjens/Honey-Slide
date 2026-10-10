//
//  PromotedPurchaseCoordinator.swift
//  Math Memory
//
//  Defers App Store promoted purchases until the parental gate is passed.
//
//  Uses StoreKit 2's purchase intents: the App Store hands the app an intent
//  instead of pushing a payment straight onto a queue, so nothing is bought
//  before an adult has approved it.
//

import Combine
import StoreKit

@MainActor
final class PromotedPurchaseCoordinator: ObservableObject {
    static let shared = PromotedPurchaseCoordinator()

    @Published private(set) var isAwaitingParentApproval = false

    /// The promoted product waiting for approval. A newer App Store request
    /// replaces an older, still-deferred one.
    private var deferredProduct: Product?
    private var listener: Task<Void, Never>?

    private init() {}

    /// Start this as early as possible, so an intent that arrives while the app
    /// is still launching is caught rather than missed.
    func startListening() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await intent in PurchaseIntent.intents {
                guard intent.product.id == PremiumStore.productID else { continue }
                self?.deferredProduct = intent.product
                self?.isAwaitingParentApproval = true
            }
        }
        // Make sure StoreKit transaction updates are observed even when the app
        // was opened directly from the App Store.
        _ = PremiumStore.shared
    }

    func approveDeferredPurchase() {
        guard let product = deferredProduct else { return }
        deferredProduct = nil
        isAwaitingParentApproval = false
        Task { await PremiumStore.shared.purchase(product) }
    }

    func cancelDeferredPurchase() {
        deferredProduct = nil
        isAwaitingParentApproval = false
    }
}
