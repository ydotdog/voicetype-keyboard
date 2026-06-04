import Foundation

struct TranscriptSnapshot: Codable, Equatable {
    let id: String
    let text: String
    let createdAt: Date
    let chargeText: String?

    static let empty = TranscriptSnapshot(id: "", text: "", createdAt: .distantPast, chargeText: nil)
}

enum SharedTranscriptStore {
    private static let latestTranscriptKey = "latestTranscript"
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

    static var latest: TranscriptSnapshot {
        get {
            guard
                let defaults = UserDefaults(suiteName: AppConstants.appGroup),
                let data = defaults.data(forKey: latestTranscriptKey),
                let snapshot = try? decoder.decode(TranscriptSnapshot.self, from: data)
            else {
                return .empty
            }
            return snapshot
        }
        set {
            guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
            if newValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.removeObject(forKey: latestTranscriptKey)
            } else if let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: latestTranscriptKey)
            }
            defaults.synchronize()
        }
    }
}
