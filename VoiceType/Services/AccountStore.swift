import Foundation

@MainActor
final class AccountStore: ObservableObject {
    static let previewToken = "local-preview-token"

    private let keychainService = "com.kyleqi.voicetype.account"
    private let tokenAccount = "userToken"
    private let emailKey = "accountEmail"
    private let userIDKey = "accountUserID"
    private let retainedTranscriptsKey = "accountRetainedTranscripts"
    private let backend: any AccountBackend
    private var balanceRevision: UInt64 = 0
    private var profileRequestRevision: UInt64 = 0
    private var balanceRefreshTask: Task<Void, Never>?

    @Published private(set) var sessionID = UUID()
    @Published private(set) var shouldDiscardPendingRecording = false

    @Published private(set) var token: String
    @Published private(set) var userID: String
    @Published private(set) var email: String
    @Published private(set) var balanceText: String
    @Published private(set) var balanceUSDMicros: Int
    @Published var errorMessage: String?
    @Published var isLoading = false

    var isSignedIn: Bool {
        !token.isEmpty
    }

    var isPreviewMode: Bool {
        token == Self.previewToken
    }

    var appAccountToken: UUID? {
        UUID(uuidString: userID)
    }

    deinit {
        balanceRefreshTask?.cancel()
    }

    init(backend: any AccountBackend = LiveAccountBackend()) {
        self.backend = backend
        let storedToken = KeychainStore.read(service: keychainService, account: tokenAccount) ?? ""
        if storedToken == Self.previewToken {
            KeychainStore.delete(service: keychainService, account: tokenAccount)
            UserDefaults.standard.removeObject(forKey: userIDKey)
            UserDefaults.standard.removeObject(forKey: emailKey)
            token = ""
            userID = ""
            email = ""
            balanceText = "0 credits"
            balanceUSDMicros = 0
        } else {
            token = storedToken
            userID = UserDefaults.standard.string(forKey: userIDKey) ?? ""
            email = UserDefaults.standard.string(forKey: emailKey) ?? ""
            balanceText = "0 credits"
            balanceUSDMicros = 0
        }
        SharedAccountStore.balanceText = token.isEmpty ? "" : balanceText
        if token.isEmpty {
            retainTranscriptsForAuthenticationExpiry()
            SharedTranscriptStore.clear()
        } else if !userID.isEmpty {
            restoreRetainedTranscripts(for: userID)
        }
    }

    func matchesSession(_ id: UUID, token expectedToken: String) -> Bool {
        sessionID == id && !token.isEmpty && token == expectedToken
    }

    func signInWithApple(identityToken: String, authorizationCode: String?, email: String?, fullName: String?) async {
        guard !isLoading else { return }
        let startingSession = sessionID
        isLoading = true
        errorMessage = nil
        defer { if sessionID == startingSession { isLoading = false } }

        do {
            let response = try await backend.signInWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                email: email,
                fullName: fullName
            )
            guard sessionID == startingSession, !Task.isCancelled else { return }
            apply(auth: response)
        } catch {
            guard sessionID == startingSession, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard isSignedIn, !isPreviewMode, !Task.isCancelled else { return }
        profileRequestRevision &+= 1
        let requestRevision = profileRequestRevision
        let requestSession = sessionID
        let requestToken = token
        let requestBalanceRevision = balanceRevision
        do {
            let payload = try await backend.me(token: requestToken)
            guard matchesSession(requestSession, token: requestToken),
                  profileRequestRevision == requestRevision, !Task.isCancelled else { return }
            apply(user: payload.user)
            if balanceRevision == requestBalanceRevision {
                apply(balance: payload.balance)
            }
            errorMessage = nil
        } catch {
            guard matchesSession(requestSession, token: requestToken),
                  profileRequestRevision == requestRevision, !Task.isCancelled else { return }
            if case BackendClientError.httpError(status: 401, message: _, context: .general) = error {
                signOut(preservePendingRecording: true)
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Mutation responses can arrive out of ledger order. Invalidate older
    /// profile reads and fetch the balance after the committed mutation instead
    /// of displaying a possibly older purchase/transcription response balance.
    func scheduleBalanceRefresh() {
        balanceRevision &+= 1
        profileRequestRevision &+= 1
        balanceRefreshTask?.cancel()
        balanceRefreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    #if DEBUG
    func grantDeveloperCreditIfAvailable(amountUSDMicros: Int = 20_000_000) async {
        guard isSignedIn, !isPreviewMode, balanceUSDMicros < 1_000_000 else { return }
        guard
            let key = Bundle.main.object(forInfoDictionaryKey: "VoiceTypeDevCreditKey") as? String,
            !key.isEmpty,
            !key.hasPrefix("$(")
        else {
            return
        }
        let requestSession = sessionID
        let requestToken = token

        do {
            _ = try await BackendClient.grantDevCredit(
                amountUSDMicros: amountUSDMicros,
                token: requestToken,
                key: key
            )
            guard matchesSession(requestSession, token: requestToken), !Task.isCancelled else { return }
            scheduleBalanceRefresh()
        } catch {
            guard matchesSession(requestSession, token: requestToken), !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
    #endif

    func apply(auth: AuthResponse) {
        balanceRefreshTask?.cancel()
        balanceRefreshTask = nil
        isLoading = false
        shouldDiscardPendingRecording = false
        sessionID = UUID()
        if userID != auth.user.id {
            SharedTranscriptStore.clear()
            KeyboardAutoInsertStore.clear()
        }
        token = auth.token
        userID = auth.user.id
        email = auth.user.email ?? ""
        KeychainStore.save(auth.token, service: keychainService, account: tokenAccount)
        UserDefaults.standard.set(auth.user.id, forKey: userIDKey)
        UserDefaults.standard.set(email, forKey: emailKey)
        restoreRetainedTranscripts(for: auth.user.id)
        apply(balance: auth.balance)
    }

    func apply(user: UserProfile) {
        userID = user.id
        email = user.email ?? email
        UserDefaults.standard.set(user.id, forKey: userIDKey)
        if let userEmail = user.email {
            UserDefaults.standard.set(userEmail, forKey: emailKey)
        }
    }

    func apply(balance: BalancePayload) {
        balanceRevision &+= 1
        balanceUSDMicros = balance.balanceUSDMicros
        balanceText = balance.formatted
        SharedAccountStore.balanceText = balanceText
    }

    func deleteAccount() async {
        guard !isLoading else { return }
        // Preview/local sessions have no server account; just clear local state.
        guard isSignedIn, !isPreviewMode else {
            DictationPreferencesStore.clear(userID: userID)
            signOut()
            return
        }
        isLoading = true
        errorMessage = nil
        let requestSession = sessionID
        let requestToken = token
        defer { if sessionID == requestSession { isLoading = false } }
        do {
            try await backend.deleteAccount(token: requestToken)
            guard matchesSession(requestSession, token: requestToken), !Task.isCancelled else { return }
            DictationPreferencesStore.clear(userID: userID)
            signOut()
        } catch {
            guard matchesSession(requestSession, token: requestToken), !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func signOut(preservePendingRecording: Bool = false) {
        balanceRefreshTask?.cancel()
        balanceRefreshTask = nil
        if preservePendingRecording {
            retainTranscriptsForAuthenticationExpiry()
        } else {
            UserDefaults.standard.removeObject(forKey: retainedTranscriptsKey)
        }
        shouldDiscardPendingRecording = !preservePendingRecording
        sessionID = UUID()
        isLoading = false
        errorMessage = nil
        token = ""
        userID = ""
        email = ""
        balanceText = "0 credits"
        balanceUSDMicros = 0
        SharedAccountStore.balanceText = ""
        SharedTranscriptStore.clear()
        KeyboardAutoInsertStore.clear()
        KeychainStore.delete(service: keychainService, account: tokenAccount)
        UserDefaults.standard.removeObject(forKey: userIDKey)
        UserDefaults.standard.removeObject(forKey: emailKey)
    }

    // Keep expired-session history outside the shared keyboard container. It is
    // hidden while signed out and restored only after the same owner signs in.
    private struct RetainedTranscripts: Codable {
        let userID: String
        let latest: TranscriptSnapshot
        let history: [TranscriptSnapshot]
    }

    private func retainTranscriptsForAuthenticationExpiry() {
        guard !userID.isEmpty else { return }
        let retained = RetainedTranscripts(
            userID: userID,
            latest: SharedTranscriptStore.latest,
            history: SharedTranscriptStore.history
        )
        guard !retained.latest.text.isEmpty || !retained.history.isEmpty,
              let data = try? JSONEncoder().encode(retained) else { return }
        UserDefaults.standard.set(data, forKey: retainedTranscriptsKey)
    }

    private func restoreRetainedTranscripts(for userID: String) {
        guard let data = UserDefaults.standard.data(forKey: retainedTranscriptsKey) else { return }
        defer { UserDefaults.standard.removeObject(forKey: retainedTranscriptsKey) }
        guard let retained = try? JSONDecoder().decode(RetainedTranscripts.self, from: data),
              retained.userID == userID else { return }
        SharedTranscriptStore.latest = retained.latest
        SharedTranscriptStore.history = retained.history
    }

    private static func formatCredits(_ credits: Int) -> String {
        "\(credits.formatted()) credits"
    }
}

struct MeResponse: Decodable {
    let user: UserProfile
    let balance: BalancePayload
}

@MainActor
protocol AccountBackend {
    func signInWithApple(identityToken: String, authorizationCode: String?, email: String?, fullName: String?) async throws -> AuthResponse
    func me(token: String) async throws -> MeResponse
    func deleteAccount(token: String) async throws
}

struct LiveAccountBackend: AccountBackend {
    func signInWithApple(identityToken: String, authorizationCode: String?, email: String?, fullName: String?) async throws -> AuthResponse {
        try await BackendClient.signInWithApple(identityToken: identityToken, authorizationCode: authorizationCode, email: email, fullName: fullName)
    }

    func me(token: String) async throws -> MeResponse {
        try await BackendClient.me(token: token)
    }

    func deleteAccount(token: String) async throws {
        try await BackendClient.deleteAccount(token: token)
    }
}
