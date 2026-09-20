import Foundation

enum BackendRequestContext {
    case general
    case storeKitPurchase
}

enum BackendClientError: LocalizedError {
    case missingBackendURL
    case invalidResponse
    case httpError(status: Int, message: String, context: BackendRequestContext)
    case missingFile

    var errorDescription: String? {
        switch self {
        case .missingBackendURL:
            "Backend URL is not configured."
        case .invalidResponse:
            "The backend returned an unexpected response."
        case let .httpError(status, message, context):
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
        case 502, 503, 504:
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

    static func transcribe(fileURL: URL, duration: TimeInterval, token: String, requestID: UUID = UUID()) async throws -> TranscriptionResponse {
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
        body.appendMultipartFile(
            name: "file",
            filename: fileURL.lastPathComponent,
            mimeType: "audio/m4a",
            data: audioData,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        return try decode(data: data, response: response)
    }

    private static func applyUserAuth(_ token: String, to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
                context: context
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func backendMessage(from data: Data) -> String {
        if
            let payload = try? JSONDecoder().decode(BackendErrorPayload.self, from: data),
            let detail = payload.detailText,
            !detail.isEmpty
        {
            return detail
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
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
