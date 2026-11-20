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
                    Text("When you edit a transcript in History, VoiceType suggests words to remember and misheard spellings to fix in new transcripts. Nothing is saved until you choose it, and saved fixes keep working until you remove them. Text typed in other apps is not read or learned.")
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
                    // Without this the separator starts under the Add button.
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    if let validationMessage {
                        Text(validationMessage).font(.footnote).foregroundStyle(AppTheme.coral)
                    }
                    ForEach(preferences.words) { word in
                        NavigationLink {
                            VocabularyWordView(preferences: $preferences, id: word.id)
                        } label: {
                            VocabularyWordRow(word: word)
                        }
                    }
                    .onDelete { preferences.words.remove(atOffsets: $0) }
                    if !preferences.words.isEmpty {
                        Button("Clear vocabulary", role: .destructive) { confirmingClear = true }
                    }
                } header: {
                    Text("Personal vocabulary · \(preferences.words.count)/\(DictationPreferences.maximumWords)")
                } footer: {
                    Text("Saved for this account on this device. Up to 50 recent words are sent with a recording to improve recognition; misheard spellings stay on this device. Add the exact spelling you want, with 2–40 characters. Tap a word to manage what it fixes, or swipe to forget it.")
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
            validationMessage = preferences.words.count >= DictationPreferences.maximumWords
                ? "Your vocabulary is full. Remove a word to add another." : "Enter a word or phrase with 2–40 characters on one line."
            return
        }
        newWord = ""
        validationMessage = nil
    }
}

private struct VocabularyWordRow: View {
    let word: PersonalVocabularyWord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(word.text)
            if !word.heardAs.isEmpty {
                Text("Fixes " + word.heardAs.map { "“\($0)”" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if word.learned {
                Text("Learned from a correction").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One saved spelling and the misheard forms it replaces.
private struct VocabularyWordView: View {
    @Binding var preferences: DictationPreferences
    let id: PersonalVocabularyWord.ID
    @State private var newVariant = ""
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let word = preferences.words.first(where: { $0.id == id }) {
                Section {
                    Text(word.text).font(.title3.weight(.semibold)).textSelection(.enabled)
                } footer: {
                    Text(word.learned ? "Learned from a correction. Sent as a spelling hint with new recordings." : "Sent as a spelling hint with new recordings.")
                }
                Section {
                    ForEach(word.heardAs, id: \.self) { heard in
                        Text(heard)
                    }
                    .onDelete { offsets in
                        for heard in offsets.map({ word.heardAs[$0] }) { preferences.forgetVariant(heard, of: id) }
                    }
                    if word.heardAs.count < DictationPreferences.maximumVariants {
                        HStack {
                            TextField("Add a misheard spelling", text: $newVariant)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .submitLabel(.done)
                                .onSubmit(addVariant)
                            Button("Add", action: addVariant)
                                .disabled(newVariant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(AppTheme.coral)
                    }
                } header: {
                    Text("Fixes in new transcripts")
                } footer: {
                    Text("When a new transcript has one of these as a whole word, VoiceType writes “\(word.text)” instead. Links and code are left as they are. Up to \(DictationPreferences.maximumVariants); they stay on this device.")
                }
                Section {
                    Button("Forget this word", role: .destructive) {
                        preferences.words.removeAll { $0.id == id }
                        dismiss()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .tint(AppTheme.coral)
        .navigationTitle("Saved word")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addVariant() {
        let heard = newVariant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferences.words.contains(where: { $0.id == DictationPreferences.key(heard) && $0.id != id }) else {
            message = "“\(heard)” is saved as its own word. Forget it first to fix it here."
            return
        }
        guard preferences.teach(heard, to: id) else {
            message = "Use up to 3 words with 2–40 characters, different from the saved spelling."
            return
        }
        newVariant = ""
        message = nil
    }
}

struct TranscriptCorrectionView: View {
    let snapshot: TranscriptSnapshot
    let userID: String
    let onSave: () -> Void
    private let initialText: String
    @State private var text: String
    @State private var preferences: DictationPreferences
    @State private var suggestions: [CorrectionSuggestion] = []
    @State private var manualWord = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    /// `draft` opens with edited text already in place.
    init(snapshot: TranscriptSnapshot, userID: String, draft: String? = nil, onSave: @escaping () -> Void) {
        self.snapshot = snapshot
        self.userID = userID
        self.onSave = onSave
        initialText = draft ?? snapshot.text
        _text = State(initialValue: draft ?? snapshot.text)
        _preferences = State(initialValue: DictationPreferencesStore.load(userID: userID))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 200)
                        .accessibilityLabel("Edit transcript")
                } header: {
                    Text("Transcript")
                } footer: {
                    Text("Saving updates History on this device; text already inserted in another app stays as it is.")
                }
                if preferences.learnFromCorrections {
                    Section {
                        ForEach($suggestions) { $suggestion in
                            Toggle(isOn: $suggestion.isSelected) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.written)
                                    Text(suggestion.heard.map { "Fixes “\($0)” in new transcripts" } ?? "Helps recognize this word")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        TextField("Add another word or name", text: $manualWord)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("Learn from this edit")
                    } footer: {
                        Text(suggestions.isEmpty
                             ? "Fix a misheard word or name above, and VoiceType suggests what to remember."
                             : "Only what you turn on is saved. You can change it later in Languages & vocabulary.")
                    }
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
            .task(id: text) { await suggest() }
        }
    }

    private func suggest() async {
        let original = snapshot.text, edited = text, preferences = preferences
        guard preferences.learnFromCorrections, original != edited else {
            suggestions = []
            return
        }
        if edited != initialText {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        let found = await Task.detached(priority: .userInitiated) {
            preferences.correctionSuggestions(original: original, edited: edited)
        }.value
        guard !Task.isCancelled else { return }
        // Keep the user's choices while they continue editing.
        let choices = Dictionary(suggestions.map { ($0.id, $0.isSelected) }, uniquingKeysWith: { first, _ in first })
        suggestions = found.map { suggestion in
            var suggestion = suggestion
            suggestion.isSelected = choices[suggestion.id] ?? suggestion.isSelected
            return suggestion
        }
    }

    private func save() {
        if preferences.learnFromCorrections {
            var latest = DictationPreferencesStore.load(userID: userID)
            let manual = manualWord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard manual.isEmpty || DictationPreferences.isValidEntry(manual) else {
                error = "Use 2–40 characters on one line for the word to remember."
                return
            }
            let chosen = suggestions.filter(\.isSelected)
            let added = Set((chosen.map(\.written) + [manual]).filter { !$0.isEmpty }.map(DictationPreferences.key))
                .subtracting(latest.words.map(\.id))
            guard latest.words.count + added.count <= DictationPreferences.maximumWords else {
                error = "Your vocabulary is full. Turn off a suggestion, or remove saved words in Languages & vocabulary."
                return
            }
            for suggestion in chosen.reversed() {
                latest.remember(suggestion.written, learned: true, heardAs: suggestion.heard)
            }
            if !manual.isEmpty { latest.remember(manual, learned: true) }
            DictationPreferencesStore.save(latest, userID: userID)
        }
        let updated = TranscriptSnapshot(id: snapshot.id, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                         createdAt: snapshot.createdAt, chargeText: snapshot.chargeText)
        // Never republish latest: doing so could insert an edited old clip in an unrelated field.
        SharedTranscriptStore.history = SharedTranscriptStore.history.map { $0.id == updated.id ? updated : $0 }
        onSave()
        dismiss()
    }
}

/// Lets the user choose how recordings become text, and the models that do
/// it: a live model while they speak, and an upload model for every other
/// recording, including a live one the service couldn't take.
struct TranscriptionModelSettingsView: View {
    let userID: String
    private let refreshCatalog: @MainActor () async -> TranscriptionModelCatalog?
    @State private var catalog: TranscriptionModelCatalog?
    @State private var mode: TranscriptionMode
    @State private var selection: String?
    @State private var liveSelection: String?
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    init(
        userID: String,
        catalog: TranscriptionModelCatalog? = TranscriptionModelCatalogStore.load(),
        refreshCatalog: @escaping @MainActor () async -> TranscriptionModelCatalog? = { await TranscriptionModelCatalogStore.refresh() }
    ) {
        self.userID = userID
        self.refreshCatalog = refreshCatalog
        let preferences = DictationPreferencesStore.load(userID: userID)
        _catalog = State(initialValue: catalog)
        _mode = State(initialValue: preferences.mode)
        _selection = State(initialValue: preferences.model)
        _liveSelection = State(initialValue: preferences.liveModel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(TranscriptionMode.allCases) { option in
                        choice(Self.title(for: option), detail: Self.caption(for: option), isSelected: mode == option) {
                            update { $0.mode = option }
                            mode = option
                        }
                    }
                } header: {
                    Text("Mode")
                } footer: {
                    if let note = modeNote { Text(note) }
                }
                if mode == .live, let live = Self.offeredLive(in: catalog) {
                    Section {
                        choice("Automatic", detail: Self.automaticDetail(for: live), isSelected: effectiveLiveSelection == nil) {
                            update { $0.liveModel = nil }
                            liveSelection = nil
                        }
                        ForEach(live.models) { model in
                            choice(model.name, detail: Self.detail(for: model), isSelected: effectiveLiveSelection == model.id) {
                                update { $0.liveModel = model.id }
                                liveSelection = model.id
                            }
                        }
                    } header: {
                        Text("Live model")
                    } footer: {
                        Text(Self.liveFooter)
                    }
                }
                Section {
                    choice("Automatic", detail: catalog.map { "Uses the service default, currently \($0.defaultModelName)." }
                           ?? "Uses the service default.", isSelected: effectiveSelection == nil) {
                        update { $0.model = nil }
                        selection = nil
                    }
                    if let catalog {
                        ForEach(catalog.models) { model in
                            choice(model.name, detail: Self.detail(for: model), isSelected: effectiveSelection == model.id) {
                                update { $0.model = model.id }
                                selection = model.id
                            }
                        }
                    } else if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading models…").foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Couldn't load models. Try again") { Task { await load() } }
                    }
                } header: {
                    Text(mode == .live ? "Upload model" : "Model")
                } footer: {
                    Text((mode == .live ? "Used when Live can't be. " : "")
                         + "Applies to new recordings; a retry keeps the model it was recorded with. Prices are estimates, and each transcript shows its actual charge.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .tint(AppTheme.coral)
            .navigationTitle("Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    /// A choice the service no longer lists is treated as Automatic, as it is
    /// when recording.
    private var effectiveSelection: String? {
        guard let selection, catalog?.models.contains(where: { $0.id == selection }) == true else { return nil }
        return selection
    }

    private var effectiveLiveSelection: String? {
        guard let liveSelection,
              Self.offeredLive(in: catalog)?.models.contains(where: { $0.id == liveSelection }) == true else { return nil }
        return liveSelection
    }

    /// Hidden while the first catalog loads, so it doesn't flash.
    private var modeNote: String? {
        guard catalog != nil || !isLoading else { return nil }
        return Self.note(for: mode, model: effectiveSelection, in: catalog)
    }

    private func choice(_ title: String, detail: String, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(AppTheme.ink)
                    Text(detail).font(.caption).foregroundStyle(AppTheme.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(AppTheme.coral)
                }
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Saves one choice and keeps the other preferences as they are.
    private func update(_ change: (inout DictationPreferences) -> Void) {
        var preferences = DictationPreferencesStore.load(userID: userID)
        change(&preferences)
        DictationPreferencesStore.save(preferences, userID: userID)
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let fresh = await refreshCatalog() { catalog = fresh }
    }

    static func title(for mode: TranscriptionMode) -> String {
        switch mode {
        case .afterRecording: "After recording"
        case .streaming: "Streaming"
        case .live: "Live"
        }
    }

    static func caption(for mode: TranscriptionMode) -> String {
        switch mode {
        case .afterRecording: "Uploads when you stop. The text appears all at once."
        case .streaming: "Uploads when you stop. The text appears as it's transcribed."
        case .live: "Sends audio while you speak, so the text appears as you talk. Costs more."
        }
    }

    static let liveFooter = "Live sends about 3 MB of audio a minute. Audio sent is charged at the live price, even if you cancel or the connection drops; if Live can't finish, the recording is also uploaded and charged with the model below. Low Data Mode uploads instead. OpenAI may keep live audio for up to 30 days for abuse monitoring."

    /// The live models a new recording can use, or nil when it will be
    /// uploaded instead, as `DictationPreferences.resolvedLiveModel` decides.
    static func offeredLive(in catalog: TranscriptionModelCatalog?) -> RealtimeTranscriptionCatalog? {
        guard let live = catalog?.realtime, live.available, !live.models.isEmpty else { return nil }
        return live
    }

    /// What happens instead when the chosen mode can't work as its caption
    /// says; nil when it can.
    static func note(for mode: TranscriptionMode, model: String?, in catalog: TranscriptionModelCatalog?) -> String? {
        var notes: [String] = []
        var streams = mode == .streaming
        if mode == .live, offeredLive(in: catalog) == nil {
            notes.append(catalog == nil
                ? "Live needs the service's model list. Until it loads, recordings upload when you stop."
                : "Live isn't available right now, so recordings upload when you stop.")
            streams = true
        }
        if streams, let catalog, !catalog.streamsPartialText(for: model) {
            let name = model.flatMap { id in catalog.models.first { $0.id == id }?.name } ?? catalog.defaultModelName
            notes.append("\(name) doesn't stream, so its text appears when it's done.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    static func automaticDetail(for live: RealtimeTranscriptionCatalog) -> String {
        guard let model = live.models.first(where: { $0.id == live.defaultModel }) ?? live.models.first else {
            return "Uses the service default."
        }
        return "Uses the service default, currently \(model.name)."
    }

    static func detail(for model: TranscriptionModelOption) -> String {
        var parts = model.recommended ? ["Recommended"] : []
        parts.append("About \(model.formattedPerMinute)")
        if let retirement = retirement(model.retiresOn) { parts.append(retirement) }
        return parts.joined(separator: " · ")
    }

    static func detail(for model: RealtimeTranscriptionModel) -> String {
        var parts = model.recommended ? ["Recommended"] : []
        switch model.textTiming {
        case "while_speaking": parts.append("Text as you speak")
        case "after_pauses": parts.append("Text after each pause")
        default: break
        }
        parts.append("About \(model.formattedPerMinute)")
        if let retirement = retirement(model.retiresOn) { parts.append(retirement) }
        return parts.joined(separator: " · ")
    }

    private static func retirement(_ retiresOn: String?) -> String? {
        guard let retiresOn, let date = try? Date.ISO8601FormatStyle().year().month().day().parse(retiresOn) else { return nil }
        return "Retires " + date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }
}
