import Foundation

struct RecordingBridgeState: Codable, Equatable {
    let sessionID: String
    let isRecording: Bool
    let startedAt: Date?
    let durationLimit: RecordingDurationLimit

    static let inactive = RecordingBridgeState(
        sessionID: "",
        isRecording: false,
        startedAt: nil,
        durationLimit: .fiveMinutes
    )
}

struct RecordingBridgeCommand: Codable, Equatable {
    enum Action: String, Codable {
        case stop
    }

    let id: String
    let action: Action
    let createdAt: Date
}

enum RecordingBridgeStore {
    private static let stateKey = "recordingBridgeState"
    private static let commandKey = "recordingBridgeCommand"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static var state: RecordingBridgeState {
        get {
            guard
                let defaults = UserDefaults(suiteName: AppConstants.appGroup),
                let data = defaults.data(forKey: stateKey),
                let state = try? decoder.decode(RecordingBridgeState.self, from: data)
            else {
                return .inactive
            }
            return state
        }
        set {
            guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
            if newValue.isRecording, let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: stateKey)
            } else {
                defaults.removeObject(forKey: stateKey)
            }
        }
    }

    static var latestCommand: RecordingBridgeCommand? {
        guard
            let defaults = UserDefaults(suiteName: AppConstants.appGroup),
            let data = defaults.data(forKey: commandKey)
        else {
            return nil
        }
        return try? decoder.decode(RecordingBridgeCommand.self, from: data)
    }

    static func requestStop() {
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
        let command = RecordingBridgeCommand(id: UUID().uuidString, action: .stop, createdAt: Date())
        guard let data = try? encoder.encode(command) else { return }
        defaults.set(data, forKey: commandKey)
    }

    static func clearCommand(id: String) {
        guard latestCommand?.id == id else { return }
        UserDefaults(suiteName: AppConstants.appGroup)?.removeObject(forKey: commandKey)
    }
}
