import Foundation
import NaturalLanguage

/// Language tags describe output intent; Chinese script is deliberately explicit.
enum DictationLanguage: String, Codable, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case english = "en", japanese = "ja", korean = "ko", spanish = "es"
    case french = "fr", german = "de", portuguese = "pt", italian = "it"
    case russian = "ru", arabic = "ar", hindi = "hi", indonesian = "id"
    case vietnamese = "vi", thai = "th", turkish = "tr", dutch = "nl"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .portuguese: "Português"
        case .italian: "Italiano"
        case .russian: "Русский"
        case .arabic: "العربية"
        case .hindi: "हिन्दी"
        case .indonesian: "Bahasa Indonesia"
        case .vietnamese: "Tiếng Việt"
        case .thai: "ไทย"
        case .turkish: "Türkçe"
        case .dutch: "Nederlands"
        }
    }
    var isChinese: Bool { self == .simplifiedChinese || self == .traditionalChinese }
}

struct DictationContext: Codable, Equatable {
    var languages: [String] = []
    var vocabulary: [String] = []
    static let empty = DictationContext()
}

struct PersonalVocabularyWord: Codable, Identifiable, Equatable {
    var id: String { text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    let text: String
    let learned: Bool
}

struct DictationPreferences: Codable, Equatable {
    var languages: [DictationLanguage] = []
    var learnFromCorrections = true
    var words: [PersonalVocabularyWord] = []

    var languageSummary: String {
        languages.isEmpty ? "Auto-detect" : languages.map(\.label).joined(separator: " · ")
    }

    mutating func toggle(_ language: DictationLanguage) {
        if languages.contains(language) { languages.removeAll { $0 == language }; return }
        if language.isChinese { languages.removeAll { $0.isChinese } }
        guard languages.count < 3 else { return }
        languages.append(language)
    }

    @discardableResult
    mutating func remember(_ raw: String, learned: Bool = false) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(text.count), !text.contains(where: { $0.isNewline }),
              text.unicodeScalars.contains(where: CharacterSet.letters.contains),
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !text.contains("<"), !text.contains(">") else { return false }
        let word = PersonalVocabularyWord(text: text, learned: learned)
        let prior = words.first { $0.id == word.id }
        guard prior != nil || words.count < 200 else { return false }
        words.removeAll { $0.id == word.id }
        words.insert(PersonalVocabularyWord(text: text, learned: prior?.learned == false ? false : learned), at: 0)
        return true
    }

    var context: DictationContext {
        // Bound request size and keep the most recently taught terms first.
        var remaining = 1500
        let hints = words.prefix(50).compactMap { word -> String? in
            guard word.text.count <= remaining else { return nil }
            remaining -= word.text.count
            return word.text
        }
        return DictationContext(languages: languages.map(\.rawValue), vocabulary: hints)
    }

    /// Learn only a small edit explicitly saved by the user, never raw AI output.
    /// Expand Latin edits to full words; Chinese edits use the changed phrase.
    static func correctedTerm(original: String, edited: String) -> String? {
        let old = Array(original), new = Array(edited)
        guard old != new, !old.isEmpty, !new.isEmpty else { return nil }
        var start = 0
        while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
        var oldEnd = old.count, end = new.count
        while oldEnd > start, end > start, old[oldEnd - 1] == new[end - 1] { oldEnd -= 1; end -= 1 }
        guard end > start, end - start <= 40, oldEnd - start <= 40 else { return nil }
        let changedStart = edited.index(edited.startIndex, offsetBy: start)
        let changedEnd = edited.index(edited.startIndex, offsetBy: end)
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = edited
        var namedTerm: String?
        tagger.enumerateTags(in: edited.startIndex..<edited.endIndex, unit: .word, scheme: .nameType,
                             options: [.joinNames, .omitWhitespace, .omitPunctuation]) { tag, range in
            guard range.overlaps(changedStart..<changedEnd),
                  tag == .personalName || tag == .placeName || tag == .organizationName else { return true }
            let candidate = String(edited[range])
            if (2...40).contains(candidate.count) { namedTerm = candidate }
            return false
        }
        if let namedTerm { return namedTerm }
        func isLatinWord(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { $0.value < 0x0250 && (CharacterSet.letters.contains($0) || $0 == "'" || $0 == "-") }
        }
        if start < new.count, isLatinWord(new[start]) {
            while start > 0, isLatinWord(new[start - 1]) { start -= 1 }
        }
        if end > 0, isLatinWord(new[end - 1]) {
            while end < new.count, isLatinWord(new[end]) { end += 1 }
        }
        let term = String(new[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard (2...40).contains(term.count), !term.contains(where: { $0.isNewline }),
              term.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
        return term
    }
}

@MainActor
enum DictationPreferencesStore {
    private static func key(_ userID: String) -> String { "dictationPreferences.v1.\(userID)" }
    static func load(userID: String, defaults: UserDefaults = .standard) -> DictationPreferences {
        guard !userID.isEmpty, let data = defaults.data(forKey: key(userID)),
              let preferences = try? JSONDecoder().decode(DictationPreferences.self, from: data) else { return DictationPreferences() }
        return preferences
    }
    static func save(_ preferences: DictationPreferences, userID: String, defaults: UserDefaults = .standard) {
        guard !userID.isEmpty, let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key(userID))
    }
    static func clear(userID: String, defaults: UserDefaults = .standard) {
        guard !userID.isEmpty else { return }
        defaults.removeObject(forKey: key(userID))
    }
}
