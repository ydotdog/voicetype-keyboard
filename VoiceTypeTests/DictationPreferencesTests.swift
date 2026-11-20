import Foundation
import XCTest
@testable import VoiceType

@MainActor
final class DictationPreferencesTests: XCTestCase {
    func testLanguagesKeepOneChineseScriptAndThreeLanguages() {
        var preferences = DictationPreferences()
        preferences.toggle(.simplifiedChinese)
        preferences.toggle(.english)
        preferences.toggle(.japanese)
        preferences.toggle(.traditionalChinese)
        XCTAssertEqual(preferences.languages, [.english, .japanese, .traditionalChinese])
        preferences.toggle(.german)
        XCTAssertEqual(preferences.languages.count, 3)
        preferences.toggle(.japanese)
        XCTAssertEqual(preferences.context.languages, ["en", "zh-Hant"])
    }

    func testVocabularyDeduplicatesBoundsAndDoesNotDemoteManualWord() {
        var preferences = DictationPreferences()
        XCTAssertTrue(preferences.remember(" VoiceType "))
        XCTAssertTrue(preferences.remember("voicetype", learned: true))
        XCTAssertEqual(preferences.words.count, 1)
        XCTAssertFalse(preferences.words[0].learned)
        XCTAssertFalse(preferences.remember("12345"))
        XCTAssertFalse(preferences.remember("one\ntwo"))
        XCTAssertFalse(preferences.remember(String(repeating: "字", count: 41)))
        for n in 0..<220 { preferences.remember("Person \(n)") }
        XCTAssertEqual(preferences.words.count, 200)
        XCTAssertEqual(preferences.context.vocabulary.count, 50)
    }

    func testVocabularyRejectsEntriesTheServiceWouldRefuse() {
        XCTAssertTrue(DictationPreferences.isValidEntry(String(repeating: "e\u{301}", count: 40)))
        XCTAssertFalse(DictationPreferences.isValidEntry(String(repeating: "e\u{301}\u{302}", count: 30)))
        XCTAssertFalse(DictationPreferences.isValidEntry("<VoiceType>"))
        XCTAssertFalse(DictationPreferences.isValidEntry("Voice\u{7}Type"))
    }

    func testTheNewestCorrectionOwnsAMisheardForm() {
        var preferences = DictationPreferences()
        XCTAssertTrue(preferences.remember("龚玥", learned: true, heardAs: "工月"))
        XCTAssertTrue(preferences.remember("宫月", learned: true, heardAs: "工月"))
        XCTAssertEqual(preferences.words.map(\.text), ["宫月", "龚玥"])
        XCTAssertEqual(preferences.words.map(\.heardAs), [["工月"], []])
        // A spelling saved as its own word is never rewritten into another.
        XCTAssertTrue(preferences.remember("龚玥", learned: true, heardAs: "宫月"))
        XCTAssertEqual(preferences.words.first { $0.text == "龚玥" }?.heardAs, [])
        XCTAssertTrue(preferences.remember("工月"))
        XCTAssertEqual(preferences.words.first { $0.text == "宫月" }?.heardAs, [])
        // Misheard forms stay on the device; only spellings are sent as hints.
        XCTAssertEqual(Set(preferences.context.vocabulary), ["龚玥", "宫月", "工月"])
    }

    func testTeachingAndForgettingMisheardForms() {
        var preferences = DictationPreferences()
        preferences.remember("Kyle Qi")
        preferences.remember("VoiceType")
        let id = DictationPreferences.key("Kyle Qi")
        XCTAssertTrue(preferences.teach(" Kyle Key ", to: id))
        XCTAssertFalse(preferences.teach("Kyle Qi", to: id))
        XCTAssertFalse(preferences.teach("k", to: id))
        XCTAssertFalse(preferences.teach("one two three four", to: id))
        XCTAssertFalse(preferences.teach("voicetype", to: id))
        XCTAssertFalse(preferences.teach("Kyle Key", to: "missing"))
        for n in 1...6 { XCTAssertTrue(preferences.teach("Kyle K\(n)", to: id)) }
        XCTAssertEqual(preferences.words.first { $0.id == id }?.heardAs, ["Kyle K6", "Kyle K5", "Kyle K4", "Kyle K3", "Kyle K2"])
        XCTAssertEqual(preferences.words.first?.id, id)
        preferences.forgetVariant("Kyle K4", of: id)
        XCTAssertEqual(preferences.words.first?.heardAs, ["Kyle K6", "Kyle K5", "Kyle K3", "Kyle K2"])
    }

    func testSavedFixesReplaceWholeWordsOnly() {
        var preferences = DictationPreferences()
        preferences.remember("龚玥", learned: true, heardAs: "工月")
        preferences.remember("GitHub", learned: true, heardAs: "github")
        preferences.remember("the", heardAs: "teh")
        preferences.remember("Kyle Qi", learned: true, heardAs: "Kyle Key")
        let segmenter = Self.segments(["明天", "和", "工月", "吃饭", "加工", "月饼", "也", "好吃"])
        XCTAssertEqual(preferences.applyingCorrections(to: "明天和工月吃饭，加工月饼也好吃。", segmenter: segmenter),
                       "明天和龚玥吃饭，加工月饼也好吃。")
        // Without word edges, a fix inside unspaced text waits for punctuation.
        XCTAssertEqual(preferences.applyingCorrections(to: "明天和工月吃饭。工月，你好", segmenter: { _ in [] }),
                       "明天和工月吃饭。龚玥，你好")
        XCTAssertEqual(preferences.applyingCorrections(to: "Github and github.com and githubber, my_github"),
                       "GitHub and github.com and githubber, my_github")
        XCTAssertEqual(preferences.applyingCorrections(to: "Teh end. teh"), "The end. the")
        XCTAssertEqual(preferences.applyingCorrections(to: "Kyle Key and Kyle Keyes"), "Kyle Qi and Kyle Keyes")
        XCTAssertEqual(preferences.applyingCorrections(to: "访问github.com，或者用github", segmenter: { _ in [] }),
                       "访问github.com，或者用GitHub")
        XCTAssertEqual(DictationPreferences().applyingCorrections(to: "github"), "github")
    }

    func testSuggestionsLearnMisheardNamesAndSkipEverydayEdits() {
        var preferences = DictationPreferences()
        let common: Set<String> = ["明天", "和", "在", "见面", "meet", "tomorrow", "their", "there", "hello", "see"]
        func suggestions(_ original: String, _ edited: String, names: [String] = [],
                         words: [String] = []) -> [CorrectionSuggestion] {
            preferences.correctionSuggestions(
                original: original, edited: edited, segmenter: Self.segments(words),
                nameRanges: { text in names.compactMap { text.range(of: $0) } },
                isCommonWord: { word in word.split(separator: " ").allSatisfy { common.contains($0.lowercased()) } })
        }
        let chinese = ["明天", "和", "工月", "龚玥", "在", "曲周", "衢州", "见面"]
        XCTAssertEqual(suggestions("明天和工月在曲周见面。", "明天和龚玥在衢州见面。", words: chinese), [
            CorrectionSuggestion(written: "龚玥", heard: "工月", isSelected: true),
            CorrectionSuggestion(written: "衢州", heard: "曲周", isSelected: true),
        ])
        // A one-character fix is learned with its neighbour, and a name is learned whole.
        XCTAssertEqual(suggestions("明天和龚月见面", "明天和龚玥见面", words: ["明天", "和", "龚月", "龚玥", "见面"]),
                       [CorrectionSuggestion(written: "龚玥", heard: "龚月", isSelected: true)])
        XCTAssertEqual(suggestions("Meet Kyle Key tomorrow", "Meet Kyle Qi tomorrow", names: ["Kyle Qi"]),
                       [CorrectionSuggestion(written: "Kyle Qi", heard: "Kyle Key", isSelected: true)])
        XCTAssertEqual(suggestions("see github", "see GitHub"), [CorrectionSuggestion(written: "GitHub", heard: "github", isSelected: true)])
        XCTAssertEqual(suggestions("put it their", "put it there"), [])
        XCTAssertEqual(suggestions("hello", "Hello"), [])
        XCTAssertEqual(suggestions("see github.com", "see GitHub.com"), [])
        XCTAssertEqual(suggestions("你好, 世界", "你好，世界"), [])
        XCTAssertEqual(suggestions("same", "same"), [])
        // A misheard form that is an everyday word is only offered as a spelling.
        XCTAssertEqual(suggestions("meet there", "meet Tere", names: ["Tere"]),
                       [CorrectionSuggestion(written: "Tere", heard: nil, isSelected: true)])
        preferences.remember("GitHub", learned: true, heardAs: "github")
        XCTAssertEqual(suggestions("see github", "see GitHub"), [])
        preferences.remember("Jon")
        XCTAssertEqual(suggestions("Meet Jon tomorrow", "Meet John tomorrow", names: ["John"]),
                       [CorrectionSuggestion(written: "John", heard: nil, isSelected: true)])
    }

    /// The system segmenter and word classes alone, as on a device without the
    /// Chinese word list or name recognition (the simulator has neither).
    func testChineseSuggestionsWithoutNameRecognition() {
        let preferences = DictationPreferences()
        func suggestions(_ original: String, _ edited: String) -> [CorrectionSuggestion] {
            preferences.correctionSuggestions(original: original, edited: edited, nameRanges: { _ in [] })
        }
        XCTAssertEqual(suggestions("明天和工月在曲周见面。", "明天和龚玥在衢州见面。"), [
            CorrectionSuggestion(written: "龚玥", heard: "工月", isSelected: true),
            CorrectionSuggestion(written: "衢州", heard: "曲周", isSelected: true),
        ])
        // A one-character fix takes in the rest of a name the segmenter split up.
        XCTAssertEqual(suggestions("明天和龚月见面", "明天和龚玥见面"), [CorrectionSuggestion(written: "龚玥", heard: "龚月", isSelected: true)])
        XCTAssertEqual(suggestions("明天和龔月見面", "明天和龔玥見面"), [CorrectionSuggestion(written: "龔玥", heard: "龔月", isSelected: true)])
        // Grammar words are never learned or replaced.
        for (original, edited) in [("下次在见", "下次再见"), ("他们说好了", "她们说好了"), ("说的好", "说得好"), ("我在北京等你", "我在北京等妳")] {
            XCTAssertEqual(suggestions(original, edited), [], original)
        }
    }

    func testPreferencesDecodeWhatTheyCanAndKeepOtherSettings() throws {
        let json = """
        {"languages": ["zh-Hans", "tlh"], "learnFromCorrections": false, "model": 5,
         "words": [{"text": "龚玥", "learned": true, "heardAs": ["工月"]}, {"bogus": 1}, {"text": "VoiceType"}]}
        """
        let preferences = try JSONDecoder().decode(DictationPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(preferences.languages, [.simplifiedChinese])
        XCTAssertFalse(preferences.learnFromCorrections)
        XCTAssertNil(preferences.model)
        XCTAssertEqual(preferences.words, [
            PersonalVocabularyWord(text: "龚玥", learned: true, heardAs: ["工月"]),
            PersonalVocabularyWord(text: "VoiceType", learned: false),
        ])
        let legacy = try JSONDecoder().decode(DictationPreferences.self, from: Data(#"{"words": "bad"}"#.utf8))
        XCTAssertEqual(legacy, DictationPreferences())
    }

    func testRecordingsUseOnlyAModelTheServiceStillLists() throws {
        let name = "dictation-model-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = DictationPreferences()
        preferences.model = "gpt-transcribe"
        preferences.remember("龚玥", heardAs: "工月")
        DictationPreferencesStore.save(preferences, userID: "alice", defaults: defaults)
        XCTAssertNil(DictationPreferencesStore.context(userID: "alice", defaults: defaults).model)
        TranscriptionModelCatalogStore.save(Self.catalog(["gpt-transcribe", "gpt-4o-mini-transcribe"]), defaults: defaults)
        XCTAssertEqual(DictationPreferencesStore.context(userID: "alice", defaults: defaults),
                       DictationContext(languages: [], vocabulary: ["龚玥"], model: "gpt-transcribe"))
        TranscriptionModelCatalogStore.save(Self.catalog(["gpt-4o-mini-transcribe"]), defaults: defaults)
        XCTAssertNil(DictationPreferencesStore.context(userID: "alice", defaults: defaults).model)
        XCTAssertEqual(DictationPreferencesStore.applyingCorrections(to: "工月，你好", userID: "alice", defaults: defaults), "龚玥，你好")
        XCTAssertEqual(DictationPreferencesStore.applyingCorrections(to: "工月，你好", userID: "bob", defaults: defaults), "工月，你好")
    }

    func testModelCatalogDecodesTheServiceResponse() throws {
        let json = """
        {"default_model": "gpt-4o-mini-transcribe", "default_model_name": "GPT-4o mini Transcribe", "models": [
          {"id": "gpt-transcribe", "name": "GPT Transcribe", "recommended": true, "streaming": true, "retires_on": null,
           "pricing_basis": "duration", "credit_units_per_minute": 7715, "formatted_per_minute": "7,715 credits/min"},
          {"id": "whisper-1", "name": "Whisper", "recommended": false, "streaming": false, "retires_on": "2027-02-26",
           "pricing_basis": "duration", "credit_units_per_minute": 10286, "formatted_per_minute": "10,286 credits/min"}]}
        """
        let catalog = try JSONDecoder().decode(TranscriptionModelCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.defaultModelName, "GPT-4o mini Transcribe")
        XCTAssertEqual(catalog.models.map(\.id), ["gpt-transcribe", "whisper-1"])
        XCTAssertEqual(TranscriptionModelSettingsView.detail(for: catalog.models[0]), "Recommended · About 7,715 credits/min")
        let retiring = TranscriptionModelSettingsView.detail(for: catalog.models[1])
        XCTAssertTrue(retiring.hasPrefix("About 10,286 credits/min · Retires "), retiring)
        XCTAssertTrue(retiring.contains("2027"), retiring)
    }

    func testAccountIsolationAndDeletion() throws {
        let name = "dictation-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = DictationPreferences()
        preferences.toggle(.simplifiedChinese)
        preferences.remember("龚玥")
        DictationPreferencesStore.save(preferences, userID: "alice", defaults: defaults)
        XCTAssertEqual(DictationPreferencesStore.load(userID: "alice", defaults: defaults), preferences)
        XCTAssertEqual(DictationPreferencesStore.load(userID: "bob", defaults: defaults), DictationPreferences())
        DictationPreferencesStore.clear(userID: "bob", defaults: defaults)
        XCTAssertEqual(DictationPreferencesStore.load(userID: "alice", defaults: defaults), preferences)
        DictationPreferencesStore.clear(userID: "alice", defaults: defaults)
        XCTAssertEqual(DictationPreferencesStore.load(userID: "alice", defaults: defaults), DictationPreferences())
    }

    func testRecoveryPersistsOriginalHintsAndLegacyRecordingsDecode() throws {
        let context = DictationContext(languages: ["zh-Hant"], vocabulary: ["龔玥"], model: "gpt-transcribe")
        let recording = RecoverableRecording(fileURL: URL(fileURLWithPath: "/tmp/audio.m4a"), duration: 2,
            clipStartTime: nil, requestID: UUID(), userID: "alice", context: context)
        let data = try JSONEncoder().encode(recording)
        XCTAssertEqual(try JSONDecoder().decode(RecoverableRecording.self, from: data).context, context)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "context")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(RecoverableRecording.self, from: legacy).context, .empty)
    }

    /// Word edges for unspaced text, independent of the system segmenter.
    private static func segments(_ words: [String]) -> (String) -> [Range<String.Index>] {
        { text in
            var ranges: [Range<String.Index>] = []
            var cursor = text.startIndex
            for word in words {
                guard let range = text.range(of: word, range: cursor..<text.endIndex) else { continue }
                ranges.append(range)
                cursor = range.upperBound
            }
            return ranges
        }
    }

    private static func catalog(_ ids: [String]) -> TranscriptionModelCatalog {
        TranscriptionModelCatalog(defaultModel: "gpt-4o-mini-transcribe", defaultModelName: "GPT-4o mini Transcribe", models: ids.map {
            TranscriptionModelOption(id: $0, name: $0, recommended: false, streaming: true, retiresOn: nil,
                                     pricingBasis: "duration", creditUnitsPerMinute: 5_143, formattedPerMinute: "5,143 credits/min")
        })
    }
}
