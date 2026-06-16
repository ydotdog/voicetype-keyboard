from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def test_add_credit_cards_are_real_storekit_purchase_entry_points() -> None:
    dashboard = read("VoiceType/Views/DashboardView.swift")
    storekit = read("VoiceType/Services/StoreKitService.swift")

    assert "ForEach(FallbackCreditPack.all)" in dashboard
    assert "CreditPackCard(pack: pack, product: store.product(for: pack.id))" in dashboard
    assert "store.purchase(productID: pack.id, account: account)" in dashboard
    assert "The App Store did not return any credit packs" not in dashboard

    assert "func purchase(productID: String, account: AccountStore) async" in storekit
    assert "await loadProducts()" in storekit
    assert "await purchase(product, account: account)" in storekit
    assert "Product.products(for: ProductIDs.all)" in storekit


def test_settings_rows_keep_full_width_tappable_hit_area() -> None:
    dashboard = read("VoiceType/Views/DashboardView.swift")

    settings_row_start = dashboard.index("private struct SettingsRow")
    settings_row = dashboard[settings_row_start : dashboard.index("#if DEBUG", settings_row_start)]
    assert "Button(action: action)" in settings_row
    assert ".frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)" in settings_row
    assert ".contentShape(Rectangle())" in settings_row
    assert ".buttonStyle(PlainHapticButtonStyle())" in settings_row


def test_keyboard_has_no_extra_globe_and_keeps_app_open_fallbacks() -> None:
    keyboard = read("VoiceTypeKeyboard/KeyboardViewController.swift")

    assert "switchKeyboardButton" not in keyboard
    assert "globe" not in keyboard.lower()
    assert "bottomRow.addArrangedSubview(returnButton)" in keyboard
    assert "bottomRow.addArrangedSubview(deleteButton)" in keyboard

    assert "extensionContext.open(url)" in keyboard
    assert "openURLThroughResponderChain(url)" in keyboard
    assert "openURLThroughApplicationRuntime(url)" in keyboard
    assert "components.scheme = AppConstants.appURLScheme" in keyboard
    assert 'URLQueryItem(name: "autostart", value: "1")' in keyboard

    # The responder-chain path must reach the hosting UIApplication and use the
    # modern open API. The old deprecated perform(openURL:) did not launch the
    # containing app from the keyboard.
    assert "if let application = current as? UIApplication" in keyboard
    assert "application.open(url, options: [:], completionHandler: nil)" in keyboard


def test_keyboard_matches_system_background_feedback_and_stop_state() -> None:
    keyboard = read("VoiceTypeKeyboard/KeyboardViewController.swift")

    # Background must use the real system keyboard material (UIInputView with the
    # .keyboard style) and keep every other layer transparent. A hardcoded color
    # can never match the translucent system keyboard, which caused the seams.
    assert "UIInputView(frame: .zero, inputViewStyle: .keyboard)" in keyboard
    assert "let keyboardBackground = UIColor.voiceType" not in keyboard
    assert "palette.keyboardBackground" not in keyboard
    assert "view.backgroundColor = .clear" in keyboard
    assert "inputView?.backgroundColor = .clear" in keyboard
    assert "contentView.backgroundColor = .clear" in keyboard

    # Haptics fire on touch-down through prepared, reused generators. The old
    # throwaway generators were created and fired the same instant, so the
    # Taptic Engine dropped them. (Keyboard haptics require Full Access.)
    assert "UISelectionFeedbackGenerator" in keyboard
    assert "let immediateFeedback" not in keyboard
    assert "keyFeedback.impactOccurred(intensity: intensity)" in keyboard
    assert "actionFeedback.impactOccurred(intensity: intensity)" in keyboard
    assert "AudioServicesPlaySystemSound(1519)" in keyboard
    assert "AudioServicesPlaySystemSound(1520)" in keyboard
    assert "for: [.touchDown, .touchDragEnter]" in keyboard

    # Tapping Stop must immediately leave the recording look and show the
    # processing state, and must never revert to the "recording" wave while a
    # long clip is still transcribing.
    stop_branch_start = keyboard.index("if viewModel.isKeyboardRecording")
    stop_branch = keyboard[stop_branch_start : keyboard.index("} else if !hasFullAccess", stop_branch_start)]
    assert "setPendingAction(.stoppingClip)" in stop_branch
    assert "updateUI(force: true)" in stop_branch
    assert "RecordingBridgeStore.requestStopClip()" in stop_branch
    assert 'title: "Finishing"' not in keyboard
    assert 'title: "Transcribing"' in keyboard


def test_uploaded_build_number_is_current() -> None:
    project = read("project.yml")
    assert "CURRENT_PROJECT_VERSION: 18" in project


def test_keyboard_clip_keeps_session_alive_across_stops() -> None:
    # After a clip stops, the keyboard mic session must stay ready so the user can
    # speak again, instead of collapsing to "Open VoiceType" the instant they tap
    # Stop. The transcribe window runs under a background task, and the recorder
    # restart reasserts the audio session and retries before giving up.
    controller = read("VoiceType/Services/RecordingController.swift")
    assert 'beginBackgroundTask(withName: "VoiceTypeKeyboardClip")' in controller
    assert "for attempt in 0..<2" in controller
    assert "currentFileURL = nil" in controller
    assert 'recoverKeyboardRecorderIfNeeded(reason: "keyboard clip handoff")' in controller
    assert "try restartKeyboardReadyRecorder()\n            guard isActiveTranscription(id)" not in controller
    assert "shouldKeepTranscribingOnRecoveryFailure" in controller
    assert "stopKeyboardReady(preserveAutoInsert: true)" in controller


def test_keyboard_mic_recovers_from_stale_internal_recorder_state() -> None:
    # The app can stay alive while the underlying AVAudioRecorder has already
    # stopped. In keyboard-ready mode isRecording is false, so the delegate must
    # not ignore that stop, and recurring heartbeats must repair the real recorder
    # before publishing a usable keyboard state.
    controller = read("VoiceType/Services/RecordingController.swift")
    backend = read("VoiceType/Services/BackendClient.swift")
    dashboard = read("VoiceType/Views/DashboardView.swift")

    assert "var isKeyboardSessionActive" in controller
    assert "var isKeyboardReady" in controller
    assert "bridgeMode == .keyboardReady" in controller
    assert "if self.isKeyboardSessionActive" in controller
    assert "recoverKeyboardRecorderIfNeeded(" in controller
    assert "self.recoverKeyboardRecorderIfNeeded(reason:" in controller
    assert "self.recoverKeyboardRecorderIfNeeded(reason: \"keyboard heartbeat\")" in controller
    assert "AVAudioSession.interruptionNotification" in controller
    assert "AVAudioSession.mediaServicesWereResetNotification" in controller
    assert "UIApplication.didBecomeActiveNotification" in controller
    assert "maximumTranscriptionWait" in controller
    assert "activeTranscriptionTask?.cancel()" in controller
    assert "activeTranscriptionID" in controller
    assert "request.timeoutInterval = min(max(duration + 90, 120), 600)" in backend
    assert "publishBridgeState()\n            } else {\n                stopKeyboardReady()" in controller

    keyboard_request = dashboard[dashboard.index("private func handleKeyboardMicRequest") :]
    assert "await recorder.startKeyboardReady(account: account)" in keyboard_request
    assert "recorder.isKeyboardSessionActive" in keyboard_request
    assert 'showToast("VoiceType is finishing your clip.")' in keyboard_request


def test_session_length_limits_the_armed_keyboard_mic_lifetime() -> None:
    # "Session length" is the lifetime of the armed keyboard mic session, measured
    # from Turn on keyboard mic. It is not reset when the picker changes, and it is
    # separate from the model-facing max length of a single Speak clip.
    controller = read("VoiceType/Services/RecordingController.swift")

    start = controller.index("private func stopIfDurationLimitReached")
    end = controller.index("\n    private func ", start + len("private func stopIfDurationLimitReached"))
    body = controller[start:end]

    assert "Date().timeIntervalSince(startedAt) >= maximumDuration" in body
    assert "await stopKeyboardSessionForDurationLimit()" in body
    assert "recorder.currentTime - clipStartTime >= Self.maximumKeyboardClipDuration" in body
    assert "private static let maximumKeyboardClipDuration: TimeInterval = 10 * 60" in controller
    assert "shouldStopKeyboardSessionAfterCurrentClip = true" in controller

    session_limit_start = controller.index("private func stopKeyboardSessionForDurationLimit")
    session_limit_end = controller.index("\n    private func ", session_limit_start + len("private func stopKeyboardSessionForDurationLimit"))
    session_limit_body = controller[session_limit_start:session_limit_end]
    assert "case .keyboardReady:" in session_limit_body
    assert "stopKeyboardReady()" in session_limit_body

    # Changing the session length re-verifies the live recorder before publishing,
    # so it can never broadcast a stale ready over a dead recorder.
    assert 'recoverKeyboardRecorderIfNeeded(reason: "session length changed")' in controller
    # A Stop with no live clip recovers the armed mic instead of silently returning.
    assert 'recoverKeyboardRecorderIfNeeded(reason: "stop clip with no active clip")' in controller


def test_keyboard_mic_live_activity_is_configured() -> None:
    project = read("project.yml")
    info = read("VoiceType/Info.plist")
    controller = read("VoiceType/Services/RecordingController.swift")
    widget = read("VoiceTypeLiveActivity/VoiceTypeKeyboardLiveActivity.swift")

    assert "NSSupportsLiveActivities: true" in project
    assert "<key>NSSupportsLiveActivities</key>\n\t<true/>" in info
    assert "VoiceTypeLiveActivity" in project
    assert "KeyboardMicLiveActivityController.shared.update" in controller
    assert "KeyboardMicLiveActivityController.shared.end" in controller
    assert "private var liveActivityEpoch: UInt64" in controller
    assert "nextLiveActivityEpoch()" in controller
    assert "epoch: epoch" in controller
    assert "glassEffect(" in widget
    assert "VoiceTypeActivityLogo" in widget
    assert "barHeights" in widget
    assert "VoiceTypeActivityGlassPanel" in widget
    assert "VoiceTypeActivityStatusDot" in widget
    assert "containerBackground(for: .widget)" in widget
    assert "readabilityScrim" in widget
    assert "VoiceTypeActivityIslandStatus" in widget
    assert "islandSubtitle" in widget
    assert "VoiceTypeActivityTimerPill" not in widget
    assert "VoiceTypeActivityTimer" not in widget
    assert "Text(startedAt, style: .timer)" not in widget
    assert "DynamicIslandExpandedRegion(.trailing)" in widget
    assert ".frame(minWidth: 86, alignment: .trailing)" in widget
    assert "func voiceTypeGlass" not in widget
    assert "compactLeading" in widget
    assert "minimal" in widget

    live_activity_controller = read("VoiceType/Services/KeyboardMicLiveActivityController.swift")
    assert "private var latestEpoch: UInt64" in live_activity_controller
    assert "private var operationChain: Task<Void, Never>?" in live_activity_controller
    assert "await serialize(epoch: epoch)" in live_activity_controller
    assert "guard epoch >= self.latestEpoch else { return }" in live_activity_controller

    compact_start = widget.index("private struct VoiceTypeActivityCompactStatus")
    compact_end = widget.index("\nprivate struct VoiceTypeActivityGlassPanel", compact_start)
    compact_body = widget[compact_start:compact_end]
    assert "VoiceTypeActivityStatusDot" in compact_body
    assert "VoiceTypeActivityTimer" not in compact_body


def test_keyboard_switcher_name_is_voicetype_without_suffix() -> None:
    # In the globe/keyboard switcher the extension must read just "VoiceType",
    # dropping the old "VoiceType Keyboard" display name. xcodegen regenerates
    # the keyboard Info.plist from project.yml, so both must agree.
    project = read("project.yml")
    info = read("VoiceTypeKeyboard/Info.plist")

    assert "VoiceType Keyboard" not in project
    assert "VoiceType Keyboard" not in info
    assert "<key>CFBundleDisplayName</key>\n\t<string>VoiceType</string>" in info


def test_keyboard_switcher_has_no_language_subtitle() -> None:
    # The globe/keyboard switcher renders a language line under the name, derived
    # from PrimaryLanguage. Setting it to "mul" (the ISO 639 code for "multiple
    # languages") suppresses that "English" subtitle while the keyboard stays
    # ASCII-capable. xcodegen regenerates the Info.plist from project.yml.
    project = read("project.yml")
    info = read("VoiceTypeKeyboard/Info.plist")

    assert "PrimaryLanguage: mul" in project
    assert "PrimaryLanguage: en-US" not in project
    assert "<key>PrimaryLanguage</key>" in info
    assert "<string>mul</string>" in info
    assert "<string>en-US</string>" not in info
