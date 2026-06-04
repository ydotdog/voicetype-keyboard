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
                    guard url.scheme == AppConstants.appURLScheme else { return }
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let autoStart = components?.queryItems?.contains {
                        $0.name == "autostart" && $0.value == "1"
                    } ?? false
                    let route = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                    if route == "record" {
                        appState.presentRecorder(autoStart: autoStart)
                    } else if route == "keyboard" {
                        appState.presentKeyboardMic(autoStart: autoStart)
                    } else if route == "keyboard-setup" {
                        appState.presentKeyboardSetup()
                    }
                }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var isRecorderPresented = false
    @Published private(set) var keyboardMicRequestID: UUID?
    @Published private(set) var keyboardSetupRequestID: UUID?
    @Published private(set) var recorderRequestID = UUID()
    private(set) var shouldAutoStartRecorder = false
    private(set) var shouldAutoStartKeyboardMic = false

    func presentRecorder(autoStart: Bool) {
        shouldAutoStartRecorder = autoStart
        recorderRequestID = UUID()
        isRecorderPresented = true
    }

    func presentKeyboardMic(autoStart: Bool) {
        shouldAutoStartKeyboardMic = autoStart
        keyboardMicRequestID = UUID()
    }

    func presentKeyboardSetup() {
        keyboardSetupRequestID = UUID()
    }

    func consumeRecorderAutoStart() -> Bool {
        let value = shouldAutoStartRecorder
        shouldAutoStartRecorder = false
        return value
    }

    func consumeKeyboardMicAutoStart() -> Bool {
        let value = shouldAutoStartKeyboardMic
        shouldAutoStartKeyboardMic = false
        return value
    }
}
