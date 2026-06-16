@preconcurrency import AVFoundation
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
            guard isRecording || isKeyboardSessionActive else { return }
            activeDurationLimit = durationLimit
            publishBridgeState()
            Task { @MainActor [weak self] in
                await self?.stopIfDurationLimitReached()
            }
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
    private var lastBridgeHeartbeatAt: Date?
    private var processingStartedAt: Date?
    private var notificationObservers: [NSObjectProtocol] = []
    private var activeTranscriptionTask: Task<Void, Never>?
    private var activeTranscriptionID: UUID?
    private var processingWatchdogTask: Task<Void, Never>?

    override init() {
        super.init()
        registerBridgeCommandObserver()
        registerRecoveryObservers()
    }

    deinit {
        removeBridgeCommandObserver()
    }

    var isKeyboardSessionActive: Bool {
        bridgeMode == .keyboardReady || bridgeMode == .keyboardRecording || bridgeMode == .transcribing
    }

    var isKeyboardReady: Bool {
        bridgeMode == .keyboardReady
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
            elapsedSeconds = 0
            isRecording = true
            bridgeMode = .standard
            publishBridgeState()
            startTimer()
        } catch {
            RecordingBridgeStore.state = .inactive
            endLiveActivity()
            KeyboardAutoInsertStore.clear()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    func startKeyboardReady(account: AccountStore) async {
        errorMessage = nil
        if isKeyboardSessionActive {
            activeAccount = account
            activeDurationLimit = durationLimit
            recoverKeyboardRecorderIfNeeded(reason: "keyboard mic start requested while already active")
            return
        }
        guard !isRecording, !isProcessing else { return }

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
            lastBridgeHeartbeatAt = nil
            elapsedSeconds = 0
            isRecording = false
            isProcessing = false
            bridgeMode = .keyboardReady
            publishBridgeState()
            startTimer()
        } catch {
            RecordingBridgeStore.state = .inactive
            endLiveActivity()
            KeyboardAutoInsertStore.clear()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    func stopKeyboardReady() {
        guard isKeyboardSessionActive else { return }
        cancelActiveTranscription()
        isStopping = true
        recorder?.stop()
        recorder = nil
        isStopping = false
        isRecording = false
        isProcessing = false
        processingStartedAt = nil
        bridgeMode = .standard
        keyboardClipStartTime = nil
        stopTimer()
        RecordingBridgeStore.state = .inactive
        endLiveActivity()
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
        lastBridgeHeartbeatAt = nil
        elapsedSeconds = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stopAndTranscribe(account: AccountStore) async {
        if bridgeMode == .keyboardRecording {
            await stopKeyboardClipAndTranscribe()
            return
        }
        guard isRecording, !isStopping, let fileURL = currentFileURL, let startedAt else { return }
        cancelActiveTranscription()
        let transcriptionID = UUID()
        activeTranscriptionID = transcriptionID
        isStopping = true
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VoiceTypeTranscription")
        recorder?.stop()
        recorder = nil
        isRecording = false
        isProcessing = true
        processingStartedAt = Date()
        stopTimer()
        RecordingBridgeStore.state = .inactive
        endLiveActivity()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let duration = Date().timeIntervalSince(startedAt)
        startProcessingWatchdog(for: transcriptionID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishStandardTranscription(
                id: transcriptionID,
                fileURL: fileURL,
                duration: duration,
                account: account,
                backgroundTask: backgroundTask
            )
        }
        activeTranscriptionTask = task
        await task.value
    }

    private func finishStandardTranscription(
        id: UUID,
        fileURL: URL,
        duration: TimeInterval,
        account: AccountStore,
        backgroundTask: UIBackgroundTaskIdentifier
    ) async {
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
            try? FileManager.default.removeItem(at: fileURL)
            if activeTranscriptionID == id {
                activeTranscriptionTask = nil
                activeTranscriptionID = nil
                processingWatchdogTask?.cancel()
                processingWatchdogTask = nil
                if currentFileURL == fileURL {
                    currentFileURL = nil
                }
                startedAt = nil
                activeAccount = nil
                activeSessionID = ""
                activeDurationLimit = durationLimit
                handledCommandID = nil
                lastBridgeHeartbeatAt = nil
                bridgeMode = .standard
                isStopping = false
                elapsedSeconds = 0
                isProcessing = false
                processingStartedAt = nil
            }
        }

        do {
            let response = try await BackendClient.transcribe(fileURL: fileURL, duration: duration, token: account.token)
            guard isActiveTranscription(id) else { return }
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
            guard isActiveTranscription(id) else { return }
            KeyboardAutoInsertStore.clear()
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        if isKeyboardSessionActive {
            stopKeyboardReady()
            return
        }
        cancelActiveTranscription()
        guard isRecording else { return }
        isStopping = true
        recorder?.stop()
        recorder = nil
        isRecording = false
        isProcessing = false
        processingStartedAt = nil
        stopTimer()
        RecordingBridgeStore.state = .inactive
        endLiveActivity()
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
        lastBridgeHeartbeatAt = nil
        bridgeMode = .standard
        isStopping = false
        elapsedSeconds = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard !self.isStopping, self.recorder === recorder else { return }
            if self.isKeyboardSessionActive {
                self.recoverKeyboardRecorderIfNeeded(
                    reason: flag ? "keyboard recorder finished unexpectedly" : "keyboard recorder failed unexpectedly"
                )
                return
            }
            guard self.isRecording else { return }
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
                self.recoverKeyboardRecorderIfNeeded(reason: "keyboard heartbeat")
                self.resetStaleProcessingIfNeeded()
                await self.stopIfDurationLimitReached()
                await self.handleBridgeCommandIfNeeded()
                self.publishBridgeHeartbeatIfNeeded()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func isActiveTranscription(_ id: UUID) -> Bool {
        activeTranscriptionID == id && !Task.isCancelled
    }

    private func cancelActiveTranscription() {
        activeTranscriptionTask?.cancel()
        activeTranscriptionTask = nil
        activeTranscriptionID = nil
        processingWatchdogTask?.cancel()
        processingWatchdogTask = nil
        processingStartedAt = nil
        isProcessing = false
        isStopping = false
    }

    private func startProcessingWatchdog(for id: UUID) {
        processingWatchdogTask?.cancel()
        processingWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumTranscriptionWait))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.resetStaleProcessingIfNeeded(id: id, force: true)
            }
        }
    }

    private func recoverKeyboardRecorderIfNeeded(reason _: String) {
        guard isKeyboardSessionActive else { return }
        if let recorder, recorder.isRecording { return }

        // stopKeyboardClipAndTranscribe intentionally publishes `.transcribing`
        // before its replacement recorder is started. Do not delete that source
        // file during the small stop -> restart handoff window.
        if isStopping, bridgeMode == .transcribing, recorder == nil {
            return
        }

        let interruptedActiveClip = bridgeMode == .keyboardRecording
        if interruptedActiveClip {
            KeyboardAutoInsertStore.clear()
            errorMessage = "The microphone session was interrupted. Try again."
        }

        recorder?.stop()
        recorder = nil
        if let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
        }
        currentFileURL = nil
        keyboardClipStartTime = nil
        isRecording = false
        if bridgeMode != .transcribing {
            isProcessing = false
            processingStartedAt = nil
            bridgeMode = .keyboardReady
        }
        if startedAt == nil {
            startedAt = Date()
        }
        if activeSessionID.isEmpty {
            activeSessionID = UUID().uuidString
        }

        do {
            try restartKeyboardReadyRecorder()
            publishBridgeState()
            if timer == nil {
                startTimer()
            }
        } catch {
            errorMessage = error.localizedDescription
            stopKeyboardReady()
        }
    }

    private func resetStaleProcessingIfNeeded(id: UUID? = nil, force: Bool = false) {
        guard
            isProcessing,
            let startedProcessingAt = processingStartedAt
        else {
            return
        }
        if let id, activeTranscriptionID != id {
            return
        }
        guard force || Date().timeIntervalSince(startedProcessingAt) > Self.maximumTranscriptionWait else {
            return
        }

        activeTranscriptionTask?.cancel()
        activeTranscriptionTask = nil
        activeTranscriptionID = nil
        processingWatchdogTask?.cancel()
        processingWatchdogTask = nil
        KeyboardAutoInsertStore.clear()
        errorMessage = "Transcription timed out. Try again."
        isProcessing = false
        processingStartedAt = nil
        isStopping = false
        if isKeyboardSessionActive {
            bridgeMode = .keyboardReady
            recoverKeyboardRecorderIfNeeded(reason: "stale transcription watchdog")
            publishBridgeState()
        } else {
            bridgeMode = .standard
            RecordingBridgeStore.state = .inactive
            endLiveActivity()
        }
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
            updatedAt: Date(),
            durationLimit: activeDurationLimit,
            mode: bridgeMode
        )
        lastBridgeHeartbeatAt = Date()
        syncLiveActivity()
    }

    private func syncLiveActivity(force: Bool = false) {
        let sessionID = activeSessionID
        let mode = bridgeMode
        let startedAt = startedAt
        let durationLimit = activeDurationLimit
        Task { @MainActor in
            await KeyboardMicLiveActivityController.shared.update(
                sessionID: sessionID,
                mode: mode,
                startedAt: startedAt,
                durationLimit: durationLimit,
                force: force
            )
        }
    }

    private func endLiveActivity() {
        Task { @MainActor in
            await KeyboardMicLiveActivityController.shared.end()
        }
    }

    private func publishBridgeHeartbeatIfNeeded() {
        guard isKeyboardSessionActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastBridgeHeartbeatAt ?? .distantPast) >= 1 else { return }
        publishBridgeState()
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
    private static let maximumTranscriptionWait: TimeInterval = 600

    private func handleBridgeCommandIfNeeded() async {
        guard
            isRecording || isKeyboardSessionActive,
            let command = RecordingBridgeStore.latestCommand,
            command.id != handledCommandID
        else {
            return
        }

        handledCommandID = command.id
        switch command.action {
        case .stop:
            RecordingBridgeStore.clearCommand(id: command.id)
            if isKeyboardSessionActive {
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
            isRecording || bridgeMode == .keyboardReady || bridgeMode == .keyboardRecording,
            let maximumDuration = activeDurationLimit.maximumDuration,
            elapsedSeconds >= maximumDuration,
            let activeAccount
        else {
            return
        }
        if isKeyboardSessionActive {
            if bridgeMode == .keyboardRecording {
                await stopKeyboardClipAndTranscribe()
            }
            stopKeyboardReady()
            return
        }
        await stopAndTranscribe(account: activeAccount)
    }

    private func registerBridgeCommandObserver() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let name = CFNotificationName(RecordingBridgeStore.commandNotificationName as CFString)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<RecordingController>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    await controller.handleBridgeCommandIfNeeded()
                }
            },
            name.rawValue,
            nil,
            .deliverImmediately
        )
    }

    private func registerRecoveryObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        notificationObservers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] notification in
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleAudioSessionInterruption(typeValue: typeValue)
                }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recoverKeyboardRecorderIfNeeded(reason: "media services reset")
                }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recoverKeyboardRecorderIfNeeded(reason: "app became active")
                    self?.resetStaleProcessingIfNeeded()
                }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                RecordingBridgeStore.state = .inactive
                Task { @MainActor in
                    await KeyboardMicLiveActivityController.shared.end()
                }
            }
        )
    }

    private func removeRecoveryObservers() {
        let center = NotificationCenter.default
        notificationObservers.forEach { center.removeObserver($0) }
        notificationObservers = []
    }

    private func handleAudioSessionInterruption(typeValue: UInt?) {
        guard
            let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch type {
        case .began:
            guard bridgeMode == .keyboardRecording else { return }
            KeyboardAutoInsertStore.clear()
            keyboardClipStartTime = nil
            isRecording = false
            bridgeMode = .keyboardReady
            publishBridgeState()
        case .ended:
            recoverKeyboardRecorderIfNeeded(reason: "audio session interruption ended")
        @unknown default:
            recoverKeyboardRecorderIfNeeded(reason: "unknown audio session interruption")
        }
    }

    nonisolated private func removeBridgeCommandObserver() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let name = CFNotificationName(RecordingBridgeStore.commandNotificationName as CFString)
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            name,
            nil
        )
    }

    private func beginKeyboardClip() {
        guard
            bridgeMode == .keyboardReady,
            !isProcessing
        else {
            return
        }
        let recorder: AVAudioRecorder
        do {
            recorder = try ensureKeyboardReadyRecorder()
        } catch {
            KeyboardAutoInsertStore.clear()
            errorMessage = error.localizedDescription
            stopKeyboardReady()
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
        cancelActiveTranscription()

        let clipEndTime = recorder.currentTime
        let clipDuration = max(0, clipEndTime - clipStartTime)
        keyboardClipStartTime = nil
        isRecording = false

        guard clipDuration >= 0.25 else {
            bridgeMode = .keyboardReady
            publishBridgeState()
            return
        }

        let transcriptionID = UUID()
        activeTranscriptionID = transcriptionID
        isStopping = true
        // Hold a background task across the whole stop -> restart -> transcribe
        // window so iOS does not suspend the app while the continuous recorder is
        // momentarily stopped, which would drop the audio assertion and kill the
        // keyboard session before it can return to ready.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VoiceTypeKeyboardClip")
        recorder.stop()
        self.recorder = nil
        isProcessing = true
        processingStartedAt = Date()
        bridgeMode = .transcribing
        publishBridgeState()
        startProcessingWatchdog(for: transcriptionID)

        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetype-clip-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishKeyboardClipTranscription(
                id: transcriptionID,
                sourceURL: sourceURL,
                clipURL: clipURL,
                clipStartTime: clipStartTime,
                clipDuration: clipDuration,
                account: activeAccount,
                backgroundTask: backgroundTask
            )
        }
        activeTranscriptionTask = task
        await task.value
    }

    private func finishKeyboardClipTranscription(
        id: UUID,
        sourceURL: URL,
        clipURL: URL,
        clipStartTime: TimeInterval,
        clipDuration: TimeInterval,
        account: AccountStore,
        backgroundTask: UIBackgroundTaskIdentifier
    ) async {
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: clipURL)
            if activeTranscriptionID == id {
                activeTranscriptionTask = nil
                activeTranscriptionID = nil
                processingWatchdogTask?.cancel()
                processingWatchdogTask = nil
                isStopping = false
                processingStartedAt = nil
            }
        }

        do {
            try restartKeyboardReadyRecorder()
            guard isActiveTranscription(id) else { return }
            try await exportClip(sourceURL: sourceURL, outputURL: clipURL, start: clipStartTime, duration: clipDuration)
            guard isActiveTranscription(id) else { return }

            let response = try await BackendClient.transcribe(fileURL: clipURL, duration: clipDuration, token: account.token)
            guard isActiveTranscription(id) else { return }
            let snapshot = TranscriptSnapshot(
                id: response.id,
                text: response.transcript,
                createdAt: Date(),
                chargeText: response.charge.formatted
            )
            SharedTranscriptStore.latest = snapshot
            lastTranscript = snapshot
            account.apply(balance: response.balance)

            isProcessing = false
            bridgeMode = .keyboardReady
            publishBridgeState()
        } catch {
            guard isActiveTranscription(id) else { return }
            KeyboardAutoInsertStore.clear()
            errorMessage = error.localizedDescription
            isProcessing = false
            if self.recorder == nil {
                stopKeyboardReady()
            } else {
                bridgeMode = .keyboardReady
                publishBridgeState()
            }
        }
    }

    private func restartKeyboardReadyRecorder() throws {
        // The keyboard-ready session stays alive only while a recorder is running:
        // that audio assertion is what keeps this app from being suspended in the
        // background between clips. When a clip stops, the shared audio session can
        // briefly lapse, so reassert it and retry once. Otherwise record() returns
        // false, this throws, and the whole keyboard session collapses to
        // "Open VoiceType" the instant the user taps Stop.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try? session.setActive(true)
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let (audioRecorder, fileURL) = try makeAudioRecorder()
                if audioRecorder.record() {
                    recorder = audioRecorder
                    currentFileURL = fileURL
                    return
                }
                try? FileManager.default.removeItem(at: fileURL)
                lastError = RecorderError.failedToStart
            } catch {
                lastError = error
            }
            if attempt == 0 {
                try? session.setActive(true)
            }
        }
        throw lastError ?? RecorderError.failedToStart
    }

    private func ensureKeyboardReadyRecorder() throws -> AVAudioRecorder {
        if let recorder, recorder.isRecording {
            return recorder
        }
        if let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
        }
        try restartKeyboardReadyRecorder()
        if startedAt == nil {
            startedAt = Date()
        }
        guard let recorder else {
            throw RecorderError.failedToStart
        }
        return recorder
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

        let exportBox = ExportSessionBox(exportSession)
        try await withCheckedThrowingContinuation { continuation in
            exportBox.session.exportAsynchronously {
                switch exportBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exportBox.session.error ?? RecorderError.failedToExport)
                default:
                    continuation.resume(throwing: RecorderError.failedToExport)
                }
            }
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
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
