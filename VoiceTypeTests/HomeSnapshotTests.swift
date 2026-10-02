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
    }

    func testCaptureDictationSettingsAndCorrection() async throws {
        let userID = "snapshot-dictation-\(UUID().uuidString)"
        var preferences = DictationPreferences()
        preferences.toggle(.simplifiedChinese)
        preferences.toggle(.english)
        preferences.remember("龚玥", learned: true)
        preferences.remember("VoiceType")
        DictationPreferencesStore.save(preferences, userID: userID)
        defer { DictationPreferencesStore.clear(userID: userID) }
        for (suffix, width, scheme) in [("narrow", CGFloat(320), ColorScheme.light), ("dark", CGFloat(430), ColorScheme.dark)] {
            try await capture(DictationSettingsView(userID: userID), tab: .settings,
                name: "dictation-\(suffix)", width: width, height: 880, scheme: scheme, standalone: true)
            try await capture(TranscriptCorrectionView(snapshot: TranscriptSnapshot(id: "preview", text: "明天和龚玥在衢州见面。", createdAt: Date(), chargeText: nil), userID: userID, onSave: {}), tab: .history,
                name: "correction-\(suffix)", width: width, height: 880, scheme: scheme, standalone: true)
        }
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

    private func capture<Content: View>(_ content: Content, tab: VoiceTypeTab, name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme, standalone: Bool = false, typeSize: DynamicTypeSize = .large) async throws {
        let screen = ZStack {
            AppTheme.background.ignoresSafeArea()
            if standalone {
                content
            } else {
            VoiceTypeTabs(selection: .constant(tab)) { _ in
            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
            }
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
        try await Task.sleep(for: .milliseconds(200))
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
