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
                    if url.host == "record" || url.path == "/record" {
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        let autoStart = components?.queryItems?.contains {
                            $0.name == "autostart" && $0.value == "1"
                        } ?? false
                        appState.presentRecorder(autoStart: autoStart)
                    }
                }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var isRecorderPresented = false
    @Published private(set) var recorderRequestID = UUID()
    private(set) var shouldAutoStartRecorder = false

    func presentRecorder(autoStart: Bool) {
        shouldAutoStartRecorder = autoStart
        recorderRequestID = UUID()
        isRecorderPresented = true
    }

    func consumeRecorderAutoStart() -> Bool {
        let value = shouldAutoStartRecorder
        shouldAutoStartRecorder = false
        return value
    }
}
