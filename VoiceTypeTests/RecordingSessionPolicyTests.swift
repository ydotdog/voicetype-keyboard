import Foundation
import Testing
@testable import VoiceType

struct RecordingSessionPolicyTests {
    private let startDate = Date(timeIntervalSince1970: 1_000_000)

    private func time(_ elapsed: TimeInterval, wallOffset: TimeInterval? = nil) -> RecordingTimeSample {
        RecordingTimeSample(date: startDate.addingTimeInterval(wallOffset ?? elapsed), monotonicSeconds: 100 + elapsed)
    }

    private func session(_ limit: RecordingDurationLimit) -> RecordingSessionPolicy {
        RecordingSessionPolicy(start: time(0), durationLimit: limit)
    }

    @Test func fiveMinutesTwelveHoursAndForeverHaveTheirActualDurations() {
        for (limit, seconds) in [(RecordingDurationLimit.fiveMinutes, 300.0), (.twelveHours, 43_200.0)] {
            var policy = session(limit)
            #expect(policy.action(at: time(seconds - 0.001), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .none)
            #expect(policy.action(at: time(seconds), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .stopKeyboardSession)
            #expect(policy.isClosing)
        }
        var forever = session(.always)
        #expect(forever.action(at: time(31_536_000), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .none)
        #expect(forever.remainingDuration(at: time(31_536_000), keyboardSession: true) == nil)
    }

    @Test func repeatedClipsDoNotRestartTheFiveMinuteWindow() {
        var policy = session(.fiveMinutes)
        for offset in stride(from: 0.0, through: 240.0, by: 60.0) {
            #expect(policy.action(at: time(offset + 15), mode: .keyboardRecording, isRecording: true, clipElapsed: 15) == .none)
            #expect(policy.action(at: time(offset + 25), mode: .transcribing, isRecording: false, clipElapsed: 0) == .none)
            #expect(policy.action(at: time(offset + 30), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .none)
        }
        #expect(policy.startedAt == startDate)
        #expect(policy.startedMonotonicSeconds == 100)
        #expect(policy.action(at: time(300), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .stopKeyboardSession)
    }

    @Test func shorteningUsesOriginalStartAndPreservesTheActiveClip() {
        var policy = session(.twelveHours)
        #expect(policy.action(at: time(360), mode: .keyboardRecording, isRecording: true, clipElapsed: 25) == .none)
        policy.setDurationLimit(.fiveMinutes, at: time(360))
        #expect(policy.action(at: time(360), mode: .keyboardRecording, isRecording: true, clipElapsed: 25) == .finishKeyboardClipAndSession)
        #expect(policy.startedAt == startDate)
        // Increasing the setting after closure starts only affects the next
        // session; it cannot re-arm capture during the saved clip's upload.
        policy.setDurationLimit(.always, at: time(361))
        #expect(policy.action(at: time(361), mode: .transcribing, isRecording: false, clipElapsed: 0) == .stopIdleCaptureWhileTranscribing)
    }

    @Test func extendingBeforeExpiryKeepsTheOriginalStart() {
        var policy = session(.fiveMinutes)
        #expect(policy.action(at: time(299), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .none)
        policy.setDurationLimit(.twelveHours, at: time(299))
        #expect(policy.action(at: time(300), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .none)
        #expect(policy.remainingDuration(at: time(300), keyboardSession: true) == 42_900)
        #expect(policy.action(at: time(43_200), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .stopKeyboardSession)
    }

    @Test func changingForeverToFiniteAfterItsDeadlineClosesImmediately() {
        var policy = session(.always)
        policy.setDurationLimit(.twelveHours, at: time(43_500))
        #expect(policy.action(at: time(43_500), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .stopKeyboardSession)
    }

    @Test func expiryStopsCaptureInEachKeyboardPhaseWithoutCancellingUpload() {
        var speaking = session(.fiveMinutes)
        var waiting = session(.fiveMinutes)
        #expect(speaking.action(at: time(300), mode: .keyboardRecording, isRecording: true, clipElapsed: 40) == .finishKeyboardClipAndSession)
        #expect(waiting.action(at: time(300), mode: .transcribing, isRecording: false, clipElapsed: 0) == .stopIdleCaptureWhileTranscribing)
    }

    @Test func singleClipCapIsSeparateFromKeyboardSessionAndStandaloneRecording() {
        var forever = session(.always)
        #expect(forever.action(at: time(900), mode: .keyboardRecording, isRecording: true, clipElapsed: 600) == .finishKeyboardClip)
        #expect(!forever.isClosing)
        #expect(forever.action(at: time(901), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .none)
        for setting in RecordingDurationLimit.allCases {
            var standard = session(setting)
            #expect(standard.action(at: time(300), mode: .standard, isRecording: true, clipElapsed: 0) == .none)
            #expect(standard.action(at: time(600), mode: .standard, isRecording: true, clipElapsed: 0) == .finishStandardRecording)
        }
    }

    @Test func simultaneousClipCapAndSessionExpiryClosesTheSession() {
        var policy = session(.twelveHours)
        #expect(policy.action(at: time(43_200), mode: .keyboardRecording, isRecording: true, clipElapsed: 600) == .finishKeyboardClipAndSession)
    }

    @Test func foregroundAfterSuspensionChecksDeadlineBeforeAnyRecovery() {
        var policy = session(.fiveMinutes)
        #expect(policy.action(at: time(10), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .none)
        // No ticks ran while the process was suspended.
        #expect(policy.action(at: time(1_000), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .stopKeyboardSession)
        policy.setDurationLimit(.always, at: time(1_001))
        #expect(policy.action(at: time(1_001), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .stopKeyboardSession)
    }

    @Test func changingDeviceClockCannotExtendOrShortenTheSession() {
        var policy = session(.fiveMinutes)
        #expect(policy.action(at: time(20, wallOffset: 86_400), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .none)
        #expect(policy.action(at: time(299, wallOffset: -86_400), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .none)
        #expect(policy.action(at: time(300, wallOffset: -86_400), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .stopKeyboardSession)
    }

    @Test func userStopOrAudioLossCannotBeUndoneByChangingSessionLength() {
        var policy = session(.always)
        policy.close()
        policy.setDurationLimit(.twelveHours, at: time(30))
        #expect(policy.action(at: time(30), mode: .keyboardRecording, isRecording: true, clipElapsed: 10) == .finishKeyboardClipAndSession)
        #expect(policy.action(at: time(31), mode: .transcribing, isRecording: false, clipElapsed: 0) == .stopIdleCaptureWhileTranscribing)
    }

    @Test func bridgeRejectsFreshButExpiredCaptureAndAllowsItsUploadToFinish() {
        let deadline = startDate.addingTimeInterval(300.125)
        for mode in [RecordingBridgeMode.keyboardReady, .keyboardRecording] {
            let state = RecordingBridgeState(
                sessionID: "session", isRecording: mode == .keyboardRecording, startedAt: startDate,
                updatedAt: deadline, durationLimit: .fiveMinutes, mode: mode, expiresAt: deadline
            )
            #expect(state.validated(at: deadline.addingTimeInterval(-0.001)) == state)
            #expect(state.validated(at: deadline) == .inactive)
        }
        let uploading = RecordingBridgeState(
            sessionID: "session", isRecording: false, startedAt: startDate, updatedAt: deadline,
            durationLimit: .fiveMinutes, mode: .transcribing, expiresAt: deadline
        )
        #expect(uploading.validated(at: deadline.addingTimeInterval(5)) == uploading)
        #expect(uploading.validated(at: deadline.addingTimeInterval(10.001)) == .inactive)
    }

    @Test func nativeRecorderBudgetUsesTheSoonestSessionOrClipDeadline() {
        var policy = session(.fiveMinutes)
        #expect(policy.recorderDuration(at: time(280), mode: .keyboardRecording, clipElapsed: 10) == 20)
        policy.setDurationLimit(.twelveHours, at: time(280))
        #expect(policy.recorderDuration(at: time(280), mode: .keyboardRecording, clipElapsed: 10) == 590)
        #expect(policy.recorderDuration(at: time(300), mode: .keyboardReady, clipElapsed: 0) == 42_900)
        var forever = session(.always)
        #expect(forever.recorderDuration(at: time(10_000), mode: .keyboardReady, clipElapsed: 0) == nil)
        #expect(forever.recorderDuration(at: time(10_000), mode: .keyboardRecording, clipElapsed: 599) == 1)
        forever.setDurationLimit(.fiveMinutes, at: time(10_000))
        #expect(forever.recorderDuration(at: time(10_000), mode: .keyboardRecording, clipElapsed: 599) == 0)
    }

    @Test func audioLevelIsBoundedAndHiddenOutsideAnActiveKeyboardClip() throws {
        for (input, expected) in [(-1.0, 0.0), (0.4, 0.4), (4.0, 1.0), (Double.nan, 0.0), (Double.infinity, 0.0)] {
            let state = RecordingBridgeState(
                sessionID: "audio", isRecording: true, startedAt: startDate,
                durationLimit: .always, mode: .keyboardRecording, audioLevel: input
            )
            #expect(state.audioLevel == expected)
            let decoded = try JSONDecoder().decode(RecordingBridgeState.self, from: JSONEncoder().encode(state))
            #expect(decoded.audioLevel == expected)
        }
        for mode in [RecordingBridgeMode.standard, .keyboardReady, .transcribing] {
            let state = RecordingBridgeState(
                sessionID: "audio", isRecording: true, startedAt: startDate,
                durationLimit: .always, mode: mode, audioLevel: 1
            )
            #expect(state.audioLevel == 0)
        }
        #expect(RecordingBridgeState.inactive.audioLevel == 0)
    }

    @Test func audioLevelDecodingSupportsOldAndMalformedSnapshots() throws {
        let baseline = RecordingBridgeState(
            sessionID: "audio", isRecording: true, startedAt: startDate,
            durationLimit: .always, mode: .keyboardRecording, audioLevel: 0.5
        )
        let data = try JSONEncoder().encode(baseline)
        var payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "audioLevel")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        #expect(try JSONDecoder().decode(RecordingBridgeState.self, from: legacyData).audioLevel == 0)
        for (input, expected) in [("invalid" as Any, 0.0), (NSNull() as Any, 0.0), (-3.0 as Any, 0.0), (8.0 as Any, 1.0)] {
            payload["audioLevel"] = input
            let invalidData = try JSONSerialization.data(withJSONObject: payload)
            #expect(try JSONDecoder().decode(RecordingBridgeState.self, from: invalidData).audioLevel == expected)
        }
    }

    @Test func staleLiveStatusExpiresAtHeartbeatOrCaptureDeadline() {
        let soon = startDate.addingTimeInterval(5)
        let later = startDate.addingTimeInterval(300)
        #expect(RecordingSessionPolicy.statusStaleDate(now: startDate, expiresAt: soon, mode: .keyboardReady) == soon)
        #expect(RecordingSessionPolicy.statusStaleDate(now: startDate, expiresAt: later, mode: .keyboardRecording) == startDate.addingTimeInterval(30))
        #expect(RecordingSessionPolicy.statusStaleDate(now: startDate, expiresAt: nil, mode: .keyboardReady) == startDate.addingTimeInterval(30))
        #expect(RecordingSessionPolicy.statusStaleDate(now: startDate, expiresAt: startDate.addingTimeInterval(-1), mode: .transcribing) == startDate.addingTimeInterval(30))
    }

    @Test func extendingAfterDeadlineCannotBeatADelayedExpiryTick() {
        var policy = session(.fiveMinutes)
        #expect(policy.action(at: time(200), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .none)
        // Preference callback runs before the delayed timer/foreground callback.
        let changed = policy.setDurationLimit(.always, at: time(301))
        #expect(!changed)
        #expect(policy.action(at: time(301), mode: .keyboardReady, isRecording: false, clipElapsed: 0) == .stopKeyboardSession)
    }
}
