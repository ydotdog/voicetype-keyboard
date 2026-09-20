import Foundation
import StoreKit

@MainActor
final class StoreKitService: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var statusMessage: String?

    private var updatesTask: Task<Void, Never>?
    private let syncCoordinator = PurchaseSyncCoordinator()
    private var submittingTransactions: Set<UInt64> = []

    deinit {
        updatesTask?.cancel()
    }

    func accountDidChange() {
        syncCoordinator.cancel()
        errorMessage = nil
        statusMessage = nil
    }

    func startObservingTransactions(account: AccountStore) {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self, weak account] in
            for await verification in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let account, account.isSignedIn, !account.isPreviewMode else { continue }
                let requestSession = account.sessionID
                let requestToken = account.token
                do {
                    try await self?.submit(verification, account: account)
                } catch {
                    if account.matchesSession(requestSession, token: requestToken), !Task.isCancelled {
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await Product.products(for: ProductIDs.all)
            products = loaded.sorted { $0.price < $1.price }
            if loaded.isEmpty {
                errorMessage = "Credit packs are unavailable right now. Check your App Store connection and tap Reload credit packs."
            } else if Set(loaded.map(\.id)).count < ProductIDs.all.count {
                errorMessage = "Some credit packs are temporarily unavailable. You can choose an available pack or reload."
            }
        } catch {
            errorMessage = "Credit packs couldn't be loaded. Check your connection and try again."
        }
    }

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    func purchase(productID: String, account: AccountStore) async {
        guard !isLoading else { return }
        if let product = product(for: productID) {
            await purchase(product, account: account)
            return
        }
        await loadProducts()
        guard let product = product(for: productID) else {
            errorMessage = "This credit pack is temporarily unavailable. Please try again later."
            return
        }
        await purchase(product, account: account)
    }

    func purchase(_ product: Product, account: AccountStore) async {
        guard !isLoading else { return }
        guard account.isSignedIn, !account.isPreviewMode else {
            errorMessage = "Sign in before adding credit."
            return
        }
        let purchaseSession = account.sessionID
        let purchaseToken = account.token
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        defer { isLoading = false }

        if account.appAccountToken == nil {
            await account.refresh()
        }
        guard account.matchesSession(purchaseSession, token: purchaseToken),
              let appAccountToken = account.appAccountToken else {
            errorMessage = "Sign in again before adding credit."
            return
        }

        do {
            let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
            switch result {
            case let .success(verification):
                guard account.matchesSession(purchaseSession, token: purchaseToken) else {
                    statusMessage = "Your purchase is saved by the App Store. Sign in to the account used to buy it to receive the credit."
                    return
                }
                try await submit(verification, account: account)
            case .pending:
                statusMessage = "Your purchase is awaiting App Store approval. Credit will be checked when the purchase completes."
            case .userCancelled:
                break
            @unknown default:
                statusMessage = "The App Store has not completed this purchase. Check purchases again later."
            }
        } catch {
            if account.matchesSession(purchaseSession, token: purchaseToken), !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    func syncUnfinishedTransactions(account: AccountStore) async {
        guard account.isSignedIn, !account.isPreviewMode else { return }
        let syncSession = account.sessionID
        let syncToken = account.token
        await syncCoordinator.run(sessionID: syncSession) { [weak self, weak account] in
            guard let self, let account,
                  account.matchesSession(syncSession, token: syncToken) else { return }
            self.errorMessage = nil
            var firstFailure: String?
            for await verification in Transaction.unfinished {
                guard account.matchesSession(syncSession, token: syncToken), !Task.isCancelled else { return }
                do {
                    try await self.submit(verification, account: account)
                } catch {
                    // Continue other receipts, but don't erase this failure when
                    // a later receipt succeeds and reports its own status.
                    firstFailure = firstFailure ?? error.localizedDescription
                }
            }
            if account.matchesSession(syncSession, token: syncToken), !Task.isCancelled,
               let firstFailure {
                self.errorMessage = firstFailure
            }
        }
    }

    func checkPurchases(account: AccountStore) async {
        guard account.isSignedIn, !account.isPreviewMode else {
            errorMessage = "Sign in before checking purchases."
            return
        }
        let requestSession = account.sessionID
        let requestToken = account.token
        statusMessage = nil
        await syncUnfinishedTransactions(account: account)
        guard account.matchesSession(requestSession, token: requestToken), !Task.isCancelled else { return }
        await account.refresh()
        guard account.matchesSession(requestSession, token: requestToken), !Task.isCancelled else { return }
        if errorMessage == nil, account.errorMessage == nil {
            statusMessage = "Purchase check finished."
        }
    }

    private func submit(_ verification: VerificationResult<Transaction>, account: AccountStore) async throws {
        let transaction = try checkVerified(verification)
        guard ProductIDs.all.contains(transaction.productID), transaction.revocationDate == nil else { return }
        guard StoreKitTransactionPolicy.canCredit(
            productID: transaction.productID,
            transactionAccount: transaction.appAccountToken,
            signedInAccount: account.appAccountToken,
            isRevoked: transaction.revocationDate != nil
        ) else { throw StoreKitError.differentAccount }
        guard submittingTransactions.insert(transaction.id).inserted else {
            throw StoreKitError.verificationInProgress
        }
        defer { submittingTransactions.remove(transaction.id) }

        let requestSession = account.sessionID
        let requestToken = account.token
        let response = try await BackendClient.submitStoreKitTransaction(
            jws: verification.jwsRepresentation,
            token: requestToken
        )
        if account.matchesSession(requestSession, token: requestToken) {
            account.scheduleBalanceRefresh()
            errorMessage = nil
            statusMessage = response.alreadyProcessed ? "Your purchase has already been added to your balance." : "Credit added to your balance."
        }
        // Finish only after the server confirms the grant. If the account changed
        // while waiting, the original account still received the credit safely.
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

enum StoreKitTransactionPolicy {
    static func canCredit(productID: String, transactionAccount: UUID?, signedInAccount: UUID?, isRevoked: Bool) -> Bool {
        guard ProductIDs.all.contains(productID), !isRevoked,
              let transactionAccount, let signedInAccount else { return false }
        return transactionAccount == signedInAccount
    }
}

enum StoreKitError: LocalizedError {
    case unverified
    case differentAccount
    case verificationInProgress

    var errorDescription: String? {
        switch self {
        case .unverified:
            "The App Store transaction could not be verified on this device. Check purchases again later."
        case .differentAccount:
            "An unfinished purchase belongs to another VoiceType account. Sign in to the account used to buy it to receive its credit."
        case .verificationInProgress:
            "A purchase is still being verified. Wait a moment, then check purchases again. You do not need to buy it again."
        }
    }
}
