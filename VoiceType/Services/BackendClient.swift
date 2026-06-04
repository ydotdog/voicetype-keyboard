import Foundation

enum BackendClientError: LocalizedError {
    case missingBackendURL
    case invalidResponse
    case httpError(status: Int, message: String)
    case missingFile

    var errorDescription: String? {
        switch self {
        case .missingBackendURL:
            "Backend URL is not configured."
        case .invalidResponse:
            "The backend returned an unexpected response."
        case let .httpError(status, message):
            "Backend error \(status): \(message)"
        case .missingFile:
            "The recording file could not be read."
        }
    }
}

enum BackendClient {
    private static var baseURL: URL? {
        if let string = Bundle.main.object(forInfoDictionaryKey: "VoiceTypeBackendURL") as? String {
            return URL(string: string)
        }
        return URL(string: "http://127.0.0.1:8000")
    }

    static func signInWithApple(identityToken: String, email: String?, fullName: String?) async throws -> AuthResponse {
        guard let baseURL else { throw BackendClientError.missingBackendURL }
        var request = URLRequest(url: baseURL.appending(path: "v1/auth/apple"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AppleAuthRequest(identityToken: identityToken, email: email, fullName: fullName)
        )
        return try await sendJSON(request)
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
        return try await sendJSON(request)
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

    static func transcribe(fileURL: URL, duration: TimeInterval, token: String) async throws -> TranscriptionResponse {
        guard let baseURL else { throw BackendClientError.missingBackendURL }
        guard let audioData = try? Data(contentsOf: fileURL) else { throw BackendClientError.missingFile }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: "v1/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyUserAuth(token, to: &request)

        var body = Data()
        body.appendMultipartField(name: "audio_seconds", value: String(format: "%.2f", duration), boundary: boundary)
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

    private static func sendJSON<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(data: data, response: response)
    }

    private static func decode<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BackendClientError.httpError(
                status: httpResponse.statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct AppleAuthRequest: Encodable {
    let identityToken: String
    let email: String?
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case email
        case fullName = "full_name"
    }
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
