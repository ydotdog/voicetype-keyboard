import AVFoundation
import Foundation

@MainActor
final class RecordingController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var lastTranscript = SharedTranscriptStore.latest
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var currentFileURL: URL?

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

    func startRecording() async {
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
            guard audioRecorder.record() else {
                try? FileManager.default.removeItem(at: fileURL)
                throw RecorderError.failedToStart
            }

            recorder = audioRecorder
            currentFileURL = fileURL
            startedAt = Date()
            elapsedSeconds = 0
            isRecording = true
            startTimer()
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    func stopAndTranscribe(account: AccountStore) async {
        guard isRecording, let fileURL = currentFileURL, let startedAt else { return }
        recorder?.stop()
        recorder = nil
        isRecording = false
        isProcessing = true
        stopTimer()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let duration = Date().timeIntervalSince(startedAt)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            currentFileURL = nil
            self.startedAt = nil
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
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        guard isRecording else { return }
        recorder?.stop()
        recorder = nil
        isRecording = false
        stopTimer()
        if let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
        }
        currentFileURL = nil
        startedAt = nil
        elapsedSeconds = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
}

enum RecorderError: LocalizedError {
    case failedToStart

    var errorDescription: String? {
        "Recording did not start. Check microphone permission and try again."
    }
}
