"""Execute the Foundation-only shared stores with isolated in-memory defaults."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(sys.platform != "darwin" or not shutil.which("xcrun"), reason="requires Apple Swift SDK")
def test_shared_recording_state_commands_and_transcript_history() -> None:
    # Shadow UserDefaults to exercise production encoding/expiry/command logic
    # without accessing the user's actual app group or preferences.
    harness = r'''
import Foundation

enum AppConstants { static let appGroup = "test.voicetype.recording" }

final class UserDefaults {
    private static var values: [String: Any] = [:]
    init?(suiteName: String) {}
    func data(forKey key: String) -> Data? { Self.values[key] as? Data }
    func string(forKey key: String) -> String? { Self.values[key] as? String }
    func set(_ value: Any?, forKey key: String) { Self.values[key] = value }
    func removeObject(forKey key: String) { Self.values.removeValue(forKey: key) }
    @discardableResult func synchronize() -> Bool { true }
}

@main struct SharedStoreChecks {
    static func main() throws {
        let defaults = UserDefaults(suiteName: AppConstants.appGroup)!
        for limit in RecordingDurationLimit.allCases {
            RecordingPreferencesStore.durationLimit = limit
            assert(RecordingPreferencesStore.durationLimit == limit)
        }
        defaults.set("unknown-setting", forKey: "recordingDurationLimit")
        assert(RecordingPreferencesStore.durationLimit == .fiveMinutes)
        let now = Date()
        let ready = RecordingBridgeState(
            sessionID: "session-a", isRecording: false, startedAt: now,
            updatedAt: now, durationLimit: .fiveMinutes, mode: .keyboardReady
        )
        RecordingBridgeStore.state = ready
        assert(RecordingBridgeStore.state.sessionID == "session-a")
        assert(RecordingBridgeStore.state.isKeyboardReady)
        RecordingBridgeStore.requestStartClip()
        let firstCommand = RecordingBridgeStore.latestCommand!
        assert(firstCommand.sessionID == "session-a")
        assert(firstCommand.action == .startClip)
        RecordingBridgeStore.requestStopClip()
        let secondCommand = RecordingBridgeStore.latestCommand!
        RecordingBridgeStore.clearCommand(id: firstCommand.id)
        assert(RecordingBridgeStore.latestCommand?.id == secondCommand.id)
        RecordingBridgeStore.clearCommand(id: secondCommand.id)
        assert(RecordingBridgeStore.latestCommand == nil)

        for mode in [RecordingBridgeMode.keyboardReady, .keyboardRecording, .transcribing, .standard] {
            RecordingBridgeStore.state = RecordingBridgeState(
                sessionID: "expired", isRecording: mode == .standard || mode == .keyboardRecording,
                startedAt: now.addingTimeInterval(-20), updatedAt: now.addingTimeInterval(-20),
                durationLimit: .always, mode: mode
            )
            assert(RecordingBridgeStore.state == .inactive)
            // Reading an expired snapshot cannot erase another process's state.
            assert(defaults.data(forKey: "recordingBridgeState") != nil)
        }
        RecordingBridgeStore.state = ready
        assert(RecordingBridgeStore.state.sessionID == "session-a")
        RecordingBridgeStore.state = .inactive
        assert(defaults.data(forKey: "recordingBridgeState") == nil)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = Data(#"{"id":"old","action":"stop","createdAt":"2026-09-13T12:00:00Z"}"#.utf8)
        let oldCommand = try decoder.decode(RecordingBridgeCommand.self, from: legacy)
        assert(oldCommand.sessionID == nil)

        for index in 0..<105 {
            SharedTranscriptStore.latest = TranscriptSnapshot(
                id: "\(index)", text: "你好 \(index)", createdAt: now, chargeText: nil
            )
        }
        assert(SharedTranscriptStore.history.count == 100)
        assert(SharedTranscriptStore.latest.text == "你好 104")
        assert(SharedTranscriptStore.history.last?.id == "5")
        SharedTranscriptStore.latest = TranscriptSnapshot(id: "104", text: "Updated", createdAt: now, chargeText: nil)
        assert(SharedTranscriptStore.history.count == 100)
        assert(SharedTranscriptStore.history.first?.text == "Updated")
        SharedTranscriptStore.clear()
        assert(SharedTranscriptStore.latest == .empty)
        assert(SharedTranscriptStore.history.isEmpty)
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="voicetype-shared-tests-") as temporary:
        directory = Path(temporary)
        source = directory / "Checks.swift"
        source.write_text(harness)
        executable = directory / "checks"
        subprocess.run(
            [
                "xcrun", "swiftc", "-module-cache-path", str(directory / "module-cache"),
                str(ROOT / "Shared/RecordingPreferences.swift"),
                str(ROOT / "Shared/RecordingBridgeStore.swift"),
                str(ROOT / "Shared/SharedTranscriptStore.swift"),
                str(source), "-o", str(executable),
            ],
            check=True, capture_output=True, text=True,
        )
        subprocess.run([str(executable)], check=True, capture_output=True, text=True)
