import Foundation

@MainActor
final class AccountStore: ObservableObject {
    private let keychainService = "com.kyleqi.voicetype.account"
    private let tokenAccount = "userToken"
    private let emailKey = "accountEmail"

    @Published private(set) var token: String
    @Published private(set) var email: String
    @Published private(set) var balanceText: String
    @Published private(set) var balanceUSDMicros: Int
    @Published var errorMessage: String?
    @Published var isLoading = false

    var isSignedIn: Bool {
        !token.isEmpty
    }

    init() {
        token = KeychainStore.read(service: keychainService, account: tokenAccount) ?? ""
        email = UserDefaults.standard.string(forKey: emailKey) ?? ""
        balanceText = "$0.0000"
        balanceUSDMicros = 0
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
        guard isSignedIn else { return }
        do {
            let payload = try await BackendClient.me(token: token)
            apply(balance: payload.balance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func apply(auth: AuthResponse) {
        token = auth.token
        email = auth.user.email ?? email
        KeychainStore.save(auth.token, service: keychainService, account: tokenAccount)
        if let userEmail = auth.user.email {
            UserDefaults.standard.set(userEmail, forKey: emailKey)
        }
        apply(balance: auth.balance)
    }

    func apply(balance: BalancePayload) {
        balanceUSDMicros = balance.balanceUSDMicros
        balanceText = balance.formatted
    }

    func signOut() {
        token = ""
        email = ""
        balanceText = "$0.0000"
        balanceUSDMicros = 0
        KeychainStore.delete(service: keychainService, account: tokenAccount)
        UserDefaults.standard.removeObject(forKey: emailKey)
    }
}

struct MeResponse: Decodable {
    let user: UserProfile
    let balance: BalancePayload
}
