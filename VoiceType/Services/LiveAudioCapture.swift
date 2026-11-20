@preconcurrency import AVFoundation
import Foundation

/// Microphone audio for a live session: 100 ms frames of 16-bit PCM at
/// 24 kHz mono, delivered on an audio thread.
protocol LiveAudioSource: AnyObject {
    func start(onFrame: @escaping @Sendable (Data) -> Void) throws
    /// Stops capturing. The last, shorter frame arrives before this returns.
    func stop()
    /// Whether any captured sample was not silent. A working microphone
    /// always hears some noise.
    var heardSignal: Bool { get }
}

/// Taps the microphone with AVAudioEngine alongside the recorder, which
/// keeps saving the recording in case it has to be uploaded.
final class EngineLiveAudioSource: LiveAudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    // Guarded by `lock`, since taps arrive on an audio thread.
    private var converter: LivePCMConverter?
    private var isStopped = false

    var heardSignal: Bool {
        lock.withLock { converter?.heardSignal ?? false }
    }

    func start(onFrame: @escaping @Sendable (Data) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = LivePCMConverter(inputFormat: format, onFrame: onFrame) else {
            throw RecorderError.failedToStart
        }
        lock.withLock { self.converter = converter }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { isStopped = true }
            throw error
        }
    }

    func stop() {
        guard lock.withLock({ !isStopped }) else { return }
        // Outside the lock: removing the tap can wait for a tap in progress.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock {
            guard !isStopped else { return }
            isStopped = true
            converter?.finish()
        }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !isStopped else { return }
            converter?.push(buffer)
        }
    }
}

/// Converts microphone buffers of any format to the service's PCM and cuts
/// it into 100 ms frames. Not thread safe.
final class LivePCMConverter {
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: LiveTranscriptionProtocol.sampleRate,
        channels: 1, interleaved: true
    )!

    private(set) var heardSignal = false
    private let converter: AVAudioConverter
    private let inputSampleRate: Double
    private let onFrame: @Sendable (Data) -> Void
    private var pending: [UInt8] = []
    private var isFinished = false

    init?(inputFormat: AVAudioFormat, onFrame: @escaping @Sendable (Data) -> Void) {
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else { return nil }
        self.converter = converter
        inputSampleRate = inputFormat.sampleRate
        self.onFrame = onFrame
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard !isFinished, buffer.frameLength > 0 else { return }
        convert(buffer)
    }

    /// Delivers the audio still in the converter, then the last frame.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        convert(nil)
        if !pending.isEmpty {
            onFrame(Data(pending))
            pending.removeAll()
        }
    }

    /// `nil` ends the stream.
    private func convert(_ buffer: AVAudioPCMBuffer?) {
        let input = BufferOnce(buffer)
        let endsStream = buffer == nil
        let inputFrames = Double(buffer?.frameLength ?? 0)
        let capacity = AVAudioFrameCount((inputFrames * Self.outputFormat.sampleRate / inputSampleRate).rounded(.up)) + 1_024
        while let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let next = input.take() {
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = endsStream ? .endOfStream : .noDataNow
                return nil
            }
            append(output)
            // A full buffer can leave converted audio behind.
            guard status == .haveData, output.frameLength == output.frameCapacity else { return }
        }
    }

    private func append(_ output: AVAudioPCMBuffer) {
        let count = Int(output.frameLength)
        guard count > 0, let channel = output.int16ChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: channel, count: count)
        if !heardSignal {
            heardSignal = samples.contains { $0 != 0 }
        }
        // Already little-endian on every iPhone.
        pending.append(contentsOf: UnsafeRawBufferPointer(samples))
        let frameBytes = LiveTranscriptionProtocol.frameBytes
        while pending.count >= frameBytes {
            onFrame(Data(pending[..<frameBytes]))
            pending.removeFirst(frameBytes)
        }
    }
}

/// Hands the converter one buffer, once.
private final class BufferOnce: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer?) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
