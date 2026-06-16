import ActivityKit
import Foundation

struct VoiceTypeKeyboardActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let mode: RecordingBridgeMode
        let startedAt: Date?
        let updatedAt: Date
        let durationLimit: RecordingDurationLimit

        var title: String {
            switch mode {
            case .keyboardRecording:
                "Listening"
            case .transcribing:
                "Transcribing"
            case .keyboardReady:
                "Ready"
            case .standard:
                "VoiceType"
            }
        }

        var subtitle: String {
            switch mode {
            case .keyboardRecording:
                "VoiceType keyboard"
            case .transcribing:
                "Finishing clip"
            case .keyboardReady:
                "Keyboard mic on"
            case .standard:
                "Keyboard mic"
            }
        }
    }

    let sessionID: String
}
