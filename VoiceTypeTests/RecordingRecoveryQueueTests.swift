import Foundation
import Testing
@testable import VoiceType

@Suite(.serialized)
@MainActor
struct RecordingRecoveryQueueTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recording(in root: URL, owner: String = "owner", start: Double? = nil) throws -> RecoverableRecording {
        let id = UUID()
        let file = root.appendingPathComponent("source-\(id).m4a")
        try Data(id.uuidString.utf8).write(to: file)
        return RecoverableRecording(fileURL: file, duration: 7, clipStartTime: start, requestID: id, userID: owner)
    }

    @Test func independentJobsSurviveReplacementRemovalAndRelaunch() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("queue")
        let queue = RecordingRecoveryQueue(directory: directory)
        let first = try recording(in: root)
        let second = try recording(in: root)
        #expect(queue.save(first))
        #expect(queue.save(second))
        let secondURL = try #require(queue.recordings[second.requestID]?.fileURL)
        try queue.remove(id: first.requestID)
        let reopened = RecordingRecoveryQueue(directory: directory)
        #expect(reopened.recordings.count == 1)
        #expect(reopened.recordings[second.requestID]?.userID == second.userID)
        #expect(try Data(contentsOf: secondURL) == Data(second.requestID.uuidString.utf8))
    }

    @Test func migratesLegacyRequestOwnerAndClipOffsetsWithoutLosingAudio() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try recording(in: root, start: 42)
        let payload: [String: Any] = ["fileURL": original.fileURL.absoluteString, "duration": 7,
            "clipStartTime": 42, "requestID": original.requestID.uuidString, "userID": original.userID]
        let legacy = root.appendingPathComponent("recording.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: legacy)
        let queue = RecordingRecoveryQueue(directory: root)
        let migrated = try #require(queue.recordings[original.requestID])
        #expect(migrated.clipStartTime == 42)
        #expect(migrated.duration == 7)
        #expect(migrated.userID == original.userID)
        #expect(try Data(contentsOf: migrated.fileURL) == Data(original.requestID.uuidString.utf8))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(RecordingRecoveryQueue(directory: root).recordings[original.requestID]?.requestID == original.requestID)
    }

    @Test func storageFailureRetainsNewSourceAndPreviousDurableJobs() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("queue")
        var diskFull = false
        let queue = RecordingRecoveryQueue(directory: directory) { source, destination in
            if diskFull { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let first = try recording(in: root)
        let second = try recording(in: root)
        #expect(queue.save(first))
        diskFull = true
        #expect(!queue.save(second))
        #expect(queue.containsAudio(at: second.fileURL))
        #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
        #expect(RecordingRecoveryQueue(directory: directory).recordings[first.requestID] != nil)
        diskFull = false
        #expect(queue.save(second))
        // Saving a volatile original cannot delete the file about to be uploaded.
        #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
        #expect(RecordingRecoveryQueue(directory: directory).recordings.count == 2)
    }

    @Test func failedReplacementKeepsPreviousDurableSegmentAndOwnerDeletionIsScoped() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("queue")
        let original = try recording(in: root, owner: "A", start: 40)
        let other = try recording(in: root, owner: "B")
        let initial = RecordingRecoveryQueue(directory: directory)
        #expect(initial.save(original))
        #expect(initial.save(other))
        let queue = RecordingRecoveryQueue(directory: directory) { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let preparedURL = root.appendingPathComponent("prepared.m4a")
        try Data("prepared segment".utf8).write(to: preparedURL)
        let replacement = RecoverableRecording(fileURL: preparedURL, duration: 7, clipStartTime: nil,
                                              requestID: original.requestID, userID: "A")
        #expect(!queue.save(replacement))
        #expect(queue.containsAudio(at: preparedURL))
        let restored = RecordingRecoveryQueue(directory: directory)
        #expect(restored.recordings[original.requestID]?.clipStartTime == 40)
        try restored.removeOtherOwners(keeping: "A")
        #expect(restored.recordings[original.requestID] != nil)
        #expect(restored.recordings[other.requestID] == nil)
    }
}
