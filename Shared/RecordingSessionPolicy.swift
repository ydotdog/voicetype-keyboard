import Foundation

/// Wall time labels the session for UI; monotonic time alone controls capture.
/// A device clock adjustment must never add or remove microphone time.
struct RecordingTimeSample {
    let date: Date
    let monotonicSeconds: TimeInterval
}

@MainActor
struct RecordingTimeSource {
    let now: () -> RecordingTimeSample

    static func continuous() -> RecordingTimeSource {
        let origin = ContinuousClock.now
        return RecordingTimeSource {
            let elapsed = origin.duration(to: .now).components
            return RecordingTimeSample(
                date: Date(),
                monotonicSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            )
        }
    }
}

enum RecordingDeadlineAction: Equatable {
    case none
    case stopKeyboardSession
    case finishKeyboardClip
    case finishKeyboardClipAndSession
    case stopIdleCaptureWhileTranscribing
    case finishStandardRecording
}

/// The same policy is used for ticks, preference changes, foreground recovery,
/// and keyboard commands, so no path can restart an already-expired session.
struct RecordingSessionPolicy {
    static let maximumClipDuration: TimeInterval = 10 * 60
    static let maximumIdleFileDuration: TimeInterval = 60

    static func statusStaleDate(now: Date, expiresAt: Date?, mode: RecordingBridgeMode) -> Date {
        let heartbeatDeadline = now.addingTimeInterval(30)
        return mode == .transcribing ? heartbeatDeadline : min(expiresAt ?? heartbeatDeadline, heartbeatDeadline)
    }

    let startedAt: Date
    let startedMonotonicSeconds: TimeInterval
    private(set) var durationLimit: RecordingDurationLimit
    private(set) var isClosing = false

    init(start: RecordingTimeSample, durationLimit: RecordingDurationLimit) {
        startedAt = start.date
        startedMonotonicSeconds = start.monotonicSeconds
        self.durationLimit = durationLimit
    }

    func elapsed(at time: RecordingTimeSample) -> TimeInterval {
        max(0, time.monotonicSeconds - startedMonotonicSeconds)
    }

    @discardableResult
    mutating func setDurationLimit(_ limit: RecordingDurationLimit, at time: RecordingTimeSample, keyboardSession: Bool = true) -> Bool {
        // A setting change can arrive before a delayed expiry tick. Evaluate
        // the old deadline first so extending cannot resurrect that session.
        guard !isClosing, !hasReachedDeadline(at: time, keyboardSession: keyboardSession) else {
            isClosing = true
            return false
        }
        durationLimit = limit
        return true
    }

    mutating func close() {
        isClosing = true
    }

    func hasReachedDeadline(at time: RecordingTimeSample, keyboardSession: Bool) -> Bool {
        let limit = keyboardSession ? durationLimit.maximumDuration : Self.maximumClipDuration
        return limit.map { elapsed(at: time) >= $0 } ?? false
    }

    func remainingDuration(at time: RecordingTimeSample, keyboardSession: Bool) -> TimeInterval? {
        let limit = keyboardSession ? durationLimit.maximumDuration : Self.maximumClipDuration
        return limit.map { max(0, $0 - elapsed(at: time)) }
    }

    func recorderDuration(at time: RecordingTimeSample, mode: RecordingBridgeMode, clipElapsed: TimeInterval) -> TimeInterval? {
        let sessionRemaining = remainingDuration(at: time, keyboardSession: mode != .standard)
        guard mode == .keyboardRecording else { return sessionRemaining }
        let clipRemaining = max(0, Self.maximumClipDuration - clipElapsed)
        return min(sessionRemaining ?? clipRemaining, clipRemaining)
    }

    mutating func action(
        at time: RecordingTimeSample,
        mode: RecordingBridgeMode,
        isRecording: Bool,
        clipElapsed: TimeInterval
    ) -> RecordingDeadlineAction {
        let keyboardSession = mode != .standard
        if hasReachedDeadline(at: time, keyboardSession: keyboardSession) {
            isClosing = true
        }
        if isClosing {
            switch mode {
            case .keyboardReady: return .stopKeyboardSession
            case .keyboardRecording: return .finishKeyboardClipAndSession
            case .transcribing: return .stopIdleCaptureWhileTranscribing
            case .standard: return isRecording ? .finishStandardRecording : .none
            }
        }
        if mode == .keyboardRecording, clipElapsed >= Self.maximumClipDuration {
            return .finishKeyboardClip
        }
        return .none
    }
}
