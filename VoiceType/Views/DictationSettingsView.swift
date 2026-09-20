import SwiftUI

struct DictationSettingsView: View {
    let userID: String
    @State private var preferences: DictationPreferences
    @State private var newWord = ""
    @State private var validationMessage: String?
    @State private var confirmingClear = false
    @Environment(\.dismiss) private var dismiss

    init(userID: String) {
        self.userID = userID
        _preferences = State(initialValue: DictationPreferencesStore.load(userID: userID))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        Form {
                            Section {
                                ForEach(DictationLanguage.allCases) { language in
                                    Button {
                                        preferences.toggle(language)
                                    } label: {
                                        HStack {
                                            Text(language.label).foregroundStyle(AppTheme.ink)
                                            Spacer()
                                            if preferences.languages.contains(language) {
                                                Image(systemName: "checkmark").foregroundStyle(AppTheme.coral)
                                            }
                                        }
                                        .frame(minHeight: 30)
                                        .contentShape(Rectangle())
                                    }
                                    .disabled(preferences.languages.count == 3 && !preferences.languages.contains(language)
                                              && !(language.isChinese && preferences.languages.contains(where: \.isChinese)))
                                    .accessibilityAddTraits(preferences.languages.contains(language) ? .isSelected : [])
                                }
                                Button("Use automatic detection") { preferences.languages = [] }
                                    .disabled(preferences.languages.isEmpty)
                            } footer: {
                                Text("Select up to 3. Choose one writing style for Chinese.")
                            }
                        }
                        .navigationTitle("Languages")
                        .navigationBarTitleDisplayMode(.inline)
                        .tint(AppTheme.coral)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Choose languages")
                            Text(preferences.languageSummary).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Languages you speak")
                } footer: {
                    Text("Choose up to 3 to help recognize short phrases. With none selected, VoiceType detects the language. Chinese follows your chosen writing style; speech is not translated.")
                }

                Section {
                    Toggle("Learn from my corrections", isOn: $preferences.learnFromCorrections)
                } footer: {
                    Text("When you edit a transcript in History, VoiceType suggests a spelling to remember. Review it before saving. Text typed in other apps is not read or learned.")
                }

                Section {
                    HStack {
                        TextField("Name, place, or phrase", text: $newWord)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit(addWord)
                            .accessibilityLabel("New vocabulary word")
                        Button("Add", action: addWord)
                            .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let validationMessage {
                        Text(validationMessage).font(.footnote).foregroundStyle(AppTheme.coral)
                    }
                    ForEach(preferences.words) { word in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(word.text)
                                if word.learned { Text("Learned from a correction").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                preferences.words.removeAll { $0.id == word.id }
                            } label: {
                                Image(systemName: "minus.circle").frame(width: 44, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Forget \(word.text)")
                        }
                    }
                    if !preferences.words.isEmpty {
                        Button("Clear vocabulary", role: .destructive) { confirmingClear = true }
                    }
                } header: {
                    Text("Personal vocabulary · \(preferences.words.count)/200")
                } footer: {
                    Text("Saved for this account on this device. Up to 50 recent words are sent with a recording to improve recognition. Add the exact spelling you want; each entry can have 2–40 characters.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .tint(AppTheme.coral)
            .navigationTitle("Dictation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: preferences) { _, value in DictationPreferencesStore.save(value, userID: userID) }
            .confirmationDialog("Clear all saved words?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear vocabulary", role: .destructive) { preferences.words = [] }
            }
        }
    }

    private func addWord() {
        guard preferences.remember(newWord) else {
            validationMessage = preferences.words.count >= 200 ? "Your vocabulary is full. Remove a word to add another." : "Enter a word or phrase with 2–40 characters on one line."
            return
        }
        newWord = ""
        validationMessage = nil
    }
}

struct TranscriptCorrectionView: View {
    let snapshot: TranscriptSnapshot
    let userID: String
    let onSave: () -> Void
    @State private var text: String
    @State private var word = ""
    @State private var remember: Bool
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(snapshot: TranscriptSnapshot, userID: String, onSave: @escaping () -> Void) {
        self.snapshot = snapshot
        self.userID = userID
        self.onSave = onSave
        _text = State(initialValue: snapshot.text)
        _remember = State(initialValue: DictationPreferencesStore.load(userID: userID).learnFromCorrections)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Transcript") {
                    TextEditor(text: $text).frame(minHeight: 200)
                        .accessibilityLabel("Edit transcript")
                }
                Section {
                    Toggle("Remember a spelling", isOn: $remember)
                    if remember {
                        TextField("Word or name to remember", text: $word)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } footer: {
                    Text("Review the suggested word or enter the complete name. It will help future recordings. Saving updates History on this device; text already inserted in another app stays as it is.")
                }
                if let error { Text(error).foregroundStyle(AppTheme.coral) }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .tint(AppTheme.coral)
            .navigationTitle("Edit & teach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: text) { _, value in
                word = DictationPreferences.correctedTerm(original: snapshot.text, edited: value) ?? ""
            }
        }
    }

    private func save() {
        var preferences = DictationPreferencesStore.load(userID: userID)
        if remember, !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard preferences.remember(word, learned: true) else {
                error = "Use 2–40 characters for the spelling, or remove a saved word if your vocabulary is full."
                return
            }
            DictationPreferencesStore.save(preferences, userID: userID)
        }
        let updated = TranscriptSnapshot(id: snapshot.id, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                         createdAt: snapshot.createdAt, chargeText: snapshot.chargeText)
        // Never republish latest: doing so could insert an edited old clip in an unrelated field.
        SharedTranscriptStore.history = SharedTranscriptStore.history.map { $0.id == updated.id ? updated : $0 }
        onSave()
        dismiss()
    }
}
