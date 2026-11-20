import Foundation

enum BackendRequestContext {
    case general
    case storeKitPurchase
}

enum BackendClientError: LocalizedError {
    case missingBackendURL
    case invalidResponse
    /// `code` is the backend's machine-readable reason, when it sends one.
    case httpError(status: Int, message: String, context: BackendRequestContext, code: String? = nil)
    case missingFile

    /// The clip was silent. Retrying cannot help and would pay the provider
    /// again, so the app discards the clip instead of saving it for retry.
    var isNoSpeech: Bool {
        if case let .httpError(_, _, _, code) = self { return code == "no_speech" }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .missingBackendURL:
            "Backend URL is not configured."
        case .invalidResponse:
            "The backend returned an unexpected response."
        case let .httpError(status, message, context, _):
            Self.userMessage(status: status, message: message, context: context)
        case .missingFile:
            "The recording file could not be read."
        }
    }

    private static func userMessage(status: Int, message: String, context: BackendRequestContext) -> String {
        switch status {
        case 400:
            return message.isEmpty ? "The request could not be completed." : message
        case 401:
            if context == .storeKitPurchase {
                return "Your purchase is awaiting verification. Check that you are signed in to the account used to buy it, then tap Check purchases. You do not need to buy it again."
            }
            return "Your session expired. Sign in again."
        case 402:
            return "Add credit before transcribing. Your credit never expires."
        case 409:
            return message.isEmpty ? "This request conflicts with an earlier request. Please try again." : message
        case 413:
            return "That recording is too large. Try a shorter clip."
        case 429:
            return "The transcription service is busy. Try again in a moment."
        case 500:
            return "VoiceType couldn't complete this request. Please try again."
        case 502...599:
            return "The service is temporarily unavailable. Please try again in a moment."
        default:
            return message.isEmpty ? "Backend error \(status)." : message
        }
    }
}

enum BackendClient {
    private static var baseURL: URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "VoiceTypeBackendURL") as? String,
              let url = URL(string: string),
              url.host != nil else { return nil }
        #if DEBUG
        guard url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")) else { return nil }
        #else
        guard url.scheme == "https" else { return nil }
        #endif
        return url
    }

    static func signInWithApple(
        identityToken: String,
        authorizationCode: String?,
        email: String?,
        fullName: String?
    ) async throws -> AuthResponse {
        guard let baseURL else { throw BackendClientError.missingBackendURL }
        var request = URLRequest(url: baseURL.appending(path: "v1/auth/apple"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AppleAuthRequest(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                email: email,
                fullName: fullName
            )
        )
        return try await sendJSON(request)
    }

    static func deleteAccount(token: String) async throws {
        guard let baseURL else { throw BackendClientError.missingBackendURL }
        var request = URLRequest(url: baseURL.appending(path: "v1/account"))
        request.httpMethod = "DELETE"
        applyUserAuth(token, to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let _: DeleteAccountResponse = try decode(data: data, response: response)
    }

    static func me(token: String) async throws -> MeResponse {
        guard let baseURL else { throw BackendClientError.missingBackendURL }
        var request = URLRequest(url: baseURL.appending(path: "v1/me"))
        applyUserAuth(token, to: &request)
        return try await sendJSON(request)
    }

    static func products() async throws -> ProductCatalogResponse {
        guard let baseURL else { throw BackendClientError.missingBackendURL }
        let request = URLRequest(url: baseURL.appending(path: "v1/billing/products"))
        return try await sendJSON(request)
    }

    static func transcriptionModels() async throws -> TranscriptionModelCatalog {
        guard let baseURL else { throw BackendClientError.missingBackendURL }
        return try await sendJSON(URLRequest(url: baseURL.appending(path: "v1/transcription/models")))
    }

    static func submitStoreKitTransaction(jws: String, token: String) async throws -> PurchaseCreditResponse {
        guard let baseURL else { throw BackendClientError.missingBackendURL }
        var request = URLRequest(url: baseURL.appending(path: "v1/billing/storekit/transactions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyUserAuth(token, to: &request)
        request.httpBody = try JSONEncoder().encode(StoreKitTransactionRequest(signedTransaction: jws))
        return try await sendJSON(request, context: .storeKitPurchase)
    }

    #if DEBUG
    static func grantDevCredit(amountUSDMicros: Int, token: String, key: String) async throws -> PurchaseCreditResponse {
        guard let baseURL else { throw BackendClientError.missingBackendURL }
        var request = URLRequest(url: baseURL.appending(path: "v1/billing/dev-credit"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-VoiceType-Dev-Credit-Key")
        applyUserAuth(token, to: &request)
        request.httpBody = try JSONEncoder().encode(DevCreditRequest(amountUSDMicros: amountUSDMicros))
        return try await sendJSON(request)
    }
    #endif

    /// `patience` is how long to keep asking while the service finishes an
    /// earlier attempt with the same `requestID`, such as a live session the
    /// app stopped waiting for. It then returns that attempt's transcript.
    static func transcribe(
        fileURL: URL, duration: TimeInterval, token: String, requestID: UUID = UUID(),
        context: DictationContext = .empty, patience: TimeInterval = 0, session: URLSession = .shared
    ) async throws -> TranscriptionResponse {
        try await waitingForEarlierAttempt(patience) {
            try await upload(fileURL: fileURL, duration: duration, token: token, requestID: requestID,
                             context: context, session: session)
        }
    }

    private static func upload(
        fileURL: URL, duration: TimeInterval, token: String, requestID: UUID,
        context: DictationContext, session: URLSession
    ) async throws -> TranscriptionResponse {
        let (request, body) = try transcriptionRequest(
            fileURL: fileURL, duration: duration, token: token, requestID: requestID, context: context, stream: false
        )
        let (data, response) = try await session.upload(for: request, from: body)
        if let pending = earlierAttemptPending(data: data, response: response) { throw pending }
        return try decode(data: data, response: response)
    }

    /// Calls `onPartial` with the text heard so far while the service is still
    /// transcribing. Partial text is raw provider output; only the returned
    /// response is normalized, charged and saved.
    ///
    /// A connection lost mid-stream throws like any failed upload. The service
    /// still finishes and charges once, and a retry with the same `requestID`
    /// returns that saved transcript.
    static func transcribeStreaming(
        fileURL: URL, duration: TimeInterval, token: String, requestID: UUID = UUID(),
        context: DictationContext = .empty, catalog: TranscriptionModelCatalog? = nil,
        patience: TimeInterval = 0, session: URLSession = .shared,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> TranscriptionResponse {
        try await waitingForEarlierAttempt(patience) {
            try await stream(fileURL: fileURL, duration: duration, token: token, requestID: requestID,
                             context: context, catalog: catalog, session: session, onPartial: onPartial)
        }
    }

    private static func stream(
        fileURL: URL, duration: TimeInterval, token: String, requestID: UUID,
        context: DictationContext, catalog: TranscriptionModelCatalog?, session: URLSession,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> TranscriptionResponse {
        if let catalog, !catalog.streamsPartialText(for: context.model) {
            return try await upload(fileURL: fileURL, duration: duration, token: token,
                                    requestID: requestID, context: context, session: session)
        }
        let (uploadRequest, body) = try transcriptionRequest(
            fileURL: fileURL, duration: duration, token: token, requestID: requestID, context: context, stream: true
        )
        var request = uploadRequest
        request.httpBody = body
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw BackendClientError.invalidResponse }
        if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
            // Something in front of the service turned the streaming request
            // away before transcription, so the same key is still unused.
            bytes.task.cancel()
            return try await upload(fileURL: fileURL, duration: duration, token: token,
                                    requestID: requestID, context: context, session: session)
        }
        guard (200..<300).contains(httpResponse.statusCode), httpResponse.mimeType == "text/event-stream" else {
            // Errors raised before the first event, and a service that
            // predates streaming and answers with JSON.
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            if let pending = earlierAttemptPending(data: data, response: httpResponse) { throw pending }
            return try decode(data: data, response: httpResponse)
        }

        var parser = ServerSentEventParser()
        var partial = ""
        for try await byte in bytes {
            guard let event = parser.push(byte) else { continue }
            let data = Data(event.data.utf8)
            switch event.name {
            case "delta":
                guard let delta = try? JSONDecoder().decode(TranscriptDelta.self, from: data).delta,
                      !delta.isEmpty else { continue }
                partial += delta
                // A silent clip can stream blank text. The final transcript is
                // trimmed, so the preview starts at the first word too.
                let heard = partial.drop(while: \.isWhitespace)
                guard !heard.isEmpty else { continue }
                await onPartial(String(heard))
            case "done":
                bytes.task.cancel()
                return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            case "error":
                bytes.task.cancel()
                throw BackendClientError.httpError(
                    status: (try? JSONDecoder().decode(StreamFailureStatus.self, from: data))?.status ?? 500,
                    message: backendMessage(from: data),
                    context: .general,
                    code: backendErrorCode(from: data)
                )
            default:
                // Events a newer service adds.
                continue
            }
        }
        throw BackendClientError.invalidResponse
    }

    private static func transcriptionRequest(
        fileURL: URL, duration: TimeInterval, token: String, requestID: UUID,
        context: DictationContext, stream: Bool
    ) throws -> (URLRequest, Data) {
        guard let baseURL else { throw BackendClientError.missingBackendURL }
        guard let audioData = try? Data(contentsOf: fileURL) else { throw BackendClientError.missingFile }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: "v1/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = min(max(duration + 90, 120), 600)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID.uuidString, forHTTPHeaderField: "Idempotency-Key")
        applyUserAuth(token, to: &request)

        var body = Data()
        body.appendMultipartField(name: "audio_seconds", value: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), duration), boundary: boundary)
        if !context.languages.isEmpty {
            body.appendMultipartField(name: "preferred_languages", value: String(decoding: try JSONEncoder().encode(context.languages), as: UTF8.self), boundary: boundary)
        }
        if !context.vocabulary.isEmpty {
            body.appendMultipartField(name: "vocabulary", value: String(decoding: try JSONEncoder().encode(context.vocabulary), as: UTF8.self), boundary: boundary)
        }
        if let model = context.model, !model.isEmpty {
            body.appendMultipartField(name: "model", value: model, boundary: boundary)
        }
        if stream {
            body.appendMultipartField(name: "stream", value: "true", boundary: boundary)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        body.appendMultipartFile(
            name: "file",
            filename: fileURL.lastPathComponent,
            mimeType: "audio/m4a",
            data: audioData,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")
        return (request, body)
    }

    /// Opens a live transcription session for one recording. `requestID` is
    /// the key its upload uses if the session can't finish.
    static func liveTranscriptionRequest(token: String, requestID: UUID) throws -> URLRequest {
        guard let baseURL, var components = URLComponents(url: baseURL.appending(path: "v1/realtime/transcriptions"),
                                                          resolvingAgainstBaseURL: false) else {
            throw BackendClientError.missingBackendURL
        }
        // baseURL only allows plain http for a server on this Mac.
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else { throw BackendClientError.missingBackendURL }
        var request = URLRequest(url: url)
        request.setValue(requestID.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(LiveTranscriptionProtocol.name, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        // Live audio is about 3 MB a minute; Low Data Mode uploads the
        // recording instead.
        request.allowsConstrainedNetworkAccess = false
        applyUserAuth(token, to: &request)
        return request
    }

    private static func applyUserAuth(_ token: String, to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// The service answers 409 with Retry-After while an earlier attempt with
    /// the same request key is still being transcribed.
    private struct EarlierAttemptPending: Error {
        let retryAfter: TimeInterval
        let error: BackendClientError
    }

    private static func earlierAttemptPending(data: Data, response: URLResponse) -> EarlierAttemptPending? {
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 409,
              let header = httpResponse.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0
        else { return nil }
        return EarlierAttemptPending(retryAfter: seconds, error: .httpError(
            status: 409, message: backendMessage(from: data), context: .general, code: backendErrorCode(from: data)))
    }

    /// Asks again after 1, 2, 4 then every 5 seconds, within the service's
    /// Retry-After, until `patience` runs out.
    private static func waitingForEarlierAttempt<T>(
        _ patience: TimeInterval, _ attempt: () async throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(max(0, patience))
        var delay: Duration = .seconds(1)
        while true {
            do {
                return try await attempt()
            } catch let pending as EarlierAttemptPending {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { throw pending.error }
                try await clock.sleep(for: min(delay, .seconds(max(1, pending.retryAfter)), remaining))
                delay = min(delay * 2, .seconds(5))
            }
        }
    }

    private static func sendJSON<T: Decodable>(
        _ request: URLRequest,
        context: BackendRequestContext = .general
    ) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(data: data, response: response, context: context)
    }

    private static func decode<T: Decodable>(
        data: Data,
        response: URLResponse,
        context: BackendRequestContext = .general
    ) throws -> T {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BackendClientError.httpError(
                status: httpResponse.statusCode,
                message: backendMessage(from: data),
                context: context,
                code: backendErrorCode(from: data)
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The backend always explains errors in a JSON `detail`. Any other body
    /// comes from a proxy or CDN, often an HTML page, and is never shown.
    static func backendMessage(from data: Data) -> String {
        (try? JSONDecoder().decode(BackendErrorPayload.self, from: data))?.detailText ?? ""
    }

    /// Some errors also carry a `code` the app acts on, such as `no_speech`.
    /// Older backends send none, and the app then keeps the clip for retry.
    static func backendErrorCode(from data: Data) -> String? {
        (try? JSONDecoder().decode(BackendErrorCode.self, from: data))?.code
    }
}

extension TranscriptionModelCatalog {
    /// Whether the service sends partial text for this model. `nil` means the
    /// service default. An unlisted model streams if the service supports it.
    func streamsPartialText(for model: String?) -> Bool {
        let id = model.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        return models.first { $0.id == id }?.streaming ?? true
    }
}

/// Splits a `text/event-stream` body into events, fed one byte at a time.
/// Lines end in CR, LF or CRLF, even when CR and LF arrive apart; a line that
/// starts with `:` is a comment; several `data` lines join with newlines; a
/// blank line ends the event. An event cut off by the end of the stream is
/// never returned.
struct ServerSentEventParser {
    struct Event: Equatable {
        /// `message` when the event names none.
        let name: String
        let data: String
    }

    private var line: [UInt8] = []
    private var lineEndedWithCR = false
    private var name = ""
    private var data = ""

    /// Returns the event this byte completes, if any.
    mutating func push(_ byte: UInt8) -> Event? {
        if lineEndedWithCR {
            lineEndedWithCR = false
            if byte == UInt8(ascii: "\n") { return nil }
        }
        switch byte {
        case UInt8(ascii: "\r"):
            lineEndedWithCR = true
            return endLine()
        case UInt8(ascii: "\n"):
            return endLine()
        default:
            line.append(byte)
            return nil
        }
    }

    mutating func push(contentsOf bytes: some Sequence<UInt8>) -> [Event] {
        bytes.compactMap { push($0) }
    }

    private mutating func endLine() -> Event? {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else { return dispatch() }
        guard line.first != UInt8(ascii: ":") else { return nil }
        // Split on the byte, so a combining mark after the colon stays in the value.
        let colon = line.firstIndex(of: UInt8(ascii: ":"))
        let field = line[..<(colon ?? line.endIndex)]
        var value = colon.map { line[($0 + 1)...] } ?? []
        if value.first == UInt8(ascii: " ") { value = value.dropFirst() }
        if field.elementsEqual("event".utf8) {
            name = String(decoding: value, as: UTF8.self)
        } else if field.elementsEqual("data".utf8) {
            data += String(decoding: value, as: UTF8.self) + "\n"
        }
        // `id`, `retry` and unknown fields don't apply to a one-shot request.
        return nil
    }

    private mutating func dispatch() -> Event? {
        defer {
            name = ""
            data = ""
        }
        guard !data.isEmpty else { return nil }
        return Event(name: name.isEmpty ? "message" : name, data: String(data.dropLast()))
    }
}

private struct TranscriptDelta: Decodable {
    let delta: String
}

/// The HTTP status the service would have sent, had the stream not started.
private struct StreamFailureStatus: Decodable {
    let status: Int?
}

/// Decoded apart from `detail`, so an unexpected `code` never hides the message.
private struct BackendErrorCode: Decodable {
    let code: String?
}

private struct BackendErrorPayload: Decodable {
    let detail: Detail

    var detailText: String? {
        switch detail {
        case let .string(value):
            return value
        case let .list(values):
            return values.compactMap(\.message).joined(separator: "\n")
        case .object:
            return nil
        }
    }

    enum Detail: Decodable {
        case string(String)
        case list([BackendValidationError])
        case object

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([BackendValidationError].self) {
                self = .list(value)
            } else {
                self = .object
            }
        }
    }
}

private struct BackendValidationError: Decodable {
    let message: String?

    enum CodingKeys: String, CodingKey {
        case message = "msg"
    }
}

private struct AppleAuthRequest: Encodable {
    let identityToken: String
    let authorizationCode: String?
    let email: String?
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
        case email
        case fullName = "full_name"
    }
}

private struct DeleteAccountResponse: Decodable {
    let ok: Bool
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}
