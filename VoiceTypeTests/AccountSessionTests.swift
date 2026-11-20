import Foundation
import Testing
@testable import VoiceType

@Suite(.serialized)
@MainActor
struct AccountSessionTests {
    private func auth(_ label: String, balance: Int = 100) -> AuthResponse {
        AuthResponse(token: "test-token-\(label)", user: UserProfile(id: label == "A" ? "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" : "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", email: "\(label)@example.invalid"), balance: payload(balance))
    }

    private func payload(_ value: Int) -> BalancePayload {
        BalancePayload(balanceUSDMicros: value, balanceCreditUnits: value, formatted: "\(value) credits")
    }

    private func waitForRequest(_ backend: DeferredAccountBackend) async throws {
        for _ in 0..<1_000 {
            if backend.profileContinuation != nil { return }
            await Task.yield()
        }
        try #require(backend.profileContinuation != nil, "Profile request did not start")
    }

    @Test func profileResponseCannotRestoreSignedOutAccount() async throws {
        let backend = DeferredAccountBackend()
        let account = AccountStore(backend: backend)
        account.apply(auth: auth("A"))
        defer { account.signOut() }
        let refresh = Task { await account.refresh() }
        try await waitForRequest(backend)
        account.signOut()
        backend.profileContinuation?.resume(returning: MeResponse(user: auth("A").user, balance: payload(999)))
        await refresh.value
        #expect(!account.isSignedIn)
        #expect(account.userID.isEmpty)
        #expect(account.balanceUSDMicros == 0)
        #expect(SharedAccountStore.balanceText.isEmpty)
    }

    @Test func oldProfileCannotOverwriteAnotherAccount() async throws {
        let backend = DeferredAccountBackend()
        let account = AccountStore(backend: backend)
        account.apply(auth: auth("A"))
        defer { account.signOut() }
        let refresh = Task { await account.refresh() }
        try await waitForRequest(backend)
        account.signOut()
        account.apply(auth: auth("B", balance: 200))
        backend.profileContinuation?.resume(returning: MeResponse(user: auth("A").user, balance: payload(999)))
        await refresh.value
        #expect(account.userID == auth("B").user.id)
        #expect(account.balanceUSDMicros == 200)
        #expect(account.email == "B@example.invalid")
    }

    @Test func staleRefreshCannotUndoPurchaseBalance() async throws {
        let backend = DeferredAccountBackend()
        let account = AccountStore(backend: backend)
        account.apply(auth: auth("A"))
        defer { account.signOut() }
        let refresh = Task { await account.refresh() }
        try await waitForRequest(backend)
        account.apply(balance: payload(500))
        backend.profileContinuation?.resume(returning: MeResponse(user: auth("A").user, balance: payload(100)))
        await refresh.value
        #expect(account.balanceUSDMicros == 500)
    }

    @Test func olderProfileCannotOverwriteNewerProfile() async throws {
        let backend = DeferredAccountBackend()
        let account = AccountStore(backend: backend)
        account.apply(auth: auth("A"))
        defer { account.signOut() }
        let older = Task { await account.refresh() }
        try await waitForRequest(backend)
        let olderResponse = try #require(backend.profileContinuation)
        backend.profileContinuation = nil
        let newer = Task { await account.refresh() }
        try await waitForRequest(backend)
        backend.profileContinuation?.resume(returning: MeResponse(user: auth("A").user, balance: payload(200)))
        await newer.value
        olderResponse.resume(returning: MeResponse(user: auth("A").user, balance: payload(100)))
        await older.value
        #expect(account.balanceUSDMicros == 200)
    }

    @Test func completedMutationInvalidatesPendingProfileAndFetchesCurrentBalance() async throws {
        let backend = DeferredAccountBackend()
        let account = AccountStore(backend: backend)
        account.apply(auth: auth("A"))
        defer { account.signOut() }
        let older = Task { await account.refresh() }
        try await waitForRequest(backend)
        let olderResponse = try #require(backend.profileContinuation)
        backend.profileContinuation = nil
        account.scheduleBalanceRefresh()
        try await waitForRequest(backend)
        olderResponse.resume(returning: MeResponse(user: auth("A").user, balance: payload(50)))
        await older.value
        #expect(account.balanceUSDMicros == 100)
        backend.profileContinuation?.resume(returning: MeResponse(user: auth("A").user, balance: payload(700)))
        for _ in 0..<1_000 {
            if account.balanceUSDMicros == 700 { break }
            await Task.yield()
        }
        #expect(account.balanceUSDMicros == 700)
    }

    @Test func expiredTokenReturnsToSignIn() async throws {
        let backend = DeferredAccountBackend()
        let account = AccountStore(backend: backend)
        account.apply(auth: auth("A"))
        defer { account.signOut() }
        let refresh = Task { await account.refresh() }
        try await waitForRequest(backend)
        backend.profileContinuation?.resume(throwing: BackendClientError.httpError(status: 401, message: "Expired", context: .general))
        await refresh.value
        #expect(!account.isSignedIn)
        #expect(account.errorMessage != nil)
    }

    @Test func expiredAuthenticationHidesPaidTranscriptAndRestoresOnlyAfterOwnerSignsInAgain() async throws {
        let backend = DeferredAccountBackend()
        let account = AccountStore(backend: backend)
        account.apply(auth: auth("A"))
        let transcript = TranscriptSnapshot(id: "paid-result", text: "Keep my completed transcription", createdAt: Date(), chargeText: "20 credits")
        SharedTranscriptStore.latest = transcript
        let refresh = Task { await account.refresh() }
        try await waitForRequest(backend)
        backend.profileContinuation?.resume(throwing: BackendClientError.httpError(status: 401, message: "Expired", context: .general))
        await refresh.value
        #expect(SharedTranscriptStore.latest.text.isEmpty)
        #expect(SharedTranscriptStore.history.isEmpty)
        // The private owner-bound copy also survives an application restart.
        let relaunched = AccountStore(backend: DeferredAccountBackend())
        defer { relaunched.signOut() }
        #expect(!relaunched.isSignedIn)
        #expect(SharedTranscriptStore.latest.text.isEmpty)
        relaunched.apply(auth: auth("A"))
        #expect(SharedTranscriptStore.latest.id == transcript.id)
        #expect(SharedTranscriptStore.latest.text == transcript.text)
        #expect(SharedTranscriptStore.history.map(\.id) == [transcript.id])
    }

    @Test func anotherAccountCannotRestoreExpiredOwnersTranscriptHistory() {
        let account = AccountStore(backend: DeferredAccountBackend())
        account.apply(auth: auth("A"))
        defer { account.signOut() }
        SharedTranscriptStore.latest = TranscriptSnapshot(id: "private-A", text: "Owner A only", createdAt: Date(), chargeText: nil)
        account.signOut(preservePendingRecording: true)
        account.apply(auth: auth("B"))
        #expect(SharedTranscriptStore.latest.text.isEmpty)
        #expect(SharedTranscriptStore.history.isEmpty)
        account.signOut()
        account.apply(auth: auth("A"))
        #expect(SharedTranscriptStore.history.isEmpty)
    }

    @Test func missingKeychainTokenOnLaunchPreservesKnownOwnersHistoryForReauthentication() {
        let account = AccountStore(backend: DeferredAccountBackend())
        account.apply(auth: auth("A"))
        SharedTranscriptStore.latest = TranscriptSnapshot(id: "paid-before-restart", text: "Do not lose my transcript", createdAt: Date(), chargeText: nil)
        KeychainStore.delete(service: "com.kyleqi.voicetype.account", account: "userToken")
        let relaunched = AccountStore(backend: DeferredAccountBackend())
        defer { relaunched.signOut() }
        #expect(!relaunched.isSignedIn)
        #expect(SharedTranscriptStore.history.isEmpty)
        relaunched.apply(auth: auth("A"))
        #expect(SharedTranscriptStore.latest.id == "paid-before-restart")
    }

    @Test func explicitSignOutDiscardsAnyRetainedTranscriptHistory() {
        let account = AccountStore(backend: DeferredAccountBackend())
        account.apply(auth: auth("A"))
        defer { account.signOut() }
        SharedTranscriptStore.latest = TranscriptSnapshot(id: "private-A", text: "Owner A only", createdAt: Date(), chargeText: nil)
        account.signOut(preservePendingRecording: true)
        account.signOut()
        account.apply(auth: auth("A"))
        #expect(SharedTranscriptStore.latest.text.isEmpty)
        #expect(SharedTranscriptStore.history.isEmpty)
    }

    @Test func sameUserSigningInAgainInvalidatesPreviousSession() {
        let account = AccountStore(backend: DeferredAccountBackend())
        account.apply(auth: auth("A"))
        defer { account.signOut() }
        let originalSession = account.sessionID
        let originalToken = account.token
        account.signOut()
        account.apply(auth: auth("A"))
        #expect(!account.matchesSession(originalSession, token: originalToken))
        #expect(account.matchesSession(account.sessionID, token: account.token))
    }

    @Test func unavailableDeletionPreservesAccountAndCredit() async {
        let account = AccountStore(backend: DeferredAccountBackend())
        account.apply(auth: auth("A", balance: 500))
        defer { account.signOut() }
        await account.deleteAccount()
        #expect(account.isSignedIn)
        #expect(account.balanceUSDMicros == 500)
        #expect(account.errorMessage != nil)
        #expect(!account.isLoading)
    }

    @Test func purchasePolicyRejectsOtherAccountsRevokedAndUnknownProducts() {
        let owner = UUID()
        let product = ProductIDs.all[0]
        #expect(StoreKitTransactionPolicy.canCredit(productID: product, transactionAccount: owner, signedInAccount: owner, isRevoked: false))
        #expect(!StoreKitTransactionPolicy.canCredit(productID: product, transactionAccount: owner, signedInAccount: UUID(), isRevoked: false))
        #expect(!StoreKitTransactionPolicy.canCredit(productID: product, transactionAccount: nil, signedInAccount: owner, isRevoked: false))
        #expect(!StoreKitTransactionPolicy.canCredit(productID: product, transactionAccount: owner, signedInAccount: nil, isRevoked: false))
        #expect(!StoreKitTransactionPolicy.canCredit(productID: product, transactionAccount: owner, signedInAccount: owner, isRevoked: true))
        #expect(!StoreKitTransactionPolicy.canCredit(productID: "unrelated.product", transactionAccount: owner, signedInAccount: owner, isRevoked: false))
    }

    @Test func purchaseWithoutAnAccountTokenIsNotBlamedOnAnotherAccount() throws {
        let owner = UUID()
        #expect(StoreKitTransactionPolicy.refusal(transactionAccount: owner, signedInAccount: UUID()) == .differentAccount)
        // No account can claim it, so it doesn't matter whether the ID has loaded.
        #expect(StoreKitTransactionPolicy.refusal(transactionAccount: nil, signedInAccount: nil) == .unlinkedPurchase)
        let unlinked = StoreKitTransactionPolicy.refusal(transactionAccount: nil, signedInAccount: owner)
        #expect(unlinked == .unlinkedPurchase)
        let message = try #require(unlinked.errorDescription)
        #expect(message.contains("isn't linked to a VoiceType account"))
        #expect(!message.contains("another"))
    }

    @Test func purchaseIsNotBlamedOnAnotherAccountWhileTheSignedInAccountIDIsUnknown() async throws {
        // Deleting the app clears UserDefaults but keeps the Keychain sign-in, so
        // a reinstall stays signed in without an ID until a profile request succeeds.
        let original = AccountStore(backend: DeferredAccountBackend())
        original.apply(auth: auth("A"))
        UserDefaults.standard.removeObject(forKey: "accountUserID")
        let backend = DeferredAccountBackend()
        let account = AccountStore(backend: backend)
        defer { account.signOut() }
        let refresh = Task { await account.refresh() }
        try await waitForRequest(backend)
        backend.profileContinuation?.resume(throwing: URLError(.notConnectedToInternet))
        await refresh.value
        #expect(account.isSignedIn)
        #expect(account.appAccountToken == nil)

        let purchase = try #require(UUID(uuidString: auth("A").user.id))
        let notLoaded = StoreKitTransactionPolicy.refusal(transactionAccount: purchase, signedInAccount: account.appAccountToken)
        #expect(notLoaded == .accountNotLoaded)
        let message = try #require(notLoaded.errorDescription)
        #expect(message.contains("hasn't loaded yet"))
        #expect(message.contains("check purchases again"))
        #expect(message.contains("do not need to buy it again"))
        #expect(!message.contains("another"))
        #expect(!message.localizedCaseInsensitiveContains("sign in"))
    }

    @Test func checkingPurchasesLoadsAMissingAccountIDBeforeMatchingThem() async {
        let original = AccountStore(backend: DeferredAccountBackend())
        original.apply(auth: auth("A"))
        UserDefaults.standard.removeObject(forKey: "accountUserID")
        let backend = LoadedAccountBackend(MeResponse(user: auth("A").user, balance: payload(100)))
        let account = AccountStore(backend: backend)
        defer { account.signOut() }
        let store = StoreKitService()
        await store.checkPurchases(account: account)
        // One request loads the ID for matching; the other is the usual balance
        // refresh after the check.
        #expect(backend.profileRequests == 2)
        #expect(account.appAccountToken == UUID(uuidString: auth("A").user.id))
    }

    @Test func buyingWhileTheAccountIDCanNotLoadAsksForAConnectionInsteadOfASignIn() async throws {
        let original = AccountStore(backend: DeferredAccountBackend())
        original.apply(auth: auth("A"))
        UserDefaults.standard.removeObject(forKey: "accountUserID")
        let backend = DeferredAccountBackend()
        let account = AccountStore(backend: backend)
        defer { account.signOut() }
        let store = StoreKitService()
        let load = Task { await store.loadPurchaseAccount(account, session: account.sessionID, token: account.token) }
        try await waitForRequest(backend)
        backend.profileContinuation?.resume(throwing: URLError(.notConnectedToInternet))
        let loaded = await load.value
        #expect(loaded == nil)
        #expect(account.isSignedIn)
        let message = try #require(store.errorMessage)
        #expect(message.contains("hasn't loaded yet"))
        #expect(!message.localizedCaseInsensitiveContains("sign in"))
    }

    @Test func buyingAfterTheSessionExpiresAsksToSignInAgain() async throws {
        let original = AccountStore(backend: DeferredAccountBackend())
        original.apply(auth: auth("A"))
        UserDefaults.standard.removeObject(forKey: "accountUserID")
        let backend = DeferredAccountBackend()
        let account = AccountStore(backend: backend)
        defer { account.signOut() }
        let store = StoreKitService()
        let load = Task { await store.loadPurchaseAccount(account, session: account.sessionID, token: account.token) }
        try await waitForRequest(backend)
        backend.profileContinuation?.resume(throwing: BackendClientError.httpError(status: 401, message: "Expired", context: .general))
        let loaded = await load.value
        #expect(loaded == nil)
        #expect(!account.isSignedIn)
        #expect(store.errorMessage == "Sign in again before adding credit.")
    }

    @Test func backendErrorsShowServiceDetailButNeverProxyPages() {
        #expect(BackendClient.backendMessage(from: Data(#"{"detail":"Unsupported transcription model: x"}"#.utf8))
            == "Unsupported transcription model: x")
        let proxyPage = Data("<!DOCTYPE html><html><title>Gateway time-out</title></html>".utf8)
        #expect(BackendClient.backendMessage(from: proxyPage).isEmpty)
        let forbidden = BackendClientError.httpError(status: 403, message: BackendClient.backendMessage(from: proxyPage), context: .general)
        #expect(forbidden.errorDescription == "Backend error 403.")
        let timeout = BackendClientError.httpError(status: 524, message: "", context: .general)
        #expect(timeout.errorDescription == "The service is temporarily unavailable. Please try again in a moment.")
        let silent = BackendClientError.httpError(status: 422, message: "No speech was detected in this recording. Nothing was charged.", context: .general)
        #expect(silent.errorDescription == "No speech was detected in this recording. Nothing was charged.")
        // An older backend sends no code, so its silent clip stays in History.
        #expect(!silent.isNoSpeech)

        let coded = Data(#"{"detail":"No speech was detected in this recording. Nothing was charged.","code":"no_speech"}"#.utf8)
        #expect(BackendClient.backendErrorCode(from: coded) == "no_speech")
        let noSpeech = BackendClientError.httpError(status: 422, message: BackendClient.backendMessage(from: coded),
                                                    context: .general, code: BackendClient.backendErrorCode(from: coded))
        #expect(noSpeech.isNoSpeech)
        #expect(noSpeech.errorDescription == silent.errorDescription)
        #expect(BackendClient.backendErrorCode(from: Data(#"{"detail":"Unsupported transcription model: x"}"#.utf8)) == nil)
        #expect(BackendClient.backendErrorCode(from: proxyPage) == nil)
        // A code of an unexpected type is ignored and never hides the detail.
        let numericCode = Data(#"{"detail":"Busy","code":7}"#.utf8)
        #expect(BackendClient.backendMessage(from: numericCode) == "Busy")
        #expect(BackendClient.backendErrorCode(from: numericCode) == nil)
        #expect(!BackendClientError.httpError(status: 422, message: "", context: .general, code: "other").isNoSpeech)
        #expect(!BackendClientError.invalidResponse.isNoSpeech)
    }
}

@MainActor
private final class DeferredAccountBackend: AccountBackend {
    var profileContinuation: CheckedContinuation<MeResponse, Error>?

    func me(token: String) async throws -> MeResponse {
        try await withCheckedThrowingContinuation { profileContinuation = $0 }
    }

    func signInWithApple(identityToken: String, authorizationCode: String?, email: String?, fullName: String?) async throws -> AuthResponse {
        throw BackendClientError.invalidResponse
    }

    func deleteAccount(token: String) async throws {
        throw BackendClientError.httpError(status: 503, message: "Revocation temporarily unavailable", context: .general)
    }
}

@MainActor
private final class LoadedAccountBackend: AccountBackend {
    let profile: MeResponse
    private(set) var profileRequests = 0

    init(_ profile: MeResponse) {
        self.profile = profile
    }

    func me(token: String) async throws -> MeResponse {
        profileRequests += 1
        return profile
    }

    func signInWithApple(identityToken: String, authorizationCode: String?, email: String?, fullName: String?) async throws -> AuthResponse {
        throw BackendClientError.invalidResponse
    }

    func deleteAccount(token: String) async throws {
        throw BackendClientError.invalidResponse
    }
}
