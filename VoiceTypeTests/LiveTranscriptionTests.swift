import AVFoundation
import Foundation
import Testing
@testable import VoiceType

// Live sessions run against a fake socket and microphone tap, and uploads against an
// in-process URLProtocol stub: nothing reaches the network, the microphone or the service.
@Suite(.serialized)
@MainActor
struct LiveTranscriptionTests {
    private let ownerID = "dddddddd-1111-4444-8888-dddddddddddd"
    private static let cancelMessage = #"{"type":"cancel"}"#
    private static let noSpeechDetail = "No speech was detected in this recording. Nothing was charged."
    private static let pendingDetail = "This recording is still being transcribed. Retry in up to 30 seconds."

    // MARK: Messages

    @Test func startMessageWithoutHintsNamesOnlyTheFormatAndModel() throws {
        let start = try Self.object(LiveTranscriptionSession.startMessage(model: "gpt-live-transcribe", context: .empty))
        #expect(start.keys.sorted() == ["format", "model", "type"])
        #expect(start["type"] as? String == "start")
        #expect(start["format"] as? String == "pcm_s16le_24000_mono")
        #expect(start["model"] as? String == "gpt-live-transcribe")
    }

    @Test func startMessageSendsHintsAsJSONTextLikeTheUploadForm() throws {
        let context = DictationContext(languages: ["en", "zh-Hans"], vocabulary: ["VoiceType", "衢州"])
        let start = try Self.object(LiveTranscriptionSession.startMessage(model: "gpt-transcribe", context: context))
        #expect(start["model"] as? String == "gpt-transcribe")
        #expect(start["preferred_languages"] as? String == #"["en","zh-Hans"]"#)
        #expect(start["vocabulary"] as? String == #"["VoiceType","衢州"]"#)
    }

    @Test func commitMessageClampsTheRecordedLength() {
        let cases: [(seconds: TimeInterval, expected: String)] = [
            (3.14159, "3.14"), (0, "0.00"), (-2, "0.00"), (900, "600.00"), (.nan, "0.00"), (.infinity, "0.00"),
        ]
        for (seconds, expected) in cases {
            #expect(LiveTranscriptionSession.commitMessage(audioSeconds: seconds) == #"{"type":"commit","audio_seconds":\#(expected)}"#)
        }
    }

    // MARK: Session

    @Test func sendsTheStartMessageThenAudioInOrderThenTheCommit() async throws {
        let transport = FakeLiveTransport()
        let session = makeSession(transport)
        defer { session.cancel() }
        session.audio.append(Data(repeating: 1, count: 4_800))
        session.audio.append(Data())
        session.audio.append(Data(repeating: 2, count: 2_400))
        session.commit(audioSeconds: 0.15)
        // Audio after the commit belongs to no recording.
        session.audio.append(Data(repeating: 3, count: 4_800))
        try await eventually { session.isCommitted }

        let first = try #require(transport.sentTexts.first)
        let start = try Self.object(first)
        #expect(start["type"] as? String == "start")
        let expected: [LiveTranscriptionMessage] = [
            .data(Data(repeating: 1, count: 4_800)),
            .data(Data(repeating: 2, count: 2_400)),
            .text(#"{"type":"commit","audio_seconds":0.15}"#),
        ]
        #expect(Array(transport.sent.dropFirst()) == expected)
        #expect(Self.summary(session.outcome) == "pending")

        try transport.deliver(Self.doneEvent(id: "live-1", transcript: "Hello world."))
        let outcome = await session.result()
        guard case let .transcribed(response) = outcome else {
            Issue.record("Expected a transcript, got \(Self.summary(outcome))")
            return
        }
        #expect(response.id == "live-1")
        #expect(response.transcript == "Hello world.")
        #expect(response.charge.costCreditUnits == 486)
        #expect(transport.isClosed)
    }

    @Test func reportsPartialTextAndIgnoresOtherEvents() async throws {
        let transport = FakeLiveTransport()
        let heard = Heard()
        let session = makeSession(transport, heard: heard)
        defer { session.cancel() }
        transport.deliver(#"{"type":"ready","session_id":"rt-1","model":"gpt-live-transcribe","text_timing":"while_speaking","credit_units_per_minute":29144}"#)
        transport.deliver(#"{"type":"partial","text":"  Hello","truncated":false}"#)
        transport.deliver(#"{"type":"partial","text":"   "}"#)
        transport.deliver(#"{"type":"partial","text":"end of a long sentence","truncated":true}"#)
        transport.deliver(#"{"type":"usage","seconds":1.2}"#)
        transport.deliver("not json")
        transport.deliverBinary(Data([0, 1, 2]))
        transport.deliver(#"{"type":"partial","text":"Last"}"#)
        try await eventually { heard.texts.count == 3 }
        #expect(heard.texts == ["Hello", "…end of a long sentence", "Last"])
        #expect(Self.summary(session.outcome) == "pending")
    }

    @Test func noSpeechIsRejectedLikeTheUploadWouldBe() async throws {
        let transport = FakeLiveTransport()
        let session = makeSession(transport)
        defer { session.cancel() }
        session.commit(audioSeconds: 1)
        try transport.deliver(Self.errorEvent(code: "no_speech", status: 422, detail: Self.noSpeechDetail))
        let outcome = await session.result()
        #expect(Self.summary(outcome) == "rejected: 422 no_speech")
        guard case let .rejected(error) = outcome else { return }
        #expect(error.isNoSpeech)
        #expect(error.localizedDescription == Self.noSpeechDetail)
        #expect(transport.isClosed)
    }

    @Test(arguments: [
        "provider_error", "busy", "timeout", "too_long", "superseded", "fallback_required", "key_used",
        "credit_exhausted", "insufficient_credit", "server_restarting", "disconnected", "realtime_unavailable",
        "unsupported_model", "invalid_request", "rate_limited", "protocol_error", "unauthorized", "internal_error",
    ])
    func otherServiceErrorsUploadTheRecording(code: String) async throws {
        let transport = FakeLiveTransport()
        let session = makeSession(transport)
        defer { session.cancel() }
        session.commit(audioSeconds: 1)
        try transport.deliver(Self.errorEvent(code: code))
        let outcome = await session.result()
        #expect(Self.summary(outcome) == "upload: \(code)")
        #expect(transport.isClosed)
    }

    @Test func aCancelledSessionAndAnUncodedErrorSettleWithoutGuessing() async throws {
        let cancelled = FakeLiveTransport()
        let first = makeSession(cancelled)
        defer { first.cancel() }
        try cancelled.deliver(Self.errorEvent(code: "cancelled", status: 499))
        let firstOutcome = await first.result()
        #expect(Self.summary(firstOutcome) == "cancelled")

        let uncoded = FakeLiveTransport()
        let second = makeSession(uncoded)
        defer { second.cancel() }
        try uncoded.deliver(Self.errorEvent(code: nil))
        let secondOutcome = await second.result()
        #expect(Self.summary(secondOutcome) == "upload: -")
        #expect(uncoded.isClosed)
    }

    @Test func cancelSendsOnlyACancelAndDropsLaterAudio() async throws {
        let transport = FakeLiveTransport()
        let session = makeSession(transport)
        try await eventually { transport.sentTexts.count == 1 }
        session.cancel()
        session.audio.append(Data(repeating: 4, count: 4_800))
        #expect(Self.summary(session.outcome) == "cancelled")
        try await eventually { transport.isClosed }
        #expect(transport.sentTexts.count == 2)
        #expect(transport.sentTexts.last == Self.cancelMessage)
        #expect(transport.sentFrames.isEmpty)
        #expect(!session.isCommitted)
    }

    @Test func endCancelsARecordingButKeepsACommittedOneForItsUpload() async throws {
        let recording = FakeLiveTransport()
        let first = makeSession(recording)
        first.end()
        #expect(Self.summary(first.outcome) == "cancelled")
        try await eventually { recording.isClosed }
        // Ended before its start message went out: only the cancel follows.
        #expect(recording.sentTexts == [Self.cancelMessage])

        let committed = FakeLiveTransport()
        let second = makeSession(committed)
        defer { second.cancel() }
        second.commit(audioSeconds: 2)
        try await eventually { second.isCommitted }
        second.end()
        #expect(Self.summary(second.outcome) == "upload: -")
        #expect(committed.isClosed)
        #expect(committed.sentTexts.last == #"{"type":"commit","audio_seconds":2.00}"#)
    }

    @Test func aSlowResultUploadsTheRecording() async throws {
        let transport = FakeLiveTransport()
        let session = makeSession(transport, resultTimeout: .milliseconds(50))
        defer { session.cancel() }
        session.commit(audioSeconds: 1)
        let outcome = await session.result()
        #expect(Self.summary(outcome) == "upload: timeout")
        #expect(transport.isClosed)
    }

    @Test func aConnectionThatFallsTenSecondsBehindUploadsTheRecording() async throws {
        let transport = FakeLiveTransport()
        transport.holdsSends = true
        let session = makeSession(transport)
        defer { session.cancel() }
        // The start message is stuck on the socket, so no audio leaves.
        try await eventually { transport.sent.count == 1 }
        for _ in 0..<LiveAudioInput.backlogLimit {
            session.audio.append(Data(repeating: 5, count: 4_800))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.sent.count == 1)
        #expect(Self.summary(session.outcome) == "pending")

        session.audio.append(Data(repeating: 6, count: 4_800))
        try await eventually { Self.summary(session.outcome) == "upload: backlog" }
        #expect(transport.isClosed)
    }

    @Test func connectionProblemsUploadTheRecording() async throws {
        let dropped = FakeLiveTransport()
        let first = makeSession(dropped)
        defer { first.cancel() }
        dropped.fail(URLError(.networkConnectionLost))
        let firstOutcome = await first.result()
        #expect(Self.summary(firstOutcome) == "upload: -")

        let offline = FakeLiveTransport()
        offline.sendError = URLError(.notConnectedToInternet)
        let second = makeSession(offline)
        defer { second.cancel() }
        let secondOutcome = await second.result()
        #expect(Self.summary(secondOutcome) == "upload: -")
        #expect(offline.sent.isEmpty)
        #expect(offline.isClosed)

        let garbled = FakeLiveTransport()
        let third = makeSession(garbled)
        defer { third.cancel() }
        third.commit(audioSeconds: 1)
        garbled.deliver(#"{"type":"done","id":"x"}"#)
        let thirdOutcome = await third.result()
        #expect(Self.summary(thirdOutcome) == "upload: -")
    }

    @Test func cancellingTheWaitEndsTheSession() async throws {
        let committed = FakeLiveTransport()
        let first = makeSession(committed)
        defer { first.cancel() }
        first.commit(audioSeconds: 1)
        try await eventually { first.isCommitted }
        let waiter = Task { await first.result() }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        let firstOutcome = await waiter.value
        #expect(Self.summary(firstOutcome) == "upload: -")

        let recording = FakeLiveTransport()
        let second = makeSession(recording)
        defer { second.cancel() }
        try await eventually { recording.sentTexts.count == 1 }
        let recordingWaiter = Task { await second.result() }
        try await Task.sleep(for: .milliseconds(20))
        recordingWaiter.cancel()
        let secondOutcome = await recordingWaiter.value
        #expect(Self.summary(secondOutcome) == "cancelled")
        try await eventually { recording.isClosed }
        #expect(recording.sentTexts.last == Self.cancelMessage)
    }

    // MARK: Microphone audio

    @Test func convertsMicrophoneFormatsToFramesOfTheServiceAudio() throws {
        let formats: [(rate: Double, channels: AVAudioChannelCount)] = [
            (48_000, 1), (44_100, 1), (16_000, 1), (48_000, 2),
        ]
        for (rate, channels) in formats {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
            let frames = FrameCollector()
            let made = LivePCMConverter(inputFormat: format) { frames.append($0) }
            let converter = try #require(made)
            for buffer in try Self.tone(format: format, seconds: 1, amplitude: 0.3) {
                converter.push(buffer)
            }
            converter.finish()
            let sizes = frames.sizes
            let fullFrames = sizes.dropLast().allSatisfy { $0 == LiveTranscriptionProtocol.frameBytes }
            let total = sizes.reduce(0, +)
            #expect(!sizes.isEmpty, "\(rate) Hz × \(channels)")
            #expect(fullFrames, "\(rate) Hz × \(channels)")
            // One second of audio, give or take the converter's 10 ms.
            #expect(abs(total - LiveTranscriptionProtocol.bytesPerSecond) <= 960, "\(rate) Hz × \(channels): \(total) bytes")
            #expect(converter.heardSignal, "\(rate) Hz × \(channels)")

            // A finished converter takes no more audio.
            let extra = try Self.tone(format: format, seconds: 0.1, amplitude: 0.3)
            converter.push(extra[0])
            converter.finish()
            #expect(frames.sizes.count == sizes.count, "\(rate) Hz × \(channels)")
        }
    }

    @Test func silenceIsDeliveredButNotHeard() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames = FrameCollector()
        let made = LivePCMConverter(inputFormat: format) { frames.append($0) }
        let converter = try #require(made)
        for buffer in try Self.tone(format: format, seconds: 0.5, amplitude: 0) {
            converter.push(buffer)
        }
        converter.finish()
        #expect(!frames.sizes.isEmpty)
        #expect(!converter.heardSignal)
    }

    // MARK: Recording controller

    @Test func liveRecordingUsesTheLiveTranscriptWithoutUploading() async throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startRecording(account: account)
        #expect(controller.isRecording)
        #expect(fixture.liveModelRequests == [ownerID])
        let live = try #require(fixture.transports.last)
        #expect(live.token == "live-test-\(ownerID)")
        let audio = try #require(fixture.audio)
        #expect(audio.isCapturing)
        try await eventually { live.transport.sentTexts.count == 1 }
        let first = try #require(live.transport.sentTexts.first)
        let start = try Self.object(first)
        #expect(start["model"] as? String == "gpt-live-transcribe")

        audio.speak(Data(repeating: 1, count: 4_800), Data(repeating: 2, count: 4_800))
        try await eventually { live.transport.sentFrames.count == 2 }
        live.transport.deliver(#"{"type":"partial","text":"Hello wor"}"#)
        try await eventually { controller.partialTranscript == "Hello wor" }

        try #require(fixture.recorders.first).capturedTime = 2
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await eventually { live.transport.sentTexts.count == 2 }
        #expect(live.transport.sentTexts.last == #"{"type":"commit","audio_seconds":2.00}"#)
        // The tap's last, shorter frame goes out before the commit.
        #expect(live.transport.sentFrames.count == 3)
        #expect(audio.stopCount == 1)
        #expect(controller.isProcessing)
        #expect(controller.partialTranscript == "Hello wor")
        // The recording is kept until the live transcript arrives.
        #expect(RecordingRecoveryQueue(directory: fixture.recoveryDirectory).recordings[live.requestID] != nil)

        try live.transport.deliver(Self.doneEvent(id: "live-standard", transcript: "Hello world."))
        await stop.value
        #expect(controller.lastTranscript.id == "live-standard")
        #expect(controller.lastTranscript.text == "Hello world.")
        #expect(controller.partialTranscript.isEmpty)
        #expect(fixture.uploads.isEmpty)
        #expect(RecordingRecoveryQueue(directory: fixture.recoveryDirectory).recordings[live.requestID] == nil)
        #expect(live.transport.isClosed)
        #expect(!controller.isProcessing)
    }

    @Test func liveSilenceThatTheTapHeardDiscardsTheRecording() async throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }
        let before = controller.lastTranscript

        await controller.startRecording(account: account)
        let live = try #require(fixture.transports.last)
        try await eventually { live.transport.sentTexts.count == 1 }
        try #require(fixture.recorders.first).capturedTime = 2
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await eventually { live.transport.sentTexts.count == 2 }
        try live.transport.deliver(Self.errorEvent(code: "no_speech", status: 422, detail: Self.noSpeechDetail))
        await stop.value

        #expect(controller.errorMessage == Self.noSpeechDetail)
        #expect(fixture.uploads.isEmpty)
        #expect(controller.failedTranscriptions.isEmpty)
        #expect(RecordingRecoveryQueue(directory: fixture.recoveryDirectory).recordings.isEmpty)
        #expect(controller.lastTranscript == before)
    }

    @Test func liveSilenceThatTheTapMissedIsUploaded() async throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        fixture.heardSignal = false
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startRecording(account: account)
        let live = try #require(fixture.transports.last)
        try await eventually { live.transport.sentTexts.count == 1 }
        try #require(fixture.recorders.first).capturedTime = 2
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await eventually { live.transport.sentTexts.count == 2 }
        try live.transport.deliver(Self.errorEvent(code: "no_speech", status: 422, detail: Self.noSpeechDetail))
        try await eventually { fixture.uploads == [live.requestID] }
        fixture.respond(to: live.requestID, with: .success(Self.response("upload-1", transcript: "Quiet words.")))
        await stop.value

        #expect(controller.lastTranscript.id == "upload-1")
        #expect(controller.errorMessage == nil)
    }

    @Test func aDroppedLiveSessionUploadsWithTheSameRequestAndHints() async throws {
        let preferences = DictationPreferences(
            languages: [.english], words: [PersonalVocabularyWord(text: "VoiceType", learned: false)], mode: .live
        )
        DictationPreferencesStore.save(preferences, userID: ownerID)
        defer { DictationPreferencesStore.clear(userID: ownerID) }
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startRecording(account: account)
        let live = try #require(fixture.transports.last)
        try await eventually { live.transport.sentTexts.count == 1 }
        let first = try #require(live.transport.sentTexts.first)
        let start = try Self.object(first)
        #expect(start["preferred_languages"] as? String == #"["en"]"#)
        #expect(start["vocabulary"] as? String == #"["VoiceType"]"#)

        live.transport.fail(URLError(.networkConnectionLost))
        try await eventually { live.transport.isClosed }
        try #require(fixture.recorders.first).capturedTime = 3
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await eventually { fixture.uploads == [live.requestID] }
        let queued = RecordingRecoveryQueue(directory: fixture.recoveryDirectory).recordings[live.requestID]
        #expect(queued?.context == DictationContext(languages: ["en"], vocabulary: ["VoiceType"]))
        fixture.respond(to: live.requestID, with: .success(Self.response("upload-2", transcript: "VoiceType rocks.")))
        await stop.value
        #expect(controller.lastTranscript.id == "upload-2")
    }

    @Test func aControllerWithoutALiveTransportOnlyUploads() async throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller(live: false)
        defer { controller.cancel() }

        await controller.startRecording(account: account)
        #expect(controller.isRecording)
        #expect(fixture.liveModelRequests.isEmpty)
        #expect(fixture.audioSources.isEmpty)
        try #require(fixture.recorders.first).capturedTime = 3
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await eventually { fixture.uploads.count == 1 }
        let id = try #require(fixture.uploads.first)
        fixture.respond(to: id, with: .success(Self.response("upload-3", transcript: "Uploaded.")))
        await stop.value
        #expect(controller.lastTranscript.id == "upload-3")
    }

    @Test func anUploadModeNeverConnects() async throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        fixture.liveModelName = nil
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startRecording(account: account)
        #expect(controller.isRecording)
        #expect(fixture.liveModelRequests == [ownerID])
        #expect(fixture.transports.isEmpty)
        #expect(fixture.audioSources.isEmpty)
        try #require(fixture.recorders.first).capturedTime = 3
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await eventually { fixture.uploads.count == 1 }
        let id = try #require(fixture.uploads.first)
        fixture.respond(to: id, with: .success(Self.response("upload-6", transcript: "Uploaded.")))
        await stop.value
        #expect(controller.lastTranscript.id == "upload-6")
    }

    @Test func aServiceWithoutLiveTranscriptionStopsLaterAttempts() async throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startRecording(account: account)
        let live = try #require(fixture.transports.last)
        try live.transport.deliver(Self.errorEvent(code: "realtime_unavailable", status: 403))
        try await eventually { live.transport.isClosed }
        try #require(fixture.recorders.first).capturedTime = 3
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await eventually { fixture.uploads == [live.requestID] }
        fixture.respond(to: live.requestID, with: .success(Self.response("upload-4", transcript: "Uploaded.")))
        await stop.value
        #expect(controller.lastTranscript.id == "upload-4")

        await controller.startRecording(account: account)
        #expect(controller.isRecording)
        #expect(fixture.transports.count == 1)
        #expect(fixture.audioSources.count == 1)
        #expect(fixture.liveModelRequests == [ownerID])
    }

    @Test func cancellingALiveRecordingSendsACancelAndUploadsNothing() async throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startRecording(account: account)
        let live = try #require(fixture.transports.last)
        let audio = try #require(fixture.audio)
        try await eventually { live.transport.sentTexts.count == 1 }
        audio.speak(Data(repeating: 1, count: 4_800))
        try await eventually { live.transport.sentFrames.count == 1 }
        controller.cancel()

        try await eventually { live.transport.isClosed }
        #expect(live.transport.sentTexts.count == 2)
        #expect(live.transport.sentTexts.last == Self.cancelMessage)
        // The tap's last frame arrives after the cancel and stays on the phone.
        #expect(live.transport.sentFrames.count == 1)
        #expect(audio.stopCount == 1)
        #expect(fixture.uploads.isEmpty)
        #expect(!controller.isRecording)
    }

    @Test func aShortKeyboardClipCancelsItsLiveSession() async throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startKeyboardReady(account: account)
        #expect(controller.isKeyboardReady)
        let recorder = try #require(fixture.recorders.first)
        recorder.capturedTime = 4
        RecordingBridgeStore.requestStartClip()
        try await eventually { controller.isKeyboardRecording }
        let live = try #require(fixture.transports.last)
        try await eventually { live.transport.sentTexts.count == 1 }
        recorder.capturedTime = 4.1
        await controller.stopAndTranscribe(account: account)

        try await eventually { live.transport.isClosed }
        #expect(live.transport.sentTexts.count == 2)
        #expect(live.transport.sentTexts.last == Self.cancelMessage)
        #expect(live.transport.sentFrames.isEmpty)
        #expect(fixture.exportRanges.isEmpty)
        #expect(fixture.uploads.isEmpty)
        #expect(controller.isKeyboardReady)
    }

    @Test func aKeyboardClipPreviewsAndInsertsTheLiveTranscript() async throws {
        PartialTranscriptStore.clear()
        defer { PartialTranscriptStore.clear() }
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startKeyboardReady(account: account)
        let recorder = try #require(fixture.recorders.first)
        recorder.capturedTime = 4
        RecordingBridgeStore.requestStartClip()
        try await eventually { controller.isKeyboardRecording }
        let sessionID = RecordingBridgeStore.state.sessionID
        let live = try #require(fixture.transports.last)
        live.transport.deliver(#"{"type":"partial","text":"Hello"}"#)
        try await eventually { PartialTranscriptStore.latest(for: sessionID)?.text == "Hello" }

        recorder.capturedTime = 9
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await eventually { live.transport.sentTexts.count == 2 }
        #expect(live.transport.sentTexts.last == #"{"type":"commit","audio_seconds":5.00}"#)
        #expect(controller.isKeyboardTranscribing)
        #expect(PartialTranscriptStore.latest(for: sessionID)?.text == "Hello")

        try live.transport.deliver(Self.doneEvent(id: "live-keyboard", transcript: "Hello keyboard."))
        await stop.value
        #expect(SharedTranscriptStore.latest.id == "live-keyboard")
        #expect(SharedTranscriptStore.latest.text == "Hello keyboard.")
        #expect(fixture.exportRanges.isEmpty)
        #expect(fixture.uploads.isEmpty)
        #expect(PartialTranscriptStore.latest(for: sessionID) == nil)
        #expect(controller.isKeyboardReady)
    }

    @Test func aKeyboardClipTheServiceCouldNotFinishIsExportedAndUploaded() async throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startKeyboardReady(account: account)
        let recorder = try #require(fixture.recorders.first)
        recorder.capturedTime = 4
        RecordingBridgeStore.requestStartClip()
        try await eventually { controller.isKeyboardRecording }
        let live = try #require(fixture.transports.last)
        try await eventually { live.transport.sentTexts.count == 1 }
        recorder.capturedTime = 9
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await eventually { live.transport.sentTexts.count == 2 }
        try live.transport.deliver(Self.errorEvent(code: "provider_error"))

        try await eventually { fixture.exportContinuation != nil }
        #expect(fixture.exportRanges.last?.start == 4)
        #expect(fixture.exportRanges.last?.duration == 5)
        try fixture.finishExport()
        try await eventually { fixture.uploads == [live.requestID] }
        fixture.respond(to: live.requestID, with: .success(Self.response("upload-keyboard", transcript: "Uploaded clip.")))
        await stop.value
        #expect(SharedTranscriptStore.latest.id == "upload-keyboard")
        #expect(controller.isKeyboardReady)
    }

    @Test func aMicrophoneTapThatCannotStartLeavesTheRecordingToUpload() async throws {
        let fixture = try LiveFixture()
        defer { fixture.cleanUp() }
        fixture.audioStartError = RecorderError.failedToStart
        let account = AccountStore(backend: LiveTestAccountBackend())
        defer { account.signOut() }
        account.apply(auth: auth())
        let controller = fixture.controller()
        defer { controller.cancel() }

        await controller.startRecording(account: account)
        #expect(controller.isRecording)
        let live = try #require(fixture.transports.last)
        try await eventually { live.transport.isClosed }
        #expect(live.transport.sentTexts == [Self.cancelMessage])

        try #require(fixture.recorders.first).capturedTime = 3
        let stop = Task { await controller.stopAndTranscribe(account: account) }
        try await eventually { fixture.uploads.count == 1 }
        let id = try #require(fixture.uploads.first)
        #expect(id != live.requestID)
        fixture.respond(to: id, with: .success(Self.response("upload-5", transcript: "Uploaded.")))
        await stop.value
        #expect(controller.lastTranscript.id == "upload-5")
    }

    // MARK: Upload after a live session

    @Test func anUploadWaitsForTheLiveSessionToFinish() async throws {
        let id = UUID()
        let file = try Self.recordingFile()
        let session = Self.stubSession()
        defer {
            session.invalidateAndCancel()
            LiveUploadStub.shared.clear(id)
            try? FileManager.default.removeItem(at: file)
        }
        let pending = try JSONSerialization.data(withJSONObject: ["detail": Self.pendingDetail])
        let finished = try Data(Self.transcriptJSON(id: "live-finished", transcript: "Finished live.").utf8)
        LiveUploadStub.shared.stub(id, [
            .init(status: 409, retryAfter: "1", body: pending),
            .init(status: 200, retryAfter: nil, body: finished),
        ])

        let started = Date()
        let response = try await BackendClient.transcribe(
            fileURL: file, duration: 2, token: "live-test-token", requestID: id, patience: 5, session: session
        )
        #expect(response.id == "live-finished")
        #expect(response.transcript == "Finished live.")
        #expect(LiveUploadStub.shared.requests(for: id).count == 2)
        #expect(Date().timeIntervalSince(started) >= 0.9)
    }

    @Test func anImpatientUploadReportsTheLiveSessionStillRunning() async throws {
        let id = UUID()
        let file = try Self.recordingFile()
        let session = Self.stubSession()
        defer {
            session.invalidateAndCancel()
            LiveUploadStub.shared.clear(id)
            try? FileManager.default.removeItem(at: file)
        }
        let pending = try JSONSerialization.data(withJSONObject: ["detail": Self.pendingDetail])
        LiveUploadStub.shared.stub(id, [.init(status: 409, retryAfter: "30", body: pending)])

        do {
            _ = try await BackendClient.transcribe(
                fileURL: file, duration: 2, token: "live-test-token", requestID: id, session: session
            )
            Issue.record("A pending live session should fail an upload without patience")
        } catch let error as BackendClientError {
            guard case let .httpError(status, message, _, _) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(status == 409)
            #expect(message == Self.pendingDetail)
            #expect(error.localizedDescription == Self.pendingDetail)
        }
        #expect(LiveUploadStub.shared.requests(for: id).count == 1)
    }

    @Test func aConflictWithoutRetryAfterIsNotRetried() async throws {
        let id = UUID()
        let file = try Self.recordingFile()
        let session = Self.stubSession()
        defer {
            session.invalidateAndCancel()
            LiveUploadStub.shared.clear(id)
            try? FileManager.default.removeItem(at: file)
        }
        let conflict = try JSONSerialization.data(withJSONObject: ["detail": "This request key was already used."])
        LiveUploadStub.shared.stub(id, [.init(status: 409, retryAfter: nil, body: conflict)])

        await #expect(throws: BackendClientError.self) {
            _ = try await BackendClient.transcribe(
                fileURL: file, duration: 2, token: "live-test-token", requestID: id, patience: 5, session: session
            )
        }
        #expect(LiveUploadStub.shared.requests(for: id).count == 1)
    }

    @Test func theLiveRequestUsesTheServiceSocketAndRequestKey() throws {
        let id = UUID()
        let request = try BackendClient.liveTranscriptionRequest(token: "live-test-token", requestID: id)
        let configured = (Bundle.main.object(forInfoDictionaryKey: "VoiceTypeBackendURL") as? String).flatMap { URL(string: $0) }
        let base = try #require(configured)
        let url = try #require(request.url)
        #expect(url.scheme == (base.scheme == "http" ? "ws" : "wss"))
        #expect(url.host() == base.host())
        #expect(url.path().hasSuffix("/v1/realtime/transcriptions"))
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == id.uuidString)
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "voicetype.realtime.v1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live-test-token")
        #expect(!request.allowsConstrainedNetworkAccess)
    }

    // MARK: Preferences

    @Test func savedModeDecodesSafely() throws {
        let unknown = try JSONDecoder().decode(
            DictationPreferences.self, from: Data(#"{"mode":"telepathy","liveModel":"gpt-transcribe"}"#.utf8)
        )
        #expect(unknown.mode == .streaming)
        #expect(unknown.liveModel == "gpt-transcribe")

        let live = DictationPreferences(mode: .live, liveModel: "gpt-live-transcribe")
        let roundTrip = try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(live))
        #expect(roundTrip == live)

        #expect(DictationPreferences().mode == .streaming)
        let older = try JSONDecoder().decode(DictationPreferences.self, from: Data(#"{"languages":["en"]}"#.utf8))
        #expect(older.mode == .streaming)
        #expect(older.liveModel == nil)
        let english: [DictationLanguage] = [.english]
        #expect(older.languages == english)
    }

    @Test func liveModelFollowsTheChoiceAndTheCatalog() {
        let live = DictationPreferences(mode: .live)
        #expect(live.resolvedLiveModel(in: Self.catalog()) == "gpt-live-transcribe")
        let chosen = DictationPreferences(mode: .live, liveModel: "gpt-transcribe")
        #expect(chosen.resolvedLiveModel(in: Self.catalog()) == "gpt-transcribe")
        let retired = DictationPreferences(mode: .live, liveModel: "gpt-retired")
        #expect(retired.resolvedLiveModel(in: Self.catalog()) == "gpt-live-transcribe")
        let unlistedDefault = Self.catalog(defaultLive: "gpt-missing", live: ["gpt-transcribe", "gpt-live-transcribe"])
        #expect(live.resolvedLiveModel(in: unlistedDefault) == "gpt-transcribe")

        let streaming = DictationPreferences(mode: .streaming, liveModel: "gpt-transcribe")
        let afterRecording = DictationPreferences(mode: .afterRecording)
        #expect(streaming.resolvedLiveModel(in: Self.catalog()) == nil)
        #expect(afterRecording.resolvedLiveModel(in: Self.catalog()) == nil)
        #expect(live.resolvedLiveModel(in: Self.catalog(available: false)) == nil)
        #expect(live.resolvedLiveModel(in: Self.catalog(live: nil)) == nil)
        #expect(live.resolvedLiveModel(in: Self.catalog(live: [])) == nil)
        #expect(live.resolvedLiveModel(in: nil) == nil)
    }

    @Test func catalogDecodesLiveModelsWhenTheServiceListsThem() throws {
        let older = try JSONDecoder().decode(TranscriptionModelCatalog.self, from: Data("""
        {"default_model":"gpt-transcribe","default_model_name":"GPT Transcribe","models":[
          {"id":"gpt-transcribe","name":"GPT Transcribe","recommended":true,"streaming":true,"retires_on":null,
           "pricing_basis":"provider_audio_price","credit_units_per_minute":7715,"formatted_per_minute":"About 7,715 credits"}
        ]}
        """.utf8))
        #expect(older.realtime == nil)

        let current = try JSONDecoder().decode(TranscriptionModelCatalog.self, from: Data("""
        {"default_model":"gpt-transcribe","default_model_name":"GPT Transcribe","models":[],
         "realtime":{"available":true,"default_model":"gpt-live-transcribe","models":[
           {"id":"gpt-live-transcribe","name":"GPT Live Transcribe","recommended":true,"live_only":true,
            "text_timing":"while_speaking","retires_on":null,"pricing_basis":"audio_minutes",
            "credit_units_per_minute":29144,"formatted_per_minute":"29,144 credits/min"}
         ]}}
        """.utf8))
        let realtime = try #require(current.realtime)
        #expect(realtime.available)
        #expect(realtime.defaultModel == "gpt-live-transcribe")
        let model = try #require(realtime.models.first)
        #expect(model.liveOnly)
        #expect(model.textTiming == "while_speaking")
        #expect(model.retiresOn == nil)
        #expect(model.creditUnitsPerMinute == 29_144)
        #expect(model.formattedPerMinute == "29,144 credits/min")
    }

    @Test func storedLiveModelNeedsTheSavedCatalog() throws {
        let suite = "live-transcription-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DictationPreferencesStore.liveModel(userID: ownerID, defaults: defaults) == nil)
        DictationPreferencesStore.save(DictationPreferences(mode: .live, liveModel: "gpt-transcribe"), userID: ownerID, defaults: defaults)
        #expect(DictationPreferencesStore.liveModel(userID: ownerID, defaults: defaults) == nil)
        TranscriptionModelCatalogStore.save(Self.catalog(), defaults: defaults)
        #expect(DictationPreferencesStore.liveModel(userID: ownerID, defaults: defaults) == "gpt-transcribe")
        #expect(DictationPreferencesStore.liveModel(userID: "another-user", defaults: defaults) == nil)
        #expect(DictationPreferencesStore.liveModel(userID: "", defaults: defaults) == nil)
    }

    // MARK: Settings

    @Test func settingsOfferLiveModelsOnlyWhenARecordingWouldUseThem() {
        let live = DictationPreferences(mode: .live)
        let catalogs: [TranscriptionModelCatalog?] = [
            Self.catalog(), Self.catalog(available: false), Self.catalog(live: nil), Self.catalog(live: []), nil,
        ]
        for catalog in catalogs {
            let offered = TranscriptionModelSettingsView.offeredLive(in: catalog) != nil
            let used = live.resolvedLiveModel(in: catalog) != nil
            #expect(offered == used)
        }
    }

    @Test func settingsExplainWhatHappensWhenAModeCannotWork() {
        let catalog = Self.catalog()
        for mode in TranscriptionMode.allCases {
            #expect(TranscriptionModelSettingsView.note(for: mode, model: nil, in: catalog) == nil)
        }

        let unavailable = "Live isn't available right now, so recordings upload when you stop."
        #expect(TranscriptionModelSettingsView.note(for: .live, model: nil, in: Self.catalog(available: false)) == unavailable)
        #expect(TranscriptionModelSettingsView.note(for: .live, model: nil, in: Self.catalog(live: nil)) == unavailable)
        #expect(TranscriptionModelSettingsView.note(for: .live, model: nil, in: Self.catalog(live: [])) == unavailable)
        #expect(TranscriptionModelSettingsView.note(for: .live, model: nil, in: nil)
                == "Live needs the service's model list. Until it loads, recordings upload when you stop.")
        #expect(TranscriptionModelSettingsView.note(for: .streaming, model: nil, in: nil) == nil)

        let whisper = TranscriptionModelOption(
            id: "whisper-1", name: "Whisper", recommended: false, streaming: false, retiresOn: nil,
            pricingBasis: "duration", creditUnitsPerMinute: 10_286, formattedPerMinute: "10,286 credits/min"
        )
        let withWhisper = TranscriptionModelCatalog(defaultModel: catalog.defaultModel, defaultModelName: catalog.defaultModelName,
                                                    models: catalog.models + [whisper], realtime: catalog.realtime)
        let noStreaming = "Whisper doesn't stream, so its text appears when it's done."
        #expect(TranscriptionModelSettingsView.note(for: .streaming, model: "whisper-1", in: withWhisper) == noStreaming)
        #expect(TranscriptionModelSettingsView.note(for: .afterRecording, model: "whisper-1", in: withWhisper) == nil)
        #expect(TranscriptionModelSettingsView.note(for: .live, model: "whisper-1", in: withWhisper) == nil)

        // Automatic follows the service default, which may not stream either.
        let whisperByDefault = TranscriptionModelCatalog(defaultModel: "whisper-1", defaultModelName: "Whisper",
                                                         models: catalog.models + [whisper], realtime: nil)
        #expect(TranscriptionModelSettingsView.note(for: .streaming, model: nil, in: whisperByDefault) == noStreaming)
        #expect(TranscriptionModelSettingsView.note(for: .live, model: nil, in: whisperByDefault) == unavailable + " " + noStreaming)
    }

    @Test func liveModelDetailsSayWhenTextAppearsAndWhatItCosts() {
        let live = RealtimeTranscriptionModel(
            id: "gpt-live-transcribe", name: "GPT Live Transcribe", recommended: true, liveOnly: true,
            textTiming: "while_speaking", retiresOn: nil, pricingBasis: "audio_minutes",
            creditUnitsPerMinute: 29_144, formattedPerMinute: "29,144 credits/min"
        )
        let paused = RealtimeTranscriptionModel(
            id: "gpt-transcribe", name: "GPT Transcribe", recommended: false, liveOnly: false,
            textTiming: "after_pauses", retiresOn: "2027-02-26", pricingBasis: "audio_minutes",
            creditUnitsPerMinute: 7_715, formattedPerMinute: "7,715 credits/min"
        )
        let unknown = RealtimeTranscriptionModel(
            id: "gpt-next", name: "GPT Next", recommended: false, liveOnly: true,
            textTiming: "eventually", retiresOn: nil, pricingBasis: "audio_minutes",
            creditUnitsPerMinute: 1_000, formattedPerMinute: "1,000 credits/min"
        )
        #expect(TranscriptionModelSettingsView.detail(for: live) == "Recommended · Text as you speak · About 29,144 credits/min")
        let retiring = TranscriptionModelSettingsView.detail(for: paused)
        #expect(retiring.hasPrefix("Text after each pause · About 7,715 credits/min · Retires "))
        #expect(retiring.contains("2027"))
        #expect(TranscriptionModelSettingsView.detail(for: unknown) == "About 1,000 credits/min")

        let listed = RealtimeTranscriptionCatalog(available: true, defaultModel: "gpt-live-transcribe", models: [paused, live])
        #expect(TranscriptionModelSettingsView.automaticDetail(for: listed) == "Uses the service default, currently GPT Live Transcribe.")
        // Recording uses the first model when the default isn't listed.
        let unlisted = RealtimeTranscriptionCatalog(available: true, defaultModel: "gpt-missing", models: [paused, live])
        #expect(TranscriptionModelSettingsView.automaticDetail(for: unlisted) == "Uses the service default, currently GPT Transcribe.")
        let recordingCatalog = TranscriptionModelCatalog(
            defaultModel: "gpt-transcribe", defaultModelName: "GPT Transcribe", models: [], realtime: unlisted
        )
        let recorded = DictationPreferences(mode: .live).resolvedLiveModel(in: recordingCatalog)
        #expect(recorded == "gpt-transcribe")
    }

    @Test func eachModeHasACaption() {
        let titles = TranscriptionMode.allCases.map(TranscriptionModelSettingsView.title(for:))
        #expect(titles == ["After recording", "Streaming", "Live"])
        for mode in TranscriptionMode.allCases {
            #expect(!TranscriptionModelSettingsView.caption(for: mode).isEmpty)
        }
        #expect(TranscriptionModelSettingsView.liveFooter.contains("30 days"))
        #expect(TranscriptionModelSettingsView.liveFooter.contains("even if you cancel"))
    }

    // MARK: Helpers

    private func auth() -> AuthResponse {
        AuthResponse(token: "live-test-\(ownerID)", user: UserProfile(id: ownerID, email: nil),
                     balance: BalancePayload(balanceUSDMicros: 100_000, balanceCreditUnits: 100_000, formatted: "100,000 credits"))
    }

    private func eventually(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "The expected live transition did not occur", sourceLocation: sourceLocation)
    }

    private func makeSession(
        _ transport: FakeLiveTransport, context: DictationContext = .empty,
        resultTimeout: Duration = .seconds(15), heard: Heard? = nil
    ) -> LiveTranscriptionSession {
        LiveTranscriptionSession(
            requestID: UUID(), model: "gpt-live-transcribe", context: context,
            transport: transport, resultTimeout: resultTimeout
        ) { text in
            heard?.texts.append(text)
        }
    }

    private static func response(_ id: String, transcript: String) -> TranscriptionResponse {
        TranscriptionResponse(
            id: id, transcript: transcript, model: "gpt-live-transcribe",
            charge: ChargePayload(costUSDMicros: 486, costCreditUnits: 486, formatted: "486 credits", pricingBasis: "provider_realtime_price"),
            balance: BalancePayload(balanceUSDMicros: 99_514, balanceCreditUnits: 99_514, formatted: "99,514 credits")
        )
    }

    private static func transcriptJSON(id: String, transcript: String, type: String? = nil) throws -> String {
        var object: [String: Any] = [
            "id": id,
            "transcript": transcript,
            "model": "gpt-live-transcribe",
            "charge": [
                "cost_usd_micros": 486, "cost_credit_units": 486,
                "formatted": "486 credits", "pricing_basis": "provider_realtime_price",
            ] as [String: Any],
            "balance": [
                "balance_usd_micros": 99_514, "balance_credit_units": 99_514, "formatted": "99,514 credits",
            ] as [String: Any],
        ]
        if let type { object["type"] = type }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func doneEvent(id: String, transcript: String) throws -> String {
        try transcriptJSON(id: id, transcript: transcript, type: "done")
    }

    private static func errorEvent(code: String?, status: Int = 502, detail: String = "Live transcription stopped.") throws -> String {
        var object: [String: Any] = ["type": "error", "status": status, "detail": detail]
        if let code { object["code"] = code }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private static func summary(_ outcome: LiveTranscriptionOutcome?) -> String {
        switch outcome {
        case nil:
            return "pending"
        case let .transcribed(response)?:
            return "transcribed: \(response.id)"
        case let .rejected(error)?:
            if case let .httpError(status, _, _, code) = error {
                return "rejected: \(status) \(code ?? "-")"
            }
            return "rejected: \(error)"
        case .cancelled?:
            return "cancelled"
        case let .upload(code)?:
            return "upload: \(code ?? "-")"
        }
    }

    private static func catalog(
        available: Bool = true, defaultLive: String = "gpt-live-transcribe",
        live: [String]? = ["gpt-live-transcribe", "gpt-transcribe"]
    ) -> TranscriptionModelCatalog {
        TranscriptionModelCatalog(
            defaultModel: "gpt-transcribe", defaultModelName: "GPT Transcribe",
            models: [
                TranscriptionModelOption(
                    id: "gpt-transcribe", name: "GPT Transcribe", recommended: true, streaming: true, retiresOn: nil,
                    pricingBasis: "provider_audio_price", creditUnitsPerMinute: 7_715, formattedPerMinute: "About 7,715 credits"
                ),
            ],
            realtime: live.map { ids in
                RealtimeTranscriptionCatalog(available: available, defaultModel: defaultLive, models: ids.map { id in
                    RealtimeTranscriptionModel(
                        id: id, name: id, recommended: id == "gpt-live-transcribe", liveOnly: id == "gpt-live-transcribe",
                        textTiming: id == "gpt-live-transcribe" ? "while_speaking" : "after_pauses", retiresOn: nil,
                        pricingBasis: "provider_realtime_price", creditUnitsPerMinute: 29_144,
                        formattedPerMinute: "About 29,144 credits"
                    )
                })
            }
        )
    }

    /// A 440 Hz tone on every channel, in the tap's usual 4,096-frame buffers.
    private static func tone(format: AVAudioFormat, seconds: Double, amplitude: Float) throws -> [AVAudioPCMBuffer] {
        var remaining = Int(format.sampleRate * seconds)
        var position = 0
        var buffers: [AVAudioPCMBuffer] = []
        while remaining > 0 {
            let count = min(remaining, 4_096)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let channels = try #require(buffer.floatChannelData)
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<count {
                    let time = Double(position + frame) / format.sampleRate
                    channels[channel][frame] = amplitude * Float(sin(2 * Double.pi * 440 * time))
                }
            }
            buffers.append(buffer)
            position += count
            remaining -= count
        }
        return buffers
    }

    private static func recordingFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-upload-\(UUID().uuidString).m4a")
        try Data("inert live upload audio".utf8).write(to: url)
        return url
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveUploadURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

// MARK: - Doubles

/// A socket that records what the session sends and delivers what a test
/// says the service sent.
private final class FakeLiveTransport: LiveTranscriptionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [LiveTranscriptionMessage] = []
    private var inbox: [Result<LiveTranscriptionMessage, any Error>] = []
    private var receiver: CheckedContinuation<LiveTranscriptionMessage, any Error>?
    private var heldSends: [CheckedContinuation<Void, any Error>] = []
    private var _isClosed = false
    private var _holdsSends = false
    private var _sendError: (any Error)?

    /// Sends are recorded but never complete, like a stalled connection.
    var holdsSends: Bool {
        get { lock.withLock { _holdsSends } }
        set { lock.withLock { _holdsSends = newValue } }
    }

    /// Every send fails with this, before anything is recorded.
    var sendError: (any Error)? {
        get { lock.withLock { _sendError } }
        set { lock.withLock { _sendError = newValue } }
    }

    var sent: [LiveTranscriptionMessage] { lock.withLock { _sent } }

    var sentTexts: [String] {
        sent.compactMap { message -> String? in
            if case let .text(text) = message { return text }
            return nil
        }
    }

    var sentFrames: [Data] {
        sent.compactMap { message -> Data? in
            if case let .data(data) = message { return data }
            return nil
        }
    }

    var isClosed: Bool { lock.withLock { _isClosed } }

    func send(_ message: LiveTranscriptionMessage) async throws {
        enum Next {
            case fail(any Error)
            case done
            case hold
        }
        let next: Next = lock.withLock {
            if _isClosed { return .fail(URLError(.cancelled)) }
            if let error = _sendError { return .fail(error) }
            _sent.append(message)
            return _holdsSends ? .hold : .done
        }
        switch next {
        case let .fail(error):
            throw error
        case .done:
            return
        case .hold:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let closed = lock.withLock { () -> Bool in
                    if _isClosed { return true }
                    heldSends.append(continuation)
                    return false
                }
                if closed { continuation.resume(throwing: URLError(.cancelled)) }
            }
        }
    }

    func receive() async throws -> LiveTranscriptionMessage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LiveTranscriptionMessage, any Error>) in
            let ready = lock.withLock { () -> Result<LiveTranscriptionMessage, any Error>? in
                if !inbox.isEmpty { return inbox.removeFirst() }
                if _isClosed { return .failure(URLError(.cancelled)) }
                receiver = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func close() {
        let waiting = lock.withLock { () -> (CheckedContinuation<LiveTranscriptionMessage, any Error>?, [CheckedContinuation<Void, any Error>]) in
            guard !_isClosed else { return (nil, []) }
            _isClosed = true
            let pending = (receiver, heldSends)
            receiver = nil
            heldSends = []
            return pending
        }
        waiting.0?.resume(throwing: URLError(.cancelled))
        for send in waiting.1 { send.resume(throwing: URLError(.cancelled)) }
    }

    func deliver(_ text: String) {
        enqueue(.success(.text(text)))
    }

    func deliverBinary(_ data: Data) {
        enqueue(.success(.data(data)))
    }

    func fail(_ error: any Error) {
        enqueue(.failure(error))
    }

    private func enqueue(_ result: Result<LiveTranscriptionMessage, any Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<LiveTranscriptionMessage, any Error>? in
            guard !_isClosed else { return nil }
            if let receiver {
                self.receiver = nil
                return receiver
            }
            inbox.append(result)
            return nil
        }
        waiting?.resume(with: result)
    }
}

/// A microphone tap the test speaks into.
private final class FakeLiveAudio: LiveAudioSource, @unchecked Sendable {
    var startError: (any Error)?
    var heardSignal = true
    /// What the tap still delivers when it stops: the last, shorter frame.
    var framesOnStop: [Data] = []
    private(set) var isCapturing = false
    private(set) var stopCount = 0
    private var onFrame: (@Sendable (Data) -> Void)?

    func start(onFrame: @escaping @Sendable (Data) -> Void) throws {
        if let startError { throw startError }
        self.onFrame = onFrame
        isCapturing = true
    }

    func speak(_ frames: Data...) {
        for frame in frames { onFrame?(frame) }
    }

    func stop() {
        stopCount += 1
        guard isCapturing else { return }
        isCapturing = false
        for frame in framesOnStop { onFrame?(frame) }
        onFrame = nil
    }
}

private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []

    func append(_ frame: Data) {
        lock.withLock { frames.append(frame) }
    }

    var sizes: [Int] { lock.withLock { frames.map(\.count) } }
}

@MainActor
private final class Heard {
    var texts: [String] = []
}

@MainActor
private final class LiveFixture {
    static let audioBytes = Data("finalized live test audio".utf8)
    let directory: URL
    let recoveryDirectory: URL
    var recorders: [LiveTestRecorder] = []
    var exportContinuation: CheckedContinuation<Void, Error>?
    var exportOutputURL: URL?
    var exportRanges: [(start: TimeInterval, duration: TimeInterval)] = []
    var uploads: [UUID] = []
    var pendingUploads: [(id: UUID, continuation: CheckedContinuation<TranscriptionResponse, Error>)] = []
    var transports: [(token: String, requestID: UUID, transport: FakeLiveTransport)] = []
    var audioSources: [FakeLiveAudio] = []
    /// What the saved settings choose; nil uploads.
    var liveModelName: String? = "gpt-live-transcribe"
    var liveModelRequests: [String] = []
    var heardSignal = true
    var audioStartError: (any Error)?
    var framesOnStop = [Data(repeating: 1, count: 2_400)]

    var transport: FakeLiveTransport? { transports.last?.transport }
    var audio: FakeLiveAudio? { audioSources.last }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-transcription-\(UUID().uuidString)")
        recoveryDirectory = directory.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func controller(live: Bool = true) -> RecordingController {
        let liveTransport: ((String, UUID) throws -> any LiveTranscriptionTransport)?
        if live {
            liveTransport = { [self] token, requestID in
                let transport = FakeLiveTransport()
                transports.append((token, requestID, transport))
                return transport
            }
        } else {
            liveTransport = nil
        }
        return RecordingController(
            recoveryDirectory: recoveryDirectory,
            recorderFactory: { [self] in
                let url = directory.appendingPathComponent("live-\(UUID().uuidString).m4a")
                let recorder = try LiveTestRecorder(url: url, settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                ])
                try Self.audioBytes.write(to: url)
                recorders.append(recorder)
                return (recorder, url)
            },
            permissionRequest: { true },
            clipExporter: { [self] _, outputURL, start, duration in
                exportOutputURL = outputURL
                exportRanges.append((start, duration))
                try await withCheckedThrowingContinuation { exportContinuation = $0 }
            },
            audioSessionActivation: {},
            transcriptionRequest: { [self] _, _, _, id, _ in
                uploads.append(id)
                return try await withCheckedThrowingContinuation { pendingUploads.append((id, $0)) }
            },
            liveTransport: liveTransport,
            liveAudioSource: { [self] in
                let audio = FakeLiveAudio()
                audio.heardSignal = heardSignal
                audio.startError = audioStartError
                audio.framesOnStop = framesOnStop
                audioSources.append(audio)
                return audio
            },
            liveModel: { [self] userID in
                liveModelRequests.append(userID)
                return liveModelName
            }
        )
    }

    func respond(to id: UUID, with result: Result<TranscriptionResponse, Error>) {
        guard let index = pendingUploads.firstIndex(where: { $0.id == id }) else { return }
        pendingUploads.remove(at: index).continuation.resume(with: result)
    }

    func finishExport() throws {
        try Self.audioBytes.write(to: #require(exportOutputURL))
        exportContinuation?.resume()
        exportContinuation = nil
    }

    func cleanUp() {
        exportContinuation?.resume(throwing: CancellationError())
        exportContinuation = nil
        pendingUploads.forEach { $0.continuation.resume(throwing: CancellationError()) }
        pendingUploads = []
        transports.forEach { $0.transport.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private struct LiveTestAccountBackend: AccountBackend {
    func signInWithApple(identityToken: String, authorizationCode: String?, email: String?, fullName: String?) async throws -> AuthResponse {
        throw BackendClientError.invalidResponse
    }
    func me(token: String) async throws -> MeResponse { throw BackendClientError.invalidResponse }
    func deleteAccount(token: String) async throws { throw BackendClientError.invalidResponse }
}

// No recording method calls AVFoundation: the controller runs its real
// lifecycle without microphone permission, capture, or networking.
private final class LiveTestRecorder: AVAudioRecorder, @unchecked Sendable {
    var capturedTime: TimeInterval = 0
    var capturing = false
    override var currentTime: TimeInterval { capturedTime }
    override var isRecording: Bool { capturing }
    override func record() -> Bool {
        capturing = true
        return true
    }
    override func record(forDuration duration: TimeInterval) -> Bool { record() }
    override func pause() { capturing = false }
    override func stop() { capturing = false }
    override func updateMeters() {}
    override func averagePower(forChannel channelNumber: Int) -> Float { -160 }
}

/// Replies for uploads, by request key.
private final class LiveUploadStub: @unchecked Sendable {
    static let shared = LiveUploadStub()

    struct Reply {
        let status: Int
        let retryAfter: String?
        let body: Data
    }

    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var received: [String: [Date]] = [:]

    func stub(_ id: UUID, _ replies: [Reply]) {
        lock.withLock { self.replies[id.uuidString] = replies }
    }

    func requests(for id: UUID) -> [Date] {
        lock.withLock { received[id.uuidString] ?? [] }
    }

    func clear(_ id: UUID) {
        lock.withLock {
            replies[id.uuidString] = nil
            received[id.uuidString] = nil
        }
    }

    /// The last reply repeats.
    fileprivate func next(for key: String?) -> Reply? {
        guard let key else { return nil }
        return lock.withLock {
            received[key, default: []].append(Date())
            guard let reply = replies[key]?.first else { return nil }
            if (replies[key]?.count ?? 0) > 1 { replies[key]?.removeFirst() }
            return reply
        }
    }
}

private final class LiveUploadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        let stubbed = LiveUploadStub.shared.next(for: request.value(forHTTPHeaderField: "Idempotency-Key"))
        var headers = ["Content-Type": "application/json"]
        if let retryAfter = stubbed?.retryAfter { headers["Retry-After"] = retryAfter }
        guard let url = request.url, let reply = stubbed,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: reply.body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
