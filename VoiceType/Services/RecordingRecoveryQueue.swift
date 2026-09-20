import Foundation

struct FailedTranscriptionSnapshot: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
}

struct RecoverableRecording: Codable {
    var fileURL: URL
    let duration: TimeInterval
    let clipStartTime: TimeInterval?
    let requestID: UUID
    let userID: String
    var createdAt: Date

    init(fileURL: URL, duration: TimeInterval, clipStartTime: TimeInterval?, requestID: UUID,
         userID: String, createdAt: Date = Date()) {
        self.fileURL = fileURL
        self.duration = duration
        self.clipStartTime = clipStartTime
        self.requestID = requestID
        self.userID = userID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case fileURL, duration, clipStartTime, requestID, userID, createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fileURL = try values.decode(URL.self, forKey: .fileURL)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        clipStartTime = try values.decodeIfPresent(TimeInterval.self, forKey: .clipStartTime)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        userID = try values.decode(String.self, forKey: .userID)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }
}

/// Each request owns an independent metadata/audio pair. Replacing one job is
/// committed by an atomic metadata write before the previous audio is removed.
@MainActor
final class RecordingRecoveryQueue {
    let directory: URL
    private(set) var recordings: [UUID: RecoverableRecording] = [:]
    private let copyFile: (URL, URL) throws -> Void
    private var legacyRequestID: UUID?

    init(directory: URL, copyFile: @escaping (URL, URL) throws -> Void = {
        try FileManager.default.copyItem(at: $0, to: $1)
    }) {
        self.directory = directory
        self.copyFile = copyFile
        restore()
    }

    var orderedRecordings: [RecoverableRecording] {
        recordings.values.sorted {
            if $0.createdAt == $1.createdAt { return $0.requestID.uuidString < $1.requestID.uuidString }
            return $0.createdAt > $1.createdAt
        }
    }

    func containsAudio(at url: URL) -> Bool {
        recordings.values.contains { $0.fileURL == url }
    }

    @discardableResult
    func save(_ recording: RecoverableRecording) -> Bool {
        guard isValid(recording) else { return false }
        var saved = recording
        let previous = recordings[recording.requestID]
        guard previous == nil || previous?.userID == recording.userID else { return false }
        if let previous { saved.createdAt = previous.createdAt }
        let jobDirectory = directory.appendingPathComponent(recording.requestID.uuidString, isDirectory: true)
        let metadataURL = jobDirectory.appendingPathComponent("recording.json")
        let sourceURL = recording.fileURL
        do {
            try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
            var root = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            saved.fileURL = jobDirectory.appendingPathComponent("audio-\(UUID().uuidString).m4a")
            try copyFile(sourceURL, saved.fileURL)
            try JSONEncoder().encode(saved).write(to: metadataURL, options: .atomic)
            recordings[saved.requestID] = saved
            if let previous, previous.fileURL != saved.fileURL, previous.fileURL != sourceURL {
                try? FileManager.default.removeItem(at: previous.fileURL)
            }
            return true
        } catch {
            if saved.fileURL != sourceURL { try? FileManager.default.removeItem(at: saved.fileURL) }
            // Keep the new finalized source in memory and any previous durable
            // metadata/audio on disk. Callers must not upload until save succeeds.
            saved.fileURL = sourceURL
            recordings[saved.requestID] = saved
            return false
        }
    }

    func remove(id: UUID) throws {
        guard let recording = recordings[id] else { return }
        let jobDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: jobDirectory.path) {
            try FileManager.default.removeItem(at: jobDirectory)
        }
        if FileManager.default.fileExists(atPath: recording.fileURL.path) {
            try FileManager.default.removeItem(at: recording.fileURL)
        }
        if legacyRequestID == id {
            let legacyMetadata = directory.appendingPathComponent("recording.json")
            if FileManager.default.fileExists(atPath: legacyMetadata.path) {
                try FileManager.default.removeItem(at: legacyMetadata)
            }
            legacyRequestID = nil
        }
        recordings.removeValue(forKey: id)
        if recordings.isEmpty, FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func removeAll() throws {
        // Volatile originals may live outside the queue during disk pressure.
        let originals = recordings.values.map(\.fileURL)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        for url in originals where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        recordings = [:]
        legacyRequestID = nil
    }

    func removeOtherOwners(keeping userID: String) throws {
        for recording in Array(recordings.values) where recording.userID != userID {
            try remove(id: recording.requestID)
        }
    }

    private func restore() {
        let directories = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in directories {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let recording = loadMetadata(at: folder.appendingPathComponent("recording.json")),
                  recording.requestID == id else { continue }
            recordings[id] = recording
        }
        let legacyURL = directory.appendingPathComponent("recording.json")
        guard let legacy = loadMetadata(at: legacyURL) else { return }
        legacyRequestID = legacy.requestID
        if recordings[legacy.requestID] == nil {
            recordings[legacy.requestID] = legacy
            guard save(legacy) else { return }
        }
        // A committed new record exists before retiring the old single slot.
        try? FileManager.default.removeItem(at: legacyURL)
        if recordings[legacy.requestID]?.fileURL != legacy.fileURL {
            try? FileManager.default.removeItem(at: legacy.fileURL)
        }
        legacyRequestID = nil
    }

    private func loadMetadata(at url: URL) -> RecoverableRecording? {
        guard let data = try? Data(contentsOf: url),
              var recording = try? JSONDecoder().decode(RecoverableRecording.self, from: data) else { return nil }
        recording.fileURL = url.deletingLastPathComponent().appendingPathComponent(recording.fileURL.lastPathComponent)
        if recording.createdAt == .distantPast {
            recording.createdAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        }
        return isValid(recording) ? recording : nil
    }

    private func isValid(_ recording: RecoverableRecording) -> Bool {
        guard !recording.userID.isEmpty, recording.duration.isFinite,
              recording.duration > 0, recording.duration <= RecordingSessionPolicy.maximumClipDuration + 1,
              recording.clipStartTime.map({ $0.isFinite && $0 >= 0 }) ?? true,
              let size = try? recording.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size > 0
    }
}
