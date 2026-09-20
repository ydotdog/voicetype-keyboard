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
