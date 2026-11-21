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

/// How a recording becomes text. The keyboard follows the same choice.
enum TranscriptionMode: String, Codable, CaseIterable, Identifiable {
    /// Uploads the recording when it stops; the text arrives all at once.
    case afterRecording = "after_recording"
    /// Uploads the recording when it stops; the text appears as it is transcribed.
    case streaming
    /// Sends the audio while the user speaks; the text appears as they speak.
    /// Recordings are uploaded instead when live transcription can't be used.
    case live
    var id: String { rawValue }
}

struct DictationContext: Codable, Equatable {
    var languages: [String] = []
    var vocabulary: [String] = []
    /// The model chosen when the recording was made, so a retry is
    /// transcribed and billed the same way. `nil` uses the service default.
    var model: String?
    static let empty = DictationContext()
}

struct PersonalVocabularyWord: Codable, Identifiable, Equatable {
    var id: String { DictationPreferences.key(text) }
    let text: String
    let learned: Bool
    /// Misheard spellings replaced with `text` in new transcripts, newest
    /// first. They stay on this device and are never sent as hints.
    var heardAs: [String] = []
}

extension PersonalVocabularyWord {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        learned = (try? values.decodeIfPresent(Bool.self, forKey: .learned)) ?? false
        heardAs = (try? values.decodeIfPresent([String].self, forKey: .heardAs)) ?? []
    }
}

struct DictationPreferences: Codable, Equatable {
    static let maximumWords = 200
    static let maximumVariants = 5

    var languages: [DictationLanguage] = []
    var learnFromCorrections = true
    var words: [PersonalVocabularyWord] = []
    /// A model from the service catalog; `nil` follows the service default.
    /// Recordings that are uploaded use it, including a live recording the
    /// service couldn't take.
    var model: String?
    var mode: TranscriptionMode = .streaming
    /// A live model from the service catalog; `nil` follows the service default.
    var liveModel: String?

    var languageSummary: String {
        languages.isEmpty ? "Auto-detect" : languages.map(\.label).joined(separator: " · ")
    }

    mutating func toggle(_ language: DictationLanguage) {
        if languages.contains(language) { languages.removeAll { $0 == language }; return }
        if language.isChinese { languages.removeAll { $0.isChinese } }
        guard languages.count < 3 else { return }
        languages.append(language)
    }

    /// Saves a spelling and, optionally, a misheard form it should replace.
    /// A spelling saved as its own word is never rewritten into another, and
    /// the newest correction owns a misheard form.
    @discardableResult
    mutating func remember(_ raw: String, learned: Bool = false, heardAs rawHeard: String? = nil) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEntry(text) else { return false }
        let id = Self.key(text)
        let prior = words.first { $0.id == id }
        guard prior != nil || words.count < Self.maximumWords else { return false }
        let heard = rawHeard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heardID = Self.key(heard)
        let teachesVariant = Self.isValidVariant(heard, of: text)
            && !words.contains { $0.id == heardID && $0.id != id }
        var heardAs = prior?.heardAs ?? []
        if teachesVariant {
            heardAs.removeAll { Self.key($0) == heardID }
            heardAs.insert(heard, at: 0)
        }
        heardAs.removeAll { $0 == text }
        for index in words.indices where words[index].id != id {
            words[index].heardAs.removeAll { Self.key($0) == id || (teachesVariant && Self.key($0) == heardID) }
        }
        words.removeAll { $0.id == id }
        words.insert(PersonalVocabularyWord(text: text, learned: prior?.learned == false ? false : learned,
                                            heardAs: Array(heardAs.prefix(Self.maximumVariants))), at: 0)
        return true
    }

    /// Adds a misheard form to a saved word; false when it can't be used.
    @discardableResult
    mutating func teach(_ rawHeard: String, to id: PersonalVocabularyWord.ID) -> Bool {
        guard let word = words.first(where: { $0.id == id }) else { return false }
        let heard = rawHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidVariant(heard, of: word.text),
              !words.contains(where: { $0.id == Self.key(heard) && $0.id != id }) else { return false }
        return remember(word.text, learned: word.learned, heardAs: heard)
    }

    mutating func forgetVariant(_ heard: String, of id: PersonalVocabularyWord.ID) {
        guard let index = words.firstIndex(where: { $0.id == id }) else { return }
        words[index].heardAs.removeAll { $0 == heard }
    }

    var context: DictationContext {
        // Bound request size (the service counts code points) and keep the
        // most recently taught terms first.
        var remaining = 1500
        let hints = words.prefix(50).compactMap { word -> String? in
            let size = word.text.unicodeScalars.count
            guard size <= remaining else { return nil }
            remaining -= size
            return word.text
        }
        return DictationContext(languages: languages.map(\.rawValue), vocabulary: hints, model: model)
    }

    /// Replaces misheard forms the user taught with the saved spelling. A
    /// match has to start and end on a word boundary, so 工月 inside 加工月饼
    /// is left alone.
    func applyingCorrections(
        to text: String,
        segmenter: (String) -> [Range<String.Index>] = DictationPreferences.wordRanges(in:)
    ) -> String {
        let rules = words.flatMap { word in word.heardAs.map { (heard: $0, written: word.text) } }
            .sorted { $0.heard.count > $1.heard.count }
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var edges: Set<Int>?
        func isBoundary(_ index: String.Index) -> Bool {
            guard index.samePosition(in: text) != nil else { return false }
            guard index > text.startIndex, index < text.endIndex else { return true }
            let before = Self.wordClass(text[text.index(before: index)]), after = Self.wordClass(text[index])
            if before == .separator || after == .separator || before != after { return true }
            if before == .spaced { return false }
            if edges == nil { edges = Self.segmentEdges(text, segmenter) }
            return edges?.contains(index.utf16Offset(in: text)) == true
        }
        // One UTF-16 copy keeps a search per rule fast on long transcripts.
        let haystack = NSString(string: text)
        var matches: [(range: Range<String.Index>, written: String)] = []
        for rule in rules {
            var location = 0
            while location < haystack.length {
                let found = haystack.range(of: rule.heard, options: .caseInsensitive,
                                           range: NSRange(location: location, length: haystack.length - location))
                guard found.location != NSNotFound, found.length > 0 else { break }
                if let range = Range(found, in: text), isBoundary(range.lowerBound), isBoundary(range.upperBound),
                   !matches.contains(where: { $0.range.overlaps(range) }), !Self.isMachineText(range, in: text) {
                    matches.append((range, Self.matchingCase(rule.written, to: text[range])))
                    location = found.location + found.length
                } else {
                    location = found.location + 1
                }
            }
        }
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            result += text[cursor..<match.range.lowerBound]
            result += match.written
            cursor = match.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Words worth remembering from an edit the user saved. Everyday words are
    /// left out, and a misheard form is only replaced automatically when it
    /// isn't an everyday word itself (or is a multi-word name or term).
    func correctionSuggestions(
        original: String, edited: String,
        segmenter: (String) -> [Range<String.Index>] = DictationPreferences.wordRanges(in:),
        nameRanges: (String) -> [Range<String.Index>] = DictationPreferences.recognizedNames(in:),
        isCommonWord: ((String) -> Bool?)? = nil
    ) -> [CorrectionSuggestion] {
        guard original != edited, original.utf16.count + edited.utf16.count <= 20_000 else { return [] }
        let isCommonWord = isCommonWord ?? CommonWords(spoken: languages, sample: original).contains
        var names: [Range<String.Index>]?
        var suggestions: [CorrectionSuggestion] = []
        for span in Self.changedSpans(from: original, to: edited, segmenter: segmenter).prefix(40) {
            var heardRange = span.heard, writtenRange = span.written
            var isName = false
            if names == nil { names = nameRanges(edited) }
            if let name = names?.first(where: { $0.lowerBound <= writtenRange.lowerBound && writtenRange.upperBound <= $0.upperBound }),
               name.lowerBound.samePosition(in: edited) != nil, name.upperBound.samePosition(in: edited) != nil {
                // Learn the whole name: 龚月 → 龚玥 rather than 月 → 玥.
                let before = edited[name.lowerBound..<writtenRange.lowerBound]
                let after = edited[writtenRange.upperBound..<name.upperBound]
                if original[..<heardRange.lowerBound].hasSuffix(before), original[heardRange.upperBound...].hasPrefix(after) {
                    heardRange = original.index(heardRange.lowerBound, offsetBy: -before.count)
                        ..< original.index(heardRange.upperBound, offsetBy: after.count)
                    writtenRange = name
                    isName = true
                }
            }
            if !isName, let joined = Self.joiningSingleCharacterNouns(heardRange, in: original, writtenRange, in: edited) {
                heardRange = joined.heard
                writtenRange = joined.written
            }
            let written = String(edited[writtenRange]), heard = String(original[heardRange])
            guard Self.isValidEntry(written), heard.count <= 40, !Self.isMachineText(writtenRange, in: edited) else { continue }
            // Case, spacing and punctuation fixes aren't words to learn, but
            // GitHub or VoiceType spelled with inner capitals is.
            if Self.lettersAndNumbers(heard) == Self.lettersAndNumbers(written), !Self.hasInternalCapitals(written) { continue }
            let termCased = Self.isTermCased(written, atSentenceStart: Self.isSentenceStart(edited, at: writtenRange.lowerBound))
            let heardWords = heard.split(whereSeparator: \.isWhitespace).count
            let heardIsEveryday = isCommonWord(heard) != false && !(heardWords > 1 && (isName || termCased))
            let canReplace = !heard.isEmpty && Self.isValidVariant(heard, of: written)
                && !words.contains { $0.id == Self.key(heard) && $0.id != Self.key(written) } && !heardIsEveryday
            let writtenIsCommon = isCommonWord(written)
            if !canReplace, writtenIsCommon == true, !isName, !termCased { continue }
            if let saved = words.first(where: { $0.id == Self.key(written) }), saved.text == written,
               !canReplace || saved.heardAs.contains(heard) { continue }
            // In scripts written without spaces, fixing characters that don't
            // form a word is almost always a misheard name or term (曲周 → 衢州).
            let fixesUnspacedNonWord = canReplace && !(heard + written).contains { Self.wordClass($0) == .spaced }
            let suggestion = CorrectionSuggestion(written: written, heard: canReplace ? heard : nil,
                                                  isSelected: isName || termCased || writtenIsCommon == false || fixesUnspacedNonWord)
            guard !suggestions.contains(where: { $0.id == suggestion.id }) else { continue }
            suggestions.append(suggestion)
            if suggestions.count == 6 { break }
        }
        return suggestions
    }
}

extension DictationPreferences {
    /// One unreadable field shouldn't erase the rest of a user's settings.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        languages = (try? values.decodeIfPresent([String].self, forKey: .languages))?
            .compactMap(DictationLanguage.init(rawValue:)) ?? []
        learnFromCorrections = (try? values.decodeIfPresent(Bool.self, forKey: .learnFromCorrections)) ?? true
        words = (try? values.decodeIfPresent([LossyWord].self, forKey: .words))?.compactMap(\.word) ?? []
        model = try? values.decodeIfPresent(String.self, forKey: .model)
        mode = (try? values.decodeIfPresent(String.self, forKey: .mode)).flatMap(TranscriptionMode.init(rawValue:)) ?? .streaming
        liveModel = try? values.decodeIfPresent(String.self, forKey: .liveModel)
    }

    private struct LossyWord: Decodable {
        let word: PersonalVocabularyWord?
        init(from decoder: Decoder) throws { word = try? PersonalVocabularyWord(from: decoder) }
    }
}

extension DictationPreferences {
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A saved spelling: one line of 2–40 characters with a letter, within
    /// the limits the service accepts.
    static func isValidEntry(_ text: String) -> Bool {
        (2...40).contains(text.count) && text.unicodeScalars.count <= 80
            && !text.contains(where: \.isNewline) && !text.contains("<") && !text.contains(">")
            && text.unicodeScalars.contains(where: isLetter)
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// A misheard form: a short phrase of up to three words.
    static func isValidVariant(_ heard: String, of text: String) -> Bool {
        heard != text && (2...40).contains(heard.count) && !heard.contains(where: \.isNewline)
            && !heard.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && heard.contains(where: { $0.isLetter || $0.isNumber })
            && heard.split(whereSeparator: \.isWhitespace).count <= 3
    }

    static func wordRanges(in text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
    }

    /// Named-entity recognition depends on optional system language
    /// resources, so suggestions also work when nothing is recognized.
    static func recognizedNames(in text: String) -> [Range<String.Index>] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: [Range<String.Index>] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.joinNames, .omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .personalName || tag == .placeName || tag == .organizationName, (2...40).contains(text[range].count) {
                names.append(range)
            }
            return true
        }
        return names
    }

    fileprivate enum WordClass { case separator, spaced, unspaced }

    /// Scripts written without spaces between words, where word edges come
    /// from the system segmenter.
    private static let unspacedScripts: [ClosedRange<UInt32>] = [
        0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x2E80...0x2FDF, 0x3005...0x3007,
        0x3021...0x3029, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
        0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x323AF,
    ]
    private static let joiners: Set<Character> = ["'", "’", "-", "_"]

    fileprivate static func wordClass(_ character: Character) -> WordClass {
        guard character.isLetter || character.isNumber, let scalar = character.unicodeScalars.first else { return .separator }
        return unspacedScripts.contains { $0.contains(scalar.value) } ? .unspaced : .spaced
    }

    /// Letters as the service counts them (general category L).
    fileprivate static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    private static func segmentEdges(_ text: String, _ segmenter: (String) -> [Range<String.Index>]) -> Set<Int> {
        Set(segmenter(text).flatMap { [$0.lowerBound.utf16Offset(in: text), $0.upperBound.utf16Offset(in: text)] })
    }

    /// URLs, e-mail addresses, file names and code keep their spelling.
    private static func isMachineText(_ range: Range<String.Index>, in text: String) -> Bool {
        func extends(_ character: Character) -> Bool { !character.isWhitespace && wordClass(character) != .unspaced }
        var start = range.lowerBound, end = range.upperBound
        while start > text.startIndex, extends(text[text.index(before: start)]) { start = text.index(before: start) }
        while end < text.endIndex, extends(text[end]) { end = text.index(after: end) }
        let chunk = text[start..<end]
        if chunk.contains(where: { "/@_\\`=".contains($0) }) { return true }
        return zip(chunk, chunk.dropFirst()).contains { $0 == "." && ($1.isLetter || $1.isNumber) }
    }

    private static func matchingCase(_ written: String, to match: Substring) -> String {
        guard !written.contains(where: \.isUppercase), match.first?.isUppercase == true, let first = written.first else { return written }
        return first.uppercased() + written.dropFirst()
    }

    /// Splits text for comparison: punctuation and spaces stand alone, words
    /// in spaced scripts stay whole, and unspaced runs follow the segmenter.
    private static func lexicalTokens(_ text: String, segmenter: (String) -> [Range<String.Index>]) -> [Range<String.Index>] {
        var edges: Set<Int>?
        var tokens: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(after: start)
            switch wordClass(text[start]) {
            case .separator:
                break
            case .spaced:
                while end < text.endIndex {
                    if wordClass(text[end]) == .spaced {
                        end = text.index(after: end)
                    } else if joiners.contains(text[end]), text.index(after: end) < text.endIndex,
                              wordClass(text[text.index(after: end)]) == .spaced {
                        end = text.index(end, offsetBy: 2)
                    } else {
                        break
                    }
                }
            case .unspaced:
                if edges == nil { edges = segmentEdges(text, segmenter) }
                while end < text.endIndex, wordClass(text[end]) == .unspaced, edges?.contains(end.utf16Offset(in: text)) != true {
                    end = text.index(after: end)
                }
            }
            tokens.append(start..<end)
            start = end
        }
        return tokens
    }

    /// The spans that differ between two texts, aligned on words, with shared
    /// unspaced characters and edge punctuation trimmed. Only short spans
    /// with new text are returned.
    private static func changedSpans(
        from original: String, to edited: String, segmenter: (String) -> [Range<String.Index>]
    ) -> [(heard: Range<String.Index>, written: Range<String.Index>)] {
        // Spaces aren't compared, so "voice type" → "VoiceType" stays one change.
        let oldTokens = lexicalTokens(original, segmenter: segmenter).filter { !original[$0].allSatisfy(\.isWhitespace) }
        let newTokens = lexicalTokens(edited, segmenter: segmenter).filter { !edited[$0].allSatisfy(\.isWhitespace) }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in newTokens.map({ edited[$0] }).difference(from: oldTokens.map { original[$0] }) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        func span(_ tokens: [Range<String.Index>], _ range: Range<Int>, in text: String) -> Range<String.Index> {
            guard let first = range.first, let last = range.last else {
                let index = range.lowerBound < tokens.count ? tokens[range.lowerBound].lowerBound : text.endIndex
                return index..<index
            }
            return tokens[first].lowerBound..<tokens[last].upperBound
        }
        var spans: [(heard: Range<String.Index>, written: Range<String.Index>)] = []
        var old = 0, new = 0
        while old < oldTokens.count || new < newTokens.count {
            if old < oldTokens.count, new < newTokens.count, !removed.contains(old), !inserted.contains(new) {
                old += 1; new += 1; continue
            }
            let oldStart = old, newStart = new
            while old < oldTokens.count, removed.contains(old) { old += 1 }
            while new < newTokens.count, inserted.contains(new) { new += 1 }
            guard old > oldStart || new > newStart else { break }
            if let trimmed = trim(span(oldTokens, oldStart..<old, in: original), in: original,
                                  span(newTokens, newStart..<new, in: edited), in: edited) {
                spans.append(trimmed)
            }
        }
        return spans
    }

    private static func trim(
        _ heard: Range<String.Index>, in original: String, _ written: Range<String.Index>, in edited: String
    ) -> (heard: Range<String.Index>, written: Range<String.Index>)? {
        let old = Array(original[heard]), new = Array(edited[written])
        var lead = 0, trail = 0
        while lead < old.count, lead < new.count, old[lead] == new[lead], wordClass(new[lead]) != .spaced { lead += 1 }
        while trail < old.count - lead, trail < new.count - lead, old[old.count - 1 - trail] == new[new.count - 1 - trail],
              wordClass(new[new.count - 1 - trail]) != .spaced { trail += 1 }
        // Keep a neighbouring character around a one-character fix inside a
        // word, so 张伟 → 张炜 is learned whole rather than 伟 → 炜.
        if old.count - lead - trail == 1, new.count - lead - trail == 1,
           wordClass(old[lead]) == .unspaced, wordClass(new[lead]) == .unspaced {
            if lead > 0, wordClass(new[lead - 1]) == .unspaced { lead -= 1 }
            else if trail > 0, wordClass(new[new.count - trail]) == .unspaced { trail -= 1 }
        }
        var oldStart = lead, oldEnd = old.count - trail, newStart = lead, newEnd = new.count - trail
        while oldStart < oldEnd, wordClass(old[oldStart]) == .separator { oldStart += 1 }
        while oldEnd > oldStart, wordClass(old[oldEnd - 1]) == .separator { oldEnd -= 1 }
        while newStart < newEnd, wordClass(new[newStart]) == .separator { newStart += 1 }
        while newEnd > newStart, wordClass(new[newEnd - 1]) == .separator { newEnd -= 1 }
        guard newEnd > newStart, newEnd - newStart <= 40, oldEnd - oldStart <= 40 else { return nil }
        let heardStart = original.index(heard.lowerBound, offsetBy: oldStart)
        let writtenStart = edited.index(written.lowerBound, offsetBy: newStart)
        return (heardStart..<original.index(heardStart, offsetBy: oldEnd - oldStart),
                writtenStart..<edited.index(writtenStart, offsetBy: newEnd - newStart))
    }

    /// The segmenter splits a Chinese name it doesn't know into single
    /// characters, so a one-character fix takes in the single-character nouns
    /// beside it: 龚月 → 龚玥 rather than 月 → 玥.
    private static func joiningSingleCharacterNouns(
        _ heard: Range<String.Index>, in original: String, _ written: Range<String.Index>, in edited: String
    ) -> (heard: Range<String.Index>, written: Range<String.Index>)? {
        func isHan(_ character: Character) -> Bool { character.unicodeScalars.allSatisfy(CommonWords.isHan) }
        guard original[heard].count == 1, edited[written].count == 1, let changed = edited[written].first, isHan(changed) else { return nil }
        var runStart = written.lowerBound, runEnd = written.upperBound
        while runStart > edited.startIndex, isHan(edited[edited.index(before: runStart)]) { runStart = edited.index(before: runStart) }
        while runEnd < edited.endIndex, isHan(edited[runEnd]) { runEnd = edited.index(after: runEnd) }
        // Word classes are only tagged in simplified script.
        let run = String(edited[runStart..<runEnd])
        let simplified = run.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? run
        guard simplified.count == run.count else { return nil }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = simplified
        tagger.setLanguage(.simplifiedChinese, range: simplified.startIndex..<simplified.endIndex)
        var nouns = Set<Int>()
        tagger.enumerateTags(in: simplified.startIndex..<simplified.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .noun, simplified[range].count == 1 { nouns.insert(simplified.distance(from: simplified.startIndex, to: range.lowerBound)) }
            return true
        }
        let offset = edited.distance(from: runStart, to: written.lowerBound)
        guard nouns.contains(offset) else { return nil }
        var start = written.lowerBound, end = written.upperBound, heardStart = heard.lowerBound, heardEnd = heard.upperBound
        var first = offset, last = offset
        while last - first < 3, nouns.contains(first - 1), heardStart > original.startIndex,
              original[original.index(before: heardStart)] == edited[edited.index(before: start)] {
            start = edited.index(before: start); heardStart = original.index(before: heardStart); first -= 1
        }
        while last - first < 3, nouns.contains(last + 1), heardEnd < original.endIndex, original[heardEnd] == edited[end] {
            end = edited.index(after: end); heardEnd = original.index(after: heardEnd); last += 1
        }
        return first == last ? nil : (heardStart..<heardEnd, start..<end)
    }

    private static func lettersAndNumbers(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber }).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func hasInternalCapitals(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).contains { $0.dropFirst().contains(where: \.isUppercase) }
    }

    /// Capitalized like a name or product: inner capitals, letters with
    /// digits, or a capital that isn't explained by the start of a sentence.
    private static func isTermCased(_ text: String, atSentenceStart: Bool) -> Bool {
        if hasInternalCapitals(text) { return true }
        if text.contains(where: \.isNumber), text.contains(where: { $0.isLetter && wordClass($0) == .spaced }) { return true }
        let capitalized = text.split(whereSeparator: \.isWhitespace).map { part in
            part.first?.isUppercase == true && part != "I" && !part.hasPrefix("I'") && !part.hasPrefix("I’")
        }
        return capitalized.dropFirst().contains(true) || (capitalized.first == true && !atSentenceStart)
    }

    private static func isSentenceStart(_ text: String, at index: String.Index) -> Bool {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let character = text[previous]
            if character.isNewline { return true }
            guard character.isWhitespace || "\"'“‘«(（「『".contains(character) else {
                return ".!?。！？…".contains(character)
            }
            cursor = previous
        }
        return true
    }
}

struct CorrectionSuggestion: Identifiable, Equatable {
    /// The spelling the user wrote.
    let written: String
    /// What the transcript said instead, when it is safe to replace it in
    /// new transcripts.
    let heard: String?
    var isSelected: Bool
    var id: String { DictationPreferences.key(written) + "→" + DictationPreferences.key(heard ?? "") }
}

/// Everyday words from the system's word lists, or for Han text without a
/// list, from the system segmenter. `nil` means neither can tell, so callers
/// stay conservative.
private struct CommonWords {
    private static let latinLanguages: Set<String> = [
        "en", "es", "fr", "de", "pt", "it", "id", "vi", "tr", "nl", "ca", "cs", "da", "fi",
        "hr", "hu", "ms", "nb", "pl", "ro", "sk", "sv",
    ]
    private let hanLanguages: [String]
    private let latinLanguages: [String]

    init(spoken: [DictationLanguage], sample: String) {
        let chosen = spoken.map(\.rawValue)
        let han = chosen.filter { ["zh-Hans", "zh-Hant", "ja"].contains($0) }.map { $0 == "zh-Hant" ? "zh-Hans" : $0 }
        hanLanguages = han.isEmpty ? ["zh-Hans"] : Array(Set(han))
        var latin = chosen.filter(Self.latinLanguages.contains)
        if chosen.isEmpty {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(String(sample.prefix(2_000)))
            if let detected = recognizer.dominantLanguage?.rawValue, Self.latinLanguages.contains(detected) { latin.append(detected) }
        }
        latinLanguages = Array(Set(latin + ["en"]))
    }

    func contains(_ phrase: String) -> Bool? {
        var unknown = false
        for part in phrase.split(whereSeparator: \.isWhitespace) {
            switch containsWord(part.lowercased()) {
            case .some(false): return false
            case .none: unknown = true
            case .some(true): break
            }
        }
        return unknown ? nil : true
    }

    private func containsWord(_ word: String) -> Bool? {
        let letters = word.unicodeScalars.filter(DictationPreferences.isLetter)
        guard !letters.isEmpty else { return true }
        var forms = [word]
        let candidates: [String]
        var readings: [HanReading] = []
        if letters.allSatisfy(Self.isHan) {
            candidates = hanLanguages
            let simplified = word.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? word
            if simplified != word { forms.append(simplified) }
            // The system tags Chinese word classes, not Japanese ones.
            readings = hanLanguages.map { $0 == "ja" ? .unknown : Self.reading(simplified) }
            // Grammar words appear in ordinary sentences, so a spelling made
            // with them (在见 for 再见) is never a misheard name.
            if readings.contains(.grammar) { return true }
        } else if letters.allSatisfy({ $0.value < 0x250 || (0x1E00...0x1EFF).contains($0.value) }) {
            candidates = latinLanguages
        } else {
            return nil
        }
        var missingList = false
        for language in candidates {
            switch EmbeddingVocabulary.shared.contains(forms, language: language) {
            case .some(true): return true
            case .none: missingList = true
            case .some(false): break
            }
        }
        guard missingList else { return false }
        // Without a word list, the segmenter still tells a word it knows
        // (衢州) from characters it can't join into one (工月).
        if readings.contains(.word) { return true }
        return !readings.isEmpty && readings.allSatisfy { $0 == .unjoined } ? false : nil
    }

    /// How the system segmenter reads a run of Han characters.
    private enum HanReading { case word, unjoined, grammar, unknown }

    private static let grammarClasses: Set<NLTag> = [
        .pronoun, .determiner, .particle, .preposition, .conjunction, .interjection, .classifier, .number, .idiom, .otherWord,
    ]

    private static func reading(_ text: String) -> HanReading {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let whole = text.startIndex..<text.endIndex
        tagger.setLanguage(.simplifiedChinese, range: whole)
        var tokens: [(characters: Int, tag: NLTag?)] = []
        tagger.enumerateTags(in: whole, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            tokens.append((text[range].count, tag))
            return true
        }
        guard !tokens.isEmpty else { return .unknown }
        if tokens.contains(where: { $0.tag.map(grammarClasses.contains) == true }) { return .grammar }
        if tokens.count == 1 { return .word }
        return tokens.allSatisfy { $0.characters == 1 && $0.tag == .noun } ? .unjoined : .unknown
    }

    fileprivate static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        [0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3400...0x4DBF, 0x4E00...0x9FFF,
         0xF900...0xFAFF, 0x20000...0x323AF].contains { $0.contains(scalar.value) }
    }
}

/// System word lists, loaded once per language. `nil` when the OS has none.
private final class EmbeddingVocabulary: @unchecked Sendable {
    static let shared = EmbeddingVocabulary()
    private let lock = NSLock()
    private var embeddings: [String: NLEmbedding?] = [:]

    func contains(_ forms: [String], language: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        let embedding: NLEmbedding?
        if let cached = embeddings[language] {
            embedding = cached
        } else {
            embedding = NLEmbedding.wordEmbedding(for: NLLanguage(rawValue: language))
            embeddings[language] = .some(embedding)
        }
        guard let embedding else { return nil }
        return forms.contains { embedding.contains($0) }
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

    /// Hints for a new recording. A model the service no longer lists falls
    /// back to the service default instead of failing the request.
    static func context(userID: String, defaults: UserDefaults = .standard) -> DictationContext {
        var context = load(userID: userID, defaults: defaults).context
        if let model = context.model,
           TranscriptionModelCatalogStore.load(defaults: defaults)?.models.contains(where: { $0.id == model }) != true {
            context.model = nil
        }
        return context
    }

    /// The live model for a new recording, or nil when it is uploaded: the
    /// user chose an upload mode, or the service doesn't offer live
    /// transcription. A live model the service no longer lists falls back to
    /// its default.
    static func liveModel(userID: String, defaults: UserDefaults = .standard) -> String? {
        load(userID: userID, defaults: defaults).resolvedLiveModel(in: TranscriptionModelCatalogStore.load(defaults: defaults))
    }

    /// Saved fixes keep applying when learning is turned off; the setting
    /// only stops new suggestions.
    static func applyingCorrections(to text: String, userID: String, defaults: UserDefaults = .standard) -> String {
        load(userID: userID, defaults: defaults).applyingCorrections(to: text)
    }
}

extension DictationPreferences {
    func resolvedLiveModel(in catalog: TranscriptionModelCatalog?) -> String? {
        guard mode == .live, let live = catalog?.realtime, live.available, let first = live.models.first else { return nil }
        if let liveModel, live.models.contains(where: { $0.id == liveModel }) { return liveModel }
        return live.models.contains { $0.id == live.defaultModel } ? live.defaultModel : first.id
    }
}

@MainActor
enum TranscriptionModelCatalogStore {
    private static let key = "transcriptionModelCatalog.v1"
    static func load(defaults: UserDefaults = .standard) -> TranscriptionModelCatalog? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TranscriptionModelCatalog.self, from: data)
    }
    static func save(_ catalog: TranscriptionModelCatalog, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: key)
    }
    /// Keeps the last catalog when the service can't be reached.
    @discardableResult
    static func refresh(defaults: UserDefaults = .standard) async -> TranscriptionModelCatalog? {
        do {
            let catalog = try await BackendClient.transcriptionModels()
            save(catalog, defaults: defaults)
            return catalog
        } catch {
            return load(defaults: defaults)
        }
    }
}
