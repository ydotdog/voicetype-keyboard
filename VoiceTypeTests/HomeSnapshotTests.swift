import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import VoiceType

/// Renders the production screens with inert, test-only data and callbacks.
/// No authentication, microphone action, or live service is invoked.
@MainActor
final class HomeSnapshotTests: XCTestCase {
    func testCaptureHome() async throws {
        let savedBalance = SharedAccountStore.balanceText
        defer { SharedAccountStore.balanceText = savedBalance }
        let account = AccountStore(backend: SnapshotAccountBackend())
        account.apply(balance: BalancePayload(balanceUSDMicros: 1_000_000, balanceCreditUnits: 100_000, formatted: "100,000 credits"))
        let recovery = FileManager.default.temporaryDirectory.appendingPathComponent("home-snapshot-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: recovery) }
        let recorder = RecordingController(recoveryDirectory: recovery, permissionRequest: { false }, audioSessionActivation: {})
        let store = StoreKitService()
        for (suffix, width, height, scheme) in [
            ("current", CGFloat(430), CGFloat(880), ColorScheme.light),
            ("narrow", CGFloat(320), CGFloat(700), ColorScheme.light),
            ("dark", CGFloat(430), CGFloat(880), ColorScheme.dark),
        ] {
            try await capture(HomeScreen(account: account, recorder: recorder), tab: .home, name: "home-\(suffix)", width: width, height: height, scheme: scheme)
            try await capture(CreditScreen(store: store, account: account), tab: .credit, name: "credit-\(suffix)", width: width, height: height, scheme: scheme)
        }
    }

    func testCaptureHistory() async throws {
        let now = Date()
        let firstID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let secondID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let failed = [
            FailedTranscriptionSnapshot(id: firstID, createdAt: now.addingTimeInterval(-60), duration: 12.4),
            FailedTranscriptionSnapshot(id: secondID, createdAt: now.addingTimeInterval(-360), duration: 42),
        ]
        let history = [TranscriptSnapshot(
            id: "snapshot-success",
            text: "Let's meet at ten tomorrow. I'll bring the notes.",
            createdAt: now.addingTimeInterval(-180),
            chargeText: "27 credits"
        )]

        for (suffix, width, height, scheme) in [
            ("current", CGFloat(430), CGFloat(880), ColorScheme.light),
            ("narrow", CGFloat(320), CGFloat(700), ColorScheme.light),
            ("dark", CGFloat(430), CGFloat(880), ColorScheme.dark),
        ] {
            for isRetrying in [false, true] {
                let content = HistoryContent(
                    history: history,
                    failedTranscriptions: failed,
                    retryingTranscriptionID: isRetrying ? firstID : nil,
                    retryErrorMessage: nil,
                    isSignedIn: true,
                    copy: { _ in }, retry: { _ in }, delete: { _ in }
                )
                try await capture(content, tab: .history, name: "history-\(isRetrying ? "retrying" : "saved")-\(suffix)", width: width, height: height, scheme: scheme)
            }
        }

        let errorContent = HistoryContent(
            history: [], failedTranscriptions: failed, retryingTranscriptionID: nil,
            retryErrorMessage: "Couldn't connect. Your recordings are still saved; try again when you're online.",
            isSignedIn: true, copy: { _ in }, retry: { _ in }, delete: { _ in }
        )
        try await capture(errorContent, tab: .history, name: "history-error-narrow", width: 320, height: 700, scheme: .light)

        let longHistory = history + [TranscriptSnapshot(
            id: "snapshot-long",
            text: "下周一上午十点和设计团队过一遍新版键盘的交互稿，重点看粘贴按钮的位置和录音状态的提示。会后把结论整理成文档发给大家，周三之前确认是否进入开发排期。Remember to invite Priya from the QA team.",
            createdAt: now.addingTimeInterval(-240),
            chargeText: "112 credits"
        )]
        let defaults = UserDefaults.standard
        let savedDisplay = defaults.object(forKey: HistoryDisplay.fullTextKey)
        defer {
            if let savedDisplay {
                defaults.set(savedDisplay, forKey: HistoryDisplay.fullTextKey)
            } else {
                defaults.removeObject(forKey: HistoryDisplay.fullTextKey)
            }
        }
        for showsFullText in [false, true] {
            defaults.set(showsFullText, forKey: HistoryDisplay.fullTextKey)
            let content = HistoryContent(
                history: longHistory, failedTranscriptions: [], retryingTranscriptionID: nil,
                retryErrorMessage: nil, isSignedIn: true, copy: { _ in }, retry: { _ in }, delete: { _ in }
            )
            try await capture(content, tab: .history, name: "history-\(showsFullText ? "full" : "preview")-narrow",
                              width: 320, height: 760, scheme: .light)
        }
    }

    func testCaptureDictationSettingsAndCorrection() async throws {
        let userID = "snapshot-dictation-\(UUID().uuidString)"
        var preferences = DictationPreferences()
        preferences.toggle(.simplifiedChinese)
        preferences.toggle(.english)
        preferences.remember("龚玥", learned: true, heardAs: "工月")
        preferences.teach("龚月", to: DictationPreferences.key("龚玥"))
        preferences.remember("Kyle Qi", learned: true)
        preferences.remember("VoiceType")
        DictationPreferencesStore.save(preferences, userID: userID)
        // A new account, so neither fix is already saved.
        let learnerID = "snapshot-correction-\(UUID().uuidString)"
        DictationPreferencesStore.save(DictationPreferences(languages: preferences.languages), userID: learnerID)
        defer {
            DictationPreferencesStore.clear(userID: userID)
            DictationPreferencesStore.clear(userID: learnerID)
        }
        let snapshot = TranscriptSnapshot(id: "preview", text: "明天和工月在曲周见面。", createdAt: Date(), chargeText: nil)
        for (suffix, width, scheme) in [("narrow", CGFloat(320), ColorScheme.light), ("dark", CGFloat(430), ColorScheme.dark)] {
            try await capture(DictationSettingsView(userID: userID), tab: .settings,
                name: "dictation-\(suffix)", width: width, height: 880, scheme: scheme, standalone: true)
            // Suggestions are computed off the main thread after the view appears.
            try await capture(TranscriptCorrectionView(snapshot: snapshot, userID: learnerID, draft: "明天和龚玥在衢州见面。", onSave: {}), tab: .history,
                name: "correction-\(suffix)", width: width, height: 880, scheme: scheme, standalone: true, delay: .seconds(2))
        }
    }

    func testCaptureTranscriptionModels() async throws {
        let userID = "snapshot-models-\(UUID().uuidString)"
        var preferences = DictationPreferences()
        preferences.model = "gpt-transcribe"
        DictationPreferencesStore.save(preferences, userID: userID)
        defer { DictationPreferencesStore.clear(userID: userID) }
        func option(_ id: String, _ name: String, recommended: Bool = false, credits: Int, retiresOn: String? = nil) -> TranscriptionModelOption {
            TranscriptionModelOption(id: id, name: name, recommended: recommended, streaming: id != "whisper-1", retiresOn: retiresOn,
                                     pricingBasis: "duration", creditUnitsPerMinute: credits,
                                     formattedPerMinute: "\(credits.formatted()) credits/min")
        }
        let catalog = TranscriptionModelCatalog(defaultModel: "gpt-4o-mini-transcribe", defaultModelName: "GPT-4o mini Transcribe", models: [
            option("gpt-transcribe", "GPT Transcribe", recommended: true, credits: 7_715),
            option("gpt-4o-mini-transcribe", "GPT-4o mini Transcribe", credits: 5_143, retiresOn: "2027-02-26"),
            option("gpt-4o-transcribe", "GPT-4o Transcribe", credits: 10_286, retiresOn: "2027-02-26"),
            option("whisper-1", "Whisper", credits: 10_286, retiresOn: "2027-02-26"),
        ])
        for (suffix, width, scheme) in [("narrow", CGFloat(320), ColorScheme.light), ("dark", CGFloat(430), ColorScheme.dark)] {
            try await capture(TranscriptionModelSettingsView(userID: userID, catalog: catalog, refreshCatalog: { catalog }), tab: .settings,
                name: "models-\(suffix)", width: width, height: 880, scheme: scheme, standalone: true)
        }
        try await capture(TranscriptionModelSettingsView(userID: userID, catalog: nil, refreshCatalog: { nil }), tab: .settings,
            name: "models-unavailable-narrow", width: 320, height: 700, scheme: .light, standalone: true)

        preferences.mode = .live
        DictationPreferencesStore.save(preferences, userID: userID)
        func live(_ id: String, _ name: String, recommended: Bool = false, timing: String, credits: Int) -> RealtimeTranscriptionModel {
            RealtimeTranscriptionModel(id: id, name: name, recommended: recommended, liveOnly: id == "gpt-live-transcribe",
                                       textTiming: timing, retiresOn: nil, pricingBasis: "audio_minutes", creditUnitsPerMinute: credits,
                                       formattedPerMinute: "\(credits.formatted()) credits/min")
        }
        let liveCatalog = TranscriptionModelCatalog(
            defaultModel: catalog.defaultModel, defaultModelName: catalog.defaultModelName, models: catalog.models,
            realtime: RealtimeTranscriptionCatalog(available: true, defaultModel: "gpt-live-transcribe", models: [
                live("gpt-live-transcribe", "GPT Live Transcribe", recommended: true, timing: "while_speaking", credits: 29_144),
                live("gpt-transcribe", "GPT Transcribe", timing: "after_pauses", credits: 7_715),
            ])
        )
        for (suffix, width, scheme) in [("narrow", CGFloat(320), ColorScheme.light), ("dark", CGFloat(430), ColorScheme.dark)] {
            try await capture(TranscriptionModelSettingsView(userID: userID, catalog: liveCatalog, refreshCatalog: { liveCatalog }), tab: .settings,
                name: "models-live-\(suffix)", width: width, height: 1500, scheme: scheme, standalone: true)
        }
        // An older or switched-off service: Live explains that it uploads.
        try await capture(TranscriptionModelSettingsView(userID: userID, catalog: catalog, refreshCatalog: { catalog }), tab: .settings,
            name: "models-live-unavailable-narrow", width: 320, height: 880, scheme: .light, standalone: true)
    }

    func testCaptureNativeSettings() async throws {
        let account = AccountStore(backend: SnapshotAccountBackend())
        let store = StoreKitService()
        for (suffix, width, scheme, typeSize) in [
            ("phone", CGFloat(390), ColorScheme.light, DynamicTypeSize.large),
            ("narrow", CGFloat(320), ColorScheme.light, DynamicTypeSize.large),
            ("dark", CGFloat(390), ColorScheme.dark, DynamicTypeSize.large),
            ("accessibility", CGFloat(390), ColorScheme.light, DynamicTypeSize.accessibility3),
        ] {
            let tabs = VoiceTypeTabs(selection: .constant(.settings)) { _ in
                SettingsScreen(account: account, store: store, openKeyboardSetup: {})
            }
            try await capture(tabs, tab: .settings, name: "settings-\(suffix)", width: width,
                              height: 844, scheme: scheme, standalone: true, typeSize: typeSize)
        }
    }

    func testCaptureMicStatesAndAdaptiveLayout() async throws {
        for (suffix, width, height, scheme, typeSize) in [
            ("phone", CGFloat(390), CGFloat(844), ColorScheme.light, DynamicTypeSize.large),
            ("narrow", CGFloat(320), CGFloat(700), ColorScheme.light, DynamicTypeSize.large),
            ("wide", CGFloat(760), CGFloat(800), ColorScheme.light, DynamicTypeSize.large),
            ("landscape", CGFloat(844), CGFloat(390), ColorScheme.light, DynamicTypeSize.large),
            ("accessibility", CGFloat(390), CGFloat(1000), ColorScheme.light, DynamicTypeSize.accessibility3),
            ("dark", CGFloat(390), CGFloat(844), ColorScheme.dark, DynamicTypeSize.large),
        ] {
            for state in HomeMicState.allCases {
                let content = HomeContent(micState: state, elapsedSeconds: 65,
                                          durationLimit: .constant(.fiveMinutes),
                                          isBusy: state == .starting || state == .transcribing,
                                          hasNegativeBalance: false, errorMessage: nil, toggleMic: {})
                try await capture(content, tab: .home, name: "mic-\(state)-\(suffix)",
                                  width: width, height: height, scheme: scheme, typeSize: typeSize)
            }
        }
    }

    /// Approximate iPhone Duo window sizes in points: closed, open in portrait,
    /// open in landscape, and half of the open display in each orientation.
    /// Apple publishes no point sizes. These are its App Store screenshot sizes
    /// (1398 × 2034 px for the outer display, 2007 × 2853 px for the inner one)
    /// divided by 3. The simulator here has no iPhone Duo, so these check how
    /// the layouts respond to the sizes, not to the device.
    private static let duoSizes: [(name: String, width: CGFloat, height: CGFloat)] = [
        ("duo-closed", 466, 678),
        ("duo-open-portrait", 669, 951),
        ("duo-open-landscape", 951, 669),
        ("duo-half-landscape", 475, 669),
        ("duo-half-portrait", 334, 951),
    ]

    func testCaptureIPhoneDuoSizes() async throws {
        let savedBalance = SharedAccountStore.balanceText
        defer { SharedAccountStore.balanceText = savedBalance }
        let account = AccountStore(backend: SnapshotAccountBackend())
        account.apply(balance: BalancePayload(balanceUSDMicros: 1_000_000, balanceCreditUnits: 100_000, formatted: "100,000 credits"))
        let store = StoreKitService()
        let now = Date()
        let history = HistoryContent(
            history: [TranscriptSnapshot(id: "snapshot-success", text: "Let's meet at ten tomorrow. I'll bring the notes.",
                                         createdAt: now.addingTimeInterval(-180), chargeText: "27 credits")],
            failedTranscriptions: [FailedTranscriptionSnapshot(id: UUID(), createdAt: now.addingTimeInterval(-60), duration: 12.4)],
            retryingTranscriptionID: nil, retryErrorMessage: nil, isSignedIn: true,
            copy: { _ in }, retry: { _ in }, delete: { _ in }
        )
        for size in Self.duoSizes {
            for state in [HomeMicState.ready, .recording] {
                let home = HomeContent(micState: state, elapsedSeconds: 65, durationLimit: .constant(.fiveMinutes),
                                       isBusy: false, hasNegativeBalance: false, errorMessage: nil, toggleMic: {})
                try await capture(home, tab: .home, name: "mic-\(state)-\(size.name)",
                                  width: size.width, height: size.height, scheme: .light)
            }
            try await capture(CreditScreen(store: store, account: account), tab: .credit, name: "credit-\(size.name)",
                              width: size.width, height: size.height, scheme: .light)
            try await capture(history, tab: .history, name: "history-\(size.name)",
                              width: size.width, height: size.height, scheme: .light)
            let settings = VoiceTypeTabs(selection: .constant(.settings)) { _ in
                SettingsScreen(account: account, store: store, openKeyboardSetup: {})
            }
            try await capture(settings, tab: .settings, name: "settings-\(size.name)",
                              width: size.width, height: size.height, scheme: .light, standalone: true)
        }
    }

    func testCaptureSignInAndKeyboardSetup() async throws {
        let account = AccountStore(backend: SnapshotAccountBackend())
        let phoneSizes: [(name: String, width: CGFloat, height: CGFloat)] = [
            ("phone", 390, 844), ("small", 375, 667), ("zoomed", 320, 568),
        ]
        for size in phoneSizes + Self.duoSizes {
            try await capture(SignInScreen(openKeyboardSetup: {}).environmentObject(account), tab: .home,
                              name: "signin-\(size.name)", width: size.width, height: size.height, scheme: .light, standalone: true)
            try await capture(KeyboardSetupScreen(close: {}), tab: .home,
                              name: "setup-\(size.name)", width: size.width, height: size.height, scheme: .light, standalone: true)
        }
        try await capture(SignInScreen(openKeyboardSetup: {}).environmentObject(account), tab: .home,
                          name: "signin-dark", width: 390, height: 844, scheme: .dark, standalone: true)
        try await capture(SignInScreen(openKeyboardSetup: {}).environmentObject(account), tab: .home,
                          name: "signin-accessibility", width: 390, height: 844, scheme: .light, standalone: true,
                          typeSize: .accessibility3)
    }

    /// The toast belongs to the tab's content, so it sits above the tab bar.
    func testCaptureToastInsideTab() async throws {
        let history = HistoryContent(
            history: [TranscriptSnapshot(id: "snapshot-success", text: "Let's meet at ten tomorrow. I'll bring the notes.",
                                         createdAt: Date().addingTimeInterval(-180), chargeText: "27 credits")],
            failedTranscriptions: [], retryingTranscriptionID: nil, retryErrorMessage: nil, isSignedIn: true,
            copy: { _ in }, retry: { _ in }, delete: { _ in }
        )
        let sizes: [(name: String, width: CGFloat, height: CGFloat)] = [("phone", 390, 844), ("duo-open-landscape", 951, 669)]
        for size in sizes {
            let tabs = VoiceTypeTabs(selection: .constant(.history)) { _ in
                TabPage { history }
                    .toast("Copied", bottomPadding: 16)
            }
            try await capture(tabs, tab: .history, name: "toast-\(size.name)",
                              width: size.width, height: size.height, scheme: .light, standalone: true)
        }
    }

    private func capture<Content: View>(_ content: Content, tab: VoiceTypeTab, name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme, standalone: Bool = false, typeSize: DynamicTypeSize = .large, delay: Duration = .milliseconds(200)) async throws {
        let maxWidth = pageWidth(for: tab)
        let screen = ZStack {
            AppTheme.background.ignoresSafeArea()
            if standalone {
                content
            } else {
                VoiceTypeTabs(selection: .constant(tab)) { _ in
                    TabPage(maxWidth: maxWidth) { content }
                }
            }
        }
        .environment(\.colorScheme, scheme)
        .environment(\.dynamicTypeSize, typeSize)
        .frame(width: width, height: height)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let hosting = UIHostingController(rootView: screen)
        hosting.safeAreaRegions = []
        hosting.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = hosting
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        hosting.view.frame = window.bounds
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        await Task.yield()
        try await Task.sleep(for: delay)
        hosting.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: hosting.view.bounds, format: format)
        let image = renderer.image { _ in
            XCTAssertTrue(hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true))
        }
        let data = try XCTUnwrap(image.pngData())
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("voicetype-\(name).png")
        try data.write(to: output, options: .atomic)
        print("UI_SNAPSHOT_PATH=\(output.path)")
        let attachment = XCTAttachment(image: image)
        attachment.name = "VoiceType \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The widest each tab's page grows in the app.
    private func pageWidth(for tab: VoiceTypeTab) -> CGFloat {
        switch tab {
        case .home, .credit: PageWidth.wide
        case .history, .settings: PageWidth.reading
        }
    }
}

@MainActor
private struct SnapshotAccountBackend: AccountBackend {
    enum UnexpectedCall: Error { case liveOperation }

    func signInWithApple(identityToken: String, authorizationCode: String?, email: String?, fullName: String?) async throws -> AuthResponse {
        throw UnexpectedCall.liveOperation
    }

    func me(token: String) async throws -> MeResponse {
        throw UnexpectedCall.liveOperation
    }

    func deleteAccount(token: String) async throws {
        throw UnexpectedCall.liveOperation
    }
}
