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
                        appState.isRecorderPresented = true
                    }
                }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var isRecorderPresented = false
}
