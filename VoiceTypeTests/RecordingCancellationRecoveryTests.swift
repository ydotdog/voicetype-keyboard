import AVFoundation
import Foundation
import Testing
import UIKit
@testable import VoiceType

@Suite(.serialized)
@MainActor
struct RecordingCancellationRecoveryTests {
    private let ownerID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    private func auth(_ userID: String) -> AuthResponse {
        AuthResponse(token: "capture-test-\(userID)", user: UserProfile(id: userID, email: nil),
                     balance: BalancePayload(balanceUSDMicros: 100, balanceCreditUnits: 100, formatted: "100 credits"))
    }

    private func waitUntil(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<5_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "The expected controller transition did not occur", sourceLocation: sourceLocation)
    }

    private func metadata(_ directory: URL) throws -> [String: Any] {
        let recording = try #require(RecordingRecoveryQueue(directory: directory).orderedRecordings.first)
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recording)) as? [String: Any])
    }

    private func result(_ id: UUID) -> TranscriptionResponse {
        TranscriptionResponse(id: id.uuidString, transcript: "Recovered \(id)", model: "test",
            charge: ChargePayload(costUSDMicros: 1, costCreditUnits: 1, formatted: "1 credit", pricingBasis: "test"),
            balance: BalancePayload(balanceUSDMicros: 99, balanceCreditUnits: 99, formatted: "99 credits"))
    }

    @Test(arguments: RecordingDurationLimit.allCases)
    func freshKeyboardSessionUsesItsSavedWindow(_ limit: RecordingDurationLimit) async throws {
        let previous = RecordingPreferencesStore.durationLimit
        defer { RecordingPreferencesStore.durationLimit = previous }
        RecordingPreferencesStore.durationLimit = limit
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: CaptureAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startKeyboardReady(account: account)

        let audio = try #require(fixture.recorders.first)
        let state = RecordingBridgeStore.state
        #expect(controller.durationLimit == limit)
        #expect(controller.isKeyboardReady)
        #expect(!controller.isRecording)
        #expect(audio.lastScheduledDuration == limit.maximumDuration)
        #expect(state.durationLimit == limit)
        if let duration = limit.maximumDuration {
            let start = try #require(state.startedAt)
            let end = try #require(state.expiresAt)
            #expect(abs(end.timeIntervalSince(start) - duration) < 0.02)
        } else {
            #expect(state.expiresAt == nil)
        }
    }

    @Test func absentOrInvalidPreferenceStartsAFiveMinuteWindow() async throws {
        let defaults = try #require(UserDefaults(suiteName: AppConstants.appGroup))
        let key = "recordingDurationLimit"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            defaults.synchronize()
        }
        for rawValue in [String?.none, "obsolete-value"] {
            if let rawValue { defaults.set(rawValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            defaults.synchronize()
            let fixture = try CaptureFixture()
            defer { fixture.cleanUp() }
            let account = AccountStore(backend: CaptureAccountBackend())
            defer { account.signOut() }
            account.apply(auth: auth(ownerID))
            let controller = fixture.controller()
            defer { controller.cancel() }
            await controller.startKeyboardReady(account: account)
            #expect(controller.isKeyboardReady)
            #expect(fixture.recorders.first?.lastScheduledDuration == 300)
            #expect(RecordingBridgeStore.state.durationLimit == .fiveMinutes)
        }
    }

    @Test func delayedPermissionUsesLatestSavedWindowAndDuplicateStartDoesNotPromptAgain() async throws {
        let previous = RecordingPreferencesStore.durationLimit
        defer { RecordingPreferencesStore.durationLimit = previous }
        RecordingPreferencesStore.durationLimit = .fiveMinutes
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: CaptureAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        var permission: CheckedContinuation<Bool, Never>?
        defer { permission?.resume(returning: false) }
        var prompts = 0
        var elapsed: TimeInterval = 0
        let controller = fixture.controller(timeSource: RecordingTimeSource {
            RecordingTimeSample(date: Date(), monotonicSeconds: elapsed)
        }, permissionRequest: {
            prompts += 1
            return await withCheckedContinuation { permission = $0 }
        })
        defer { controller.cancel() }
        // A different settings writer changes the store after this controller
        // exists, then again while the permission prompt remains open.
        RecordingPreferencesStore.durationLimit = .twelveHours
        let activation = Task { await controller.startKeyboardReady(account: account) }
        try await waitUntil { permission != nil }
        #expect(controller.durationLimit == .twelveHours)
        await controller.startKeyboardReady(account: account)
        #expect(prompts == 1)
        #expect(fixture.recorders.isEmpty)
        RecordingPreferencesStore.durationLimit = .always
        elapsed = 90
        permission?.resume(returning: true)
        permission = nil
        await activation.value

        #expect(fixture.recorders.count == 1)
        #expect(controller.durationLimit == .always)
        #expect(controller.isKeyboardReady)
        #expect(fixture.recorders.first?.lastScheduledDuration == nil)
        #expect(RecordingBridgeStore.state.durationLimit == .always)
        #expect(RecordingBridgeStore.state.expiresAt == nil)
    }

    @Test func deniedOrCancelledPermissionCannotCreateAKeyboardSession() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: CaptureAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        var permission: CheckedContinuation<Bool, Never>?
        defer { permission?.resume(returning: false) }
        let controller = fixture.controller(permissionRequest: {
            await withCheckedContinuation { permission = $0 }
        })
        defer { controller.cancel() }
        let denied = Task { await controller.startKeyboardReady(account: account) }
        try await waitUntil { permission != nil }
        permission?.resume(returning: false)
        permission = nil
        await denied.value
        #expect(!controller.isStarting)
        #expect(!controller.isKeyboardSessionActive)
        #expect(fixture.recorders.isEmpty)
        #expect(controller.errorMessage == "Microphone permission is required.")

        let cancelled = Task { await controller.startKeyboardReady(account: account) }
        try await waitUntil { permission != nil }
        controller.cancel()
        permission?.resume(returning: true)
        permission = nil
        await cancelled.value
        #expect(!controller.isStarting)
        #expect(!controller.isKeyboardSessionActive)
        #expect(fixture.recorders.isEmpty)
    }

    @Test func repeatedActivationKeepsOriginalDeadlineAndCannotRestartAnExpiredWindow() async throws {
        let previous = RecordingPreferencesStore.durationLimit
        defer { RecordingPreferencesStore.durationLimit = previous }
        RecordingPreferencesStore.durationLimit = .fiveMinutes
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: CaptureAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        var elapsed: TimeInterval = 0
        var prompts = 0
        let controller = fixture.controller(timeSource: RecordingTimeSource {
            RecordingTimeSample(date: Date(), monotonicSeconds: elapsed)
        }, permissionRequest: { prompts += 1; return true })
        defer { controller.cancel() }
        await controller.startKeyboardReady(account: account)
        let initial = RecordingBridgeStore.state
        let audio = try #require(fixture.recorders.first)
        RecordingPreferencesStore.durationLimit = .twelveHours
        elapsed = 120
        await controller.startKeyboardReady(account: account)
        let repeated = RecordingBridgeStore.state
        #expect(repeated.sessionID == initial.sessionID)
        #expect(repeated.startedAt == initial.startedAt)
        #expect(repeated.durationLimit == .fiveMinutes)
        #expect(controller.durationLimit == .fiveMinutes)
        #expect(prompts == 1)
        #expect(fixture.recorders.count == 1)
        #expect(audio.recordCalls == 1)

        elapsed = 300
        await controller.startKeyboardReady(account: account)
        #expect(!controller.isKeyboardSessionActive)
        #expect(!audio.isRecording)
        #expect(fixture.recorders.count == 1)
        #expect(prompts == 1)
    }

    @Test func historyRetryFinishesWithoutChangingConcurrentLiveCaptureOrInsertion() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let ids = try fixture.seedFailures(owner: ownerID, count: 2)
        let account = AccountStore(backend: CaptureAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let baseline = TranscriptSnapshot(id: "baseline", text: "Latest live transcript", createdAt: Date(timeIntervalSince1970: 1_700_000_000), chargeText: nil)
        SharedTranscriptStore.latest = baseline
        let controller = fixture.controller()
        defer { controller.cancel() }
        controller.reconcileFailedTranscription(account: account)
        let retry = Task { await controller.retryFailedTranscription(id: ids[0], account: account) }
        try await waitUntil { fixture.pendingTranscriptions.contains { $0.id == ids[0] } }
        await controller.retryFailedTranscription(id: ids[0], account: account)
        #expect(fixture.transcriptionCalls == [ids[0]])

        await controller.startKeyboardReady(account: account)
        #expect(controller.isKeyboardReady)
        let audio = try #require(fixture.recorders.first)
        audio.capturedTime = 3
        RecordingBridgeStore.requestStartClip()
        try await waitUntil { controller.isKeyboardRecording }
        let sessionID = RecordingBridgeStore.state.sessionID
        KeyboardAutoInsertStore.arm(baselineTranscriptID: baseline.id)
        fixture.respond(to: ids[0], with: .success(result(ids[0])))
        await retry.value

        #expect(controller.isKeyboardRecording)
        #expect(audio.isRecording)
        #expect(!controller.isProcessing)
        #expect(RecordingBridgeStore.state.sessionID == sessionID)
        #expect(SharedTranscriptStore.latest == baseline)
        #expect(SharedTranscriptStore.history.contains { $0.id == ids[0].uuidString })
        #expect(Set(controller.failedTranscriptions.map(\.id)) == [ids[1]])
        let probe = TranscriptSnapshot(id: "future-live", text: "New live text", createdAt: Date(), chargeText: nil)
        #expect(KeyboardAutoInsertStore.shouldInsert(probe))
    }

    @Test func newLiveSuccessRemovesOnlyItsCheckpointAndLeavesOlderFailures() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let ids = try fixture.seedFailures(owner: ownerID, count: 2)
        let account = AccountStore(backend: CaptureAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller()
        defer { controller.cancel() }
        await controller.startRecording(account: account)
        #expect(controller.isRecording)
        try #require(fixture.recorders.first).capturedTime = 8
        let live = Task { await controller.stopAndTranscribe(account: account) }
        try await waitUntil { !fixture.pendingTranscriptions.isEmpty }
        let liveID = try #require(fixture.pendingTranscriptions.first?.id)
        #expect(!ids.contains(liveID))
        fixture.respond(to: liveID, with: .success(result(liveID)))
        await live.value
        #expect(Set(controller.failedTranscriptions.map(\.id)) == Set(ids))
        #expect(SharedTranscriptStore.latest.id == liveID.uuidString)
        #expect(RecordingRecoveryQueue(directory: fixture.recoveryDirectory).recordings.count == 2)
    }

    @Test func failedKeyboardUploadReturnsReadyAndAllowsAnotherClipWithoutRetry() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: CaptureAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller()
        defer { controller.cancel() }
        controller.durationLimit = .fiveMinutes
        await controller.startKeyboardReady(account: account)
        let originalSession = RecordingBridgeStore.state
        let audio = try #require(fixture.recorders.first)
        audio.capturedTime = 4
        RecordingBridgeStore.requestStartClip()
        try await waitUntil { controller.isKeyboardRecording }
        audio.capturedTime = 9
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await waitUntil { fixture.exportContinuation != nil }
        try CaptureFixture.audioBytes.write(to: #require(fixture.exportOutputURL))
        fixture.exportContinuation?.resume()
        fixture.exportContinuation = nil
        try await waitUntil { !fixture.pendingTranscriptions.isEmpty }
        let failedID = try #require(fixture.pendingTranscriptions.first?.id)
        fixture.respond(to: failedID, with: .failure(BackendClientError.invalidResponse))
        await stop.value
        #expect(controller.isKeyboardReady)
        #expect(!controller.isProcessing)
        #expect(controller.failedTranscriptions.map(\.id) == [failedID])
        #expect(RecordingBridgeStore.state.sessionID == originalSession.sessionID)
        #expect(RecordingBridgeStore.state.startedAt == originalSession.startedAt)

        let nextAudio = try #require(fixture.recorders.last)
        #expect(nextAudio !== audio)
        #expect(nextAudio.isRecording)
        nextAudio.capturedTime = 2
        RecordingBridgeStore.requestStartClip()
        try await waitUntil { controller.isKeyboardRecording }
        #expect(controller.failedTranscriptions.map(\.id) == [failedID])
        #expect(controller.retryingTranscriptionID == nil)
        #expect(RecordingRecoveryQueue(directory: fixture.recoveryDirectory).recordings[failedID] != nil)
    }

    @Test func retryFailureAndDeleteCannotStopLiveCaptureOrResurrectDeletedHistory() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let id = try #require(fixture.seedFailures(owner: ownerID, count: 1).first)
        let account = AccountStore(backend: CaptureAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller()
        defer { controller.cancel() }
        let first = Task { await controller.retryFailedTranscription(id: id, account: account) }
        try await waitUntil { !fixture.pendingTranscriptions.isEmpty }
        await controller.startRecording(account: account)
        KeyboardAutoInsertStore.arm(baselineTranscriptID: "baseline")
        fixture.respond(to: id, with: .failure(BackendClientError.invalidResponse))
        await first.value
        #expect(controller.isRecording)
        #expect(!controller.isProcessing)
        #expect(controller.errorMessage == nil)
        #expect(controller.retryErrorMessage != nil)
        let probe = TranscriptSnapshot(id: "future-live", text: "New live text", createdAt: Date(), chargeText: nil)
        #expect(KeyboardAutoInsertStore.shouldInsert(probe))

        let second = Task { await controller.retryFailedTranscription(id: id, account: account) }
        try await waitUntil { !fixture.pendingTranscriptions.isEmpty }
        controller.discardFailedTranscription(id: id)
        fixture.respond(to: id, with: .success(result(id)))
        await second.value
        #expect(controller.isRecording)
        #expect(controller.failedTranscriptions.isEmpty)
        #expect(controller.retryingTranscriptionID == nil)
        #expect(!SharedTranscriptStore.history.contains { $0.id == id.uuidString })
    }

    @Test func expiredRetryRetainsOriginalIDForSameOwnerAndRejectsLateCompletion() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let id = try #require(fixture.seedFailures(owner: ownerID, count: 1).first)
        let account = AccountStore(backend: CaptureAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller()
        let first = Task { await controller.retryFailedTranscription(id: id, account: account) }
        try await waitUntil { !fixture.pendingTranscriptions.isEmpty }
        account.signOut(preservePendingRecording: true)
        controller.cancel(discardFailed: false)
        controller.reconcileFailedTranscription(account: account)
        fixture.respond(to: id, with: .success(result(id)))
        await first.value
        #expect(controller.failedTranscriptions.isEmpty)
        #expect(!SharedTranscriptStore.history.contains { $0.id == id.uuidString })
        account.apply(auth: auth(ownerID))
        controller.reconcileFailedTranscription(account: account)
        #expect(controller.failedTranscriptions.first?.id == id)
        let second = Task { await controller.retryFailedTranscription(id: id, account: account) }
        try await waitUntil { !fixture.pendingTranscriptions.isEmpty }
        #expect(fixture.transcriptionCalls == [id, id])
        fixture.respond(to: id, with: .failure(BackendClientError.invalidResponse))
        await second.value
        #expect(controller.failedTranscriptions.first?.id == id)
    }

    @Test func fastMeterPublishesIndependentSamplesAndClearsAfterCaptureStops() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore()
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller(timeSource: RecordingTimeSource {
            RecordingTimeSample(date: Date(), monotonicSeconds: 0)
        })
        defer { controller.cancel() }
        await controller.startKeyboardReady(account: account)
        let audio = try #require(fixture.recorders.first)
        audio.capturedTime = 2
        RecordingBridgeStore.requestStartClip()
        try await waitUntil { controller.isKeyboardRecording }
        let state = RecordingBridgeStore.state
        audio.averagePowerValue = -12
        for _ in 0..<100 {
            if RecordingAudioLevelStore.latest(for: state.sessionID)?.level == 0.8 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(RecordingAudioLevelStore.latest(for: state.sessionID)?.level == 0.8)
        #expect(RecordingBridgeStore.state.updatedAt == state.updatedAt)
        controller.cancel()
        try await Task.sleep(for: .milliseconds(80))
        #expect(RecordingAudioLevelStore.latest(for: state.sessionID) == nil)
    }

    @Test func fiveMinuteSpeakKeepsTheExistingRecorderWithoutPauseOrResume() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore()
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        var elapsed: TimeInterval = 0
        let controller = fixture.controller(timeSource: RecordingTimeSource {
            RecordingTimeSample(date: Date(), monotonicSeconds: elapsed)
        })
        defer { controller.cancel() }
        controller.durationLimit = .fiveMinutes
        await controller.startKeyboardReady(account: account)
        let audio = try #require(fixture.recorders.first)
        audio.rejectResumeAfterPause = true
        elapsed = 30
        audio.capturedTime = 30
        RecordingBridgeStore.requestStartClip()
        try await waitUntil { controller.isKeyboardRecording }

        #expect(audio.isRecording)
        #expect(audio.pauseCalls == 0)
        #expect(audio.recordCalls == 1)
        #expect(audio.lastScheduledDuration == 300)
        #expect(RecordingBridgeStore.state.isKeyboardRecording)
        #expect(RecordingBridgeStore.state.isRecording)
        #expect(controller.errorMessage == nil)
    }

    @Test func longerWindowsStillApplyTheTighterNativeClipLimit() async throws {
        for limit in [RecordingDurationLimit.twelveHours, .always] {
            let fixture = try CaptureFixture()
            defer { fixture.cleanUp() }
            let account = AccountStore()
            defer { account.signOut() }
            account.apply(auth: auth(ownerID))
            var elapsed: TimeInterval = 0
            let controller = fixture.controller(timeSource: RecordingTimeSource {
                RecordingTimeSample(date: Date(), monotonicSeconds: elapsed)
            })
            defer { controller.cancel() }
            controller.durationLimit = limit
            await controller.startKeyboardReady(account: account)
            let audio = try #require(fixture.recorders.first)
            elapsed = 20
            audio.capturedTime = 20
            RecordingBridgeStore.requestStartClip()
            try await waitUntil { controller.isKeyboardRecording }
            #expect(audio.isRecording)
            #expect(audio.pauseCalls == 1)
            #expect(audio.recordCalls == 2)
            #expect(audio.lastScheduledDuration == 600)
        }
    }

    @Test func keyboardWaveformFollowsMeasuredPowerAndResetsWhenClipStops() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore()
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        var elapsed: TimeInterval = 0
        let controller = fixture.controller(timeSource: RecordingTimeSource {
            RecordingTimeSample(date: Date(), monotonicSeconds: elapsed)
        })
        defer { controller.cancel() }
        await controller.startKeyboardReady(account: account)
        let audio = try #require(fixture.recorders.first)
        #expect(audio.meterUpdates == 0)
        #expect(RecordingBridgeStore.state.audioLevel == 0)
        audio.capturedTime = 5
        RecordingBridgeStore.requestStartClip()
        try await waitUntil { controller.isKeyboardRecording }
        #expect(audio.meterUpdates > 0)
        #expect(RecordingBridgeStore.state.audioLevel == 0)

        for (power, expected) in [(Float(-30), 0.5), (Float(0), 1.0), (Float(-160), 0.0), (Float.nan, 0.0)] {
            audio.averagePowerValue = power
            elapsed += 1.1
            let previousSamples = audio.meterUpdates
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            try await waitUntil {
                audio.meterUpdates > previousSamples && abs(RecordingBridgeStore.state.audioLevel - expected) < 0.0001
            }
            #expect(abs(RecordingBridgeStore.state.audioLevel - expected) < 0.0001)
        }

        audio.averagePowerValue = -12
        elapsed += 1.1
        let previousSamples = audio.meterUpdates
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { audio.meterUpdates > previousSamples && RecordingBridgeStore.state.audioLevel > 0 }
        #expect(RecordingBridgeStore.state.audioLevel > 0)
        audio.capturedTime = 8
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await waitUntil { fixture.exportContinuation != nil }
        #expect(RecordingBridgeStore.state.mode == .transcribing)
        #expect(RecordingBridgeStore.state.audioLevel == 0)
        let samplesAtStop = audio.meterUpdates
        elapsed += 2
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(audio.meterUpdates == samplesAtStop)
        #expect(fixture.recorders.last?.meterUpdates == 0)
        controller.cancel(discardFailed: false)
        #expect(RecordingBridgeStore.state.audioLevel == 0)
        fixture.exportContinuation?.resume(throwing: CancellationError())
        fixture.exportContinuation = nil
        await stop.value
    }

    @Test func authenticationExpiryPreservesCurrentStandardRecordingForOriginalOwner() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore()
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller()
        await controller.startRecording(account: account)
        #expect(controller.isRecording)
        let audio = try #require(fixture.recorders.first)
        audio.capturedTime = 4.5

        account.signOut(preservePendingRecording: true)
        controller.cancel(discardFailed: account.shouldDiscardPendingRecording)
        controller.reconcileFailedTranscription(account: account)
        #expect(!audio.isRecording)
        #expect(!controller.isRecording)
        #expect(!controller.isProcessing)
        #expect(!controller.hasFailedTranscription)
        #expect(controller.failedTranscriptionDuration == 0)
        let saved = try metadata(fixture.recoveryDirectory)
        #expect(saved["userID"] as? String == ownerID)
        #expect(saved["duration"] as? Double == 4.5)
        let savedPath = try #require(saved["fileURL"] as? String)
        let savedURL = try #require(URL(string: savedPath))
        #expect(try Data(contentsOf: savedURL) == CaptureFixture.audioBytes)

        let relaunched = RecordingController(recoveryDirectory: fixture.recoveryDirectory)
        account.apply(auth: auth(ownerID))
        relaunched.reconcileFailedTranscription(account: account)
        #expect(relaunched.hasFailedTranscription)
        #expect(relaunched.failedTranscriptionDuration == 4.5)
    }

    @Test func expiryDuringKeyboardExportRetainsCheckpointAndNeverUploads() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore()
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller()
        await controller.startKeyboardReady(account: account)
        #expect(controller.isKeyboardReady)
        let audio = try #require(fixture.recorders.first)
        audio.capturedTime = 12
        RecordingBridgeStore.requestStartClip()
        try await waitUntil { controller.isKeyboardRecording }
        audio.capturedTime = 18
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await waitUntil { fixture.exportContinuation != nil }

        // The source is durable before the asynchronous exporter completes.
        let before = try metadata(fixture.recoveryDirectory)
        #expect(before["clipStartTime"] as? Double == 12)
        #expect(before["duration"] as? Double == 6)
        let requestID = try #require(before["requestID"] as? String)
        account.signOut(preservePendingRecording: true)
        controller.cancel(discardFailed: account.shouldDiscardPendingRecording)
        controller.reconcileFailedTranscription(account: account)
        fixture.exportContinuation?.resume(throwing: CancellationError())
        fixture.exportContinuation = nil
        await stop.value

        #expect(!controller.isProcessing)
        #expect(!controller.isKeyboardSessionActive)
        #expect(!controller.hasFailedTranscription)
        let after = try metadata(fixture.recoveryDirectory)
        #expect(after["requestID"] as? String == requestID)
        #expect(after["userID"] as? String == ownerID)
        let savedPath = try #require(after["fileURL"] as? String)
        let savedURL = try #require(URL(string: savedPath))
        #expect(try Data(contentsOf: savedURL) == CaptureFixture.audioBytes)
        account.apply(auth: auth(ownerID))
        controller.reconcileFailedTranscription(account: account)
        #expect(controller.hasFailedTranscription)
        #expect(controller.failedTranscriptionDuration == 6)
        let retry = Task { await controller.retryFailedTranscription(account: account) }
        try await waitUntil { fixture.exportContinuation != nil }
        #expect(fixture.exportRanges.count == 2)
        #expect(fixture.exportRanges.last?.start == 12)
        #expect(fixture.exportRanges.last?.duration == 6)
        controller.cancel(discardFailed: false)
        fixture.exportContinuation?.resume(throwing: CancellationError())
        fixture.exportContinuation = nil
        await retry.value
    }

    @Test func expiryWhileKeyboardIsRecordingRetainsOnlyTheSpokenRange() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore()
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller()
        await controller.startKeyboardReady(account: account)
        let audio = try #require(fixture.recorders.first)
        audio.capturedTime = 40
        RecordingBridgeStore.requestStartClip()
        try await waitUntil { controller.isKeyboardRecording }
        audio.capturedTime = 47
        account.signOut(preservePendingRecording: true)
        controller.cancel(discardFailed: false)
        controller.reconcileFailedTranscription(account: account)
        #expect(!controller.hasFailedTranscription)
        let saved = try metadata(fixture.recoveryDirectory)
        #expect(saved["clipStartTime"] as? Double == 40)
        #expect(saved["duration"] as? Double == 7)
        #expect(saved["userID"] as? String == ownerID)

        let relaunched = fixture.controller()
        account.apply(auth: auth(ownerID))
        relaunched.reconcileFailedTranscription(account: account)
        let retry = Task { await relaunched.retryFailedTranscription(account: account) }
        try await waitUntil { fixture.exportContinuation != nil }
        #expect(fixture.exportRanges.last?.start == 40)
        #expect(fixture.exportRanges.last?.duration == 7)
        relaunched.cancel(discardFailed: false)
        fixture.exportContinuation?.resume(throwing: CancellationError())
        fixture.exportContinuation = nil
        await retry.value
    }

    @Test func explicitLogoutDiscardsCurrentRecordingAndDifferentOwnerCannotRestore() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore()
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller()
        await controller.startRecording(account: account)
        let audio = try #require(fixture.recorders.first)
        audio.capturedTime = 3
        account.signOut()
        controller.cancel(discardFailed: account.shouldDiscardPendingRecording)
        #expect(!FileManager.default.fileExists(atPath: audio.url.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.recoveryDirectory.path))

        account.apply(auth: auth(ownerID))
        await controller.startRecording(account: account)
        try #require(fixture.recorders.last).capturedTime = 5
        account.signOut(preservePendingRecording: true)
        controller.cancel(discardFailed: false)
        #expect(FileManager.default.fileExists(atPath: fixture.recoveryDirectory.path))
        account.apply(auth: auth("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        controller.reconcileFailedTranscription(account: account)
        #expect(!controller.hasFailedTranscription)
        #expect(!FileManager.default.fileExists(atPath: fixture.recoveryDirectory.path))
    }

    @Test func unsuccessfulStandardFinishRetainsCapturedPrefixAndReportsError() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore()
        defer { account.signOut() }
        account.apply(auth: auth(ownerID))
        let controller = fixture.controller()
        await controller.startRecording(account: account)
        let audio = try #require(fixture.recorders.first)
        audio.capturedTime = 3.25
        audio.capturing = false
        controller.audioRecorderDidFinishRecording(audio, successfully: false)
        try await waitUntil { !controller.isRecording }
        #expect(controller.hasFailedTranscription)
        #expect(controller.failedTranscriptionDuration == 3.25)
        #expect(controller.errorMessage?.contains("interrupted") == true)
        #expect(!controller.isProcessing)
    }
}

@MainActor
private final class CaptureFixture {
    static let audioBytes = Data("finalized captured audio prefix".utf8)
    let directory: URL
    let recoveryDirectory: URL
    var recorders: [CaptureTestRecorder] = []
    var exportContinuation: CheckedContinuation<Void, Error>?
    var exportOutputURL: URL?
    var exportRanges: [(start: TimeInterval, duration: TimeInterval)] = []
    var transcriptionCalls: [UUID] = []
    var pendingTranscriptions: [(id: UUID, continuation: CheckedContinuation<TranscriptionResponse, Error>)] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-recovery-\(UUID().uuidString)")
        recoveryDirectory = directory.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func controller(
        timeSource: RecordingTimeSource = .continuous(),
        permissionRequest: @escaping () async -> Bool = { true }
    ) -> RecordingController {
        RecordingController(
            recoveryDirectory: recoveryDirectory,
            timeSource: timeSource,
            recorderFactory: { [self] in
                let url = directory.appendingPathComponent("capture-\(UUID().uuidString).m4a")
                let recorder = try CaptureTestRecorder(url: url, settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1
                ])
                try Self.audioBytes.write(to: url)
                recorders.append(recorder)
                return (recorder, url)
            },
            permissionRequest: permissionRequest,
            clipExporter: { [self] _, outputURL, start, duration in
                exportOutputURL = outputURL
                exportRanges.append((start, duration))
                try await withCheckedThrowingContinuation { exportContinuation = $0 }
            },
            audioSessionActivation: {},
            transcriptionRequest: { [self] _, _, _, id in
                transcriptionCalls.append(id)
                return try await withCheckedThrowingContinuation { pendingTranscriptions.append((id, $0)) }
            }
        )
    }

    func seedFailures(owner: String, count: Int) throws -> [UUID] {
        let queue = RecordingRecoveryQueue(directory: recoveryDirectory)
        return try (0..<count).map { _ in
            let id = UUID()
            let file = directory.appendingPathComponent("failed-\(id).m4a")
            try Self.audioBytes.write(to: file)
            try #require(queue.save(RecoverableRecording(fileURL: file, duration: 5, clipStartTime: nil,
                                                        requestID: id, userID: owner)))
            return id
        }
    }

    func respond(to id: UUID, with result: Result<TranscriptionResponse, Error>) {
        guard let index = pendingTranscriptions.firstIndex(where: { $0.id == id }) else { return }
        pendingTranscriptions.remove(at: index).continuation.resume(with: result)
    }

    func cleanUp() {
        exportContinuation?.resume(throwing: CancellationError())
        exportContinuation = nil
        pendingTranscriptions.forEach { $0.continuation.resume(throwing: CancellationError()) }
        pendingTranscriptions = []
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private struct CaptureAccountBackend: AccountBackend {
    func signInWithApple(identityToken: String, authorizationCode: String?, email: String?, fullName: String?) async throws -> AuthResponse {
        throw BackendClientError.invalidResponse
    }
    func me(token: String) async throws -> MeResponse { throw BackendClientError.invalidResponse }
    func deleteAccount(token: String) async throws { throw BackendClientError.invalidResponse }
}

// No recording method calls AVFoundation: these tests execute the real
// controller lifecycle without microphone permission, capture, or networking.
private final class CaptureTestRecorder: AVAudioRecorder, @unchecked Sendable {
    var capturedTime: TimeInterval = 0
    var capturing = false
    var averagePowerValue: Float = -160
    var meterUpdates = 0
    var pauseCalls = 0
    var recordCalls = 0
    var rejectResumeAfterPause = false
    var lastScheduledDuration: TimeInterval?
    override var currentTime: TimeInterval { capturedTime }
    override var isRecording: Bool { capturing }
    override func record() -> Bool {
        recordCalls += 1
        guard !rejectResumeAfterPause || pauseCalls == 0 else { return false }
        capturing = true
        return true
    }
    override func record(forDuration duration: TimeInterval) -> Bool {
        lastScheduledDuration = duration
        return record()
    }
    override func pause() { pauseCalls += 1; capturing = false }
    override func stop() { capturing = false }
    override func updateMeters() { meterUpdates += 1 }
    override func averagePower(forChannel channelNumber: Int) -> Float { averagePowerValue }
}
