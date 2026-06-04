import Foundation

enum RecordingDurationLimit: String, CaseIterable, Codable, Identifiable {
    case fiveMinutes
    case twelveHours
    case always

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .fiveMinutes:
            "5 min"
        case .twelveHours:
            "12 hr"
        case .always:
            "Forever"
        }
    }

    var maximumDuration: TimeInterval? {
        switch self {
        case .fiveMinutes:
            5 * 60
        case .twelveHours:
            12 * 60 * 60
        case .always:
            nil
        }
    }
}

enum RecordingPreferencesStore {
    private static let durationLimitKey = "recordingDurationLimit"

    static var durationLimit: RecordingDurationLimit {
        get {
            guard
                let defaults = UserDefaults(suiteName: AppConstants.appGroup),
                let rawValue = defaults.string(forKey: durationLimitKey),
                let value = RecordingDurationLimit(rawValue: rawValue)
            else {
                return .fiveMinutes
            }
            return value
        }
        set {
            guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
            defaults.set(newValue.rawValue, forKey: durationLimitKey)
            defaults.synchronize()
        }
    }
}
