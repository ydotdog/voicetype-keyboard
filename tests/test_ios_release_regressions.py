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


def test_keyboard_background_feedback_and_stop_state_are_pinned() -> None:
    keyboard = read("VoiceTypeKeyboard/KeyboardViewController.swift")

    assert "let keyboardBackground = UIColor.voiceType" in keyboard
    assert "view.backgroundColor = palette.keyboardBackground" in keyboard
    assert "inputView?.backgroundColor = palette.keyboardBackground" in keyboard
    assert "contentView.backgroundColor = palette.keyboardBackground" in keyboard
    assert "contentView.backgroundColor = .clear" not in keyboard

    assert "UISelectionFeedbackGenerator" in keyboard
    assert "let immediateFeedback = UIImpactFeedbackGenerator(style: .light)" in keyboard
    assert "let immediateFeedback = UIImpactFeedbackGenerator(style: .medium)" in keyboard
    assert "AudioServicesPlaySystemSound(1519)" in keyboard
    assert "AudioServicesPlaySystemSound(1520)" in keyboard
    assert "for: [.touchDown, .touchDragEnter]" in keyboard

    stop_branch_start = keyboard.index("if viewModel.isKeyboardRecording")
    stop_branch = keyboard[stop_branch_start : keyboard.index("} else if !hasFullAccess", stop_branch_start)]
    assert "setPendingAction(.stoppingClip)" in stop_branch
    assert "updateUI(force: true)" in stop_branch
    assert "RecordingBridgeStore.requestStopClip()" in stop_branch
    assert 'title: "Finishing"' in keyboard


def test_uploaded_build_number_is_current() -> None:
    project = read("project.yml")
    assert "CURRENT_PROJECT_VERSION: 7" in project
