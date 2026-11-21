import Foundation
import Testing
@testable import VoiceType

// Every request goes to an in-process URLProtocol stub; nothing reaches the network.
@Suite(.serialized)
@MainActor
struct TranscriptionStreamingTests {
    // MARK: Event parser

    @Test func parserNamesEventsAndJoinsDataLines() {
        var parser = ServerSentEventParser()
        let events = parser.push(contentsOf: Data("event: delta\ndata: {\"delta\":\"Hi\"}\n\ndata: first\ndata: second\n\n".utf8))
        #expect(events == [.init(name: "delta", data: #"{"delta":"Hi"}"#), .init(name: "message", data: "first\nsecond")])
    }

    @Test func parserHandlesLineEndingsSplitAcrossChunks() {
        var parser = ServerSentEventParser()
        var events = parser.push(contentsOf: Data("event: delta\r".utf8))
        // The LF that completes a CRLF arrives in the next chunk and must not
        // read as a blank line, which would end the event and drop its name.
        events += parser.push(contentsOf: Data("\ndata: 1\r\n\r".utf8))
        events += parser.push(contentsOf: Data("\nevent: done\rdata: 2\r\r".utf8))
        #expect(events == [.init(name: "delta", data: "1"), .init(name: "done", data: "2")])
    }

    @Test func parserSkipsCommentsAndFieldsItDoesNotUse() {
        var parser = ServerSentEventParser()
        let events = parser.push(contentsOf: Data(": keepalive\n\nid: 7\nretry: 1000\nfoo: bar\n:note\ndata:no space\ndata:  two spaces\n\n".utf8))
        #expect(events == [.init(name: "message", data: "no space\n two spaces")])
    }

    @Test func parserResetsTheNameAfterEachEventAndDropsOneCutOff() {
        var parser = ServerSentEventParser()
        let events = parser.push(contentsOf: Data("event: delta\ndata: 1\n\ndata: 2\n\nevent: empty\n\ndata: 3\n\n".utf8))
        #expect(events == [.init(name: "delta", data: "1"), .init(name: "message", data: "2"), .init(name: "message", data: "3")])
        #expect(parser.push(contentsOf: Data("event: done\ndata: {}\n".utf8)).isEmpty)
    }

    @Test func parserKeepsCharactersSplitAcrossBytes() {
        var parser = ServerSentEventParser()
        let events = Array("data: 你好 👋\n\n".utf8).compactMap { parser.push($0) }
        #expect(events == [.init(name: "message", data: "你好 👋")])
    }

    // MARK: Streaming client

    @Test func streamReportsHeardTextInOrderAndReturnsTheFinalTranscript() async throws {
        let stub = try StreamStub()
        defer { stub.cleanUp() }
        StubTransport.shared.expect([.init(chunks: [
            Data(": keepalive\n\n".utf8),
            event("delta", #"{"delta":"Hello"}"#),
            event("delta", #"{"delta":" wor"}"#),
            Data("event: delta\r\ndata: {\"delta\":\"ld\"}\r\n\r\n".utf8),
            event("delta", #"{"delta":""}"#),
            event("progress", #"{"seconds":3}"#),
            event("done", doneJSON(stub.requestID, transcript: "Hello world.")),
        ])], for: stub.requestID)

        let response = try await stub.transcribe(model: "gpt-4o-mini-transcribe")
        #expect(stub.heard.updates == ["Hello", "Hello wor", "Hello world"])
        #expect(response.id == stub.requestID.uuidString)
        #expect(response.transcript == "Hello world.")
        #expect(response.charge.formatted == "12 credits")
        let requests = StubTransport.shared.requests(for: stub.requestID)
        #expect(requests.count == 1)
        let sent = try #require(requests.first)
        #expect(sent.request.url?.path == "/v1/transcriptions")
        #expect(sent.request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer stream-test-token")
        #expect(sent.body.contains("name=\"stream\"\r\n\r\ntrue\r\n"))
        #expect(sent.body.contains("name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n"))
        #expect(sent.body.contains(StreamStub.audio))
    }

    @Test func blankTextBeforeTheFirstWordIsNotReported() async throws {
        let stub = try StreamStub()
        defer { stub.cleanUp() }
        StubTransport.shared.expect([.init(chunks: [
            event("delta", #"{"delta":" "}"#),
            event("delta", #"{"delta":"\n"}"#),
            event("delta", #"{"delta":"Hi"}"#),
            event("delta", #"{"delta":" there"}"#),
            event("done", doneJSON(stub.requestID, transcript: "Hi there.")),
        ])], for: stub.requestID)
        _ = try await stub.transcribe()
        #expect(stub.heard.updates == ["Hi", "Hi there"])
    }

    @Test func serviceWithoutStreamingAnswersWithJSON() async throws {
        let stub = try StreamStub()
        defer { stub.cleanUp() }
        StubTransport.shared.expect([.init(contentType: "application/json",
                                           chunks: [Data(doneJSON(stub.requestID, transcript: "Hello world.").utf8)])],
                                    for: stub.requestID)
        let response = try await stub.transcribe()
        #expect(response.transcript == "Hello world.")
        #expect(stub.heard.updates.isEmpty)
        #expect(StubTransport.shared.requests(for: stub.requestID).count == 1)
    }

    @Test(arguments: [404, 405])
    func routeThatRefusesTheStreamFallsBackToAPlainUploadWithTheSameKey(status: Int) async throws {
        let stub = try StreamStub()
        defer { stub.cleanUp() }
        StubTransport.shared.expect([
            .init(status: status, contentType: "application/json", chunks: [Data(#"{"detail":"Not Found"}"#.utf8)]),
            .init(contentType: "application/json", chunks: [Data(doneJSON(stub.requestID, transcript: "Hello world.").utf8)]),
        ], for: stub.requestID)
        let response = try await stub.transcribe()
        #expect(response.transcript == "Hello world.")
        // The stub files requests under their Idempotency-Key.
        let requests = StubTransport.shared.requests(for: stub.requestID)
        #expect(requests.count == 2)
        #expect(requests.first?.body.contains("name=\"stream\"") == true)
        let plain = try #require(requests.last)
        #expect(plain.request.value(forHTTPHeaderField: "Accept") != "text/event-stream")
        #expect(plain.body.contains("name=\"audio_seconds\""))
        #expect(!plain.body.contains("name=\"stream\""))
    }

    @Test func modelThatCannotStreamUploadsWithoutAskingForAStream() async throws {
        let stub = try StreamStub()
        defer { stub.cleanUp() }
        StubTransport.shared.expect([.init(contentType: "application/json",
                                           chunks: [Data(doneJSON(stub.requestID, transcript: "Hello world.").utf8)])],
                                    for: stub.requestID)
        let response = try await stub.transcribe(model: "whisper-1", catalog: catalog())
        #expect(response.transcript == "Hello world.")
        let requests = StubTransport.shared.requests(for: stub.requestID)
        #expect(requests.count == 1)
        let sent = try #require(requests.first)
        #expect(sent.request.value(forHTTPHeaderField: "Accept") != "text/event-stream")
        #expect(sent.body.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        #expect(!sent.body.contains("name=\"stream\""))
    }

    @Test func catalogDecidesWhichModelsStream() {
        let catalog = catalog()
        #expect(catalog.streamsPartialText(for: nil))
        #expect(catalog.streamsPartialText(for: ""))
        #expect(catalog.streamsPartialText(for: "gpt-transcribe"))
        #expect(!catalog.streamsPartialText(for: "whisper-1"))
        // A model this catalog predates: ask, and the service decides.
        #expect(catalog.streamsPartialText(for: "gpt-next-transcribe"))
        let whisperDefault = TranscriptionModelCatalog(defaultModel: "whisper-1", defaultModelName: "Whisper",
                                                       models: catalog.models)
        #expect(!whisperDefault.streamsPartialText(for: nil))
    }

    @Test func errorEventCarriesTheStatusAndCodeTheServiceWouldHaveSent() async throws {
        let stub = try StreamStub()
        defer { stub.cleanUp() }
        StubTransport.shared.expect([.init(chunks: [
            event("delta", #"{"delta":" "}"#),
            event("error", #"{"status":422,"detail":"No speech was detected. Nothing was charged.","code":"no_speech"}"#),
        ])], for: stub.requestID)
        let error = await #expect(throws: BackendClientError.self) { try await stub.transcribe() }
        #expect(stub.heard.updates.isEmpty)
        #expect(error?.isNoSpeech == true)
        guard case let .httpError(status, message, _, _) = error else { return }
        #expect(status == 422)
        #expect(message == "No speech was detected. Nothing was charged.")
    }

    @Test func failureAfterHeardTextIsReportedWithoutATranscript() async throws {
        let stub = try StreamStub()
        defer { stub.cleanUp() }
        StubTransport.shared.expect([.init(chunks: [
            event("delta", #"{"delta":"Hel"}"#),
            event("error", #"{"detail":"Transcription failed. Try again."}"#),
        ])], for: stub.requestID)
        let error = await #expect(throws: BackendClientError.self) { try await stub.transcribe() }
        #expect(stub.heard.updates == ["Hel"])
        #expect(error?.isNoSpeech == false)
        guard case let .httpError(status, message, _, code) = error else { return }
        #expect(status == 500)
        #expect(message == "Transcription failed. Try again.")
        #expect(code == nil)
    }

    @Test func streamThatEndsWithoutAResultIsAnInvalidResponse() async throws {
        let stub = try StreamStub()
        defer { stub.cleanUp() }
        // A proxy that cuts the body cleanly, mid-event.
        StubTransport.shared.expect([.init(chunks: [
            event("delta", #"{"delta":"Hel"}"#),
            Data("event: done\ndata: {\"id\":".utf8),
        ])], for: stub.requestID)
        let error = await #expect(throws: BackendClientError.self) { try await stub.transcribe() }
        #expect(stub.heard.updates == ["Hel"])
        guard case .invalidResponse = error else {
            Issue.record("Expected invalidResponse, got \(String(describing: error))")
            return
        }
    }

    @Test func connectionLostMidStreamThrowsTheNetworkError() async throws {
        let stub = try StreamStub()
        defer { stub.cleanUp() }
        StubTransport.shared.expect([.init(chunks: [event("delta", #"{"delta":"Hel"}"#)],
                                           failure: URLError(.networkConnectionLost))], for: stub.requestID)
        let error = await #expect(throws: URLError.self) { try await stub.transcribe() }
        #expect(error?.code == .networkConnectionLost)
        #expect(stub.heard.updates == ["Hel"])
    }

    @Test func errorBeforeTheStreamStartsIsAnOrdinaryHTTPError() async throws {
        let stub = try StreamStub()
        defer { stub.cleanUp() }
        StubTransport.shared.expect([.init(status: 402, contentType: "application/json",
                                           chunks: [Data(#"{"detail":"Not enough credit."}"#.utf8)])], for: stub.requestID)
        let error = await #expect(throws: BackendClientError.self) { try await stub.transcribe() }
        guard case let .httpError(status, message, _, code) = error else { return }
        #expect(status == 402)
        #expect(message == "Not enough credit.")
        #expect(code == nil)
        #expect(StubTransport.shared.requests(for: stub.requestID).count == 1)
    }

    // MARK: Keyboard preview store

    @Test func heardTextIsReadOnlyByItsKeyboardSession() throws {
        PartialTranscriptStore.clear()
        defer { PartialTranscriptStore.clear() }
        #expect(PartialTranscriptStore.latest(for: "session-a") == nil)
        PartialTranscriptStore.publish("Hello wor", sessionID: "session-a")
        #expect(PartialTranscriptStore.latest(for: "session-a") == PartialTranscript(sessionID: "session-a", text: "Hello wor"))
        #expect(PartialTranscriptStore.latest(for: "session-b") == nil)
        #expect(PartialTranscriptStore.latest(for: "") == nil)
        PartialTranscriptStore.publish("Ignored", sessionID: "")
        #expect(PartialTranscriptStore.latest(for: "session-a")?.text == "Hello wor")
        PartialTranscriptStore.publish("Hello world", sessionID: "session-a")
        #expect(PartialTranscriptStore.latest(for: "session-a")?.text == "Hello world")
        PartialTranscriptStore.publish(" \n", sessionID: "session-a")
        #expect(PartialTranscriptStore.latest(for: "session-a") == nil)
        PartialTranscriptStore.publish("Hello again", sessionID: "session-a")
        PartialTranscriptStore.clear()
        #expect(PartialTranscriptStore.latest(for: "session-a") == nil)

        // iOS may purge Caches while a clip is transcribing.
        let directory = try #require(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup))
            .appendingPathComponent("Library/Caches/PartialTranscript", isDirectory: true)
        try FileManager.default.removeItem(at: directory)
        PartialTranscriptStore.publish("After a purge", sessionID: "session-a")
        #expect(PartialTranscriptStore.latest(for: "session-a")?.text == "After a purge")
    }

    // MARK: Helpers

    private func event(_ name: String, _ json: String) -> Data {
        Data("event: \(name)\ndata: \(json)\n\n".utf8)
    }

    private func doneJSON(_ id: UUID, transcript: String) -> String {
        """
        {"id":"\(id.uuidString)","transcript":"\(transcript)","model":"gpt-4o-mini-transcribe",\
        "charge":{"cost_usd_micros":1200,"cost_credit_units":12,"formatted":"12 credits","pricing_basis":"audio_minutes"},\
        "balance":{"balance_usd_micros":98800,"balance_credit_units":988,"formatted":"988 credits"}}
        """
    }

    private func catalog() -> TranscriptionModelCatalog {
        func option(_ id: String, streaming: Bool) -> TranscriptionModelOption {
            TranscriptionModelOption(id: id, name: id, recommended: false, streaming: streaming, retiresOn: nil,
                                     pricingBasis: "audio_minutes", creditUnitsPerMinute: 60, formattedPerMinute: "60 credits")
        }
        return TranscriptionModelCatalog(defaultModel: "gpt-transcribe", defaultModelName: "GPT Transcribe",
                                         models: [option("gpt-transcribe", streaming: true), option("whisper-1", streaming: false)])
    }
}

/// One request's audio file, URL session and heard text.
@MainActor
private final class StreamStub {
    static let audio = "inert streaming test audio"
    let requestID = UUID()
    let file: URL
    let session: URLSession
    let heard = HeardText()

    init() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("stream-test-\(requestID.uuidString).m4a")
        try Data(Self.audio.utf8).write(to: file)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func transcribe(model: String? = nil, catalog: TranscriptionModelCatalog? = nil) async throws -> TranscriptionResponse {
        let heard = heard
        return try await BackendClient.transcribeStreaming(
            fileURL: file, duration: 3.5, token: "stream-test-token", requestID: requestID,
            context: DictationContext(languages: ["en"], model: model), catalog: catalog, session: session
        ) { heard.updates.append($0) }
    }

    func cleanUp() {
        session.invalidateAndCancel()
        StubTransport.shared.forget(requestID)
        try? FileManager.default.removeItem(at: file)
    }
}

@MainActor
private final class HeardText {
    var updates: [String] = []
}

/// Canned replies, in order, for each Idempotency-Key. URLSession runs the
/// protocol on its own threads, so access is locked.
private final class StubTransport: @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var contentType = "text/event-stream; charset=utf-8"
        var chunks: [Data] = []
        var failure: URLError?
    }

    struct Received: Sendable {
        let request: URLRequest
        let body: String
    }

    static let shared = StubTransport()
    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var received: [String: [Received]] = [:]

    func expect(_ replies: [Reply], for requestID: UUID) {
        lock.withLock { self.replies[requestID.uuidString] = replies }
    }

    func requests(for requestID: UUID) -> [Received] {
        lock.withLock { received[requestID.uuidString] ?? [] }
    }

    func forget(_ requestID: UUID) {
        lock.withLock {
            replies[requestID.uuidString] = nil
            received[requestID.uuidString] = nil
        }
    }

    func reply(to request: URLRequest, body: Data) -> Reply? {
        let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
        return lock.withLock {
            received[key, default: []].append(Received(request: request, body: String(decoding: body, as: UTF8.self)))
            guard let next = replies[key]?.first else { return nil }
            replies[key]?.removeFirst()
            return next
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        guard let url = request.url,
              let reply = StubTransport.shared.reply(to: request, body: Self.body(of: request)),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": reply.contentType]) else {
            client.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client.urlProtocol(self, didLoad: chunk) }
        if let failure = reply.failure {
            // A connection drops after the bytes before it were read. A failure
            // sent with them can overtake them on the way to the reader.
            nonisolated(unsafe) let loading = self
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                loading.client?.urlProtocol(loading, didFailWithError: failure)
            }
        } else {
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
