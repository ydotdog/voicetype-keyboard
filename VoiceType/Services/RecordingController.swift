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
    private var bridgeMode: RecordingBridgeMode = .standard
    private var keyboardClipStartTime: TimeInterval?

    var isKeyboardReady: Bool {
        bridgeMode == .keyboardReady || bridgeMode == .keyboardRecording || bridgeMode == .transcribing
    }

    var isKeyboardRecording: Bool {
        bridgeMode == .keyboardRecording
    }

    var isKeyboardTranscribing: Bool {
        bridgeMode == .transcribing
    }

    var statusText: String {
        if isKeyboardRecording {
            return "Keyboard recording \(Self.durationFormatter.string(from: elapsedSeconds) ?? "0:00")"
        }
        if isKeyboardTranscribing {
            return "Transcribing"
        }
        if isKeyboardReady {
            return "Keyboard mic ready"
        }
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

            let (audioRecorder, fileURL) = try makeAudioRecorder()
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
            bridgeMode = .standard
            publishBridgeState()
            startTimer()
        } catch {
            RecordingBridgeStore.state = .inactive
            KeyboardAutoInsertStore.clear()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    func startKeyboardReady(account: AccountStore) async {
        guard !isKeyboardReady, !isRecording, !isProcessing else { return }
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

            let (audioRecorder, fileURL) = try makeAudioRecorder()
            guard audioRecorder.record() else {
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
            keyboardClipStartTime = nil
            elapsedSeconds = 0
            isRecording = false
            isProcessing = false
            bridgeMode = .keyboardReady
            publishBridgeState()
            startTimer()
        } catch {
            RecordingBridgeStore.state = .inactive
            KeyboardAutoInsertStore.clear()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    func stopKeyboardReady() {
        guard isKeyboardReady else { return }
        isStopping = true
        recorder?.stop()
        recorder = nil
        isStopping = false
        isRecording = false
        isProcessing = false
        bridgeMode = .standard
        keyboardClipStartTime = nil
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
        elapsedSeconds = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stopAndTranscribe(account: AccountStore) async {
        if bridgeMode == .keyboardRecording {
            await stopKeyboardClipAndTranscribe()
            return
        }
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
            bridgeMode = .standard
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
        if isKeyboardReady {
            stopKeyboardReady()
            return
        }
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
        bridgeMode = .standard
        isStopping = false
        elapsedSeconds = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.isRecording, !self.isStopping, self.recorder === recorder else { return }
            guard self.bridgeMode == .standard else {
                self.stopKeyboardReady()
                return
            }
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

    private func makeAudioRecorder() throws -> (AVAudioRecorder, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetype-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder.isMeteringEnabled = true
        audioRecorder.delegate = self
        return (audioRecorder, fileURL)
    }

    private func publishBridgeState() {
        RecordingBridgeStore.state = RecordingBridgeState(
            sessionID: activeSessionID,
            isRecording: isRecording,
            startedAt: startedAt,
            durationLimit: activeDurationLimit,
            mode: bridgeMode
        )
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
            if isKeyboardReady {
                stopKeyboardReady()
            } else if let activeAccount {
                await stopAndTranscribe(account: activeAccount)
            }
        case .startClip:
            RecordingBridgeStore.clearCommand(id: command.id)
            beginKeyboardClip()
        case .stopClip:
            RecordingBridgeStore.clearCommand(id: command.id)
            await stopKeyboardClipAndTranscribe()
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
        if isKeyboardReady {
            if bridgeMode == .keyboardRecording {
                await stopKeyboardClipAndTranscribe()
            }
            stopKeyboardReady()
            return
        }
        await stopAndTranscribe(account: activeAccount)
    }

    private func beginKeyboardClip() {
        guard
            bridgeMode == .keyboardReady,
            !isProcessing,
            let recorder
        else {
            return
        }
        keyboardClipStartTime = recorder.currentTime
        isRecording = true
        bridgeMode = .keyboardRecording
        publishBridgeState()
    }

    private func stopKeyboardClipAndTranscribe() async {
        guard
            bridgeMode == .keyboardRecording,
            !isStopping,
            let sourceURL = currentFileURL,
            let recorder,
            let clipStartTime = keyboardClipStartTime,
            let activeAccount
        else {
            return
        }

        let clipEndTime = recorder.currentTime
        let clipDuration = max(0, clipEndTime - clipStartTime)
        keyboardClipStartTime = nil
        isRecording = false

        guard clipDuration >= 0.25 else {
            bridgeMode = .keyboardReady
            publishBridgeState()
            return
        }

        isStopping = true
        recorder.stop()
        self.recorder = nil
        isStopping = false
        isProcessing = true
        bridgeMode = .transcribing
        publishBridgeState()

        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetype-clip-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        do {
            try restartKeyboardReadyRecorder()
            try await exportClip(sourceURL: sourceURL, outputURL: clipURL, start: clipStartTime, duration: clipDuration)

            #if DEBUG
            if activeAccount.isPreviewMode {
                let snapshot = TranscriptSnapshot(
                    id: UUID().uuidString,
                    text: "This is a local preview transcript from VoiceType.",
                    createdAt: Date(),
                    chargeText: "0 credits"
                )
                SharedTranscriptStore.latest = snapshot
                lastTranscript = snapshot
            } else {
                let response = try await BackendClient.transcribe(fileURL: clipURL, duration: clipDuration, token: activeAccount.token)
                let snapshot = TranscriptSnapshot(
                    id: response.id,
                    text: response.transcript,
                    createdAt: Date(),
                    chargeText: response.charge.formatted
                )
                SharedTranscriptStore.latest = snapshot
                lastTranscript = snapshot
                activeAccount.apply(balance: response.balance)
            }
            #else
            let response = try await BackendClient.transcribe(fileURL: clipURL, duration: clipDuration, token: activeAccount.token)
            let snapshot = TranscriptSnapshot(
                id: response.id,
                text: response.transcript,
                createdAt: Date(),
                chargeText: response.charge.formatted
            )
            SharedTranscriptStore.latest = snapshot
            lastTranscript = snapshot
            activeAccount.apply(balance: response.balance)
            #endif

            isProcessing = false
            bridgeMode = .keyboardReady
            publishBridgeState()
        } catch {
            KeyboardAutoInsertStore.clear()
            errorMessage = error.localizedDescription
            isProcessing = false
            if recorder == nil {
                stopKeyboardReady()
            } else {
                bridgeMode = .keyboardReady
                publishBridgeState()
            }
        }

        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: clipURL)
    }

    private func restartKeyboardReadyRecorder() throws {
        let (audioRecorder, fileURL) = try makeAudioRecorder()
        guard audioRecorder.record() else {
            try? FileManager.default.removeItem(at: fileURL)
            throw RecorderError.failedToStart
        }
        recorder = audioRecorder
        currentFileURL = fileURL
    }

    private func exportClip(sourceURL: URL, outputURL: URL, start: TimeInterval, duration: TimeInterval) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.failedToExport
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        let startTime = CMTime(seconds: start, preferredTimescale: 600)
        let endTime = CMTime(seconds: start + duration, preferredTimescale: 600)
        exportSession.timeRange = CMTimeRangeFromTimeToTime(start: startTime, end: endTime)

        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exportSession.error ?? RecorderError.failedToExport)
                default:
                    continuation.resume(throwing: RecorderError.failedToExport)
                }
            }
        }
    }
}

enum RecorderError: LocalizedError {
    case failedToStart
    case failedToExport

    var errorDescription: String? {
        switch self {
        case .failedToStart:
        "Recording did not start. Check microphone permission and try again."
        case .failedToExport:
            "Recording could not be prepared for transcription."
        }
    }
}
