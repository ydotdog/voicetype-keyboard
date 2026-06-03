import Foundation

enum AppConstants {
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "VoiceTypeAppGroup") as? String ?? "group.com.kyleqi.voicetype"
    static let appURLScheme = "voicetype"
}

enum ProductIDs {
    static let small = "com.kyleqi.voicetype.credits.small"
    static let medium = "com.kyleqi.voicetype.credits.medium"
    static let large = "com.kyleqi.voicetype.credits.large"

    static let all = [small, medium, large]
}
