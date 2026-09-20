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

    func testCorrectionsLearnWordRatherThanChangedLetterOrWholeTranscript() {
        XCTAssertEqual(DictationPreferences.correctedTerm(original: "Meet Jon tomorrow", edited: "Meet John tomorrow"), "John")
        XCTAssertEqual(DictationPreferences.correctedTerm(original: "明天去北京", edited: "明天去衢州"), "衢州")
        XCTAssertEqual(DictationPreferences.correctedTerm(original: "明天和张伟去衢州", edited: "明天和张炜去衢州"), "张炜")
        XCTAssertNil(DictationPreferences.correctedTerm(original: "你好, 世界", edited: "你好，世界"))
        XCTAssertNil(DictationPreferences.correctedTerm(original: "same", edited: "same"))
        XCTAssertNil(DictationPreferences.correctedTerm(original: "hi", edited: String(repeating: "new words ", count: 20)))
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
        let context = DictationContext(languages: ["zh-Hant"], vocabulary: ["龔玥"])
        let recording = RecoverableRecording(fileURL: URL(fileURLWithPath: "/tmp/audio.m4a"), duration: 2,
            clipStartTime: nil, requestID: UUID(), userID: "alice", context: context)
        let data = try JSONEncoder().encode(recording)
        XCTAssertEqual(try JSONDecoder().decode(RecoverableRecording.self, from: data).context, context)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "context")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(RecoverableRecording.self, from: legacy).context, .empty)
    }
}
