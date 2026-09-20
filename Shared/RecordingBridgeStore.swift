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
    let expiresAt: Date?
    /// Normalized measured microphone power for the active keyboard clip.
    /// No audio samples or speech content are shared with the keyboard.
    let audioLevel: Double

    init(
        sessionID: String,
        isRecording: Bool,
        startedAt: Date?,
        updatedAt: Date? = nil,
        durationLimit: RecordingDurationLimit,
        mode: RecordingBridgeMode,
        expiresAt: Date? = nil,
        audioLevel: Double = 0
    ) {
        self.sessionID = sessionID
        self.isRecording = isRecording
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.durationLimit = durationLimit
        self.mode = mode
        self.expiresAt = expiresAt
        self.audioLevel = mode == .keyboardRecording && isRecording ? Self.clampedAudioLevel(audioLevel) : 0
    }

    enum CodingKeys: String, CodingKey {
        case sessionID
        case isRecording
        case startedAt
        case updatedAt
        case durationLimit
        case mode
        case expiresAt
        case audioLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        isRecording = try container.decode(Bool.self, forKey: .isRecording)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        durationLimit = try container.decode(RecordingDurationLimit.self, forKey: .durationLimit)
        mode = try container.decodeIfPresent(RecordingBridgeMode.self, forKey: .mode) ?? .standard
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        let decodedLevel = (try? container.decode(Double.self, forKey: .audioLevel)) ?? 0
        audioLevel = mode == .keyboardRecording && isRecording ? Self.clampedAudioLevel(decodedLevel) : 0
    }

    private static func clampedAudioLevel(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
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

    func validated(at now: Date) -> RecordingBridgeState {
        guard isRecording || isKeyboardReady else { return .inactive }
        let heartbeatAge = now.timeIntervalSince(updatedAt ?? startedAt ?? .distantPast)
        guard heartbeatAge >= -2, heartbeatAge <= 10 else { return .inactive }
        // An upload may finish after capture expires. It remains transcribing,
        // while fresh keyboard-ready/recording snapshots must honor the deadline.
        if mode != .transcribing {
            let legacyDeadline = durationLimit.maximumDuration.flatMap { limit in
                startedAt?.addingTimeInterval(limit)
            }
            if let deadline = expiresAt ?? legacyDeadline, now >= deadline { return .inactive }
        }
        return self
    }
}

struct RecordingBridgeCommand: Codable, Equatable {
    enum Action: String, Codable {
        case stop
        case dismissKeyboardSession
        case startClip
        case stopClip
    }

    let id: String
    let action: Action
    let createdAt: Date
    let sessionID: String?

    init(id: String, action: Action, createdAt: Date, sessionID: String? = nil) {
        self.id = id
        self.action = action
        self.createdAt = createdAt
        self.sessionID = sessionID
    }
}

enum RecordingBridgeStore {
    static let commandNotificationName = "com.kyleqi.voicetype.recording-bridge-command"

    private static let stateKey = "recordingBridgeState"
    private static let commandKey = "recordingBridgeCommand"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid recording timestamp")
        }
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
            // Readers never delete snapshots: another process may already have
            // published a newer heartbeat while this snapshot was being decoded.
            return state.validated(at: Date())
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

    static func requestImmediateStop(sessionID: String) {
        guard !sessionID.isEmpty, state.sessionID == sessionID else { return }
        writeCommand(.dismissKeyboardSession, sessionID: sessionID)
    }

    private static func writeCommand(_ action: RecordingBridgeCommand.Action, sessionID: String? = nil) {
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
        let command = RecordingBridgeCommand(
            id: UUID().uuidString, action: action, createdAt: Date(), sessionID: sessionID ?? state.sessionID
        )
        guard let data = try? encoder.encode(command) else { return }
        defaults.set(data, forKey: commandKey)
        defaults.synchronize()
        postCommandNotification()
    }

    static func clearCommand(id: String) {
        guard latestCommand?.id == id else { return }
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
        defaults.removeObject(forKey: commandKey)
        defaults.synchronize()
    }

    private static func postCommandNotification() {
        let name = CFNotificationName(commandNotificationName as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }
}
