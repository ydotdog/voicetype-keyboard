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
                "Recording"
            case .transcribing:
                "Transcribing"
            case .keyboardReady:
                "Keyboard mic ready"
            case .standard:
                "VoiceType"
            }
        }

        var subtitle: String {
            switch mode {
            case .keyboardRecording:
                "Tap Stop in the keyboard when done."
            case .transcribing:
                "Finishing your clip."
            case .keyboardReady:
                "Ready in other apps."
            case .standard:
                "Open VoiceType to start."
            }
        }
    }

    let sessionID: String
}
