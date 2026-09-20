import SwiftUI

@main
struct VoiceTypeApp: App {
    @StateObject private var account = AccountStore()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(account)
                .environmentObject(appState)
                .onOpenURL { url in
                    appState.handleIncomingURL(url)
                }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var keyboardMicRequestID: UUID?
    @Published private(set) var keyboardSetupRequestID: UUID?
    private let activationStore: KeyboardMicActivationStore
    private let uptime: @MainActor () -> TimeInterval
    private var keyboardMicRequestedAt: TimeInterval?
    private var lastAcceptedActivationURL: URL?

    init(
        activationStore: KeyboardMicActivationStore = .shared,
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.activationStore = activationStore
        self.uptime = uptime
    }

    var hasPendingKeyboardMicAutoStart: Bool {
        guard let keyboardMicRequestedAt else { return false }
        let elapsed = uptime() - keyboardMicRequestedAt
        return elapsed.isFinite && elapsed >= 0 && elapsed < 120
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == AppConstants.appURLScheme else { return }
        let route = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Public links only reveal controls. The keyboard's native Link carries
        // a short-lived App Group capability to request one background session.
        switch route {
        // Legacy clip links now lead to the keyboard microphone controls.
        case "record": presentKeyboardMic(autoStart: false)
        case "keyboard":
            // iOS can deliver the same open again before the first foreground
            // handler consumes it. Do not cancel that pending user request.
            guard url != lastAcceptedActivationURL else { return }
            let shouldActivate = activationStore.consume(url, uptime: uptime())
            presentKeyboardMic(autoStart: shouldActivate)
            if shouldActivate { lastAcceptedActivationURL = url }
        case "keyboard-setup": presentKeyboardSetup()
        default: keyboardMicRequestedAt = nil
        }
    }

    func presentKeyboardMic(autoStart: Bool) {
        keyboardMicRequestedAt = autoStart ? uptime() : nil
        if !autoStart { lastAcceptedActivationURL = nil }
        keyboardMicRequestID = UUID()
    }

    func presentKeyboardSetup() {
        keyboardMicRequestedAt = nil
        lastAcceptedActivationURL = nil
        keyboardSetupRequestID = UUID()
    }

    func consumeKeyboardMicAutoStart() -> Bool {
        let value = hasPendingKeyboardMicAutoStart
        keyboardMicRequestedAt = nil
        return value
    }
}
