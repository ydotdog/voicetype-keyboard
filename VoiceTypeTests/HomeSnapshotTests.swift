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

    /// The longest `testCaptureAtSceneSize` leaves each page on the simulator's
    /// screen while a script takes a screenshot of the display, from the
    /// environment variable `UI_ON_SCREEN_SECONDS`. Nil in a normal test run.
    private static let onScreenSeconds: Double? = ProcessInfo.processInfo.environment["UI_ON_SCREEN_SECONDS"].flatMap { Double($0) }

    /// Whether `testCaptureAtSceneSize` repeats its pages with the scene turned to
    /// landscape, from the environment variable `UI_TURN_SCENE`. False in a
    /// normal test run, so that no other test runs in a turned scene.
    private static let turnsScene = ProcessInfo.processInfo.environment["UI_TURN_SCENE"] == "1"

    /// Renders the pages in a window as large as the scene the system gave the
    /// app, with the system's safe areas. The sizes above imitate a device; this
    /// shows the pages the way the simulator the tests run on lays them out, in
    /// the posture and orientation it is in.
    func testCaptureAtSceneSize() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        try describe(scene, name: "scene")
        try await captureScenePages(in: scene, prefix: "scene")

        guard Self.turnsScene else { return }
        let turned = try await turn(scene, toLandscape: true)
        XCTAssertTrue(turned, "The scene did not turn to landscape.")
        if turned {
            try describe(scene, name: "scene-landscape")
            try await captureScenePages(in: scene, prefix: "scene-landscape")
        }
        _ = try await turn(scene, toLandscape: false)
    }

    /// Asks the system to turn the scene to landscape or back to portrait, the way
    /// it turns when the device is turned on its side, and waits until it has.
    /// Returns false when the scene has not turned in time.
    private func turn(_ scene: UIWindowScene, toLandscape landscape: Bool) async throws -> Bool {
        let orientations: UIInterfaceOrientationMask = landscape ? .landscapeRight : .portrait
        scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)) { @Sendable error in
            print("UI_SCENE the system refused to turn the scene: \(error)")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let size = scene.coordinateSpace.bounds.size
            if scene.effectiveGeometry.interfaceOrientation.isLandscape == landscape, (size.width > size.height) == landscape {
                // Lets the turn's animation end before a page is laid out.
                try await Task.sleep(for: .seconds(1))
                return true
            }
        }
        return false
    }

    /// Renders the app's pages in a window as large as `scene`. Each image is
    /// named `prefix` followed by its page.
    private func captureScenePages(in scene: UIWindowScene, prefix: String) async throws {
        let size = scene.coordinateSpace.bounds.size

        let savedBalance = SharedAccountStore.balanceText
        defer { SharedAccountStore.balanceText = savedBalance }
        let account = AccountStore(backend: SnapshotAccountBackend())
        account.apply(balance: BalancePayload(balanceUSDMicros: 1_000_000, balanceCreditUnits: 100_000, formatted: "100,000 credits"))
        let store = StoreKitService()
        let userID = "snapshot-scene-\(UUID().uuidString)"
        defer { DictationPreferencesStore.clear(userID: userID) }
        let transcript = TranscriptSnapshot(id: "snapshot-success", text: "Let's meet at ten tomorrow. I'll bring the notes.",
                                            createdAt: Date().addingTimeInterval(-180), chargeText: "27 credits")
        let history = HistoryContent(
            history: [transcript],
            failedTranscriptions: [FailedTranscriptionSnapshot(id: UUID(), createdAt: Date().addingTimeInterval(-60), duration: 12.4)],
            retryingTranscriptionID: nil, retryErrorMessage: nil, isSignedIn: true,
            copy: { _ in }, retry: { _ in }, delete: { _ in }
        )

        func page<Content: View>(_ content: Content, tab: VoiceTypeTab, name: String, standalone: Bool = false,
                                 delay: Duration = .milliseconds(200)) async throws {
            try await capture(content, tab: tab, name: "\(prefix)-\(name)", width: size.width, height: size.height,
                              scheme: .light, standalone: standalone, delay: delay, systemSafeAreas: true)
        }

        for state in [HomeMicState.ready, .recording] {
            let home = HomeContent(micState: state, elapsedSeconds: 65, durationLimit: .constant(.fiveMinutes),
                                   isBusy: false, hasNegativeBalance: false, errorMessage: nil, toggleMic: {})
            try await page(home, tab: .home, name: "mic-\(state)")
        }
        try await page(CreditScreen(store: store, account: account), tab: .credit, name: "credit")
        try await page(history, tab: .history, name: "history")
        let settings = VoiceTypeTabs(selection: .constant(.settings)) { _ in
            SettingsScreen(account: account, store: store, openKeyboardSetup: {})
        }
        try await page(settings, tab: .settings, name: "settings", standalone: true)
        let toast = VoiceTypeTabs(selection: .constant(.history)) { _ in
            TabPage { history }
                .toast("Copied", bottomPadding: 16)
        }
        try await page(toast, tab: .history, name: "toast", standalone: true)
        try await page(SignInScreen(openKeyboardSetup: {}).environmentObject(account), tab: .home, name: "signin", standalone: true)
        try await page(KeyboardSetupScreen(close: {}), tab: .home, name: "setup", standalone: true)
        // The app presents these three as sheets. Here each fills the window, which
        // is enough to show where the system puts their bar buttons.
        try await page(DictationSettingsView(userID: userID), tab: .settings, name: "dictation", standalone: true)
        try await page(TranscriptCorrectionView(snapshot: transcript, userID: userID, draft: transcript.text, onSave: {}), tab: .history,
                       name: "correction", standalone: true, delay: .seconds(2))
        try await page(TranscriptionModelSettingsView(userID: userID, catalog: nil, refreshCatalog: { nil }), tab: .settings,
                       name: "models", standalone: true)
    }

    /// Records the scene the test host runs in: its size, safe areas and size
    /// classes. The images of `testCaptureAtSceneSize` are read against these.
    /// The report is the file `voicetype-` followed by `name`.
    private func describe(_ scene: UIWindowScene, name: String) throws {
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()

        func sizeClassName(_ sizeClass: UIUserInterfaceSizeClass) -> String {
            switch sizeClass {
            case .compact: return "compact"
            case .regular: return "regular"
            default: return "unspecified"
            }
        }
        func orientationName(_ orientation: UIInterfaceOrientation) -> String {
            switch orientation {
            case .portrait: return "portrait"
            case .portraitUpsideDown: return "portrait, upside down"
            case .landscapeLeft: return "landscape left"
            case .landscapeRight: return "landscape right"
            default: return "unknown"
            }
        }
        let bounds = scene.coordinateSpace.bounds
        let screen = scene.screen
        let insets = window.safeAreaInsets
        let traits = scene.traitCollection
        let geometry = scene.effectiveGeometry
        var lines: [String] = []
        lines.append("scene: \(bounds.width) x \(bounds.height) points")
        lines.append("screen: \(screen.bounds.width) x \(screen.bounds.height) points, scale \(screen.scale)")
        lines.append("screen pixels: \(screen.nativeBounds.width) x \(screen.nativeBounds.height)")
        lines.append("safe area insets: top \(insets.top), left \(insets.left), bottom \(insets.bottom), right \(insets.right)")
        lines.append("horizontal size class: \(sizeClassName(traits.horizontalSizeClass))")
        lines.append("vertical size class: \(sizeClassName(traits.verticalSizeClass))")
        lines.append("orientation: \(orientationName(geometry.interfaceOrientation))")
        lines.append("idiom: \(UIDevice.current.userInterfaceIdiom.rawValue)")
        // The descriptions list every value the system reports, including ones that
        // a newer SDK adds and this code cannot name.
        lines.append("geometry: \(String(describing: geometry))")
        lines.append("traits: \(String(describing: traits))")
        for other in UIApplication.shared.connectedScenes {
            var line = "connected scene: role \(other.session.role.rawValue), activation state \(other.activationState.rawValue)"
            if let windowScene = other as? UIWindowScene {
                let sceneBounds = windowScene.coordinateSpace.bounds
                let frames: [String] = windowScene.windows.map { "\($0.frame.width) x \($0.frame.height)" }
                line += ", \(sceneBounds.width) x \(sceneBounds.height) points"
                line += ", windows \(frames.joined(separator: " | "))"
            }
            lines.append(line)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("voicetype-\(name).txt")
        try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
        print("UI_SCENE_REPORT=\(output.path)")
        for line in lines {
            print("UI_SCENE \(name) | \(line)")
        }
    }

    /// `systemSafeAreas` keeps the insets the system gives the window and lets the
    /// page fill it. Otherwise the page gets exactly `width` × `height` and no insets.
    private func capture<Content: View>(_ content: Content, tab: VoiceTypeTab, name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme, standalone: Bool = false, typeSize: DynamicTypeSize = .large, delay: Duration = .milliseconds(200), systemSafeAreas: Bool = false) async throws {
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
        .frame(width: systemSafeAreas ? nil : width, height: systemSafeAreas ? nil : height)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let hosting = UIHostingController(rootView: screen)
        if systemSafeAreas {
            // Above the app's own window, so that the page is what the screen shows.
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        } else {
            hosting.safeAreaRegions = []
        }
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

        if systemSafeAreas, let seconds = Self.onScreenSeconds {
            // Leaves the page on the simulator's screen and says so with a file. A
            // script on the Mac then takes a screenshot of the display and answers
            // with a second file. The image above has no status bar; that one does.
            let folder = FileManager.default.temporaryDirectory
            let marker = folder.appendingPathComponent("voicetype-onscreen-\(name).marker")
            let answer = folder.appendingPathComponent("voicetype-onscreen-\(name).done")
            try? FileManager.default.removeItem(at: answer)
            try Data().write(to: marker)
            defer {
                try? FileManager.default.removeItem(at: marker)
                try? FileManager.default.removeItem(at: answer)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            while ContinuousClock.now < deadline, !FileManager.default.fileExists(atPath: answer.path) {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
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
