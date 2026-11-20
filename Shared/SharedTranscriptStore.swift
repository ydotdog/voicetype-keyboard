import Foundation

struct TranscriptSnapshot: Codable, Equatable, Identifiable {
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

    /// A recovered older clip belongs in History. Publishing it as `latest`
    /// could insert it into a different, newly armed keyboard dictation.
    static func appendHistory(_ snapshot: TranscriptSnapshot) {
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
        appendToHistory(snapshot, defaults: defaults)
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

/// Text the service has heard so far in the keyboard clip being transcribed.
struct PartialTranscript: Codable, Equatable {
    let sessionID: String
    let text: String
}

/// The keyboard previews this text and never inserts it: it is raw provider
/// output, before normalization and saved corrections. A disposable file like
/// the audio meter, since deltas arrive several times a second and only the
/// latest matters. The app clears it when the clip finishes or fails.
enum PartialTranscriptStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let fileURL: URL? = {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) else { return nil }
        let directory = container.appendingPathComponent("Library/Caches/PartialTranscript", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("partial.json")
        } catch { return nil }
    }()

    static func publish(_ text: String, sessionID: String) {
        guard let fileURL, !sessionID.isEmpty,
              let data = try? encoder.encode(PartialTranscript(sessionID: sessionID, text: text)) else { return }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = .atomic
        #endif
        do {
            try data.write(to: fileURL, options: options)
        } catch {
            // iOS may purge Caches while the keyboard session is open.
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: options)
        }
    }

    /// Only the keyboard session that recorded the clip sees its text.
    static func latest(for sessionID: String) -> PartialTranscript? {
        guard let fileURL, !sessionID.isEmpty,
              let data = try? Data(contentsOf: fileURL),
              let partial = try? decoder.decode(PartialTranscript.self, from: data),
              partial.sessionID == sessionID,
              !partial.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return partial
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
