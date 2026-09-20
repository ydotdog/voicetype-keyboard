@preconcurrency import ActivityKit
import Foundation

@MainActor
final class KeyboardMicLiveActivityController {
    static let shared = KeyboardMicLiveActivityController()

    private var activity: Activity<VoiceTypeKeyboardActivityAttributes>?
    private var lastPublishedState: VoiceTypeKeyboardActivityAttributes.ContentState?
    private var lastPublishedAt: Date?

    // The newest epoch that has been allowed to take effect. RecordingController
    // stamps every update/end with a monotonic epoch reflecting the true *intent*
    // order, even though the Tasks that deliver them can run out of order. Any
    // operation that arrives carrying an older epoch is dropped, so a stale
    // "recording" update can never overtake a later "end" and resurrect the Live
    // Activity after the mic is already off.
    private var latestEpoch: UInt64 = 0

    // ActivityKit calls suspend (each request/update/end is an await), so two
    // operations spawned as independent Tasks could otherwise interleave at those
    // suspension points -- an end() could run *through the middle* of an update()
    // that is still creating an activity, leaving a recording activity stranded.
    // Chaining every operation onto this serial Task guarantees each one runs to
    // completion before the next begins.
    private var operationChain: Task<Void, Never>?

    private init() {}

    func update(
        sessionID: String,
        mode: RecordingBridgeMode,
        startedAt: Date?,
        durationLimit: RecordingDurationLimit,
        epoch: UInt64,
        expiresAt: Date? = nil,
        force: Bool = false
    ) async {
        await serialize(epoch: epoch) { [weak self] in
            await self?.performUpdate(
                sessionID: sessionID,
                mode: mode,
                startedAt: startedAt,
                durationLimit: durationLimit,
                expiresAt: expiresAt,
                force: force
            )
        }
    }

    func end(epoch: UInt64) async {
        await serialize(epoch: epoch) { [weak self] in
            await self?.endAllActivities()
        }
    }

    private func serialize(epoch: UInt64, _ work: @escaping @MainActor () async -> Void) async {
        let previous = operationChain
        let task = Task { @MainActor in
            await previous?.value
            // Drop anything the controller has already superseded. The check runs
            // when the operation actually executes (after every earlier one has
            // finished), so the highest-epoch intent always wins regardless of the
            // order in which the delivering Tasks were scheduled.
            guard epoch >= self.latestEpoch else { return }
            self.latestEpoch = epoch
            await work()
        }
        operationChain = task
        await task.value
    }

    private func performUpdate(
        sessionID: String,
        mode: RecordingBridgeMode,
        startedAt: Date?,
        durationLimit: RecordingDurationLimit,
        expiresAt: Date?,
        force: Bool
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard mode == .keyboardReady || mode == .keyboardRecording || mode == .transcribing else {
            await endAllActivities()
            return
        }

        let state = VoiceTypeKeyboardActivityAttributes.ContentState(
            mode: mode,
            startedAt: startedAt,
            updatedAt: Date(),
            durationLimit: durationLimit
        )
        if !force, activity?.attributes.sessionID == sessionID, shouldSkipUpdate(state) {
            return
        }

        do {
            let staleDate = RecordingSessionPolicy.statusStaleDate(now: Date(), expiresAt: expiresAt, mode: mode)
            let activity = try await currentActivity(sessionID: sessionID, state: state, staleDate: staleDate)
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
            self.activity = activity
            lastPublishedState = state
            lastPublishedAt = Date()
        } catch {
            self.activity = nil
        }
    }

    private func endAllActivities() async {
        let content = ActivityContent(state: endState(), staleDate: nil)
        for activity in Activity<VoiceTypeKeyboardActivityAttributes>.activities {
            await activity.end(content, dismissalPolicy: .immediate)
        }
        activity = nil
        lastPublishedState = nil
        lastPublishedAt = nil
    }

    private func endState() -> VoiceTypeKeyboardActivityAttributes.ContentState {
        VoiceTypeKeyboardActivityAttributes.ContentState(
            mode: .standard,
            startedAt: nil,
            updatedAt: Date(),
            durationLimit: .fiveMinutes
        )
    }

    private func currentActivity(
        sessionID: String,
        state: VoiceTypeKeyboardActivityAttributes.ContentState,
        staleDate: Date
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
            content: ActivityContent(state: state, staleDate: staleDate),
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
        if lastPublishedState.mode != state.mode || lastPublishedState.durationLimit != state.durationLimit
            || lastPublishedState.startedAt != state.startedAt {
            return false
        }
        return Date().timeIntervalSince(lastPublishedAt) < 15
    }
}
