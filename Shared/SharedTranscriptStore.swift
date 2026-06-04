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
    private static let transcriptHistoryKey = "transcriptHistory"
    private static let maximumHistoryCount = 100
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
                appendToHistory(newValue, defaults: defaults)
            }
            defaults.synchronize()
        }
    }

    static var history: [TranscriptSnapshot] {
        get {
            guard
                let defaults = UserDefaults(suiteName: AppConstants.appGroup),
                let data = defaults.data(forKey: transcriptHistoryKey),
                let snapshots = try? decoder.decode([TranscriptSnapshot].self, from: data)
            else {
                return []
            }
            return snapshots
        }
        set {
            guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
            let snapshots = Array(newValue.prefix(maximumHistoryCount))
            if snapshots.isEmpty {
                defaults.removeObject(forKey: transcriptHistoryKey)
            } else if let data = try? encoder.encode(snapshots) {
                defaults.set(data, forKey: transcriptHistoryKey)
            }
            defaults.synchronize()
        }
    }

    static func clear() {
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
        defaults.removeObject(forKey: latestTranscriptKey)
        defaults.removeObject(forKey: transcriptHistoryKey)
        defaults.synchronize()
    }

    private static func appendToHistory(_ snapshot: TranscriptSnapshot, defaults: UserDefaults) {
        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var snapshots = history.filter { $0.id != snapshot.id }
        snapshots.insert(snapshot, at: 0)
        snapshots = Array(snapshots.prefix(maximumHistoryCount))
        guard let data = try? encoder.encode(snapshots) else { return }
        defaults.set(data, forKey: transcriptHistoryKey)
    }
}
