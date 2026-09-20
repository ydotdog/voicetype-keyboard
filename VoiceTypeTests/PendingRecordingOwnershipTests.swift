import Foundation
import Testing
@testable import VoiceType

@Suite(.serialized)
@MainActor
struct PendingRecordingOwnershipTests {
    private let ownerID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    private func auth(userID: String) -> AuthResponse {
        AuthResponse(
            token: "pending-test-token-\(userID)",
            user: UserProfile(id: userID, email: nil),
            balance: BalancePayload(balanceUSDMicros: 100, balanceCreditUnits: 100, formatted: "100 credits")
        )
    }

    private func seedRecording() throws -> (directory: URL, audio: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-recording-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("saved.m4a")
        try Data("retained audio bytes".utf8).write(to: audio)
        let metadata: [String: Any] = [
            "fileURL": audio.absoluteString,
            "duration": 42.0,
            "requestID": UUID().uuidString,
            "userID": ownerID
        ]
        try JSONSerialization.data(withJSONObject: metadata)
            .write(to: directory.appendingPathComponent("recording.json"))
        return (directory, audio)
    }

    private func savedAudio(in directory: URL) throws -> URL {
        try #require(RecordingRecoveryQueue(directory: directory).orderedRecordings.first?.fileURL)
    }

    @Test func expiredSessionHidesAudioAndOwnerCanRecoverAfterRelaunch() throws {
        let saved = try seedRecording()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let account = AccountStore()
        defer { account.signOut() }
        let recorder = RecordingController(recoveryDirectory: saved.directory)
        #expect(!recorder.hasFailedTranscription)
        #expect(recorder.failedTranscriptionDuration == 0)
        account.apply(auth: auth(userID: ownerID))
        recorder.reconcileFailedTranscription(account: account)
        #expect(recorder.hasFailedTranscription)
        #expect(recorder.failedTranscriptionDuration == 42)

        account.signOut(preservePendingRecording: true)
        recorder.cancel(discardFailed: account.shouldDiscardPendingRecording)
        recorder.reconcileFailedTranscription(account: account)
        #expect(!recorder.hasFailedTranscription)
        #expect(recorder.failedTranscriptionDuration == 0)
        let retainedAudio = try savedAudio(in: saved.directory)
        #expect(try Data(contentsOf: retainedAudio) == Data("retained audio bytes".utf8))

        let relaunched = RecordingController(recoveryDirectory: saved.directory)
        relaunched.reconcileFailedTranscription(account: account)
        #expect(!relaunched.hasFailedTranscription)
        account.apply(auth: auth(userID: ownerID))
        relaunched.reconcileFailedTranscription(account: account)
        #expect(relaunched.hasFailedTranscription)
        #expect(relaunched.failedTranscriptionDuration == 42)
    }

    @Test func differentOwnerAndExplicitSignOutDiscardRetainedAudio() throws {
        let account = AccountStore()
        defer { account.signOut() }
        let otherOwnerRecording = try seedRecording()
        defer { try? FileManager.default.removeItem(at: otherOwnerRecording.directory) }
        let wrongOwnerRecorder = RecordingController(recoveryDirectory: otherOwnerRecording.directory)
        account.apply(auth: auth(userID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        wrongOwnerRecorder.reconcileFailedTranscription(account: account)
        #expect(!wrongOwnerRecorder.hasFailedTranscription)
        #expect(!FileManager.default.fileExists(atPath: otherOwnerRecording.directory.path))

        let explicitSignOutRecording = try seedRecording()
        defer { try? FileManager.default.removeItem(at: explicitSignOutRecording.directory) }
        let recorder = RecordingController(recoveryDirectory: explicitSignOutRecording.directory)
        account.apply(auth: auth(userID: ownerID))
        recorder.reconcileFailedTranscription(account: account)
        #expect(recorder.hasFailedTranscription)
        account.signOut()
        recorder.cancel(discardFailed: account.shouldDiscardPendingRecording)
        #expect(!recorder.hasFailedTranscription)
        #expect(!FileManager.default.fileExists(atPath: explicitSignOutRecording.directory.path))
    }

    @Test func retryWithoutAuthenticationPreservesAudio() async throws {
        let saved = try seedRecording()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let account = AccountStore()
        account.signOut(preservePendingRecording: true)
        let recorder = RecordingController(recoveryDirectory: saved.directory)
        await recorder.retryFailedTranscription(account: account)
        #expect(!recorder.hasFailedTranscription)
        let retainedAudio = try savedAudio(in: saved.directory)
        #expect(FileManager.default.fileExists(atPath: retainedAudio.path))
        #expect(!recorder.isProcessing)
    }
}
