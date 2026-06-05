import Foundation

enum SharedAccountStore {
    private static let balanceTextKey = "accountBalanceText"

    static var balanceText: String {
        get {
            UserDefaults(suiteName: AppConstants.appGroup)?.string(forKey: balanceTextKey) ?? ""
        }
        set {
            guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.removeObject(forKey: balanceTextKey)
            } else {
                defaults.set(newValue, forKey: balanceTextKey)
            }
            defaults.synchronize()
        }
    }
}

enum KeyboardAutoInsertStore {
    private static let baselineTranscriptIDKey = "keyboardAutoInsertBaselineTranscriptID"
    private static let lastInsertedTranscriptIDKey = "keyboardAutoInsertLastInsertedTranscriptID"

    static func arm(baselineTranscriptID: String) {
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
        defaults.set(baselineTranscriptID, forKey: baselineTranscriptIDKey)
        defaults.synchronize()
    }

    static func clear() {
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroup) else { return }
        defaults.removeObject(forKey: baselineTranscriptIDKey)
        defaults.synchronize()
    }

    static func shouldInsert(_ snapshot: TranscriptSnapshot) -> Bool {
        guard
            let defaults = UserDefaults(suiteName: AppConstants.appGroup),
            let baseline = defaults.string(forKey: baselineTranscriptIDKey),
            defaults.string(forKey: lastInsertedTranscriptIDKey) != snapshot.id,
            !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            snapshot.id != baseline
        else {
            return false
        }
        return true
    }

    static func claimForInsert(_ snapshot: TranscriptSnapshot) -> Bool {
        guard shouldInsert(snapshot), let defaults = UserDefaults(suiteName: AppConstants.appGroup) else {
            return false
        }
        defaults.set(snapshot.id, forKey: lastInsertedTranscriptIDKey)
        defaults.removeObject(forKey: baselineTranscriptIDKey)
        defaults.synchronize()
        return true
    }
}
