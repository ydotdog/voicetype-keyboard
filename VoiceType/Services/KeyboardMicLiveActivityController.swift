@preconcurrency import ActivityKit
import Foundation

@MainActor
final class KeyboardMicLiveActivityController {
    static let shared = KeyboardMicLiveActivityController()

    private var activity: Activity<VoiceTypeKeyboardActivityAttributes>?
    private var lastPublishedState: VoiceTypeKeyboardActivityAttributes.ContentState?
    private var lastPublishedAt: Date?

    private init() {}

    func update(
        sessionID: String,
        mode: RecordingBridgeMode,
        startedAt: Date?,
        durationLimit: RecordingDurationLimit,
        force: Bool = false
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard mode == .keyboardReady || mode == .keyboardRecording || mode == .transcribing else {
            await end()
            return
        }

        let state = VoiceTypeKeyboardActivityAttributes.ContentState(
            mode: mode,
            startedAt: startedAt,
            updatedAt: Date(),
            durationLimit: durationLimit
        )
        if !force, shouldSkipUpdate(state) {
            return
        }

        do {
            let activity = try await currentActivity(sessionID: sessionID, state: state)
            await activity.update(ActivityContent(state: state, staleDate: nil))
            self.activity = activity
            lastPublishedState = state
            lastPublishedAt = Date()
        } catch {
            self.activity = nil
        }
    }

    func end() async {
        let endState = VoiceTypeKeyboardActivityAttributes.ContentState(
            mode: .standard,
            startedAt: nil,
            updatedAt: Date(),
            durationLimit: .fiveMinutes
        )
        let content = ActivityContent(state: endState, staleDate: nil)
        for activity in Activity<VoiceTypeKeyboardActivityAttributes>.activities {
            await activity.end(content, dismissalPolicy: .immediate)
        }
        activity = nil
        lastPublishedState = nil
        lastPublishedAt = nil
    }

    private func currentActivity(
        sessionID: String,
        state: VoiceTypeKeyboardActivityAttributes.ContentState
    ) async throws -> Activity<VoiceTypeKeyboardActivityAttributes> {
        if let activity, activity.attributes.sessionID == sessionID {
            return activity
        }
        if let existing = Activity<VoiceTypeKeyboardActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID
        }) {
            activity = existing
            return existing
        }

        let staleActivities = Activity<VoiceTypeKeyboardActivityAttributes>.activities
        for staleActivity in staleActivities {
            await staleActivity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }

        return try Activity.request(
            attributes: VoiceTypeKeyboardActivityAttributes(sessionID: sessionID),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
    }

    private func shouldSkipUpdate(_ state: VoiceTypeKeyboardActivityAttributes.ContentState) -> Bool {
        guard
            let lastPublishedState,
            let lastPublishedAt
        else {
            return false
        }
        if lastPublishedState.mode != state.mode || lastPublishedState.durationLimit != state.durationLimit {
            return false
        }
        return Date().timeIntervalSince(lastPublishedAt) < 15
    }
}
