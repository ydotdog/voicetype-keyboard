import Foundation
import os

/// What the service speaks at `/v1/realtime/transcriptions`.
enum LiveTranscriptionProtocol {
    static let name = "voicetype.realtime.v1"
    static let audioFormat = "pcm_s16le_24000_mono"
    static let sampleRate: Double = 24_000
    static let bytesPerSecond = 48_000
    /// 100 ms of audio.
    static let frameBytes = 4_800
}

enum LiveTranscriptionMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

/// A WebSocket to the service. `close()` may be called more than once, and
/// makes pending sends and receives throw.
protocol LiveTranscriptionTransport: AnyObject, Sendable {
    func send(_ message: LiveTranscriptionMessage) async throws
    func receive() async throws -> LiveTranscriptionMessage
    func close()
}

/// A WebSocket on its own URLSession, so closing it cancels nothing else.
final class URLSessionLiveTranscriptionTransport: LiveTranscriptionTransport, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.default
        // Live audio is about 3 MB a minute; Low Data Mode uploads the
        // recording instead.
        configuration.allowsConstrainedNetworkAccess = false
        // Fail at once without a connection. The upload waits for one.
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        task.resume()
    }

    func send(_ message: LiveTranscriptionMessage) async throws {
        switch message {
        case let .text(text): try await task.send(.string(text))
        case let .data(data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> LiveTranscriptionMessage {
        switch try await task.receive() {
        case let .string(text): return .text(text)
        case let .data(data): return .data(data)
        @unknown default: throw BackendClientError.invalidResponse
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }
}

enum LiveTranscriptionOutcome: Sendable {
    /// The service transcribed, charged and saved the recording.
    case transcribed(TranscriptionResponse)
    /// An upload would fail the same way, such as for a silent recording.
    case rejected(BackendClientError)
    /// The app threw the recording away.
    case cancelled
    /// Upload the recording with the same request ID. The service then
    /// returns the live transcript if it finished after all, or transcribes
    /// the upload and charges the live audio it already sent on. `code` is
    /// the service's reason, when it gave one.
    case upload(code: String?)
}

private enum LiveOutgoingMessage: Sendable {
    case audio(Data)
    case commit(TimeInterval)
}

/// Takes microphone frames from any thread and queues them to send. Gives
/// up once 10 seconds of audio are waiting: a connection that slow can't
/// return the transcript in time, so the recording is uploaded instead.
final class LiveAudioInput: Sendable {
    static let backlogLimit = 100

    private struct State {
        var unsent = 0
        var isOpen = true
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let outgoing: AsyncStream<LiveOutgoingMessage>.Continuation
    private let overflow: AsyncStream<Void>.Continuation

    fileprivate init(outgoing: AsyncStream<LiveOutgoingMessage>.Continuation, overflow: AsyncStream<Void>.Continuation) {
        self.outgoing = outgoing
        self.overflow = overflow
    }

    func append(_ frame: Data) {
        guard !frame.isEmpty else { return }
        let overflowed = state.withLock { state -> Bool in
            guard state.isOpen else { return false }
            guard state.unsent < Self.backlogLimit else {
                state.isOpen = false
                return true
            }
            state.unsent += 1
            // Queued under the lock, so no frame follows `close()`.
            outgoing.yield(.audio(frame))
            return false
        }
        if overflowed {
            overflow.yield()
            overflow.finish()
        }
    }

    fileprivate func didSend() {
        state.withLock { $0.unsent -= 1 }
    }

    fileprivate func close() {
        state.withLock { $0.isOpen = false }
        overflow.finish()
    }
}

/// Streams one recording to the service while it is spoken, and gets its
/// transcript soon after it stops.
@MainActor
final class LiveTranscriptionSession {
    private static let log = Logger(subsystem: "com.kyleqi.voicetype", category: "LiveTranscription")

    let requestID: UUID
    let model: String
    /// The languages and words the session was started with. An upload of
    /// the same recording must send the same ones to use its result.
    let context: DictationContext
    /// Where the microphone delivers audio, from any thread.
    let audio: LiveAudioInput
    /// Whether the service was told the recording ended. It then finishes
    /// the transcript even if the app goes away.
    private(set) var isCommitted = false
    private(set) var outcome: LiveTranscriptionOutcome?

    private let transport: any LiveTranscriptionTransport
    private let outgoing: AsyncStream<LiveOutgoingMessage>.Continuation
    private let resultTimeout: Duration
    private let onPartial: @MainActor (String) -> Void
    private var isCommitQueued = false
    private var tasks: [Task<Void, Never>] = []
    private var waiters: [CheckedContinuation<LiveTranscriptionOutcome, Never>] = []

    /// `onPartial` gets the text heard so far, a preview only.
    /// `resultTimeout` is how long to wait for the transcript after
    /// `commit`, before uploading the recording instead.
    init(
        requestID: UUID, model: String, context: DictationContext,
        transport: any LiveTranscriptionTransport, resultTimeout: Duration = .seconds(15),
        onPartial: @escaping @MainActor (String) -> Void
    ) {
        self.requestID = requestID
        self.model = model
        self.context = context
        self.transport = transport
        self.resultTimeout = resultTimeout
        self.onPartial = onPartial
        let (stream, outgoing) = AsyncStream.makeStream(of: LiveOutgoingMessage.self)
        let (overflow, overflowSignal) = AsyncStream.makeStream(of: Void.self)
        self.outgoing = outgoing
        audio = LiveAudioInput(outgoing: outgoing, overflow: overflowSignal)
        tasks = [
            Task { await self.sendAll(stream) },
            Task { await self.receiveAll() },
            Task {
                for await _ in overflow {
                    Self.log.notice("Live transcription fell behind the microphone")
                    self.settle(.upload(code: "backlog"))
                }
            },
        ]
    }

    /// Ends the recording. `audioSeconds` is its length as recorded, which
    /// the service checks against the audio it received.
    func commit(audioSeconds: TimeInterval) {
        guard outcome == nil, !isCommitQueued else { return }
        isCommitQueued = true
        audio.close()
        outgoing.yield(.commit(audioSeconds))
        outgoing.finish()
        let timeout = resultTimeout
        tasks.append(Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            // The service still finishes, and the upload returns its result.
            Self.log.notice("Live transcription result timed out")
            self.settle(.upload(code: "timeout"))
        })
    }

    /// Waits for the outcome. Cancelling the waiting task ends the session.
    func result() async -> LiveTranscriptionOutcome {
        if let outcome { return outcome }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let outcome {
                    continuation.resume(returning: outcome)
                } else {
                    waiters.append(continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.end() }
        }
    }

    /// Throws the recording away. The service stops at once and charges
    /// the audio it already sent on.
    func cancel() {
        guard outcome == nil else { return }
        settle(.cancelled, closing: false)
        let transport = transport
        Task.detached {
            // Sending can't be cancelled, so give up after two seconds.
            let deadline = Task {
                try? await Task.sleep(for: .seconds(2))
                transport.close()
            }
            try? await transport.send(.text(#"{"type":"cancel"}"#))
            deadline.cancel()
            transport.close()
        }
    }

    /// Stops the session without throwing the recording away. A committed
    /// recording still finishes on the service, and its upload returns that
    /// transcript; one still being recorded is cancelled.
    func end() {
        guard outcome == nil else { return }
        if isCommitQueued {
            settle(.upload(code: nil))
        } else {
            cancel()
        }
    }

    private func sendAll(_ messages: AsyncStream<LiveOutgoingMessage>) async {
        do {
            // Nothing more goes out once the session ends, besides a cancel.
            guard outcome == nil else { return }
            try await transport.send(.text(Self.startMessage(model: model, context: context)))
            for await message in messages {
                guard outcome == nil else { return }
                switch message {
                case let .audio(frame):
                    try await transport.send(.data(frame))
                    audio.didSend()
                case let .commit(seconds):
                    try await transport.send(.text(Self.commitMessage(audioSeconds: seconds)))
                    isCommitted = true
                }
            }
        } catch {
            guard outcome == nil else { return }
            Self.log.notice("Live transcription send failed: \(error.localizedDescription, privacy: .public)")
            settle(.upload(code: nil))
        }
    }

    private func receiveAll() async {
        do {
            while outcome == nil {
                guard case let .text(text) = try await transport.receive() else { continue }
                handle(Data(text.utf8))
            }
        } catch {
            guard outcome == nil else { return }
            Self.log.notice("Live transcription connection ended: \(error.localizedDescription, privacy: .public)")
            settle(.upload(code: nil))
        }
    }

    private func handle(_ data: Data) {
        guard outcome == nil, let event = try? JSONDecoder().decode(LiveServerEvent.self, from: data) else { return }
        switch event.type {
        case "ready":
            Self.log.info("Live transcription ready; model=\(self.model, privacy: .public)")
        case "partial":
            // The service sends all the text so far, or only its end when
            // `truncated`.
            let heard = (event.text ?? "").drop(while: \.isWhitespace)
            guard !heard.isEmpty else { return }
            onPartial(event.truncated == true ? "…" + heard : String(heard))
        case "done":
            if let response = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) {
                settle(.transcribed(response))
            } else {
                settle(.upload(code: nil))
            }
        case "error":
            Self.log.notice("Live transcription ended: \(event.code ?? "unknown", privacy: .public)")
            settle(Self.outcome(code: event.code, status: event.status, detail: event.detail))
        default:
            // Events a newer service adds.
            break
        }
    }

    private func settle(_ outcome: LiveTranscriptionOutcome, closing: Bool = true) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        audio.close()
        outgoing.finish()
        for task in tasks { task.cancel() }
        tasks = []
        if closing { transport.close() }
        let waiters = waiters
        self.waiters = []
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    static func outcome(code: String?, status: Int?, detail: String?) -> LiveTranscriptionOutcome {
        switch code {
        case "no_speech":
            .rejected(.httpError(status: status ?? 422, message: detail ?? "", context: .general, code: code))
        case "cancelled":
            .cancelled
        default:
            .upload(code: code)
        }
    }

    /// Languages and words are JSON text, exactly as the upload form sends
    /// them, so an upload of the same recording matches this session.
    static func startMessage(model: String, context: DictationContext) throws -> String {
        let encoder = JSONEncoder()
        func json(_ values: [String]) throws -> String? {
            values.isEmpty ? nil : String(decoding: try encoder.encode(values), as: UTF8.self)
        }
        let message = LiveStartMessage(
            model: model,
            preferredLanguages: try json(context.languages),
            vocabulary: try json(context.vocabulary)
        )
        return String(decoding: try encoder.encode(message), as: UTF8.self)
    }

    static func commitMessage(audioSeconds: TimeInterval) -> String {
        let seconds = audioSeconds.isFinite ? min(max(audioSeconds, 0), 600) : 0
        return String(format: #"{"type":"commit","audio_seconds":%.2f}"#, locale: Locale(identifier: "en_US_POSIX"), seconds)
    }
}

private struct LiveStartMessage: Encodable {
    let type = "start"
    let format = LiveTranscriptionProtocol.audioFormat
    let model: String
    let preferredLanguages: String?
    let vocabulary: String?

    enum CodingKeys: String, CodingKey {
        case type, format, model, vocabulary
        case preferredLanguages = "preferred_languages"
    }
}

private struct LiveServerEvent: Decodable {
    let type: String
    let text: String?
    let truncated: Bool?
    let status: Int?
    let code: String?
    let detail: String?
}
