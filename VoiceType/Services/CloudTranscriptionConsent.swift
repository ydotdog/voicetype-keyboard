import Foundation
import SwiftUI

/// Consent is scoped to the signed-in account and the disclosed processor.
/// Changing processors requires a new version and a new explicit decision.
@MainActor
final class CloudTranscriptionConsent: ObservableObject {
    static let shared = CloudTranscriptionConsent()
    static let policyVersion = "openai-audio-v1"
    static let changed = Notification.Name("VoiceTypeCloudConsentChanged")
    static let privacyURL = URL(string: "https://voicetype.y.dog/privacy")!
    static let supportURL = URL(string: "https://voicetype.y.dog/support")!
    @Published private(set) var revision = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isGranted(userID: String) -> Bool {
        !userID.isEmpty && defaults.string(forKey: key(userID)) == Self.policyVersion
    }

    func setGranted(_ granted: Bool, userID: String) {
        guard !userID.isEmpty else { return }
        if granted { defaults.set(Self.policyVersion, forKey: key(userID)) }
        else { defaults.removeObject(forKey: key(userID)) }
        revision += 1
        NotificationCenter.default.post(name: Self.changed, object: userID)
    }

    private func key(_ userID: String) -> String { "cloudTranscriptionConsent.\(userID)" }
}

struct CloudTranscriptionConsentView: View {
    let userID: String
    var onAllow: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Cloud transcription", systemImage: "waveform")
                        .font(.title2.weight(.semibold))
                    Text("VoiceType sends the audio clips you choose, your language choices, and up to 50 vocabulary hints to the VoiceType server and OpenAI to turn speech into text.")
                    Text("While keyboard mic is on, temporary audio is recorded on your device. Only clips you start and finish are uploaded. Failed clips stay on your device for retry.")
                    Text("You can withdraw permission in Settings at any time. Basic keyboard typing works without cloud transcription.")
                    Link("Read the privacy policy", destination: CloudTranscriptionConsent.privacyURL)
                }
                Section {
                    Button("Allow cloud transcription") {
                        CloudTranscriptionConsent.shared.setGranted(true, userID: userID)
                        onAllow()
                        dismiss()
                    }
                    .disabled(userID.isEmpty)
                    .accessibilityIdentifier("consent.allow")
                    Button("Not now", role: .cancel) { dismiss() }
                }
            }
            .navigationTitle("Your privacy")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
