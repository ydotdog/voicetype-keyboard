import Foundation
import StoreKit

@MainActor
final class StoreKitService: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await Product.products(for: ProductIDs.all)
            products = loaded.sorted { $0.price < $1.price }
            if loaded.isEmpty {
                errorMessage = "The App Store did not return any credit packs for this build. Try reloading; if it stays empty, the in-app purchases are not available to this TestFlight build yet."
            } else {
                let loadedIDs = Set(loaded.map(\.id))
                let missingIDs = ProductIDs.all.filter { !loadedIDs.contains($0) }
                if !missingIDs.isEmpty {
                    errorMessage = "Some credit packs are not available from the App Store yet: \(missingIDs.joined(separator: ", "))"
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purchase(_ product: Product, account: AccountStore) async {
        guard account.isSignedIn else {
            errorMessage = "Sign in before adding credit."
            return
        }

        var appAccountToken = account.appAccountToken
        if appAccountToken == nil {
            await account.refresh()
            appAccountToken = account.appAccountToken
        }
        guard let appAccountToken else {
            errorMessage = "Account refresh failed. Sign in again before adding credit."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let options: Set<Product.PurchaseOption> = [.appAccountToken(appAccountToken)]
            let result = try await product.purchase(options: options)
            switch result {
            case let .success(verification):
                try await submit(verification, account: account)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncUnfinishedTransactions(account: AccountStore) async {
        guard account.isSignedIn, !account.isPreviewMode else { return }
        do {
            for await verification in Transaction.unfinished {
                try await submit(verification, account: account)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submit(_ verification: VerificationResult<Transaction>, account: AccountStore) async throws {
        let signedTransaction = verification.jwsRepresentation
        let transaction = try checkVerified(verification)
        let response = try await BackendClient.submitStoreKitTransaction(
            jws: signedTransaction,
            token: account.token
        )
        account.apply(balance: response.balance)
        await transaction.finish()
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
