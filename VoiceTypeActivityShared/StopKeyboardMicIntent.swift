import AppIntents

struct StopKeyboardMicIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn off microphone"
    static let description = IntentDescription("Stop VoiceType's current keyboard microphone session.")
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = false

    @Parameter(title: "Session") var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingBridgeStore.requestImmediateStop(sessionID: sessionID)
        return .result()
    }
}
