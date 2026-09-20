@preconcurrency import AVFoundation
import Foundation
import OSLog
import UIKit

@MainActor
final class RecordingController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false {
        didSet { updateKeyboardMetering() }
    }
    @Published private(set) var isProcessing = false
    @Published private(set) var isStarting = false
    @Published private(set) var hasFailedTranscription = false
    @Published private(set) var failedTranscriptions: [FailedTranscriptionSnapshot] = []
    @Published private(set) var retryingTranscriptionID: UUID?
    @Published private(set) var retryErrorMessage: String?
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var lastTranscript = SharedTranscriptStore.latest
    @Published var durationLimit = RecordingPreferencesStore.durationLimit {
        didSet {
            RecordingPreferencesStore.durationLimit = durationLimit
            guard isRecording || isKeyboardSessionActive else { return }
            let changed = sessionPolicy?.setDurationLimit(durationLimit, at: timeSource.now(), keyboardSession: isKeyboardSessionActive) == true
            if changed { activeDurationLimit = durationLimit }
            // Shortening an existing session takes effect from its original
            // start immediately, before any recorder recovery or publication.
            guard !enforceSessionDeadline() else { return }
            if isKeyboardSessionActive {
                recoverKeyboardRecorderIfNeeded(reason: "session length changed")
                guard isRecording || isKeyboardSessionActive else { return }
                guard refreshRecorderCaptureLimit() else { return }
            }
            publishBridgeState()
        }
    }
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var meterTimer: Timer?
    private var meterGeneration: UUID?
    private var startedAt: Date?
    private var currentFileURL: URL?
    private weak var activeAccount: AccountStore?
    private var activeSessionID = ""
    private var activeDurationLimit = RecordingPreferencesStore.durationLimit
    private var handledCommandID: String?
    private var isStopping = false
    private var bridgeMode: RecordingBridgeMode = .standard {
        didSet { updateKeyboardMetering() }
    }
    private var keyboardClipStartTime: TimeInterval?
    private var lastBridgeHeartbeatAt: TimeInterval?
    private var lastLiveActivitySyncAt: TimeInterval?
    private var processingStartedAt: TimeInterval?
    private var notificationObservers: [NSObjectProtocol] = []
    private var activeTranscriptionTask: Task<Void, Never>?
    private var activeTranscriptionID: UUID?
    private var processingWatchdogTask: Task<Void, Never>?
    private var shouldStopKeyboardSessionAfterCurrentClip = false
    private var pendingStartID: UUID?
    private var activeAccountToken = ""
    private var activeAccountSessionID: UUID?
    private var activeAccountUserID = ""
    private var isAudioSessionInterrupted = false
    private var transcriptionBackgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    private var activeTranscriptionAudio: RecoverableRecording?
    private var recoveryDirectoryOverride: URL?
    private lazy var recoveryQueue = RecordingRecoveryQueue(directory: failedRecordingDirectory)
    private weak var recoveryAccount: AccountStore?
    private var hiddenCheckpointIDs: Set<UUID> = []
    private var historyRetryTask: Task<Void, Never>?
    private var historyRetryWatchdog: Task<Void, Never>?
    private var historyRetryExecutionID: UUID?
    private weak var historyRetryAccount: AccountStore?
    private var historyRetrySessionID: UUID?
    private var historyRetryToken = ""
    private var lastRecorderTime: TimeInterval = 0
    private var isRecoveringInterruptedClip = false
    private var sessionPolicy: RecordingSessionPolicy?
    private var timeSource = RecordingTimeSource.continuous()
    private var recorderAutoStopAt: TimeInterval?
    private var recorderAutoStopFileTime: TimeInterval?
    private var recorderFactory: (() throws -> (AVAudioRecorder, URL))?
    private var permissionRequest: (() async -> Bool)?
    private var clipExporter: ((URL, URL, TimeInterval, TimeInterval) async throws -> Void)?
    private var audioSessionActivation: (() throws -> Void)?
    private var transcriptionRequest: ((URL, TimeInterval, String, UUID) async throws -> TranscriptionResponse)?
    private nonisolated static let commandObservers = WeakObserverRegistry<RecordingController>()
    private nonisolated let bridgeObserverToken = RecordingController.commandObservers.makeToken()
    private static let recordingLog = Logger(subsystem: "com.kyleqi.voicetype", category: "Recording")

    var failedTranscriptionDuration: TimeInterval {
        failedTranscriptions.first?.duration ?? 0
    }

    var maximumStandardRecordingDuration: TimeInterval {
        Self.maximumKeyboardClipDuration
    }
    // Monotonic stamp for Live Activity operations. Bumped synchronously on the
    // main actor at each call site so the epochs reflect the true *intent* order,
    // even though the Tasks that deliver update/end run unordered. The controller
    // uses it to drop a stale update that would otherwise resurrect the Live
    // Activity after a later end -- the lock screen kept showing "recording" while
    // the app and Dynamic Island were already off.
    private var liveActivityEpoch: UInt64 = 0

    override init() {
        super.init()
        registerBridgeCommandObserver()
        registerRecoveryObservers()
        restoreFailedTranscription()
    }

    init(
        recoveryDirectory: URL,
        timeSource: RecordingTimeSource = .continuous(),
        recorderFactory: (() throws -> (AVAudioRecorder, URL))? = nil,
        permissionRequest: (() async -> Bool)? = nil,
        clipExporter: ((URL, URL, TimeInterval, TimeInterval) async throws -> Void)? = nil,
        audioSessionActivation: (() throws -> Void)? = nil,
        transcriptionRequest: ((URL, TimeInterval, String, UUID) async throws -> TranscriptionResponse)? = nil
    ) {
        recoveryDirectoryOverride = recoveryDirectory
        self.timeSource = timeSource
        self.recorderFactory = recorderFactory
        self.permissionRequest = permissionRequest
        self.clipExporter = clipExporter
        self.audioSessionActivation = audioSessionActivation
        self.transcriptionRequest = transcriptionRequest
        super.init()
        registerBridgeCommandObserver()
        registerRecoveryObservers()
        restoreFailedTranscription()
    }

    isolated deinit {
        removeBridgeCommandObserver()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        timer?.invalidate()
        meterTimer?.invalidate()
        if meterGeneration != nil { RecordingAudioLevelStore.clear() }
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

    func reconcileFailedTranscription(account: AccountStore) {
        recoveryAccount = account
        if let retrySession = historyRetrySessionID,
           !account.matchesSession(retrySession, token: historyRetryToken) {
            cancelHistoryRetry()
        }
        guard account.isSignedIn else {
            if account.shouldDiscardPendingRecording { discardAllFailedTranscriptions() }
            hiddenCheckpointIDs = []
            publishFailedTranscriptions()
            return
        }
        do { try recoveryQueue.removeOtherOwners(keeping: account.userID) }
        catch { retryErrorMessage = "A previous account's saved audio could not be removed. Try again after freeing storage." }
        if !isProcessing {
            hiddenCheckpointIDs = []
        }
        publishFailedTranscriptions()
    }

    func startRecording(account: AccountStore) async {
        guard !isRecording, !isProcessing, !isStarting, !isKeyboardSessionActive else { return }
        guard account.isSignedIn else {
            errorMessage = "Sign in before recording."
            return
        }
        guard canStartRecording(account: account) else { return }
        errorMessage = nil
        let startID = UUID()
        let token = account.token
        let accountSessionID = account.sessionID
        pendingStartID = startID
        isStarting = true
        defer { finishPendingStart(startID) }
        let hasPermission = await requestMicrophonePermission()
        guard pendingStartID == startID, !Task.isCancelled,
              account.matchesSession(accountSessionID, token: token) else { return }
        guard hasPermission else {
            errorMessage = "Microphone permission is required."
            return
        }

        do {
            try activateAudioSession()

            let (audioRecorder, fileURL) = try makeAudioRecorder()
            let start = timeSource.now()
            guard armRecorder(audioRecorder, duration: Self.maximumKeyboardClipDuration) else {
                try? FileManager.default.removeItem(at: fileURL)
                throw RecorderError.failedToStart
            }

            recorder = audioRecorder
            lastRecorderTime = 0
            currentFileURL = fileURL
            let startedAt = start.date
            self.startedAt = startedAt
            sessionPolicy = RecordingSessionPolicy(start: start, durationLimit: durationLimit)
            activeAccount = account
            activeAccountToken = token
            activeAccountSessionID = accountSessionID
            activeAccountUserID = account.userID
            isAudioSessionInterrupted = false
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
            guard hasActiveAccountSession(account) else {
                cancelForAccountChange(account: account)
                return
            }
            activeAccount = account
            guard !enforceSessionDeadline() else { return }
            recoverKeyboardRecorderIfNeeded(reason: "keyboard mic start requested while already active")
            return
        }
        guard !isRecording, !isProcessing, !isStarting else { return }
        guard account.isSignedIn else {
            errorMessage = "Sign in before turning on the microphone."
            return
        }
        guard canStartRecording(account: account) else { return }
        refreshInactiveKeyboardPreference()
        let startID = UUID()
        let token = account.token
        let accountSessionID = account.sessionID
        pendingStartID = startID
        isStarting = true
        defer { finishPendingStart(startID) }
        let hasPermission = await requestMicrophonePermission()
        guard pendingStartID == startID, !Task.isCancelled,
              account.matchesSession(accountSessionID, token: token) else { return }
        guard hasPermission else {
            errorMessage = "Microphone permission is required."
            return
        }
        // Permission can remain open while Settings changes. Choose the saved
        // window only after permission returns, before starting its clock.
        let sessionLimit = refreshInactiveKeyboardPreference()

        do {
            try activateAudioSession()

            let (audioRecorder, fileURL) = try makeAudioRecorder()
            let start = timeSource.now()
            guard armRecorder(audioRecorder, duration: sessionLimit.maximumDuration) else {
                try? FileManager.default.removeItem(at: fileURL)
                throw RecorderError.failedToStart
            }

            recorder = audioRecorder
            lastRecorderTime = 0
            currentFileURL = fileURL
            let startedAt = start.date
            self.startedAt = startedAt
            sessionPolicy = RecordingSessionPolicy(start: start, durationLimit: sessionLimit)
            activeAccount = account
            activeAccountToken = token
            activeAccountSessionID = accountSessionID
            activeAccountUserID = account.userID
            isAudioSessionInterrupted = false
            activeSessionID = UUID().uuidString
            activeDurationLimit = sessionLimit
            handledCommandID = RecordingBridgeStore.latestCommand?.id
            keyboardClipStartTime = nil
            shouldStopKeyboardSessionAfterCurrentClip = false
            lastBridgeHeartbeatAt = nil
            elapsedSeconds = 0
            isRecording = false
            isProcessing = false
            bridgeMode = .keyboardReady
            publishBridgeState()
            startTimer()
            Self.recordingLog.info("Keyboard microphone ready; recorder running=\(audioRecorder.isRecording)")
        } catch {
            RecordingBridgeStore.state = .inactive
            endLiveActivity()
            KeyboardAutoInsertStore.clear()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func refreshInactiveKeyboardPreference() -> RecordingDurationLimit {
        let savedLimit = RecordingPreferencesStore.durationLimit
        if durationLimit != savedLimit { durationLimit = savedLimit }
        return savedLimit
    }

    func stopKeyboardReady(preserveAutoInsert: Bool = false) {
        cancelPendingStart()
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
        shouldStopKeyboardSessionAfterCurrentClip = false
        stopTimer()
        RecordingBridgeStore.state = .inactive
        endLiveActivity()
        if !preserveAutoInsert {
            KeyboardAutoInsertStore.clear()
        }
        if let currentFileURL {
            removeAudioUnlessRetained(at: currentFileURL)
        }
        currentFileURL = nil
        startedAt = nil
        sessionPolicy = nil
        activeAccount = nil
        activeAccountToken = ""
        activeAccountSessionID = nil
        activeAccountUserID = ""
        activeSessionID = ""
        activeDurationLimit = durationLimit
        handledCommandID = nil
        lastBridgeHeartbeatAt = nil
        elapsedSeconds = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func finishKeyboardSession() async {
        let task = beginFinishingKeyboardSession()
        await task?.value
    }

    @discardableResult
    private func beginFinishingKeyboardSession() -> Task<Void, Never>? {
        if isKeyboardSessionActive {
            sessionPolicy?.close()
        }
        switch bridgeMode {
        case .keyboardRecording:
            shouldStopKeyboardSessionAfterCurrentClip = true
            return beginKeyboardClipTranscription()
        case .transcribing:
            shouldStopKeyboardSessionAfterCurrentClip = true
            stopIdleRecorderWhileTranscribing()
        case .keyboardReady:
            stopKeyboardReady()
        case .standard:
            cancelPendingStart()
        }
        return nil
    }

    private func stopIdleRecorderWhileTranscribing() {
        guard bridgeMode == .transcribing, recorder != nil || currentFileURL != nil else { return }
        let idleRecorder = recorder
        recorder = nil
        idleRecorder?.stop()
        if let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
        }
        currentFileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stopAndTranscribe(account: AccountStore) async {
        if bridgeMode == .keyboardRecording {
            await stopKeyboardClipAndTranscribe()
        } else {
            await beginStandardTranscription(account: account)?.value
        }
    }

    @discardableResult
    private func beginStandardTranscription(account: AccountStore) -> Task<Void, Never>? {
        guard isRecording, !isStopping, let fileURL = currentFileURL, let startedAt else { return nil }
        guard hasActiveAccountSession(account) else {
            cancelForAccountChange(account: account)
            return nil
        }
        let token = activeAccountToken
        let accountSessionID = account.sessionID
        let recordedDuration = max(recorder?.currentTime ?? 0, lastRecorderTime)
        let duration = min(Self.maximumKeyboardClipDuration, recordedDuration > 0 ? recordedDuration : Date().timeIntervalSince(startedAt))
        cancelActiveTranscription()
        let transcriptionID = UUID()
        activeTranscriptionID = transcriptionID
        isStopping = true
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VoiceTypeTranscription") { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleBackgroundTimeExpiration(for: transcriptionID)
            }
        }
        transcriptionBackgroundTasks[transcriptionID] = backgroundTask
        recorder?.stop()
        recorder = nil
        activeTranscriptionAudio = RecoverableRecording(
            fileURL: fileURL, duration: duration, clipStartTime: nil,
            requestID: transcriptionID, userID: activeAccountUserID
        )
        // Preserve the finalized file before yielding to any authentication or
        // lifecycle event, including before the upload task first runs.
        retainFailedTranscription(showRetry: false)
        isRecording = false
        isProcessing = true
        processingStartedAt = timeSource.now().monotonicSeconds
        stopTimer()
        RecordingBridgeStore.state = .inactive
        endLiveActivity()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        startProcessingWatchdog(for: transcriptionID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishStandardTranscription(
                id: transcriptionID,
                fileURL: fileURL,
                duration: duration,
                account: account,
                token: token,
                accountSessionID: accountSessionID,
                requestID: transcriptionID
            )
        }
        activeTranscriptionTask = task
        return task
    }

    private func finishStandardTranscription(
        id: UUID,
        fileURL: URL,
        duration: TimeInterval,
        account: AccountStore,
        token: String,
        accountSessionID: UUID,
        requestID: UUID,
        clipStartTime: TimeInterval? = nil
    ) async {
        var preparedURL = fileURL
        defer {
            endTranscriptionBackgroundTask(for: id)
            removeAudioUnlessRetained(at: fileURL)
            if preparedURL != fileURL {
                removeAudioUnlessRetained(at: preparedURL)
            }
            if activeTranscriptionID == id {
                activeTranscriptionAudio = nil
                activeTranscriptionTask = nil
                activeTranscriptionID = nil
                processingWatchdogTask?.cancel()
                processingWatchdogTask = nil
                if currentFileURL == fileURL {
                    currentFileURL = nil
                }
                startedAt = nil
                sessionPolicy = nil
                activeAccount = nil
                activeAccountToken = ""
                activeAccountSessionID = nil
                activeAccountUserID = ""
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
            guard isActiveTranscription(id), account.matchesSession(accountSessionID, token: token) else { return }
            if let clipStartTime {
                preparedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voicetype-retry-\(UUID().uuidString).m4a")
                try await exportClip(sourceURL: fileURL, outputURL: preparedURL, start: clipStartTime, duration: duration)
            }
            guard isActiveTranscription(id), account.matchesSession(accountSessionID, token: token) else { return }
            activeTranscriptionAudio = RecoverableRecording(
                fileURL: preparedURL, duration: duration, clipStartTime: nil,
                requestID: requestID, userID: account.userID
            )
            guard retainFailedTranscription(showRetry: false) else { throw RecorderError.failedToSaveAudio }
            let response = try await transcribe(fileURL: preparedURL, duration: duration, token: token, requestID: requestID)
            guard isActiveTranscription(id), account.matchesSession(accountSessionID, token: token) else { return }
            let snapshot = TranscriptSnapshot(
                id: response.id,
                text: response.transcript,
                createdAt: Date(),
                chargeText: response.charge.formatted
            )
            SharedTranscriptStore.latest = snapshot
            lastTranscript = snapshot
            account.scheduleBalanceRefresh()
            removeCompletedCheckpoint(id: requestID)
        } catch {
            guard isActiveTranscription(id), account.matchesSession(accountSessionID, token: token) else { return }
            KeyboardAutoInsertStore.clear()
            errorMessage = error.localizedDescription
            retainFailedTranscription()
        }
    }

    func cancel(discardFailed: Bool = true) {
        cancelPendingStart()
        if discardFailed {
            if let account = recoveryAccount, !account.isSignedIn, account.shouldDiscardPendingRecording {
                discardAllFailedTranscriptions()
            } else if let id = activeTranscriptionAudio?.requestID {
                discardFailedTranscription(id: id)
            }
        } else {
            preserveCapturedRecording(showRetry: false)
        }
        if let account = historyRetryAccount, let sessionID = historyRetrySessionID,
           !account.matchesSession(sessionID, token: historyRetryToken) { cancelHistoryRetry() }
        if isKeyboardSessionActive {
            stopKeyboardReady()
            return
        }
        cancelActiveTranscription()
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
            removeAudioUnlessRetained(at: currentFileURL)
        }
        currentFileURL = nil
        startedAt = nil
        sessionPolicy = nil
        activeAccount = nil
        activeAccountToken = ""
        activeAccountSessionID = nil
        activeAccountUserID = ""
        activeSessionID = ""
        activeDurationLimit = durationLimit
        handledCommandID = nil
        lastBridgeHeartbeatAt = nil
        bridgeMode = .standard
        shouldStopKeyboardSessionAfterCurrentClip = false
        isStopping = false
        elapsedSeconds = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard !self.isStopping, self.recorder === recorder else { return }
            if flag, let nativeDeadline = self.recorderAutoStopAt,
               self.timeSource.now().monotonicSeconds >= nativeDeadline - 0.05 {
                // currentTime can reset after a native timed stop. Preserve the
                // known endpoint so the last fraction of the clip is included.
                self.lastRecorderTime = max(self.lastRecorderTime, self.recorderAutoStopFileTime ?? 0)
                if self.enforceSessionDeadline() { return }
            }
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
            guard flag else {
                let account = self.activeAccount
                self.cancel(discardFailed: false)
                if let account { self.reconcileFailedTranscription(account: account) }
                self.errorMessage = self.hasFailedTranscription
                    ? "Recording was interrupted. Retry the saved audio."
                    : "Recording was interrupted before audio could be saved. Try again."
                return
            }
            guard let activeAccount = self.activeAccount else {
                self.cancel(discardFailed: false)
                return
            }
            await self.stopAndTranscribe(account: activeAccount)
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        if let permissionRequest { return await permissionRequest() }
        return await withCheckedContinuation { continuation in
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

    private var failedRecordingDirectory: URL {
        recoveryDirectoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingTranscription", isDirectory: true)
    }

    private func canStartRecording(account: AccountStore) -> Bool {
        reconcileFailedTranscription(account: account)
        return true
    }

    private func publishFailedTranscriptions() {
        guard let account = recoveryAccount, account.isSignedIn else {
            failedTranscriptions = []
            hasFailedTranscription = false
            return
        }
        failedTranscriptions = recoveryQueue.orderedRecordings.filter {
            $0.userID == account.userID && !hiddenCheckpointIDs.contains($0.requestID)
        }.map { FailedTranscriptionSnapshot(id: $0.requestID, createdAt: $0.createdAt, duration: $0.duration) }
        hasFailedTranscription = !failedTranscriptions.isEmpty
    }

    func discardFailedTranscription(id: UUID) {
        if retryingTranscriptionID == id { cancelHistoryRetry() }
        do {
            try recoveryQueue.remove(id: id)
            hiddenCheckpointIDs.remove(id)
            retryErrorMessage = nil
        } catch {
            retryErrorMessage = "The saved recording could not be deleted. Free some storage and try again."
        }
        publishFailedTranscriptions()
    }

    private func removeCompletedCheckpoint(id: UUID) {
        do { try recoveryQueue.remove(id: id) }
        catch { retryErrorMessage = "Transcription finished, but its saved audio could not be removed." }
        hiddenCheckpointIDs.remove(id)
        publishFailedTranscriptions()
    }

    // Compatibility for callers displaying the latest failed item.
    func discardFailedTranscription() {
        guard let id = failedTranscriptions.first?.id else { return }
        discardFailedTranscription(id: id)
    }

    private func discardAllFailedTranscriptions() {
        cancelHistoryRetry()
        do { try recoveryQueue.removeAll() }
        catch { retryErrorMessage = "Saved audio could not be deleted. Free some storage and try again." }
        hiddenCheckpointIDs = []
        publishFailedTranscriptions()
    }

    private func restoreFailedTranscription() {
        _ = recoveryQueue
        publishFailedTranscriptions()
    }

    @discardableResult
    private func retainFailedTranscription(showRetry: Bool = true) -> Bool {
        guard let recording = activeTranscriptionAudio,
              let activeAccount,
              hasActiveAccountSession(activeAccount),
              activeAccount.userID == recording.userID else { return false }
        return retainRecording(recording, showRetry: showRetry)
    }

    /// Authentication can already be cleared when cancellation arrives. Keep
    /// only the original owner's captured segment; this never starts an upload.
    private func preserveCapturedRecording(showRetry: Bool) {
        if let activeTranscriptionAudio {
            retainRecording(activeTranscriptionAudio, showRetry: showRetry)
            return
        }
        guard isRecording, let fileURL = currentFileURL, !activeAccountUserID.isEmpty else { return }
        let clipStart = bridgeMode == .keyboardRecording ? keyboardClipStartTime : nil
        let capturedTime = max(recorder?.currentTime ?? 0, lastRecorderTime)
        let duration = min(Self.maximumKeyboardClipDuration, max(0, capturedTime - (clipStart ?? 0)))
        isStopping = true
        recorder?.stop()
        recorder = nil
        guard duration > 0 else { return }
        retainRecording(RecoverableRecording(
            fileURL: fileURL, duration: duration, clipStartTime: clipStart,
            requestID: UUID(), userID: activeAccountUserID
        ), showRetry: showRetry)
    }

    @discardableResult
    private func retainRecording(_ recording: RecoverableRecording, showRetry: Bool) -> Bool {
        guard !activeAccountUserID.isEmpty, activeAccountUserID == recording.userID else { return false }
        let saved = recoveryQueue.save(recording)
        if showRetry { hiddenCheckpointIDs.remove(recording.requestID) }
        else { hiddenCheckpointIDs.insert(recording.requestID) }
        if !saved {
            retryErrorMessage = "The audio is retained while VoiceType stays open. Free storage before retrying."
        }
        publishFailedTranscriptions()
        return saved
    }

    private func removeAudioUnlessRetained(at url: URL) {
        guard !recoveryQueue.containsAudio(at: url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func retryFailedTranscription(account: AccountStore) async {
        reconcileFailedTranscription(account: account)
        guard let id = failedTranscriptions.first?.id else { return }
        await retryFailedTranscription(id: id, account: account)
    }

    func retryFailedTranscription(id: UUID, account: AccountStore) async {
        guard historyRetryExecutionID == nil else { return }
        reconcileFailedTranscription(account: account)
        guard account.isSignedIn else {
            retryErrorMessage = "Sign in again to retry your saved recordings."
            return
        }
        guard let recording = recoveryQueue.recordings[id], recording.userID == account.userID,
              !hiddenCheckpointIDs.contains(id) else { return }
        let executionID = UUID()
        let sessionID = account.sessionID
        let token = account.token
        historyRetryExecutionID = executionID
        retryingTranscriptionID = id
        historyRetryAccount = account
        historyRetrySessionID = sessionID
        historyRetryToken = token
        retryErrorMessage = nil
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VoiceTypeHistoryRetry") { [weak self] in
            Task { @MainActor [weak self] in self?.handleBackgroundTimeExpiration(for: executionID) }
        }
        transcriptionBackgroundTasks[executionID] = backgroundTask
        historyRetryWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumTranscriptionWait))
            guard !Task.isCancelled, let self, self.historyRetryExecutionID == executionID else { return }
            self.cancelHistoryRetry()
            self.retryErrorMessage = "Retry timed out. The recording is still saved in History."
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishHistoryRetry(recording: recording, executionID: executionID,
                                          account: account, sessionID: sessionID, token: token)
        }
        historyRetryTask = task
        await task.value
    }

    private func finishHistoryRetry(recording: RecoverableRecording, executionID: UUID,
                                    account: AccountStore, sessionID: UUID, token: String) async {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("voicetype-history-source-\(UUID().uuidString).m4a")
        var preparedURL = sourceURL
        defer {
            endTranscriptionBackgroundTask(for: executionID)
            removeAudioUnlessRetained(at: sourceURL)
            if preparedURL != sourceURL { removeAudioUnlessRetained(at: preparedURL) }
            if historyRetryExecutionID == executionID {
                historyRetryTask = nil
                historyRetryExecutionID = nil
                retryingTranscriptionID = nil
                historyRetryWatchdog?.cancel()
                historyRetryWatchdog = nil
                historyRetryAccount = nil
                historyRetrySessionID = nil
                historyRetryToken = ""
                publishFailedTranscriptions()
            }
        }
        do {
            guard isCurrentHistoryRetry(executionID, account: account, sessionID: sessionID, token: token) else { return }
            try FileManager.default.copyItem(at: recording.fileURL, to: sourceURL)
            if let start = recording.clipStartTime {
                preparedURL = FileManager.default.temporaryDirectory.appendingPathComponent("voicetype-history-clip-\(UUID().uuidString).m4a")
                try await exportClip(sourceURL: sourceURL, outputURL: preparedURL, start: start, duration: recording.duration)
            }
            guard isCurrentHistoryRetry(executionID, account: account, sessionID: sessionID, token: token) else { return }
            let prepared = RecoverableRecording(fileURL: preparedURL, duration: recording.duration, clipStartTime: nil,
                                               requestID: recording.requestID, userID: recording.userID, createdAt: recording.createdAt)
            guard recoveryQueue.save(prepared) else { throw RecorderError.failedToSaveAudio }
            let response = try await transcribe(fileURL: preparedURL, duration: recording.duration, token: token, requestID: recording.requestID)
            guard isCurrentHistoryRetry(executionID, account: account, sessionID: sessionID, token: token) else { return }
            // History retries never participate in the keyboard's latest-result
            // or insertion protocol, even if a live clip starts during this await.
            SharedTranscriptStore.appendHistory(TranscriptSnapshot(id: response.id, text: response.transcript,
                createdAt: recording.createdAt, chargeText: response.charge.formatted))
            account.scheduleBalanceRefresh()
            do { try recoveryQueue.remove(id: recording.requestID) }
            catch { retryErrorMessage = "Transcription finished, but its saved audio could not be removed." }
        } catch {
            guard isCurrentHistoryRetry(executionID, account: account, sessionID: sessionID, token: token) else { return }
            retryErrorMessage = error.localizedDescription
        }
    }

    private func isCurrentHistoryRetry(_ id: UUID, account: AccountStore, sessionID: UUID, token: String) -> Bool {
        historyRetryExecutionID == id && !Task.isCancelled && account.matchesSession(sessionID, token: token)
    }

    private func cancelHistoryRetry() {
        if let id = historyRetryExecutionID { endTranscriptionBackgroundTask(for: id) }
        historyRetryTask?.cancel()
        historyRetryTask = nil
        historyRetryWatchdog?.cancel()
        historyRetryWatchdog = nil
        historyRetryExecutionID = nil
        retryingTranscriptionID = nil
        historyRetryAccount = nil
        historyRetrySessionID = nil
        historyRetryToken = ""
    }

    private func transcribe(fileURL: URL, duration: TimeInterval, token: String, requestID: UUID) async throws -> TranscriptionResponse {
        if let transcriptionRequest { return try await transcriptionRequest(fileURL, duration, token, requestID) }
        return try await BackendClient.transcribe(fileURL: fileURL, duration: duration, token: token, requestID: requestID)
    }

    private func finishPendingStart(_ id: UUID) {
        guard pendingStartID == id else { return }
        pendingStartID = nil
        isStarting = false
    }

    private func cancelPendingStart() {
        pendingStartID = nil
        isStarting = false
    }

    private func hasActiveAccountSession(_ account: AccountStore) -> Bool {
        guard let activeAccountSessionID else { return false }
        return account.matchesSession(activeAccountSessionID, token: activeAccountToken)
    }

    private func cancelForAccountChange(account: AccountStore) {
        cancel(discardFailed: account.shouldDiscardPendingRecording)
        reconcileFailedTranscription(account: account)
    }

    private func startTimer() {
        stopTimer()
        let sessionID = activeSessionID
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeSessionID == sessionID else { return }
                self.runSessionMaintenance()
            }
        }
        timer.tolerance = 0.05
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runSessionMaintenance() {
        guard let sessionPolicy else { return }
        elapsedSeconds = sessionPolicy.elapsed(at: timeSource.now())
        if let recorder, recorder.isRecording {
            lastRecorderTime = recorder.currentTime
        }
        resetStaleProcessingIfNeeded()
        guard self.sessionPolicy != nil else { return }
        // Capture closes synchronously. Network work remains in its own task,
        // so a slow transcription cannot accumulate suspended heartbeat tasks.
        if enforceSessionDeadline() {
            publishBridgeHeartbeatIfNeeded()
            return
        }
        if bridgeMode == .standard, isRecording, recorder?.isRecording != true {
            if let activeAccount {
                beginStandardTranscription(account: activeAccount)
            } else {
                cancel()
            }
            return
        }
        recoverKeyboardRecorderIfNeeded(reason: "keyboard heartbeat")
        rotateIdleKeyboardRecorderIfNeeded()
        handleBridgeCommandIfNeeded()
        publishBridgeHeartbeatIfNeeded()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func isActiveTranscription(_ id: UUID) -> Bool {
        activeTranscriptionID == id && !Task.isCancelled
    }

    private func cancelActiveTranscription() {
        if let activeTranscriptionID {
            endTranscriptionBackgroundTask(for: activeTranscriptionID)
        }
        activeTranscriptionTask?.cancel()
        activeTranscriptionTask = nil
        activeTranscriptionID = nil
        activeTranscriptionAudio = nil
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
        guard isKeyboardSessionActive, !isAudioSessionInterrupted else { return }
        guard sessionPolicy != nil, startedAt != nil, !activeSessionID.isEmpty else {
            stopKeyboardReady()
            return
        }
        guard !enforceSessionDeadline() else { return }
        if bridgeMode == .transcribing, shouldStopKeyboardSessionAfterCurrentClip { return }
        guard let activeAccount, hasActiveAccountSession(activeAccount) else {
            if let activeAccount {
                cancelForAccountChange(account: activeAccount)
            } else {
                cancel(discardFailed: false)
            }
            return
        }
        if let recorder, recorder.isRecording { return }

        let shouldKeepTranscribingOnRecoveryFailure = bridgeMode == .transcribing && isProcessing

        let interruptedActiveClip = bridgeMode == .keyboardRecording
        if interruptedActiveClip {
            // AVAudioRecorder can stop before its interruption notification
            // arrives. Preserve the last captured segment instead of deleting it.
            guard !isRecoveringInterruptedClip else { return }
            isRecoveringInterruptedClip = true
            shouldStopKeyboardSessionAfterCurrentClip = true
            errorMessage = "The microphone session ended because audio was interrupted."
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.stopKeyboardClipAndTranscribe()
                self.isRecoveringInterruptedClip = false
            }
            return
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
        do {
            try restartKeyboardReadyRecorder()
            publishBridgeState()
            if timer == nil {
                startTimer()
            }
        } catch {
            errorMessage = error.localizedDescription
            if shouldKeepTranscribingOnRecoveryFailure {
                // Keep the upload, but do not create failing recorders on every
                // heartbeat when the input route is unavailable.
                sessionPolicy?.close()
                shouldStopKeyboardSessionAfterCurrentClip = true
                publishBridgeState()
            } else {
                stopKeyboardReady()
            }
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
        guard force || timeSource.now().monotonicSeconds - startedProcessingAt > Self.maximumTranscriptionWait else {
            return
        }

        errorMessage = "Transcription timed out. Retry the saved recording."
        retainFailedTranscription()
        if let activeTranscriptionID {
            endTranscriptionBackgroundTask(for: activeTranscriptionID)
        }
        activeTranscriptionTask?.cancel()
        activeTranscriptionTask = nil
        activeTranscriptionID = nil
        activeTranscriptionAudio = nil
        processingWatchdogTask?.cancel()
        processingWatchdogTask = nil
        KeyboardAutoInsertStore.clear()
        isProcessing = false
        processingStartedAt = nil
        isStopping = false
        if isKeyboardSessionActive {
            if shouldStopKeyboardSessionAfterCurrentClip {
                shouldStopKeyboardSessionAfterCurrentClip = false
                stopKeyboardReady()
            } else {
                bridgeMode = .keyboardReady
                recoverKeyboardRecorderIfNeeded(reason: "stale transcription watchdog")
                publishBridgeState()
            }
        } else {
            cancel(discardFailed: false)
        }
    }

    private func endTranscriptionBackgroundTask(for id: UUID) {
        guard let task = transcriptionBackgroundTasks.removeValue(forKey: id), task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
    }

    private func handleBackgroundTimeExpiration(for id: UUID) {
        endTranscriptionBackgroundTask(for: id)
        if historyRetryExecutionID == id {
            cancelHistoryRetry()
            retryErrorMessage = "Retry could not finish in the background. The recording is still saved in History."
            return
        }
        guard activeTranscriptionID == id else { return }
        // A live keyboard recorder already holds its own background audio
        // assertion. Otherwise release work before iOS terminates the process.
        guard recorder?.isRecording != true else { return }
        resetStaleProcessingIfNeeded(id: id, force: true)
        errorMessage = "Transcription could not finish in the background. Keep VoiceType open and retry the saved recording."
    }

    private func makeAudioRecorder() throws -> (AVAudioRecorder, URL) {
        if let recorderFactory {
            let result = try recorderFactory()
            result.0.delegate = self
            return result
        }
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

    private func activateAudioSession() throws {
        if let audioSessionActivation {
            try audioSessionActivation()
            return
        }
        let session = AVAudioSession.sharedInstance()
        // Recording must coexist with the user's music or podcast. The default
        // playAndRecord policy is exclusive; spokenAudio is a playback mode for
        // podcasts/audiobooks, not a speech-recognition recording requirement.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
    }

    private func armRecorder(_ audioRecorder: AVAudioRecorder, duration: TimeInterval?) -> Bool {
        if let duration, duration <= 0 { return false }
        let now = timeSource.now().monotonicSeconds
        let requestedDeadline = duration.map { now + $0 }
        if audioRecorder.isRecording {
            lastRecorderTime = audioRecorder.currentTime
            let deadlineIsUnchanged: Bool
            switch (recorderAutoStopAt, requestedDeadline) {
            case (nil, nil):
                deadlineIsUnchanged = true
            case let (current?, requested?):
                // The policy and recorder sample the clock a few instructions
                // apart. An unchanged absolute deadline must not interrupt the
                // only background audio capture just to apply it again.
                deadlineIsUnchanged = abs(current - requested) <= 0.05
            default:
                deadlineIsUnchanged = false
            }
            if deadlineIsUnchanged {
                Self.recordingLog.info("Kept running recorder; native deadline unchanged")
                return true
            }
            Self.recordingLog.info("Rearming running recorder; background=\(UIApplication.shared.applicationState == .background)")
            audioRecorder.pause()
        }
        let position = audioRecorder.currentTime
        let started = duration.map { audioRecorder.record(forDuration: $0) } ?? audioRecorder.record()
        recorderAutoStopAt = started ? duration.map { now + $0 } : nil
        recorderAutoStopFileTime = started ? duration.map { position + $0 } : nil
        if !started {
            Self.recordingLog.error("Recorder start or rearm failed; background=\(UIApplication.shared.applicationState == .background)")
        }
        return started
    }

    private func refreshRecorderCaptureLimit() -> Bool {
        guard let recorder, let policy = sessionPolicy else { return false }
        let clipElapsed = keyboardClipStartTime.map { max(0, recorder.currentTime - $0) } ?? 0
        let duration = policy.recorderDuration(at: timeSource.now(), mode: bridgeMode, clipElapsed: clipElapsed)
        // Pause/resume keeps the existing audio file and position while replacing
        // AVAudioRecorder's native deadline. Protect the short assertion gap.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VoiceTypeUpdateCaptureDeadline")
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        guard armRecorder(recorder, duration: duration) else {
            finishAfterAudioSystemChange(message: "The microphone could not continue. Turn it on again when you are ready.")
            return false
        }
        return true
    }

    private func rotateIdleKeyboardRecorderIfNeeded() {
        guard bridgeMode == .keyboardReady || bridgeMode == .transcribing,
              !isAudioSessionInterrupted,
              let recorder,
              recorder.currentTime >= Self.maximumIdleAudioFileDuration else { return }

        // Ready mode needs a running recorder for background audio. Rotate its
        // local file so a 12-hour or Forever session cannot fill device storage.
        // No active Speak clip is included in this discarded idle file.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VoiceTypeRotateIdleAudio")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        self.recorder = nil
        recorder.stop()
        recoverKeyboardRecorderIfNeeded(reason: "rotate idle keyboard audio")
    }

    private func publishBridgeState(updateLiveActivity: Bool = true) {
        let now = timeSource.now()
        let expiresAt = sessionPolicy?.remainingDuration(at: now, keyboardSession: isKeyboardSessionActive)
            .map { now.date.addingTimeInterval($0) }
        RecordingBridgeStore.state = RecordingBridgeState(
            sessionID: activeSessionID,
            isRecording: isRecording,
            startedAt: startedAt,
            updatedAt: now.date,
            durationLimit: activeDurationLimit,
            mode: bridgeMode,
            expiresAt: expiresAt,
            audioLevel: measuredKeyboardAudioLevel()
        )
        lastBridgeHeartbeatAt = now.monotonicSeconds
        if updateLiveActivity { syncLiveActivity() }
    }

    private func measuredKeyboardAudioLevel() -> Double {
        guard bridgeMode == .keyboardRecording, isRecording,
              let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        guard decibels.isFinite else { return 0 }
        // A bounded decibel display range makes speech visible while keeping
        // silence at zero. Every value comes from the current recorder meter.
        return min(1, max(0, (decibels + 60) / 60))
    }

    private func updateKeyboardMetering() {
        guard bridgeMode == .keyboardRecording, isRecording else {
            guard meterTimer != nil || meterGeneration != nil else { return }
            meterTimer?.invalidate()
            meterTimer = nil
            meterGeneration = nil
            RecordingAudioLevelStore.clear()
            return
        }
        guard meterTimer == nil else { return }
        let generation = UUID()
        let sessionID = activeSessionID
        meterGeneration = generation
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.meterGeneration == generation,
                      self.activeSessionID == sessionID, self.bridgeMode == .keyboardRecording,
                      self.isRecording else { return }
                RecordingAudioLevelStore.publish(sessionID: sessionID, level: self.measuredKeyboardAudioLevel())
            }
        }
        timer.tolerance = 0.005
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RecordingAudioLevelStore.publish(sessionID: sessionID, level: measuredKeyboardAudioLevel())
    }

    private func nextLiveActivityEpoch() -> UInt64 {
        liveActivityEpoch += 1
        return liveActivityEpoch
    }

    private func syncLiveActivity(force: Bool = false) {
        let epoch = nextLiveActivityEpoch()
        let sessionID = activeSessionID
        let mode = bridgeMode
        let startedAt = startedAt
        let durationLimit = activeDurationLimit
        let now = timeSource.now()
        lastLiveActivitySyncAt = now.monotonicSeconds
        let expiresAt = sessionPolicy?.remainingDuration(at: now, keyboardSession: isKeyboardSessionActive)
            .map { now.date.addingTimeInterval($0) }
        Task { @MainActor in
            await KeyboardMicLiveActivityController.shared.update(
                sessionID: sessionID,
                mode: mode,
                startedAt: startedAt,
                durationLimit: durationLimit,
                epoch: epoch,
                expiresAt: expiresAt,
                force: force
            )
        }
    }

    private func endLiveActivity() {
        lastLiveActivitySyncAt = nil
        let epoch = nextLiveActivityEpoch()
        Task { @MainActor in
            await KeyboardMicLiveActivityController.shared.end(epoch: epoch)
        }
    }

    private func publishBridgeHeartbeatIfNeeded() {
        guard isRecording || isKeyboardSessionActive else { return }
        let now = timeSource.now().monotonicSeconds
        guard now - (lastBridgeHeartbeatAt ?? -.infinity) >= 1 else { return }
        publishBridgeState()
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
    private static let maximumTranscriptionWait: TimeInterval = 600
    private static let maximumKeyboardClipDuration = RecordingSessionPolicy.maximumClipDuration
    private static let maximumIdleAudioFileDuration = RecordingSessionPolicy.maximumIdleFileDuration

    private func handleBridgeCommandIfNeeded() {
        guard
            isRecording || isKeyboardSessionActive,
            let command = RecordingBridgeStore.latestCommand,
            command.id != handledCommandID
        else {
            return
        }

        Self.recordingLog.info("Received keyboard command \(command.action.rawValue, privacy: .public); mode=\(self.bridgeMode.rawValue, privacy: .public)")

        guard !enforceSessionDeadline() else {
            RecordingBridgeStore.clearCommand(id: command.id)
            return
        }

        handledCommandID = command.id
        guard command.sessionID == nil || command.sessionID == activeSessionID,
              Date().timeIntervalSince(command.createdAt) <= 10 else {
            Self.recordingLog.notice("Ignored keyboard command for an old session or timestamp")
            RecordingBridgeStore.clearCommand(id: command.id)
            return
        }
        switch command.action {
        case .stop:
            RecordingBridgeStore.clearCommand(id: command.id)
            if isKeyboardSessionActive {
                beginFinishingKeyboardSession()
            } else if let activeAccount {
                beginStandardTranscription(account: activeAccount)
            }
        case .startClip:
            RecordingBridgeStore.clearCommand(id: command.id)
            beginKeyboardClip()
        case .stopClip:
            RecordingBridgeStore.clearCommand(id: command.id)
            beginKeyboardClipTranscription()
        }
    }

    /// Returns true when the current event must not reopen/start capture.
    @discardableResult
    private func enforceSessionDeadline() -> Bool {
        guard var policy = sessionPolicy else { return false }
        let clipElapsed = keyboardClipStartTime.map {
            max(0, max(recorder?.currentTime ?? 0, lastRecorderTime) - $0)
        } ?? 0
        let action = policy.action(
            at: timeSource.now(), mode: bridgeMode, isRecording: isRecording, clipElapsed: clipElapsed
        )
        sessionPolicy = policy
        switch action {
        case .none:
            return false
        case .stopKeyboardSession:
            stopKeyboardReady()
        case .finishKeyboardClip:
            beginKeyboardClipTranscription()
        case .finishKeyboardClipAndSession:
            shouldStopKeyboardSessionAfterCurrentClip = true
            beginKeyboardClipTranscription()
        case .stopIdleCaptureWhileTranscribing:
            shouldStopKeyboardSessionAfterCurrentClip = true
            stopIdleRecorderWhileTranscribing()
        case .finishStandardRecording:
            if let activeAccount {
                beginStandardTranscription(account: activeAccount)
            } else {
                cancel()
            }
        }
        return true
    }

    private func registerBridgeCommandObserver() {
        Self.commandObservers.register(self, token: bridgeObserverToken)
        let observer = UnsafeMutableRawPointer(bitPattern: bridgeObserverToken)!
        let name = CFNotificationName(RecordingBridgeStore.commandNotificationName as CFString)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let token = UInt(bitPattern: observer)
                guard let controller = RecordingController.commandObservers.lookup(token) else { return }
                Task { @MainActor in
                    controller.handleBridgeCommandIfNeeded()
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
                    await self?.handleAudioSessionInterruption(typeValue: typeValue)
                }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishAfterAudioSystemChange(message: "The audio service restarted. Turn on the microphone again when you are ready.")
                }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: session, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishAfterAudioSystemChange(message: "The audio service was interrupted. Turn on the microphone again when you are ready.")
                }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] notification in
                let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor [weak self] in
                    guard let reasonValue, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
                    if reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory {
                        self?.finishAfterAudioSystemChange(message: "The microphone connection changed. Turn it on again when you are ready.")
                    } else {
                        self?.runSessionMaintenance()
                    }
                }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.runSessionMaintenance()
                    self?.resetStaleProcessingIfNeeded()
                }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                RecordingBridgeStore.state = .inactive
                Task { @MainActor [weak self] in
                    // A terminal end must outrank any in-flight update; if the
                    // controller is already gone there is nothing left to bump, so
                    // .max guarantees this end wins.
                    let epoch = self?.nextLiveActivityEpoch() ?? .max
                    await KeyboardMicLiveActivityController.shared.end(epoch: epoch)
                }
            }
        )
    }

    private func removeRecoveryObservers() {
        let center = NotificationCenter.default
        notificationObservers.forEach { center.removeObserver($0) }
        notificationObservers = []
    }

    private func handleAudioSessionInterruption(typeValue: UInt?) async {
        guard
            let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch type {
        case .began:
            isAudioSessionInterrupted = true
            sessionPolicy?.close()
            if bridgeMode == .keyboardRecording {
                // Preserve the spoken segment. Never restart the microphone
                // during a phone call or claim a paused recorder is ready.
                shouldStopKeyboardSessionAfterCurrentClip = true
                errorMessage = "The microphone session ended because audio was interrupted."
                await stopKeyboardClipAndTranscribe()
            } else if bridgeMode == .transcribing {
                shouldStopKeyboardSessionAfterCurrentClip = true
                stopIdleRecorderWhileTranscribing()
            } else if isKeyboardSessionActive {
                stopKeyboardReady()
                errorMessage = "The microphone was interrupted. Turn it on again when you are ready."
            } else if isRecording, let activeAccount {
                await stopAndTranscribe(account: activeAccount)
            }
        case .ended:
            isAudioSessionInterrupted = false
        @unknown default:
            break
        }
    }

    private func finishAfterAudioSystemChange(message: String) {
        guard isRecording || isKeyboardSessionActive else { return }
        errorMessage = message
        if isKeyboardSessionActive {
            beginFinishingKeyboardSession()
        } else if let activeAccount {
            beginStandardTranscription(account: activeAccount)
        } else {
            cancel()
        }
    }

    nonisolated private func removeBridgeCommandObserver() {
        Self.commandObservers.remove(bridgeObserverToken)
        let observer = UnsafeMutableRawPointer(bitPattern: bridgeObserverToken)!
        let name = CFNotificationName(RecordingBridgeStore.commandNotificationName as CFString)
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            name,
            nil
        )
    }

    private func beginKeyboardClip() {
        guard !enforceSessionDeadline() else { return }
        guard
            bridgeMode == .keyboardReady,
            !isProcessing,
            !isAudioSessionInterrupted
        else {
            Self.recordingLog.notice("Cannot start clip in mode \(self.bridgeMode.rawValue, privacy: .public); interrupted=\(self.isAudioSessionInterrupted), processing=\(self.isProcessing)")
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
        guard refreshRecorderCaptureLimit() else { return }
        publishBridgeState()
        Self.recordingLog.info("Keyboard clip started; recorder running=\(recorder.isRecording)")
    }

    private func stopKeyboardClipAndTranscribe() async {
        await beginKeyboardClipTranscription()?.value
    }

    @discardableResult
    private func beginKeyboardClipTranscription() -> Task<Void, Never>? {
        // A Stop can land after the clip already ended, or after the session was
        // interrupted. Don't silently swallow it: if we still hold an armed keyboard
        // mic, repair it back to a usable ready state so the next Speak works, instead
        // of leaving the keyboard stuck on a pending "Transcribing".
        guard bridgeMode == .keyboardRecording, !isStopping else {
            if isKeyboardSessionActive, !isStopping {
                recoverKeyboardRecorderIfNeeded(reason: "stop clip with no active clip")
            }
            return nil
        }
        guard
            let sourceURL = currentFileURL,
            let clipStartTime = keyboardClipStartTime,
            let activeAccount
        else {
            errorMessage = "The recording was interrupted before audio could be saved. Try again."
            stopKeyboardReady()
            return nil
        }
        guard hasActiveAccountSession(activeAccount) else {
            cancelForAccountChange(account: activeAccount)
            return nil
        }
        let token = activeAccountToken
        let accountSessionID = activeAccount.sessionID
        cancelActiveTranscription()

        let clipEndTime = max(recorder?.currentTime ?? 0, lastRecorderTime)
        let clipDuration = min(Self.maximumKeyboardClipDuration, max(0, clipEndTime - clipStartTime))
        keyboardClipStartTime = nil
        isRecording = false

        guard clipDuration >= 0.25 else {
            if shouldStopKeyboardSessionAfterCurrentClip {
                shouldStopKeyboardSessionAfterCurrentClip = false
                stopKeyboardReady()
            } else {
                bridgeMode = .keyboardReady
                publishBridgeState()
            }
            return nil
        }

        let transcriptionID = UUID()
        activeTranscriptionID = transcriptionID
        isStopping = true
        // Hold a background task across the whole stop -> restart -> transcribe
        // window so iOS does not suspend the app while the continuous recorder is
        // momentarily stopped, which would drop the audio assertion and kill the
        // keyboard session before it can return to ready.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VoiceTypeKeyboardClip") { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleBackgroundTimeExpiration(for: transcriptionID)
            }
        }
        transcriptionBackgroundTasks[transcriptionID] = backgroundTask
        recorder?.stop()
        self.recorder = nil
        activeTranscriptionAudio = RecoverableRecording(
            fileURL: sourceURL, duration: clipDuration, clipStartTime: clipStartTime,
            requestID: transcriptionID, userID: activeAccountUserID
        )
        // Export is asynchronous. Keep the original segment and its start
        // offset durable before an expired sign-in can cancel that export.
        retainFailedTranscription(showRetry: false)
        currentFileURL = nil
        isProcessing = true
        processingStartedAt = timeSource.now().monotonicSeconds
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
                token: token,
                accountSessionID: accountSessionID
            )
        }
        activeTranscriptionTask = task
        return task
    }

    private func finishKeyboardClipTranscription(
        id: UUID,
        sourceURL: URL,
        clipURL: URL,
        clipStartTime: TimeInterval,
        clipDuration: TimeInterval,
        account: AccountStore,
        token: String,
        accountSessionID: UUID
    ) async {
        defer {
            endTranscriptionBackgroundTask(for: id)
            removeAudioUnlessRetained(at: sourceURL)
            removeAudioUnlessRetained(at: clipURL)
            if activeTranscriptionID == id {
                activeTranscriptionAudio = nil
                activeTranscriptionTask = nil
                activeTranscriptionID = nil
                processingWatchdogTask?.cancel()
                processingWatchdogTask = nil
                isStopping = false
                processingStartedAt = nil
            }
        }

        do {
            recoverKeyboardRecorderIfNeeded(reason: "keyboard clip handoff")
            guard isActiveTranscription(id), account.matchesSession(accountSessionID, token: token) else { return }
            try await exportClip(sourceURL: sourceURL, outputURL: clipURL, start: clipStartTime, duration: clipDuration)
            guard isActiveTranscription(id), account.matchesSession(accountSessionID, token: token) else { return }
            activeTranscriptionAudio = RecoverableRecording(
                fileURL: clipURL, duration: clipDuration, clipStartTime: nil,
                requestID: id, userID: account.userID
            )
            guard retainFailedTranscription(showRetry: false) else { throw RecorderError.failedToSaveAudio }

            let response = try await transcribe(fileURL: clipURL, duration: clipDuration, token: token, requestID: id)
            guard isActiveTranscription(id), account.matchesSession(accountSessionID, token: token) else { return }
            let snapshot = TranscriptSnapshot(
                id: response.id,
                text: response.transcript,
                createdAt: Date(),
                chargeText: response.charge.formatted
            )
            SharedTranscriptStore.latest = snapshot
            lastTranscript = snapshot
            account.scheduleBalanceRefresh()
            removeCompletedCheckpoint(id: id)

            if shouldStopKeyboardSessionAfterCurrentClip {
                shouldStopKeyboardSessionAfterCurrentClip = false
                stopKeyboardReady(preserveAutoInsert: true)
            } else {
                recoverKeyboardRecorderIfNeeded(reason: "keyboard clip transcribed")
                isProcessing = false
                if let recorder, recorder.isRecording {
                    bridgeMode = .keyboardReady
                    publishBridgeState()
                } else {
                    stopKeyboardReady(preserveAutoInsert: true)
                }
            }
        } catch {
            guard isActiveTranscription(id), account.matchesSession(accountSessionID, token: token) else { return }
            KeyboardAutoInsertStore.clear()
            errorMessage = error.localizedDescription
            retainFailedTranscription()
            isProcessing = false
            if shouldStopKeyboardSessionAfterCurrentClip {
                shouldStopKeyboardSessionAfterCurrentClip = false
                stopKeyboardReady()
            } else if self.recorder == nil {
                recoverKeyboardRecorderIfNeeded(reason: "keyboard clip transcription failed")
                if let recorder, recorder.isRecording {
                    bridgeMode = .keyboardReady
                    publishBridgeState()
                } else {
                    stopKeyboardReady()
                }
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
        try? activateAudioSession()
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let (audioRecorder, fileURL) = try makeAudioRecorder()
                let duration = sessionPolicy?.remainingDuration(at: timeSource.now(), keyboardSession: true)
                if armRecorder(audioRecorder, duration: duration) {
                    recorder = audioRecorder
                    lastRecorderTime = 0
                    currentFileURL = fileURL
                    return
                }
                try? FileManager.default.removeItem(at: fileURL)
                lastError = RecorderError.failedToStart
            } catch {
                lastError = error
            }
            if attempt == 0 {
                try? activateAudioSession()
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
        guard let recorder else {
            throw RecorderError.failedToStart
        }
        return recorder
    }

    private func exportClip(sourceURL: URL, outputURL: URL, start: TimeInterval, duration: TimeInterval) async throws {
        if let clipExporter {
            try await clipExporter(sourceURL, outputURL, start, duration)
            return
        }
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
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
        } onCancel: {
            exportBox.session.cancelExport()
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
    case failedToSaveAudio

    var errorDescription: String? {
        switch self {
        case .failedToStart:
        "Recording did not start. Check microphone permission and try again."
        case .failedToExport:
            "Recording could not be prepared for transcription."
        case .failedToSaveAudio:
            "The audio is retained while VoiceType stays open. Free storage before retrying from History."
        }
    }
}
