import AVFoundation
import Foundation
import UIKit

@MainActor
final class RecordingController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var lastTranscript = SharedTranscriptStore.latest
    @Published var durationLimit = RecordingPreferencesStore.durationLimit {
        didSet {
            RecordingPreferencesStore.durationLimit = durationLimit
        }
    }
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var currentFileURL: URL?
    private weak var activeAccount: AccountStore?
    private var activeSessionID = ""
    private var activeDurationLimit = RecordingPreferencesStore.durationLimit
    private var handledCommandID: String?
    private var isStopping = false

    var statusText: String {
        if isRecording {
            return "Recording \(Self.durationFormatter.string(from: elapsedSeconds) ?? "0:00")"
        }
        if isProcessing {
            return "Transcribing"
        }
        return "Ready"
    }

    func refreshLatest() {
        lastTranscript = SharedTranscriptStore.latest
    }

    func startRecording(account: AccountStore) async {
        guard !isRecording, !isProcessing else { return }
        errorMessage = nil

        let hasPermission = await requestMicrophonePermission()
        guard hasPermission else {
            errorMessage = "Microphone permission is required."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voicetype-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder.isMeteringEnabled = true
            audioRecorder.delegate = self
            let didStartRecording: Bool
            if let maximumDuration = durationLimit.maximumDuration {
                didStartRecording = audioRecorder.record(forDuration: maximumDuration)
            } else {
                didStartRecording = audioRecorder.record()
            }
            guard didStartRecording else {
                try? FileManager.default.removeItem(at: fileURL)
                throw RecorderError.failedToStart
            }

            recorder = audioRecorder
            currentFileURL = fileURL
            let startedAt = Date()
            self.startedAt = startedAt
            activeAccount = account
            activeSessionID = UUID().uuidString
            activeDurationLimit = durationLimit
            handledCommandID = RecordingBridgeStore.latestCommand?.id
            elapsedSeconds = 0
            isRecording = true
            RecordingBridgeStore.state = RecordingBridgeState(
                sessionID: activeSessionID,
                isRecording: true,
                startedAt: startedAt,
                durationLimit: activeDurationLimit
            )
            startTimer()
        } catch {
            RecordingBridgeStore.state = .inactive
            KeyboardAutoInsertStore.clear()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    func stopAndTranscribe(account: AccountStore) async {
        guard isRecording, !isStopping, let fileURL = currentFileURL, let startedAt else { return }
        isStopping = true
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VoiceTypeTranscription")
        recorder?.stop()
        recorder = nil
        isRecording = false
        isProcessing = true
        stopTimer()
        RecordingBridgeStore.state = .inactive
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let duration = Date().timeIntervalSince(startedAt)
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
            try? FileManager.default.removeItem(at: fileURL)
            currentFileURL = nil
            self.startedAt = nil
            activeAccount = nil
            activeSessionID = ""
            activeDurationLimit = durationLimit
            handledCommandID = nil
            isStopping = false
            elapsedSeconds = 0
            isProcessing = false
        }

        do {
            #if DEBUG
            if account.isPreviewMode {
                let snapshot = TranscriptSnapshot(
                    id: UUID().uuidString,
                    text: "This is a local preview transcript from VoiceType.",
                    createdAt: Date(),
                    chargeText: "0 credits"
                )
                SharedTranscriptStore.latest = snapshot
                lastTranscript = snapshot
                return
            }
            #endif

            let response = try await BackendClient.transcribe(fileURL: fileURL, duration: duration, token: account.token)
            let snapshot = TranscriptSnapshot(
                id: response.id,
                text: response.transcript,
                createdAt: Date(),
                chargeText: response.charge.formatted
            )
            SharedTranscriptStore.latest = snapshot
            lastTranscript = snapshot
            account.apply(balance: response.balance)
        } catch {
            KeyboardAutoInsertStore.clear()
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        guard isRecording else { return }
        isStopping = true
        recorder?.stop()
        recorder = nil
        isRecording = false
        stopTimer()
        RecordingBridgeStore.state = .inactive
        KeyboardAutoInsertStore.clear()
        if let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
        }
        currentFileURL = nil
        startedAt = nil
        activeAccount = nil
        activeSessionID = ""
        activeDurationLimit = durationLimit
        handledCommandID = nil
        isStopping = false
        elapsedSeconds = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.isRecording, !self.isStopping, self.recorder === recorder else { return }
            guard flag, let activeAccount = self.activeAccount else {
                self.cancel()
                return
            }
            await self.stopAndTranscribe(account: activeAccount)
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { isGranted in
                    continuation.resume(returning: isGranted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsedSeconds = Date().timeIntervalSince(startedAt)
                await self.stopIfDurationLimitReached()
                await self.handleBridgeCommandIfNeeded()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    private func handleBridgeCommandIfNeeded() async {
        guard
            isRecording,
            let command = RecordingBridgeStore.latestCommand,
            command.id != handledCommandID
        else {
            return
        }

        handledCommandID = command.id
        switch command.action {
        case .stop:
            RecordingBridgeStore.clearCommand(id: command.id)
            guard let activeAccount else { return }
            await stopAndTranscribe(account: activeAccount)
        }
    }

    private func stopIfDurationLimitReached() async {
        guard
            isRecording,
            let maximumDuration = activeDurationLimit.maximumDuration,
            elapsedSeconds >= maximumDuration,
            let activeAccount
        else {
            return
        }
        await stopAndTranscribe(account: activeAccount)
    }
}

enum RecorderError: LocalizedError {
    case failedToStart

    var errorDescription: String? {
        "Recording did not start. Check microphone permission and try again."
    }
}
