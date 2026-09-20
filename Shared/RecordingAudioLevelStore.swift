import Foundation

struct RecordingAudioLevelSample: Codable, Equatable {
    let sessionID: String
    let level: Double
    let sampledAt: TimeInterval

    var date: Date { Date(timeIntervalSince1970: sampledAt) }
}

/// A tiny, disposable signal separate from durable preferences and session IPC.
/// Atomic replacement lets the keyboard read complete measured samples without
/// flushing UserDefaults, rewriting dates or updating Live Activities per frame.
enum RecordingAudioLevelStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let fileURL: URL? = {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) else { return nil }
        let directory = container.appendingPathComponent("Library/Caches/RecordingMeter", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("level.json")
        } catch { return nil }
    }()

    static func publish(sessionID: String, level: Double, at date: Date = Date()) {
        guard let fileURL, !sessionID.isEmpty, date.timeIntervalSince1970.isFinite else { return }
        let sample = RecordingAudioLevelSample(
            sessionID: sessionID,
            level: level.isFinite ? min(1, max(0, level)) : 0,
            sampledAt: date.timeIntervalSince1970
        )
        guard let data = try? encoder.encode(sample) else { return }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = .atomic
        #endif
        do {
            try data.write(to: fileURL, options: options)
        } catch {
            // iOS may purge Caches during a long mic session. Restore only this
            // disposable signal directory, without changing recording state.
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: options)
        }
    }

    static func latest(for sessionID: String, at now: Date = Date()) -> RecordingAudioLevelSample? {
        guard let fileURL, !sessionID.isEmpty,
              let data = try? Data(contentsOf: fileURL),
              let sample = try? decoder.decode(RecordingAudioLevelSample.self, from: data),
              sample.sessionID == sessionID, sample.level.isFinite,
              (0...1).contains(sample.level), sample.sampledAt.isFinite,
              (-0.1...0.4).contains(now.timeIntervalSince1970 - sample.sampledAt)
        else { return nil }
        return sample
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
