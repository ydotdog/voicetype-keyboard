import Foundation
import StoreKit

@MainActor
final class StoreKitService: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadProducts() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await Product.products(for: ProductIDs.all)
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purchase(_ product: Product, account: AccountStore) async {
        guard account.isSignedIn else {
            errorMessage = "Sign in before adding credit."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verification):
                let signedTransaction = verification.jwsRepresentation
                let transaction = try checkVerified(verification)
                let response = try await BackendClient.submitStoreKitTransaction(
                    jws: signedTransaction,
                    token: account.token
                )
                account.apply(balance: response.balance)
                await transaction.finish()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case let .verified(safe):
            return safe
        case .unverified:
            throw StoreKitError.unverified
        }
    }
}

enum StoreKitError: LocalizedError {
    case unverified

    var errorDescription: String? {
        "The App Store transaction could not be verified on device."
    }
}
