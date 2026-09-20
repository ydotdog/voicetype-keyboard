import Foundation

/// Short-lived, single-use capabilities for the keyboard's native app Link.
/// Merely opening the public URL scheme never grants microphone activation.
struct KeyboardMicActivationStore: Sendable {
    static let lifetime: TimeInterval = 90
    static let shared = KeyboardMicActivationStore(directoryURL: FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: AppConstants.appGroup
    )?.appendingPathComponent("Library/Caches/KeyboardMicActivation", isDirectory: true))

    let directoryURL: URL?

    private struct Request: Codable {
        let issuedAt: Date
        let issuedUptime: TimeInterval

        func isValid(at now: Date, uptime: TimeInterval) -> Bool {
            let elapsed = uptime - issuedUptime
            let wallElapsed = now.timeIntervalSince(issuedAt)
            return issuedUptime.isFinite && uptime.isFinite
                && elapsed >= 0 && elapsed < KeyboardMicActivationStore.lifetime
                && wallElapsed >= -5 && wallElapsed < KeyboardMicActivationStore.lifetime
        }
    }

    func makeURL(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> URL? {
        guard let directoryURL, uptime.isFinite, uptime >= 0 else { return nil }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            removeExpiredRequests(now: now, uptime: uptime)
            let token = UUID().uuidString
            let data = try JSONEncoder().encode(Request(issuedAt: now, issuedUptime: uptime))
            #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            let options: Data.WritingOptions = .atomic
            #endif
            try data.write(to: requestURL(token: token, directory: directoryURL), options: options)
            var components = URLComponents()
            components.scheme = AppConstants.appURLScheme
            components.host = "keyboard"
            components.queryItems = [URLQueryItem(name: "activation", value: token)]
            return components.url
        } catch { return nil }
    }

    func consume(_ url: URL, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let directoryURL, let token = token(in: url) else { return false }
        let source = requestURL(token: token, directory: directoryURL)
        let claimed = directoryURL.appendingPathComponent("claimed-\(UUID().uuidString).json")
        do {
            // Renaming within one directory claims the file atomically across
            // processes. Only one receiver can consume a repeated URL.
            try FileManager.default.moveItem(at: source, to: claimed)
            defer { try? FileManager.default.removeItem(at: claimed) }
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: claimed))
            return request.isValid(at: now, uptime: uptime)
        } catch { return false }
    }

    func revoke(_ url: URL) {
        guard let directoryURL, let token = token(in: url) else { return }
        try? FileManager.default.removeItem(at: requestURL(token: token, directory: directoryURL))
    }

    private func token(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == AppConstants.appURLScheme,
              components.host == "keyboard", components.path.isEmpty,
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, let items = components.queryItems, items.count == 1,
              items[0].name == "activation", let value = items[0].value,
              let id = UUID(uuidString: value), value == id.uuidString
        else { return nil }
        return value
    }

    private func requestURL(token: String, directory: URL) -> URL {
        directory.appendingPathComponent("request-\(token).json")
    }

    private func removeExpiredRequests(now: Date, uptime: TimeInterval) {
        guard let directoryURL,
              let files = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.lastPathComponent.hasPrefix("request-") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let request = try? JSONDecoder().decode(Request.self, from: data) else { continue }
            if !request.isValid(at: now, uptime: uptime) { try? FileManager.default.removeItem(at: file) }
        }
    }
}
