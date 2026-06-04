import Foundation

@MainActor
final class AccountStore: ObservableObject {
    static let previewToken = "local-preview-token"

    private let keychainService = "com.kyleqi.voicetype.account"
    private let tokenAccount = "userToken"
    private let emailKey = "accountEmail"
    private let userIDKey = "accountUserID"

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

    init() {
        let storedToken = KeychainStore.read(service: keychainService, account: tokenAccount) ?? ""
        token = storedToken
        if storedToken == Self.previewToken {
            userID = UUID().uuidString
            email = "Local preview"
            balanceText = "5,000,000 credits"
            balanceUSDMicros = 5_000_000
        } else {
            userID = UserDefaults.standard.string(forKey: userIDKey) ?? ""
            email = UserDefaults.standard.string(forKey: emailKey) ?? ""
            balanceText = "0 credits"
            balanceUSDMicros = 0
        }
        SharedAccountStore.balanceText = balanceText
    }

    func signInWithApple(identityToken: String, email: String?, fullName: String?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await BackendClient.signInWithApple(
                identityToken: identityToken,
                email: email,
                fullName: fullName
            )
            apply(auth: response)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard isSignedIn, !isPreviewMode else { return }
        do {
            let payload = try await BackendClient.me(token: token)
            apply(user: payload.user)
            apply(balance: payload.balance)
        } catch {
            errorMessage = error.localizedDescription
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

        do {
            let response = try await BackendClient.grantDevCredit(
                amountUSDMicros: amountUSDMicros,
                token: token,
                key: key
            )
            apply(balance: response.balance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    func apply(auth: AuthResponse) {
        token = auth.token
        userID = auth.user.id
        email = auth.user.email ?? email
        KeychainStore.save(auth.token, service: keychainService, account: tokenAccount)
        UserDefaults.standard.set(auth.user.id, forKey: userIDKey)
        if let userEmail = auth.user.email {
            UserDefaults.standard.set(userEmail, forKey: emailKey)
        }
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

    func enterPreviewMode() {
        token = Self.previewToken
        userID = UUID().uuidString
        email = "Local preview"
        balanceText = "5,000,000 credits"
        balanceUSDMicros = 5_000_000
        errorMessage = nil
        SharedAccountStore.balanceText = balanceText
        KeychainStore.save(token, service: keychainService, account: tokenAccount)
        UserDefaults.standard.set(userID, forKey: userIDKey)
        UserDefaults.standard.set(email, forKey: emailKey)
    }

    func addLocalTestCredit() {
        token = Self.previewToken
        if userID.isEmpty {
            userID = UUID().uuidString
        }
        email = "Local preview"
        balanceUSDMicros += 5_000_000
        balanceText = Self.formatCredits(balanceUSDMicros)
        errorMessage = nil
        SharedAccountStore.balanceText = balanceText
        KeychainStore.save(token, service: keychainService, account: tokenAccount)
        UserDefaults.standard.set(userID, forKey: userIDKey)
        UserDefaults.standard.set(email, forKey: emailKey)
    }

    func apply(balance: BalancePayload) {
        balanceUSDMicros = balance.balanceUSDMicros
        balanceText = balance.formatted
        SharedAccountStore.balanceText = balanceText
    }

    func signOut() {
        token = ""
        userID = ""
        email = ""
        balanceText = "0 credits"
        balanceUSDMicros = 0
        SharedAccountStore.balanceText = ""
        KeyboardAutoInsertStore.clear()
        KeychainStore.delete(service: keychainService, account: tokenAccount)
        UserDefaults.standard.removeObject(forKey: userIDKey)
        UserDefaults.standard.removeObject(forKey: emailKey)
    }

    private static func formatCredits(_ credits: Int) -> String {
        "\(credits.formatted()) credits"
    }
}

struct MeResponse: Decodable {
    let user: UserProfile
    let balance: BalancePayload
}
