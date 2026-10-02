import UIKit
import SwiftUI

@MainActor
class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    private let viewModel = KeyboardViewModel()
    private(set) var refreshTimer: Timer?
    private var lastStateRefreshAt: TimeInterval = 0
    private var pendingAction: PendingKeyboardAction?
    private var pendingActionStartedAt: Date?
    private var actionNotice: String?
    private let pendingActionTimeout: TimeInterval = 4

    private let backdropView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
    private let contentView = UIView()
    private let topRow = UIStackView()
    private let brandStack = UIStackView()
    private let markView = KeyboardMarkView()
    private let wordmarkLabel = UILabel()
    private let promptLabel = UILabel()
    private let actionControl = KeyboardActionControl()
    private let actionStack = UIStackView()
    private let micImageView = UIImageView()
    private let actionTitleLabel = UILabel()
    private let waveStack = UIStackView()
    private var waveHeights: [NSLayoutConstraint] = []
    private var waveLevels = Array(repeating: CGFloat.zero, count: 10)
    private var waveSessionID: String?
    private var waveUpdatedAt: Date?
    private let helperLabel = UILabel()
    private var openAppController: UIHostingController<KeyboardOpenAppLink>?
    private(set) var keyboardActivationURL: URL?
    private var activationPreparedAt: TimeInterval?
    private var issuedActivationURLs: [URL] = []
    private let bottomRow = UIStackView()
    private let returnButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let nextKeyboardButton = UIButton(type: .system)
    private let keyFeedback = UIImpactFeedbackGenerator(style: .light)
    private let actionFeedback = UIImpactFeedbackGenerator(style: .medium)
    private var deleteRepeatTimer: Timer?
    private var deleteRepeatDocumentIdentifier: UUID?
    private var styleTraitRegistration: UITraitChangeRegistration?
    private var renderedUIState: KeyboardUIState?
    private var isKeyboardVisible = false
    private var activeDocumentIdentifier: UUID?
    private var insertionDocumentIdentifier: UUID?
    private var keyboardHeightConstraint: NSLayoutConstraint?
    private var helperHeightConstraint: NSLayoutConstraint?

    private let palette = KeyboardPalette()
    private let keyboardHeight: CGFloat = 160

    var enableInputClicksWhenVisible: Bool {
        true
    }

    isolated deinit {
        // A host can tear down its extension without a disappearance callback.
        // The run loop retains scheduled timers even when their owner is gone.
        refreshTimer?.invalidate()
        deleteRepeatTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        styleTraitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (controller: KeyboardViewController, _: UITraitCollection) in
            controller.applyPalette()
            controller.updateUI(force: true)
        }
        setupKeyboard()
        refreshKeyboardState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshKeyboardState()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshKeyboardState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isKeyboardVisible = true
        // Returning after a previous launch gets a fresh single-use capability.
        keyboardActivationURL = nil
        activationPreparedAt = nil
        refreshKeyboardState()
        prepareHaptics()
        startRefreshing()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
        updateKeyboardChrome()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isKeyboardVisible = false
        activeDocumentIdentifier = nil
        stopDeleteRepeat()
        stopRefreshing()
        resetWaveform()
        // Sever auto-insert when the keyboard leaves this field so a transcript
        // finished later cannot land in another app's text field.
        clearAutoInsert()
        setPendingAction(nil)
    }

    private func applyKeyboardAppearanceOverride() {
        guard activeDocumentIdentifier != nil else { return }
        let style: UIUserInterfaceStyle
        switch textDocumentProxy.keyboardAppearance ?? .default {
        case .dark:
            style = .dark
        case .light:
            style = .light
        default:
            style = .unspecified
        }
        guard overrideUserInterfaceStyle != style else { return }
        overrideUserInterfaceStyle = style
    }

    private func setupKeyboard() {
        // Match the system keyboard exactly by rendering the real keyboard
        // material (UIInputView with the .keyboard style) behind everything and
        // keeping every other layer transparent. A hardcoded color can never
        // match the translucent system background, which is what produced the
        // visible color seams against the system keyboard chrome and top edge.
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
        inputView?.backgroundColor = .clear
        view.insetsLayoutMarginsFromSafeArea = false

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropView)
        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let height = view.heightAnchor.constraint(equalToConstant: keyboardHeight)
        height.priority = .defaultHigh
        height.isActive = true
        keyboardHeightConstraint = height

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = .clear
        contentView.layer.cornerCurve = .continuous
        contentView.layer.maskedCorners = []
        contentView.layer.masksToBounds = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        setupTopRow()
        setupActionArea()
        setupOpenAppLink()
        setupBottomRow()
        applyPalette()
    }

    private func updateKeyboardChrome() {
        contentView.layer.cornerRadius = 0
        view.backgroundColor = .clear
        inputView?.backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    private func applyPalette() {
        view.backgroundColor = .clear
        inputView?.backgroundColor = .clear
        contentView.backgroundColor = .clear
        wordmarkLabel.attributedText = wordmark()
        promptLabel.textColor = palette.inkSoft
        helperLabel.textColor = palette.muted
        actionTitleLabel.textColor = palette.keySurface
        returnButton.backgroundColor = palette.keySurface
        returnButton.setTitleColor(palette.ink, for: .normal)
        deleteButton.backgroundColor = palette.keyGray
        deleteButton.tintColor = palette.inkSoft
        nextKeyboardButton.backgroundColor = palette.keyGray
        nextKeyboardButton.tintColor = palette.inkSoft
        for bar in waveStack.arrangedSubviews {
            bar.backgroundColor = palette.live
        }
        markView.setNeedsDisplay()
    }

    private func setupTopRow() {
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 12
        topRow.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topRow)

        brandStack.axis = .horizontal
        brandStack.alignment = .center
        brandStack.spacing = 8
        brandStack.addArrangedSubview(markView)
        brandStack.addArrangedSubview(wordmarkLabel)
        markView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            markView.widthAnchor.constraint(equalToConstant: 30),
            markView.heightAnchor.constraint(equalToConstant: 25)
        ])

        wordmarkLabel.attributedText = wordmark()
        wordmarkLabel.textColor = palette.ink
        wordmarkLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        topRow.addArrangedSubview(brandStack)

        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            topRow.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -18),
            topRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            topRow.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    private func setupActionArea() {
        promptLabel.font = .systemFont(ofSize: 24, weight: .regular)
        promptLabel.textColor = palette.inkSoft
        promptLabel.textAlignment = .center
        promptLabel.adjustsFontSizeToFitWidth = true
        promptLabel.minimumScaleFactor = 0.72
        promptLabel.isHidden = true
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(promptLabel)

        actionControl.translatesAutoresizingMaskIntoConstraints = false
        actionControl.layer.cornerCurve = .continuous
        actionControl.layer.cornerRadius = 24
        actionControl.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        installActionPressFeedback(on: actionControl)
        actionControl.isAccessibilityElement = true
        actionControl.accessibilityTraits = .button
        actionControl.accessibilityIdentifier = "keyboard.primaryAction"
        contentView.addSubview(actionControl)

        actionStack.axis = .horizontal
        actionStack.alignment = .center
        actionStack.distribution = .fill
        actionStack.spacing = 9
        actionStack.isUserInteractionEnabled = false
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionControl.addSubview(actionStack)
        NSLayoutConstraint.activate([
            actionStack.centerXAnchor.constraint(equalTo: actionControl.centerXAnchor),
            actionStack.centerYAnchor.constraint(equalTo: actionControl.centerYAnchor),
            actionStack.leadingAnchor.constraint(greaterThanOrEqualTo: actionControl.leadingAnchor, constant: 22),
            actionStack.trailingAnchor.constraint(lessThanOrEqualTo: actionControl.trailingAnchor, constant: -22)
        ])

        micImageView.contentMode = .scaleAspectFit
        micImageView.isUserInteractionEnabled = false
        micImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            micImageView.widthAnchor.constraint(equalToConstant: 24),
            micImageView.heightAnchor.constraint(equalToConstant: 24)
        ])

        actionTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        actionTitleLabel.textColor = palette.keySurface
        actionTitleLabel.adjustsFontSizeToFitWidth = true
        actionTitleLabel.minimumScaleFactor = 0.72
        actionTitleLabel.isUserInteractionEnabled = false
        actionTitleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        waveStack.axis = .horizontal
        waveStack.alignment = .center
        waveStack.distribution = .equalCentering
        waveStack.spacing = 5
        waveStack.isUserInteractionEnabled = false
        waveStack.accessibilityElementsHidden = true
        waveStack.accessibilityIdentifier = "keyboard.audioWaveform"
        waveStack.translatesAutoresizingMaskIntoConstraints = false
        waveStack.heightAnchor.constraint(equalToConstant: 34).isActive = true
        for index in waveLevels.indices {
            let bar = UIView()
            bar.backgroundColor = palette.live
            bar.layer.cornerCurve = .continuous
            bar.layer.cornerRadius = 2
            bar.isUserInteractionEnabled = false
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.accessibilityIdentifier = "keyboard.audioLevel.\(index)"
            let height = bar.heightAnchor.constraint(equalToConstant: 3.5)
            waveHeights.append(height)
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 3.5),
                height
            ])
            waveStack.addArrangedSubview(bar)
        }

        // Normal states need no footnote. Keep failures/permission guidance
        // visible and accessible instead of hiding actionable errors.
        helperLabel.font = .systemFont(ofSize: 13, weight: .medium)
        helperLabel.textColor = palette.muted
        helperLabel.textAlignment = .center
        helperLabel.numberOfLines = 2
        helperLabel.adjustsFontSizeToFitWidth = true
        helperLabel.minimumScaleFactor = 0.72
        helperLabel.translatesAutoresizingMaskIntoConstraints = false
        helperLabel.accessibilityIdentifier = "keyboard.helper"
        contentView.addSubview(helperLabel)

        let actionWidth = actionControl.widthAnchor.constraint(equalToConstant: 224)
        actionWidth.priority = .defaultHigh
        let helperHeight = helperLabel.heightAnchor.constraint(equalToConstant: 0)
        helperHeightConstraint = helperHeight

        NSLayoutConstraint.activate([
            promptLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            promptLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            promptLabel.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 7),
            promptLabel.heightAnchor.constraint(equalToConstant: 0),

            helperLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            helperLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            helperLabel.topAnchor.constraint(equalTo: actionControl.bottomAnchor, constant: 4),
            helperHeight,

            actionControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            actionControl.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            actionControl.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            actionWidth,
            actionControl.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 18),
            actionControl.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func setupBottomRow() {
        bottomRow.axis = .horizontal
        bottomRow.alignment = .center
        bottomRow.distribution = .fill
        bottomRow.spacing = 12
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomRow)

        configureTextKey(returnButton, text: "return", accessibilityLabel: "Return")
        returnButton.accessibilityIdentifier = "keyboard.return"
        installKeyPressFeedback(on: returnButton)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        returnButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        returnButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconKey(deleteButton, systemName: "delete.left", accessibilityLabel: "Delete")
        deleteButton.accessibilityIdentifier = "keyboard.delete"
        installKeyPressFeedback(on: deleteButton)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let deleteLongPress = UILongPressGestureRecognizer(target: self, action: #selector(deleteLongPressed(_:)))
        deleteLongPress.minimumPressDuration = 0.35
        deleteButton.addGestureRecognizer(deleteLongPress)

        configureIconKey(nextKeyboardButton, systemName: "globe", accessibilityLabel: "Next keyboard")
        nextKeyboardButton.accessibilityIdentifier = "keyboard.nextKeyboard"
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
        bottomRow.addArrangedSubview(nextKeyboardButton)
        bottomRow.addArrangedSubview(returnButton)
        bottomRow.addArrangedSubview(deleteButton)

        // UIStackView gives hidden arranged views a required zero width.
        let globeWidth = nextKeyboardButton.widthAnchor.constraint(equalToConstant: 44)
        globeWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            bottomRow.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            bottomRow.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 18),
            bottomRow.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -18),
            bottomRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            bottomRow.heightAnchor.constraint(equalToConstant: 44),

            globeWidth,
            nextKeyboardButton.heightAnchor.constraint(equalToConstant: 44),
            returnButton.widthAnchor.constraint(equalToConstant: 160),
            returnButton.heightAnchor.constraint(equalToConstant: 44),
            deleteButton.widthAnchor.constraint(equalToConstant: 44),
            deleteButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func setupOpenAppLink() {
        // A real user-tapped SwiftUI Link uses the system URL action. Keep it
        // beside the UIKit control, whose hitTest intentionally captures taps.
        let controller = UIHostingController(rootView: makeOpenAppLink())
        openAppController = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .clear
        controller.view.accessibilityIdentifier = "keyboard.openApp"
        contentView.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: actionControl.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: actionControl.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: actionControl.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: actionControl.bottomAnchor)
        ])
        controller.didMove(toParent: self)
    }

    private func makeOpenAppLink() -> KeyboardOpenAppLink {
        KeyboardOpenAppLink(destination: keyboardActivationURL ?? URL(string: "voicetype://keyboard")!) { [weak self] in
            self?.playActionFeedback()
        }
    }

    private func refreshOpenAppActivation() {
        guard hasFullAccess, !viewModel.isKeyboardReady, !viewModel.isKeyboardRecording,
              !viewModel.isTranscribing, pendingAction == nil else {
            issuedActivationURLs.forEach { KeyboardMicActivationStore.shared.revoke($0) }
            issuedActivationURLs.removeAll()
            keyboardActivationURL = nil
            activationPreparedAt = nil
            return
        }
        guard isKeyboardVisible, viewIfLoaded?.window != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let activationPreparedAt, now - activationPreparedAt >= 0,
           now - activationPreparedAt < 30 { return }
        activationPreparedAt = now
        keyboardActivationURL = KeyboardMicActivationStore.shared.makeURL(uptime: now)
        if let keyboardActivationURL { issuedActivationURLs.append(keyboardActivationURL) }
        // Retain the previous URL briefly: rotating the Link while a finger or
        // VoiceOver is on it must not invalidate an in-flight system open.
        while issuedActivationURLs.count > 4 {
            KeyboardMicActivationStore.shared.revoke(issuedActivationURLs.removeFirst())
        }
        openAppController?.rootView = makeOpenAppLink()
    }

    private func configureIconKey(_ button: UIButton, systemName: String, accessibilityLabel: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = palette.keyGray
        button.tintColor = palette.inkSoft
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 22
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.accessibilityLabel = accessibilityLabel
    }

    private func configureTextKey(_ button: UIButton, text: String, accessibilityLabel: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = palette.keySurface
        button.tintColor = palette.ink
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 22
        button.setTitle(text, for: .normal)
        button.setTitleColor(palette.ink, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .regular)
        button.accessibilityLabel = accessibilityLabel
    }

    private func wordmark() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3)
            .withDesign(.serif) ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3)
        let voiceFont = UIFont(descriptor: base.withSymbolicTraits([]) ?? base, size: 20)
        let typeFont = UIFont(descriptor: base.withSymbolicTraits(.traitItalic) ?? base, size: 20)
        result.append(NSAttributedString(string: "Voice", attributes: [.font: voiceFont, .foregroundColor: palette.ink]))
        result.append(NSAttributedString(string: "Type", attributes: [.font: typeFont, .foregroundColor: palette.ink]))
        return result
    }

    private func prepareHaptics() {
        keyFeedback.prepare()
        actionFeedback.prepare()
    }

    // Haptics inside a keyboard extension only fire when the user has granted
    // "Allow Full Access". With it on, the pre-prepared impact generator is the
    // reliable signal; the input click and system actuation are supplements.
    // (The old code created a throwaway generator and fired it the same instant
    // it was prepared, which the Taptic Engine drops, so it added nothing.)
    private func playKeyFeedback(intensity: CGFloat = 0.85) {
        keyFeedback.impactOccurred(intensity: intensity)
        keyFeedback.prepare()
        UIDevice.current.playInputClick()
    }

    private func playActionFeedback(intensity: CGFloat = 0.9) {
        actionFeedback.impactOccurred(intensity: intensity)
        actionFeedback.prepare()
        UIDevice.current.playInputClick()
    }

    private func installKeyPressFeedback(on control: UIControl) {
        control.addTarget(self, action: #selector(keyPressBegan(_:)), for: [.touchDown, .touchDragEnter])
        control.addTarget(
            self,
            action: #selector(pressEnded(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    private func installActionPressFeedback(on control: UIControl) {
        control.addTarget(self, action: #selector(actionPressBegan(_:)), for: [.touchDown, .touchDragEnter])
        control.addTarget(
            self,
            action: #selector(pressEnded(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    @objc private func keyPressBegan(_ sender: UIControl) {
        playKeyFeedback()
        setPressed(true, for: sender)
    }

    @objc private func actionPressBegan(_ sender: UIControl) {
        playActionFeedback()
        setPressed(true, for: sender)
    }

    @objc private func pressEnded(_ sender: UIControl) {
        setPressed(false, for: sender)
    }

    private func setPressed(_ isPressed: Bool, for control: UIControl) {
        if UIAccessibility.isReduceMotionEnabled {
            control.transform = .identity
            control.alpha = isPressed ? 0.82 : 1
            return
        }
        UIView.animate(
            withDuration: isPressed ? 0.08 : 0.14,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            control.transform = isPressed ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
            control.alpha = isPressed ? 0.82 : 1
        }
    }

    private func startRefreshing() {
        let interval: TimeInterval = shouldShowLiveWaveform ? 0.05 : 0.25
        guard refreshTimer?.isValid != true || refreshTimer?.timeInterval != interval else { return }
        stopRefreshing()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.shouldShowLiveWaveform,
                   ProcessInfo.processInfo.systemUptime - self.lastStateRefreshAt < 0.25 {
                    self.updateWaveform()
                } else {
                    self.refreshKeyboardState()
                }
            }
        }
        refreshTimer = timer
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
    }

    private var shouldShowLiveWaveform: Bool {
        isKeyboardVisible && hasFullAccess && viewModel.isKeyboardRecording
            && viewModel.recordingState.isRecording && pendingAction != .stoppingClip
    }

    private func updateWaveform() {
        guard shouldShowLiveWaveform else {
            resetWaveform()
            return
        }
        let state = viewModel.recordingState
        guard let sample = RecordingAudioLevelStore.latest(for: state.sessionID) else {
            // A stalled producer must not leave a frozen "live" sound signal.
            resetWaveform()
            return
        }
        if waveSessionID != state.sessionID {
            resetWaveform()
            waveSessionID = state.sessionID
        }
        guard waveUpdatedAt != sample.date else { return }
        waveUpdatedAt = sample.date
        let level = CGFloat(sample.level)
        if level == 0 {
            waveLevels = Array(repeating: 0, count: waveLevels.count)
        } else {
            waveLevels.removeFirst()
            waveLevels.append(level)
        }
        renderWaveform(animated: true)
    }

    private func resetWaveform() {
        waveSessionID = nil
        waveUpdatedAt = nil
        guard waveLevels.contains(where: { $0 != 0 }) else { return }
        waveLevels = Array(repeating: 0, count: waveLevels.count)
        waveStack.layer.removeAllAnimations()
        waveStack.arrangedSubviews.forEach { $0.layer.removeAllAnimations() }
        renderWaveform(animated: false)
    }

    private func renderWaveform(animated: Bool) {
        for (constraint, level) in zip(waveHeights, waveLevels) {
            constraint.constant = 3.5 + 30.5 * level
        }
        // Interpolate between measured samples only. There is no repeating or
        // random animation, and VoiceOver keeps the same accessible Stop action.
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.06, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction, .curveLinear]) {
                self.waveStack.layoutIfNeeded()
            }
        } else {
            UIView.performWithoutAnimation { self.waveStack.layoutIfNeeded() }
        }
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @MainActor
    private func refreshKeyboardState() {
        lastStateRefreshAt = ProcessInfo.processInfo.systemUptime
        updateDocumentContext()
        let wasKeyboardReady = viewModel.isKeyboardReady
        viewModel.refresh()
        if viewModel.isKeyboardReady && hasFullAccess {
            if !wasKeyboardReady { actionNotice = nil }
        }
        if !hasFullAccess { clearAutoInsert() }
        applyKeyboardAppearanceOverride()
        updateReturnKey()
        clearResolvedPendingAction()
        updateUI()
        guard hasFullAccess, !viewModel.isRecording, let insertionDocumentIdentifier else { return }
        guard let identifier = visibleDocumentIdentifier(),
              insertionDocumentIdentifier == identifier, identifier == activeDocumentIdentifier else {
            clearAutoInsert()
            updateDocumentContext()
            updateUI()
            return
        }
        guard KeyboardAutoInsertStore.claimForInsert(viewModel.snapshot) else { return }
        textDocumentProxy.insertText(viewModel.snapshot.text)
        self.insertionDocumentIdentifier = nil
    }

    private func visibleDocumentIdentifier() -> UUID? {
        guard isKeyboardVisible, viewIfLoaded?.window != nil else { return nil }
        // Do not read textDocumentProxy.documentIdentifier in Swift: UIKit may
        // return nil during startup/field changes despite its nonnull contract.
        return VTKeyboardDocumentIdentifier(self) as UUID?
    }

    private func updateDocumentContext() {
        let identifier = visibleDocumentIdentifier()
        if identifier == nil || activeDocumentIdentifier != identifier {
            clearAutoInsert()
            stopDeleteRepeat()
            setPendingAction(nil)
        }
        activeDocumentIdentifier = identifier
    }

    private func armAutoInsert() -> Bool {
        updateDocumentContext()
        guard let identifier = activeDocumentIdentifier else { return false }
        insertionDocumentIdentifier = identifier
        KeyboardAutoInsertStore.arm(baselineTranscriptID: viewModel.snapshot.id)
        return true
    }

    private func clearAutoInsert() {
        insertionDocumentIdentifier = nil
        KeyboardAutoInsertStore.clear()
    }

    private func updateReturnKey() {
        guard activeDocumentIdentifier != nil else { return }
        let title: String
        switch textDocumentProxy.returnKeyType ?? .default {
        case .go: title = "go"
        case .google, .search, .yahoo: title = "search"
        case .join: title = "join"
        case .next: title = "next"
        case .route: title = "route"
        case .send: title = "send"
        case .done: title = "done"
        case .emergencyCall: title = "call"
        case .continue: title = "continue"
        default: title = "return"
        }
        returnButton.setTitle(title, for: .normal)
        returnButton.accessibilityLabel = title.capitalized
    }

    private func updateUI(force: Bool = false) {
        updateWaveform()
        refreshOpenAppActivation()
        if isKeyboardVisible { startRefreshing() }
        let uiState = KeyboardUIState(
            pendingAction: pendingAction,
            isKeyboardRecording: viewModel.isKeyboardRecording,
            isTranscribing: viewModel.isTranscribing,
            isKeyboardReady: viewModel.isKeyboardReady,
            hasFullAccess: hasFullAccess,
            hasDocumentContext: activeDocumentIdentifier != nil,
            notice: actionNotice
        )
        guard force || uiState != renderedUIState else { return }
        renderedUIState = uiState

        actionStack.arrangedSubviews.forEach { view in
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let hasDocumentContext = activeDocumentIdentifier != nil
        let canUseBridge = viewModel.isKeyboardReady && hasFullAccess
        let microphoneOff = hasFullAccess && !viewModel.isKeyboardReady
            && !viewModel.isKeyboardRecording && !viewModel.isTranscribing && pendingAction == nil
        openAppController?.view.isHidden = !microphoneOff
        actionControl.isHidden = microphoneOff
        let needsDocument = hasFullAccess && (viewModel.isKeyboardReady || viewModel.isKeyboardRecording)
        actionControl.isEnabled = pendingAction == nil && (!viewModel.isTranscribing || !hasFullAccess)
            && (!needsDocument || hasDocumentContext) && !microphoneOff
        returnButton.isEnabled = hasDocumentContext
        deleteButton.isEnabled = hasDocumentContext
        let helperText = actionNotice ?? defaultHelperText(canUseBridge: canUseBridge, pendingAction: pendingAction)
        helperLabel.text = actionNotice
        helperLabel.isHidden = actionNotice?.isEmpty != false
        // Reserve explanation space only when it is actually needed. Normal
        // recording stays compact, with the waveform near the keyboard center.
        let showsNotice = !helperLabel.isHidden
        helperHeightConstraint?.constant = showsNotice ? 32 : 0
        keyboardHeightConstraint?.constant = keyboardHeight + (showsNotice ? 36 : 0)

        actionControl.accessibilityHint = helperText
        if !hasFullAccess {
            setStatusAction(systemName: "gearshape", title: "Enable Access", accessibilityLabel: "Show Full Access instructions", tintColor: palette.inkSoft)
        } else if pendingAction == .startingClip {
            setStatusAction(systemName: "mic.fill", title: "Starting", accessibilityLabel: "Starting recording", tintColor: palette.live)
        } else if pendingAction == .stoppingClip {
            // The moment the user taps Stop we leave the recording look behind and
            // show the processing state, even before the app confirms. Long clips
            // can take a while to transcribe, so the user must never be left
            // staring at the "recording" wave wondering if it is still capturing.
            setStatusAction(systemName: "waveform", title: "Transcribing", accessibilityLabel: "Transcribing", tintColor: palette.live)
        } else if viewModel.isKeyboardRecording {
            setStatusAction(title: "", accessibilityLabel: "Tap to finish recording", tintColor: palette.live, showsWave: true)
        } else if viewModel.isTranscribing {
            setStatusAction(systemName: "waveform", title: "Transcribing", accessibilityLabel: "Transcribing", tintColor: palette.live)
        } else {
            promptLabel.textColor = palette.inkSoft
            actionControl.backgroundColor = palette.ink
            actionControl.layer.borderWidth = 0
            micImageView.image = UIImage(systemName: "mic.fill")
            micImageView.tintColor = palette.keySurface
            actionTitleLabel.text = ""
            actionTitleLabel.textColor = palette.keySurface
            actionStack.addArrangedSubview(micImageView)

            if !hasFullAccess {
                actionControl.accessibilityLabel = "Enable Full Access for VoiceType Keyboard"
            } else if viewModel.isKeyboardReady {
                actionControl.accessibilityLabel = "Tap to speak"
            } else {
                actionControl.accessibilityLabel = "Microphone off"
            }
        }
    }

    private func setStatusAction(
        systemName: String? = nil,
        title: String,
        accessibilityLabel: String,
        tintColor: UIColor,
        showsWave: Bool = false
    ) {
        actionControl.backgroundColor = palette.keySurface
        actionControl.layer.borderColor = tintColor.withAlphaComponent(0.22).cgColor
        actionControl.layer.borderWidth = 1
        promptLabel.textColor = tintColor
        actionControl.accessibilityLabel = accessibilityLabel
        if showsWave {
            actionStack.addArrangedSubview(waveStack)
        } else if let systemName {
            micImageView.image = UIImage(systemName: systemName)
            micImageView.tintColor = tintColor
            actionStack.addArrangedSubview(micImageView)
        }
        actionTitleLabel.text = title
        actionTitleLabel.textColor = tintColor
        if !title.isEmpty {
            actionStack.addArrangedSubview(actionTitleLabel)
        }
    }

    private func defaultHelperText(canUseBridge: Bool, pendingAction: PendingKeyboardAction?) -> String {
        if pendingAction == .startingClip {
            return "Starting clip..."
        }
        if pendingAction == .stoppingClip {
            return "Processing audio..."
        }
        if !hasFullAccess {
            return "Enable Full Access in Settings."
        }
        if activeDocumentIdentifier == nil {
            return "Tap a text field to use VoiceType."
        }
        if viewModel.isKeyboardRecording {
            return "Recording. Tap to finish."
        }
        if viewModel.isTranscribing {
            return "Processing audio..."
        }
        if canUseBridge {
            return ""
        }
        return "Open VoiceType from your Home Screen and tap Turn on keyboard mic."
    }

    @objc private func actionTapped() {
        updateDocumentContext()
        viewModel.refresh()
        clearResolvedPendingAction()
        guard pendingAction == nil, !viewModel.isTranscribing || !hasFullAccess else {
            updateUI()
            return
        }
        actionNotice = nil

        if !hasFullAccess {
            clearAutoInsert()
            actionNotice = "Settings → General → Keyboard → Keyboards → VoiceType → Allow Full Access."
        } else if viewModel.isKeyboardRecording {
            guard armAutoInsert() else { updateUI(); return }
            setPendingAction(.stoppingClip)
            updateUI(force: true)
            // Re-arm here: the armed state is cleared whenever the keyboard
            // disappears, so the transcript follows the field where the user
            // actually finished the clip.
            RecordingBridgeStore.requestStopClip()
        } else if viewModel.isKeyboardReady, hasFullAccess {
            guard armAutoInsert() else { updateUI(); return }
            setPendingAction(.startingClip)
            RecordingBridgeStore.requestStartClip()
        } else {
            setPendingAction(nil)
        }
        viewModel.refresh()
        clearResolvedPendingAction()
        updateUI()
    }

    @objc private func returnTapped() {
        updateDocumentContext()
        guard activeDocumentIdentifier != nil else { updateUI(); return }
        textDocumentProxy.insertText("\n")
    }

    @objc private func deleteTapped() {
        updateDocumentContext()
        guard activeDocumentIdentifier != nil else { updateUI(); return }
        textDocumentProxy.deleteBackward()
    }

    @objc private func deleteLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            updateDocumentContext()
            guard activeDocumentIdentifier != nil else { updateUI(); return }
            playKeyFeedback(intensity: 0.9)
            setPressed(true, for: deleteButton)
            textDocumentProxy.deleteBackward()
            startDeleteRepeat()
        case .ended, .cancelled, .failed:
            stopDeleteRepeat()
            setPressed(false, for: deleteButton)
        case .changed:
            let isInside = deleteButton.bounds.contains(recognizer.location(in: deleteButton))
            if !isInside {
                stopDeleteRepeat()
            } else if deleteRepeatTimer == nil {
                startDeleteRepeat()
            }
            setPressed(isInside, for: deleteButton)
        default:
            break
        }
    }

    private func startDeleteRepeat() {
        stopDeleteRepeat()
        guard let identifier = visibleDocumentIdentifier(), identifier == activeDocumentIdentifier else { return }
        deleteRepeatDocumentIdentifier = identifier
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.deleteRepeatTick() }
        }
        deleteRepeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func deleteRepeatTick() {
        guard deleteRepeatTimer != nil, let deleteRepeatDocumentIdentifier,
              let identifier = visibleDocumentIdentifier(),
              deleteRepeatDocumentIdentifier == identifier, activeDocumentIdentifier == identifier else {
            stopDeleteRepeat()
            return
        }
        textDocumentProxy.deleteBackward()
        playKeyFeedback(intensity: 0.45)
    }

    private func stopDeleteRepeat() {
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
        deleteRepeatDocumentIdentifier = nil
    }

    private func setPendingAction(_ action: PendingKeyboardAction?) {
        pendingAction = action
        pendingActionStartedAt = action == nil ? nil : Date()
    }

    private func clearResolvedPendingAction() {
        guard let pendingAction else {
            if viewModel.isKeyboardRecording || viewModel.isTranscribing {
                actionNotice = nil
                promptLabel.textColor = palette.inkSoft
            }
            return
        }

        switch pendingAction {
        case .startingClip where viewModel.isKeyboardRecording:
            setPendingAction(nil)
            actionNotice = nil
        case .stoppingClip where !viewModel.isKeyboardRecording:
            setPendingAction(nil)
            actionNotice = nil
        default:
            guard
                let pendingActionStartedAt,
                Date().timeIntervalSince(pendingActionStartedAt) >= pendingActionTimeout
            else {
                return
            }
            setPendingAction(nil)
            clearAutoInsert()
            actionNotice = pendingAction.timeoutMessage
        }
    }
}

private struct KeyboardOpenAppLink: View {
    private let palette = KeyboardPalette()
    let destination: URL
    let onPress: @MainActor () -> Void

    var body: some View {
        Link(destination: destination) {
            Image(systemName: "mic")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color(uiColor: palette.keySurface))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: palette.ink), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(KeyboardLinkButtonStyle(onPress: onPress))
        .accessibilityLabel("Turn on keyboard microphone")
        .accessibilityHint("Opens VoiceType and enables the background microphone. Return here to dictate.")
        .accessibilityIdentifier("keyboard.openAppLink")
    }
}

private struct KeyboardLinkButtonStyle: ButtonStyle {
    let onPress: @MainActor () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { onPress() }
            }
    }
}

private struct KeyboardUIState: Equatable {
    let pendingAction: PendingKeyboardAction?
    let isKeyboardRecording: Bool
    let isTranscribing: Bool
    let isKeyboardReady: Bool
    let hasFullAccess: Bool
    let hasDocumentContext: Bool
    let notice: String?
}

private enum PendingKeyboardAction {
    case startingClip
    case stoppingClip

    var timeoutMessage: String {
        switch self {
        case .startingClip:
            return "VoiceType did not respond. Reopen it and try again."
        case .stoppingClip:
            return "Clip did not finish. Reopen VoiceType to check it."
        }
    }
}

private final class KeyboardActionControl: UIControl {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard
            isEnabled,
            !isHidden,
            alpha >= 0.01,
            self.point(inside: point, with: event)
        else {
            return nil
        }
        return self
    }
}

@MainActor
final class KeyboardViewModel: ObservableObject {
    @Published private(set) var snapshot = SharedTranscriptStore.latest
    @Published private(set) var recordingState = RecordingBridgeStore.state

    var isRecording: Bool {
        recordingState.isRecording
    }

    var isKeyboardReady: Bool {
        recordingState.mode == .keyboardReady
    }

    var isKeyboardRecording: Bool {
        recordingState.mode == .keyboardRecording
    }

    var isTranscribing: Bool {
        recordingState.mode == .transcribing
    }

    func refresh() {
        snapshot = SharedTranscriptStore.latest
        recordingState = RecordingBridgeStore.state
    }
}

private struct KeyboardPalette {
    let keySurface = UIColor.voiceType(light: .white,
                                       dark: UIColor(red: 0.173, green: 0.173, blue: 0.184, alpha: 1))
    let keyGray = UIColor.voiceType(light: UIColor(red: 0.714, green: 0.741, blue: 0.788, alpha: 1),
                                    dark: UIColor(red: 0.231, green: 0.231, blue: 0.242, alpha: 1))
    let ink = UIColor.voiceType(light: UIColor(red: 0.102, green: 0.110, blue: 0.122, alpha: 1),
                                dark: UIColor(red: 0.945, green: 0.949, blue: 0.957, alpha: 1))
    let disabledInk = UIColor.voiceType(light: UIColor(red: 0.102, green: 0.110, blue: 0.122, alpha: 0.48),
                                        dark: UIColor(red: 0.945, green: 0.949, blue: 0.957, alpha: 0.38))
    let inkSoft = UIColor.voiceType(light: UIColor(red: 0.243, green: 0.263, blue: 0.294, alpha: 1),
                                    dark: UIColor(red: 0.760, green: 0.768, blue: 0.792, alpha: 1))
    let muted = UIColor.voiceType(light: UIColor(red: 0.408, green: 0.439, blue: 0.486, alpha: 1),
                                  dark: UIColor(red: 0.596, green: 0.608, blue: 0.639, alpha: 1))
    let accent = UIColor.voiceType(light: UIColor(red: 0.878, green: 0.631, blue: 0.102, alpha: 1),
                                   dark: UIColor(red: 0.941, green: 0.737, blue: 0.271, alpha: 1))
    let live = UIColor.voiceType(light: UIColor(red: 0.812, green: 0.290, blue: 0.125, alpha: 1),
                                 dark: UIColor(red: 0.980, green: 0.480, blue: 0.260, alpha: 1))
}

private extension UIColor {
    static func voiceType(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        }
    }
}

private final class KeyboardMarkView: UIView {
    private let palette = KeyboardPalette()
    private let heights: [CGFloat] = [10, 18, 24, 16, 8]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
    }

    override func draw(_ rect: CGRect) {
        let bars = heights + [24]
        let barWidth: CGFloat = 2.4
        let spacing: CGFloat = 3
        let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
        var x = (bounds.width - totalWidth) / 2
        for (index, height) in bars.enumerated() {
            let y = (bounds.height - height) / 2
            let path = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: barWidth, height: height), cornerRadius: barWidth / 2)
            (index == bars.count - 1 ? palette.accent : palette.ink).setFill()
            path.fill()
            x += barWidth + spacing
        }
    }
}
