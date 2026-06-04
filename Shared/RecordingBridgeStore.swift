import Foundation

enum RecordingBridgeMode: String, Codable, Equatable {
    case standard
    case keyboardReady
    case keyboardRecording
    case transcribing
}

struct RecordingBridgeState: Codable, Equatable {
    let sessionID: String
    let isRecording: Bool
    let startedAt: Date?
    let updatedAt: Date?
    let durationLimit: RecordingDurationLimit
    let mode: RecordingBridgeMode

    init(
        sessionID: String,
        isRecording: Bool,
        startedAt: Date?,
        updatedAt: Date? = nil,
        durationLimit: RecordingDurationLimit,
        mode: RecordingBridgeMode
    ) {
        self.sessionID = sessionID
        self.isRecording = isRecording
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.durationLimit = durationLimit
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case sessionID
        case isRecording
        case startedAt
        case updatedAt
        case durationLimit
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        isRecording = try container.decode(Bool.self, forKey: .isRecording)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        durationLimit = try container.decode(RecordingDurationLimit.self, forKey: .durationLimit)
        mode = try container.decodeIfPresent(RecordingBridgeMode.self, forKey: .mode) ?? .standard
    }

    static let inactive = RecordingBridgeState(
        sessionID: "",
        isRecording: false,
        startedAt: nil,
        updatedAt: nil,
        durationLimit: .fiveMinutes,
        mode: .standard
    )

    var isKeyboardReady: Bool {
        mode == .keyboardReady || mode == .keyboardRecording || mode == .transcribing
    }

    var isKeyboardRecording: Bool {
        mode == .keyboardRecording
    }
}

struct RecordingBridgeCommand: Codable, Equatable {
    enum Action: String, Codable {
        case stop
        case startClip
        case stopClip
    }

    let id: String
    let action: Action
    let createdAt: Date
}

enum RecordingBridgeStore {
    private static let stateKey = "recordingBridgeState"
    private static let commandKey = "recordingBridgeCommand"
    private static let staleKeyboardStateInterval: TimeInterval = 10

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
            if state.isKeyboardReady {
                let heartbeat = state.updatedAt ?? state.startedAt ?? .distantPast
                if Date().timeIntervalSince(heartbeat) > staleKeyboardStateInterval {
                    defaults.removeObject(forKey: stateKey)
                    defaults.synchronize()
                    return .inactive
                }
            }
            return state
        }
        set {
            guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
            if (newValue.isRecording || newValue.isKeyboardReady), let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: stateKey)
            } else {
                defaults.removeObject(forKey: stateKey)
            }
            defaults.synchronize()
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
        writeCommand(.stop)
    }

    static func requestStartClip() {
        writeCommand(.startClip)
    }

    static func requestStopClip() {
        writeCommand(.stopClip)
    }

    private static func writeCommand(_ action: RecordingBridgeCommand.Action) {
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
        let command = RecordingBridgeCommand(id: UUID().uuidString, action: action, createdAt: Date())
        guard let data = try? encoder.encode(command) else { return }
        defaults.set(data, forKey: commandKey)
        defaults.synchronize()
    }

    static func clearCommand(id: String) {
        guard latestCommand?.id == id else { return }
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
        defaults.removeObject(forKey: commandKey)
        defaults.synchronize()
    }
}
