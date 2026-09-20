import AVFoundation
import Foundation
import XCTest
@testable import VoiceType

/// Exercises the real activation coordinator and recording lifecycle together.
/// XCTest runs these cases serially, before the Swift Testing suites; all account
/// storage and shared preferences touched by a case are restored on exit.
@MainActor
final class KeyboardMicActivationTests: XCTestCase {
    func testInactiveRequestWaitsForForeground() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanUp() }
        fixture.signIn()
        fixture.appState.presentKeyboardMic(autoStart: true)

        let inactive = await fixture.activate(isAppActive: false)
        XCTAssertEqual(inactive, .none)
        XCTAssertTrue(fixture.appState.hasPendingKeyboardMicAutoStart)
        XCTAssertEqual(fixture.permissionRequests, 0)
        XCTAssertTrue(fixture.recorders.isEmpty)

        let foreground = await fixture.activate()
        XCTAssertEqual(foreground, .ready)
        XCTAssertFalse(fixture.appState.hasPendingKeyboardMicAutoStart)
        fixture.assertStandbyOnly()
    }

    func testSignedOutRequestContinuesAfterSignIn() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanUp() }
        XCTAssertFalse(fixture.account.isSignedIn)
        fixture.appState.presentKeyboardMic(autoStart: true)

        let signedOut = await fixture.activate()
        XCTAssertEqual(signedOut, .needsSignIn)
        XCTAssertTrue(fixture.appState.hasPendingKeyboardMicAutoStart)
        XCTAssertEqual(fixture.permissionRequests, 0)
        XCTAssertTrue(fixture.recorders.isEmpty)

        await fixture.account.signInWithApple(identityToken: "test-identity", authorizationCode: nil, email: nil, fullName: nil)
        let signedIn = await fixture.activate()
        XCTAssertEqual(signedIn, .ready)
        XCTAssertEqual(fixture.backend.signInCalls, 1)
        XCTAssertFalse(fixture.appState.hasPendingKeyboardMicAutoStart)
        fixture.assertStandbyOnly()
    }

    func testKeyboardIntentStartsEachSavedWindowWithoutAnotherTapOrTranscription() async throws {
        for limit in RecordingDurationLimit.allCases {
            let fixture = try ActivationFixture()
            defer { fixture.cleanUp() }
            fixture.signIn()
            // Construct the controller before changing the saved preference to
            // prove activation reads the current setting, not its initial copy.
            _ = fixture.controller
            RecordingPreferencesStore.durationLimit = limit
            fixture.appState.presentKeyboardMic(autoStart: true)

            let outcome = await fixture.activate()
            XCTAssertEqual(outcome, .ready)
            XCTAssertEqual(fixture.controller.durationLimit, limit)
            XCTAssertEqual(fixture.permissionRequests, 1)
            XCTAssertEqual(fixture.audioSessionActivations, 1)
            let audio = try XCTUnwrap(fixture.recorders.first)
            XCTAssertEqual(audio.scheduledDuration, limit.maximumDuration)
            let state = RecordingBridgeStore.state
            XCTAssertEqual(state.mode, .keyboardReady)
            XCTAssertEqual(state.durationLimit, limit)
            if let duration = limit.maximumDuration {
                let start = try XCTUnwrap(state.startedAt)
                let end = try XCTUnwrap(state.expiresAt)
                XCTAssertEqual(end.timeIntervalSince(start), duration, accuracy: 0.02)
            } else {
                XCTAssertNil(state.expiresAt)
            }
            fixture.assertStandbyOnly()
        }
    }

    func testNormalLaunchAndGenericURLsNeverRequestMicrophone() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanUp() }
        fixture.signIn()
        let normalLaunch = await fixture.activate()
        XCTAssertEqual(normalLaunch, .none)

        for address in ["voicetype://keyboard", "voicetype://record", "voicetype://keyboard-setup", "voicetype://unknown"] {
            fixture.appState.handleIncomingURL(try XCTUnwrap(URL(string: address)))
            let outcome = await fixture.activate()
            XCTAssertEqual(outcome, .none, address)
            XCTAssertFalse(fixture.appState.hasPendingKeyboardMicAutoStart, address)
        }
        XCTAssertEqual(fixture.permissionRequests, 0)
        XCTAssertEqual(fixture.audioSessionActivations, 0)
        XCTAssertTrue(fixture.recorders.isEmpty)
        XCTAssertFalse(fixture.controller.isKeyboardSessionActive)
        XCTAssertEqual(fixture.transcriptionRequests, 0)
    }

    func testDeniedPermissionDoesNotLoopOnLaterForegroundEvents() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanUp() }
        fixture.signIn()
        fixture.permissionAllowed = false
        fixture.appState.presentKeyboardMic(autoStart: true)

        let denied = await fixture.activate()
        XCTAssertEqual(denied, .failed)
        XCTAssertEqual(fixture.controller.errorMessage, "Microphone permission is required.")
        XCTAssertFalse(fixture.controller.isStarting)
        XCTAssertFalse(fixture.appState.hasPendingKeyboardMicAutoStart)
        for active in [false, true, true] {
            let outcome = await fixture.activate(isAppActive: active)
            XCTAssertEqual(outcome, .none)
        }
        XCTAssertEqual(fixture.permissionRequests, 1)
        XCTAssertTrue(fixture.recorders.isEmpty)
        XCTAssertFalse(fixture.controller.isKeyboardSessionActive)
        XCTAssertEqual(fixture.transcriptionRequests, 0)
    }

    func testDuplicateDuringPermissionPromptKeepsOriginalRequestAlive() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanUp() }
        fixture.signIn()
        fixture.suspendPermission = true
        fixture.appState.presentKeyboardMic(autoStart: true)
        let firstRequest = Task { await fixture.activate() }
        for _ in 0..<5_000 {
            if fixture.permissionContinuation != nil { break }
            await Task.yield()
        }
        let permission = try XCTUnwrap(fixture.permissionContinuation)
        XCTAssertTrue(fixture.controller.isStarting)

        fixture.appState.presentKeyboardMic(autoStart: true)
        let duplicate = await fixture.activate()
        XCTAssertEqual(duplicate, .none)
        XCTAssertTrue(fixture.controller.isStarting)
        XCTAssertEqual(fixture.permissionRequests, 1)
        XCTAssertFalse(fixture.appState.hasPendingKeyboardMicAutoStart)
        fixture.permissionContinuation = nil
        permission.resume(returning: true)

        let originalOutcome = await firstRequest.value
        XCTAssertEqual(originalOutcome, .ready)
        XCTAssertEqual(fixture.recorders.count, 1)
        XCTAssertFalse(fixture.controller.isStarting)
        fixture.assertStandbyOnly()
    }

    func testDuplicateReadyRequestDoesNotResetCurrentSession() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanUp() }
        fixture.signIn()
        RecordingPreferencesStore.durationLimit = .fiveMinutes
        fixture.appState.presentKeyboardMic(autoStart: true)
        let first = await fixture.activate()
        XCTAssertEqual(first, .ready)
        let original = RecordingBridgeStore.state
        XCTAssertFalse(original.sessionID.isEmpty)

        fixture.elapsed = 120
        RecordingPreferencesStore.durationLimit = .twelveHours
        fixture.appState.presentKeyboardMic(autoStart: true)
        let duplicate = await fixture.activate()
        XCTAssertEqual(duplicate, .ready)
        let current = RecordingBridgeStore.state
        XCTAssertEqual(current.sessionID, original.sessionID)
        XCTAssertEqual(current.startedAt, original.startedAt)
        XCTAssertEqual(current.expiresAt, original.expiresAt)
        XCTAssertEqual(current.durationLimit, .fiveMinutes)
        XCTAssertEqual(fixture.controller.durationLimit, .fiveMinutes)
        XCTAssertEqual(fixture.permissionRequests, 1)
        XCTAssertEqual(fixture.recorders.count, 1)
        XCTAssertEqual(fixture.recorders.first?.recordCalls, 1)
        fixture.assertStandbyOnly()
    }

    func testFreshRequestAfterExpiredSessionStartsOneNewSavedWindow() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.cleanUp() }
        fixture.signIn()
        RecordingPreferencesStore.durationLimit = .fiveMinutes
        fixture.appState.presentKeyboardMic(autoStart: true)
        let first = await fixture.activate()
        XCTAssertEqual(first, .ready)
        let original = RecordingBridgeStore.state

        // The controller timer has not processed the elapsed deadline yet.
        // Wall time stays near real time so bridge validation remains realistic;
        // the monotonic clock independently controls actual session expiry.
        fixture.elapsed = 301
        fixture.wallDate = fixture.wallDate.addingTimeInterval(1)
        RecordingPreferencesStore.durationLimit = .twelveHours
        XCTAssertTrue(fixture.controller.isKeyboardSessionActive)
        fixture.appState.presentKeyboardMic(autoStart: true)
        let renewed = await fixture.activate()
        XCTAssertEqual(renewed, .ready)
        let current = RecordingBridgeStore.state
        XCTAssertFalse(current.sessionID.isEmpty)
        XCTAssertNotEqual(current.sessionID, original.sessionID)
        XCTAssertNotEqual(current.startedAt, original.startedAt)
        XCTAssertEqual(current.durationLimit, .twelveHours)
        XCTAssertEqual(fixture.controller.durationLimit, .twelveHours)
        let start = try XCTUnwrap(current.startedAt)
        let end = try XCTUnwrap(current.expiresAt)
        XCTAssertEqual(end.timeIntervalSince(start), 43_200, accuracy: 0.02)
        XCTAssertEqual(fixture.recorders.count, 2)
        XCTAssertEqual(fixture.permissionRequests, 2)
        XCTAssertFalse(try XCTUnwrap(fixture.recorders.first).isRecording)
        XCTAssertEqual(fixture.recorders.last?.scheduledDuration, 43_200)

        let laterForeground = await fixture.activate()
        XCTAssertEqual(laterForeground, .none)
        XCTAssertEqual(RecordingBridgeStore.state.sessionID, current.sessionID)
        XCTAssertEqual(fixture.recorders.count, 2)
        fixture.assertStandbyOnly()
    }
}

@MainActor
private final class ActivationFixture {
    private static let service = "com.kyleqi.voicetype.account"
    private static let tokenAccount = "userToken"
    private static let accountKeys = ["accountEmail", "accountUserID", "accountRetainedTranscripts"]
    private static let sharedKeys = [
        "recordingDurationLimit", "recordingBridgeState", "recordingBridgeCommand", "accountBalanceText",
        "latestTranscript", "transcriptHistory", "keyboardAutoInsertBaselineTranscriptID", "keyboardAutoInsertLastInsertedTranscriptID"
    ]
    let directory: URL
    private let sharedDefaults: UserDefaults
    private let savedAccount: [String: Any]
    private let savedShared: [String: Any]
    private let savedToken: String?
    let backend = ActivationAccountBackend()
    var elapsed: TimeInterval = 0
    var wallDate = Date()
    var permissionAllowed = true
    var suspendPermission = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var permissionRequests = 0
    var audioSessionActivations = 0
    var transcriptionRequests = 0
    var exportRequests = 0
    var recorders: [ActivationTestRecorder] = []
    lazy var account = AccountStore(backend: backend)
    lazy var appState = AppState(
        activationStore: KeyboardMicActivationStore(directoryURL: directory.appendingPathComponent("activation")),
        uptime: { [weak self] in self?.elapsed ?? 0 }
    )
    lazy var controller = RecordingController(
        recoveryDirectory: directory.appendingPathComponent("recovery"),
        timeSource: RecordingTimeSource { [weak self] in
            RecordingTimeSample(date: self?.wallDate ?? Date(), monotonicSeconds: self?.elapsed ?? 0)
        },
        recorderFactory: { [weak self] in
            guard let self else { throw ActivationTestError.unexpectedOperation }
            let file = directory.appendingPathComponent("fake-\(UUID().uuidString).m4a")
            let recorder = try ActivationTestRecorder(url: file, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1
            ])
            try Data("inert test audio".utf8).write(to: file)
            recorders.append(recorder)
            return (recorder, file)
        },
        permissionRequest: { [weak self] in
            await self?.requestPermission() ?? false
        },
        clipExporter: { [weak self] _, _, _, _ in
            self?.exportRequests += 1
            throw ActivationTestError.unexpectedOperation
        },
        audioSessionActivation: { [weak self] in self?.audioSessionActivations += 1 },
        transcriptionRequest: { [weak self] _, _, _, _ in
            self?.transcriptionRequests += 1
            throw ActivationTestError.unexpectedOperation
        }
    )

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyboard-activation-\(UUID().uuidString)")
        sharedDefaults = try XCTUnwrap(UserDefaults(suiteName: AppConstants.appGroup))
        savedAccount = Self.snapshot(Self.accountKeys, in: .standard)
        savedShared = Self.snapshot(Self.sharedKeys, in: sharedDefaults)
        savedToken = KeychainStore.read(service: Self.service, account: Self.tokenAccount)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.restore([:], keys: Self.accountKeys, in: .standard)
        Self.restore([:], keys: Self.sharedKeys, in: sharedDefaults)
        KeychainStore.delete(service: Self.service, account: Self.tokenAccount)
    }

    func signIn() { account.apply(auth: backend.auth) }

    private func requestPermission() async -> Bool {
        permissionRequests += 1
        if suspendPermission {
            return await withCheckedContinuation { permissionContinuation = $0 }
        }
        return permissionAllowed
    }

    func activate(isAppActive: Bool = true) async -> KeyboardMicActivation.Outcome {
        await KeyboardMicActivation.continuePendingRequest(
            appState: appState, account: account, recorder: controller, isAppActive: isAppActive
        )
    }

    func assertStandbyOnly(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(controller.isKeyboardReady, file: file, line: line)
        XCTAssertFalse(controller.isRecording, file: file, line: line)
        XCTAssertFalse(controller.isProcessing, file: file, line: line)
        XCTAssertFalse(controller.isKeyboardRecording, file: file, line: line)
        XCTAssertEqual(controller.elapsedSeconds, 0, file: file, line: line)
        XCTAssertEqual(exportRequests, 0, file: file, line: line)
        XCTAssertEqual(transcriptionRequests, 0, file: file, line: line)
        XCTAssertTrue(SharedTranscriptStore.history.isEmpty, file: file, line: line)
        XCTAssertEqual(SharedTranscriptStore.latest, .empty, file: file, line: line)
    }

    func cleanUp() {
        controller.cancel()
        permissionContinuation?.resume(returning: false)
        permissionContinuation = nil
        account.signOut()
        Self.restore(savedAccount, keys: Self.accountKeys, in: .standard)
        Self.restore(savedShared, keys: Self.sharedKeys, in: sharedDefaults)
        if let savedToken { KeychainStore.save(savedToken, service: Self.service, account: Self.tokenAccount) }
        else { KeychainStore.delete(service: Self.service, account: Self.tokenAccount) }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func snapshot(_ keys: [String], in defaults: UserDefaults) -> [String: Any] {
        keys.reduce(into: [:]) { result, key in result[key] = defaults.object(forKey: key) }
    }

    private static func restore(_ values: [String: Any], keys: [String], in defaults: UserDefaults) {
        for key in keys {
            if let value = values[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.synchronize()
    }
}

private enum ActivationTestError: Error { case unexpectedOperation }

@MainActor
private final class ActivationAccountBackend: AccountBackend {
    var signInCalls = 0
    let auth = AuthResponse(
        token: "activation-test-token", user: UserProfile(id: "cccccccc-cccc-cccc-cccc-cccccccccccc", email: nil),
        balance: BalancePayload(balanceUSDMicros: 100, balanceCreditUnits: 100, formatted: "100 credits")
    )
    func signInWithApple(identityToken: String, authorizationCode: String?, email: String?, fullName: String?) async throws -> AuthResponse {
        signInCalls += 1
        return auth
    }
    func me(token: String) async throws -> MeResponse { throw ActivationTestError.unexpectedOperation }
    func deleteAccount(token: String) async throws { throw ActivationTestError.unexpectedOperation }
}

/// Every capture/meter method is inert; no microphone is opened by the fixture.
private final class ActivationTestRecorder: AVAudioRecorder, @unchecked Sendable {
    private var capturing = false
    var scheduledDuration: TimeInterval?
    var recordCalls = 0
    override var currentTime: TimeInterval { 0 }
    override var isRecording: Bool { capturing }
    override func record() -> Bool { recordCalls += 1; capturing = true; return true }
    override func record(forDuration duration: TimeInterval) -> Bool { scheduledDuration = duration; return record() }
    override func pause() { capturing = false }
    override func stop() { capturing = false }
    override func updateMeters() {}
    override func averagePower(forChannel channelNumber: Int) -> Float { -160 }
}
