import Foundation

/// Continues the user's keyboard activation through foregrounding and sign-in.
/// This starts the background availability window, never a transcription clip.
@MainActor
enum KeyboardMicActivation {
    enum Outcome: Equatable {
        case none
        case needsSignIn
        case ready
        case recording
        case transcribing
        case busy
        case failed
    }

    static func continuePendingRequest(
        appState: AppState,
        account: AccountStore,
        recorder: RecordingController,
        isAppActive: Bool
    ) async -> Outcome {
        guard isAppActive, appState.hasPendingKeyboardMicAutoStart else { return .none }
        // Keep the short-lived intent while the user completes sign-in. Ordinary
        // later launches cannot reuse an expired or already consumed request.
        guard account.isSignedIn else { return .needsSignIn }
        guard appState.consumeKeyboardMicAutoStart() else { return .none }
        // A duplicate link must not cancel or replace an outstanding system
        // microphone permission prompt. That first request continues normally.
        guard !recorder.isStarting else { return .none }
        guard recorder.isKeyboardSessionActive || (!recorder.isRecording && !recorder.isProcessing) else {
            return .busy
        }
        let hadExistingSession = recorder.isKeyboardSessionActive
        let accountSessionID = account.sessionID
        let token = account.token
        await recorder.startKeyboardReady(account: account)
        // The bridge can already show "off" at the deadline while the app's
        // timer has not run yet. Close that old window first, then honor this
        // fresh, explicit keyboard request by creating a new window once.
        if hadExistingSession, !recorder.isKeyboardSessionActive,
           !recorder.isRecording, !recorder.isProcessing, !recorder.isStarting,
           recorder.errorMessage == nil, !Task.isCancelled,
           account.matchesSession(accountSessionID, token: token) {
            await recorder.startKeyboardReady(account: account)
        }
        if recorder.isKeyboardReady { return .ready }
        if recorder.isKeyboardRecording { return .recording }
        if recorder.isKeyboardTranscribing { return .transcribing }
        return .failed
    }
}
