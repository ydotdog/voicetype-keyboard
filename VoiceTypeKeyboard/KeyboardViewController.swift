import AudioToolbox
import ObjectiveC
import UIKit

final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    private let viewModel = KeyboardViewModel()
    private var refreshTimer: Timer?
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
    private let helperLabel = UILabel()
    private let bottomRow = UIStackView()
    private let returnButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let keyFeedback = UIImpactFeedbackGenerator(style: .light)
    private let actionFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private var deleteRepeatTimer: Timer?
    private var openAppFallbackWorkItem: DispatchWorkItem?
    private var styleTraitRegistration: UITraitChangeRegistration?
    private var renderedUIState: KeyboardUIState?

    private let palette = KeyboardPalette()
    private let keyboardHeight: CGFloat = 188

    var enableInputClicksWhenVisible: Bool {
        true
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
        applyKeyboardAppearanceOverride()
        refreshKeyboardState()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        applyKeyboardAppearanceOverride()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        prepareHaptics()
        startRefreshing()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateKeyboardChrome()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelOpenAppFallback()
        stopDeleteRepeat()
        stopRefreshing()
        // Sever auto-insert when the keyboard leaves this field so a transcript
        // finished later cannot land in another app's text field.
        KeyboardAutoInsertStore.clear()
    }

    private func applyKeyboardAppearanceOverride() {
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
        topRow.addArrangedSubview(UIView())

        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            topRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            topRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            topRow.heightAnchor.constraint(equalToConstant: 32)
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
        actionControl.layer.cornerRadius = 28
        actionControl.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        installActionPressFeedback(on: actionControl)
        actionControl.isAccessibilityElement = true
        actionControl.accessibilityTraits = .button
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
            micImageView.widthAnchor.constraint(equalToConstant: 32),
            micImageView.heightAnchor.constraint(equalToConstant: 32)
        ])

        actionTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
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
        waveStack.translatesAutoresizingMaskIntoConstraints = false
        waveStack.heightAnchor.constraint(equalToConstant: 34).isActive = true
        for height in [12, 22, 30, 18, 34, 26, 14, 31, 28, 20] as [CGFloat] {
            let bar = UIView()
            bar.backgroundColor = palette.live
            bar.layer.cornerCurve = .continuous
            bar.layer.cornerRadius = 2
            bar.isUserInteractionEnabled = false
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 3.5),
                bar.heightAnchor.constraint(equalToConstant: height)
            ])
            waveStack.addArrangedSubview(bar)
        }

        helperLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        helperLabel.textColor = palette.muted
        helperLabel.textAlignment = .center
        helperLabel.numberOfLines = 2
        helperLabel.adjustsFontSizeToFitWidth = true
        helperLabel.minimumScaleFactor = 0.72
        helperLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(helperLabel)

        NSLayoutConstraint.activate([
            promptLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            promptLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            promptLabel.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 7),
            promptLabel.heightAnchor.constraint(equalToConstant: 0),

            helperLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            helperLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            helperLabel.topAnchor.constraint(equalTo: actionControl.bottomAnchor, constant: 6),
            helperLabel.heightAnchor.constraint(equalToConstant: 26),

            actionControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            actionControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            actionControl.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 7),
            actionControl.heightAnchor.constraint(equalToConstant: 56)
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
        installKeyPressFeedback(on: returnButton)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        returnButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        returnButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconKey(deleteButton, systemName: "delete.left", accessibilityLabel: "Delete")
        installKeyPressFeedback(on: deleteButton)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let deleteLongPress = UILongPressGestureRecognizer(target: self, action: #selector(deleteLongPressed(_:)))
        deleteLongPress.minimumPressDuration = 0.35
        deleteButton.addGestureRecognizer(deleteLongPress)

        bottomRow.addArrangedSubview(returnButton)
        bottomRow.addArrangedSubview(deleteButton)

        NSLayoutConstraint.activate([
            bottomRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            bottomRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            bottomRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bottomRow.heightAnchor.constraint(equalToConstant: 48),

            returnButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            returnButton.heightAnchor.constraint(equalToConstant: 48),
            deleteButton.widthAnchor.constraint(equalToConstant: 48),
            deleteButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func configureIconKey(_ button: UIButton, systemName: String, accessibilityLabel: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = palette.keyGray
        button.tintColor = palette.inkSoft
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 24
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.accessibilityLabel = accessibilityLabel
    }

    private func configureTextKey(_ button: UIButton, text: String, accessibilityLabel: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = palette.keySurface
        button.tintColor = palette.ink
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 24
        button.setTitle(text, for: .normal)
        button.setTitleColor(palette.ink, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 22, weight: .regular)
        button.accessibilityLabel = accessibilityLabel
    }

    private func wordmark() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3)
            .withDesign(.serif) ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3)
        let voiceFont = UIFont(descriptor: base.withSymbolicTraits([]) ?? base, size: 25)
        let typeFont = UIFont(descriptor: base.withSymbolicTraits(.traitItalic) ?? base, size: 25)
        result.append(NSAttributedString(string: "Voice", attributes: [.font: voiceFont, .foregroundColor: palette.ink]))
        result.append(NSAttributedString(string: "Type", attributes: [.font: typeFont, .foregroundColor: palette.ink]))
        return result
    }

    private func prepareHaptics() {
        keyFeedback.prepare()
        actionFeedback.prepare()
        selectionFeedback.prepare()
    }

    // Haptics inside a keyboard extension only fire when the user has granted
    // "Allow Full Access". With it on, the pre-prepared impact generator is the
    // reliable signal; the input click and system actuation are supplements.
    // (The old code created a throwaway generator and fired it the same instant
    // it was prepared, which the Taptic Engine drops, so it added nothing.)
    private func playKeyFeedback(intensity: CGFloat = 0.85) {
        keyFeedback.impactOccurred(intensity: intensity)
        keyFeedback.prepare()
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
        UIDevice.current.playInputClick()
        AudioServicesPlaySystemSound(1519)
    }

    private func playActionFeedback(intensity: CGFloat = 0.9) {
        actionFeedback.impactOccurred(intensity: intensity)
        actionFeedback.prepare()
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
        UIDevice.current.playInputClick()
        AudioServicesPlaySystemSound(1520)
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
        stopRefreshing()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshKeyboardState()
            }
        }
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @MainActor
    private func refreshKeyboardState() {
        viewModel.refresh()
        if viewModel.isKeyboardReady {
            cancelOpenAppFallback()
            actionNotice = nil
        }
        clearResolvedPendingAction()
        updateUI()
        guard !viewModel.isRecording, KeyboardAutoInsertStore.claimForInsert(viewModel.snapshot) else { return }
        textDocumentProxy.insertText(viewModel.snapshot.text)
    }

    private func updateUI(force: Bool = false) {
        let uiState = KeyboardUIState(
            pendingAction: pendingAction,
            isKeyboardRecording: viewModel.isKeyboardRecording,
            isTranscribing: viewModel.isTranscribing,
            isKeyboardReady: viewModel.isKeyboardReady,
            hasFullAccess: hasFullAccess,
            notice: actionNotice
        )
        guard force || uiState != renderedUIState else { return }
        renderedUIState = uiState

        actionStack.arrangedSubviews.forEach { view in
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let canUseBridge = viewModel.isKeyboardReady && hasFullAccess
        actionControl.isEnabled = pendingAction == nil && !viewModel.isTranscribing
        let helperText = actionNotice ?? defaultHelperText(canUseBridge: canUseBridge, pendingAction: pendingAction)
        helperLabel.text = helperText
        helperLabel.isHidden = helperText.isEmpty

        if pendingAction == .startingClip {
            setStatusAction(systemName: "mic.fill", title: "Starting", accessibilityLabel: "Starting recording", tintColor: palette.live)
        } else if pendingAction == .stoppingClip {
            // The moment the user taps Stop we leave the recording look behind and
            // show the processing state, even before the app confirms. Long clips
            // can take a while to transcribe, so the user must never be left
            // staring at the "recording" wave wondering if it is still capturing.
            setStatusAction(systemName: "waveform", title: "Transcribing", accessibilityLabel: "Transcribing", tintColor: palette.live)
        } else if viewModel.isKeyboardRecording {
            setStatusAction(title: "Stop", accessibilityLabel: "Tap to finish recording", tintColor: palette.live, showsWave: true)
        } else if viewModel.isTranscribing {
            setStatusAction(systemName: "waveform", title: "Transcribing", accessibilityLabel: "Transcribing", tintColor: palette.live)
        } else {
            promptLabel.textColor = palette.inkSoft
            actionControl.backgroundColor = canUseBridge ? palette.ink : palette.disabledInk
            actionControl.layer.borderWidth = 0
            micImageView.image = UIImage(systemName: canUseBridge ? "mic.fill" : "arrow.up.forward.app.fill")
            micImageView.tintColor = palette.keySurface
            actionTitleLabel.text = actionTitle(canUseBridge: canUseBridge)
            actionTitleLabel.textColor = palette.keySurface
            actionStack.addArrangedSubview(micImageView)
            actionStack.addArrangedSubview(actionTitleLabel)

            if !hasFullAccess {
                actionControl.accessibilityLabel = "Enable Full Access for VoiceType Keyboard"
            } else if viewModel.isKeyboardReady {
                actionControl.accessibilityLabel = "Tap to speak"
            } else {
                actionControl.accessibilityLabel = "Open VoiceType to turn on keyboard microphone"
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
        actionStack.addArrangedSubview(actionTitleLabel)
    }

    private func actionTitle(canUseBridge: Bool) -> String {
        if !hasFullAccess {
            return "Enable Access"
        }
        return canUseBridge ? "Speak" : "Open VoiceType"
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
        if viewModel.isKeyboardRecording {
            return "Recording. Tap Stop when done."
        }
        if viewModel.isTranscribing {
            return "Processing audio..."
        }
        if canUseBridge {
            return ""
        }
        return "Open VoiceType and tap Turn on keyboard mic."
    }

    @objc private func actionTapped() {
        playActionFeedback(intensity: 0.55)
        viewModel.refresh()
        clearResolvedPendingAction()
        guard pendingAction == nil else {
            updateUI()
            return
        }
        actionNotice = nil

        if viewModel.isKeyboardRecording {
            setPendingAction(.stoppingClip)
            updateUI(force: true)
            // Re-arm here: the armed state is cleared whenever the keyboard
            // disappears, so the transcript follows the field where the user
            // actually finished the clip.
            KeyboardAutoInsertStore.arm(baselineTranscriptID: viewModel.snapshot.id)
            RecordingBridgeStore.requestStopClip()
        } else if !hasFullAccess {
            setPendingAction(nil)
            actionNotice = nil
            openContainingApp(route: .keyboardSetup)
        } else if viewModel.isKeyboardReady, hasFullAccess {
            setPendingAction(.startingClip)
            KeyboardAutoInsertStore.arm(baselineTranscriptID: viewModel.snapshot.id)
            RecordingBridgeStore.requestStartClip()
        } else {
            setPendingAction(nil)
            actionNotice = nil
            openContainingApp(route: .keyboardMic)
        }
        viewModel.refresh()
        clearResolvedPendingAction()
        updateUI()
    }

    @objc private func returnTapped() {
        playKeyFeedback(intensity: 0.5)
        textDocumentProxy.insertText("\n")
    }

    @objc private func deleteTapped() {
        playKeyFeedback(intensity: 0.5)
        textDocumentProxy.deleteBackward()
    }

    @objc private func deleteLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            playKeyFeedback(intensity: 0.9)
            setPressed(true, for: deleteButton)
            textDocumentProxy.deleteBackward()
            startDeleteRepeat()
        case .ended, .cancelled, .failed:
            stopDeleteRepeat()
            setPressed(false, for: deleteButton)
        default:
            break
        }
    }

    private func startDeleteRepeat() {
        stopDeleteRepeat()
        deleteRepeatTimer = Timer.scheduledTimer(
            timeInterval: 0.08,
            target: self,
            selector: #selector(deleteRepeatTick),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func deleteRepeatTick() {
        textDocumentProxy.deleteBackward()
        playKeyFeedback(intensity: 0.45)
    }

    private func stopDeleteRepeat() {
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }

    private func openContainingApp(route: ContainingAppRoute) {
        guard let url = route.url else { return }
        scheduleOpenAppFallback(route: route)
        // Primary path: walk the responder chain to the hosting UIApplication and
        // call the modern open(_:options:completionHandler:). This is what
        // actually launches the containing app from a Full Access keyboard.
        // Fall back to the runtime sharedApplication trick, then to the
        // extension context as a last resort.
        if openURLThroughResponderChain(url) || openURLThroughApplicationRuntime(url) {
            return
        }
        if let extensionContext {
            extensionContext.open(url) { [weak self] didOpen in
                DispatchQueue.main.async {
                    guard let self, !didOpen else { return }
                    self.showOpenAppFallback(route: route)
                }
            }
        } else {
            showOpenAppFallback(route: route)
        }
    }

    @discardableResult
    private func openURLThroughResponderChain(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    @discardableResult
    private func openURLThroughApplicationRuntime(_ url: URL) -> Bool {
        let sharedSelector = NSSelectorFromString("sharedApplication")
        let openSelector = NSSelectorFromString("openURL:")
        guard
            let applicationClass = NSClassFromString("UIApplication"),
            let sharedMethod = class_getClassMethod(applicationClass, sharedSelector),
            let openMethod = class_getInstanceMethod(applicationClass, openSelector)
        else {
            return false
        }

        typealias SharedApplicationFunction = @convention(c) (AnyClass, Selector) -> AnyObject
        typealias OpenURLFunction = @convention(c) (AnyObject, Selector, NSURL) -> Bool
        let sharedApplication = unsafeBitCast(
            method_getImplementation(sharedMethod),
            to: SharedApplicationFunction.self
        )
        let openURL = unsafeBitCast(
            method_getImplementation(openMethod),
            to: OpenURLFunction.self
        )
        let application = sharedApplication(applicationClass, sharedSelector)
        return openURL(application, openSelector, url as NSURL)
    }

    private func scheduleOpenAppFallback(route: ContainingAppRoute) {
        cancelOpenAppFallback()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.viewModel.isKeyboardReady else { return }
            self.actionNotice = route.fallbackMessage
            self.updateUI()
        }
        openAppFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: workItem)
    }

    private func showOpenAppFallback(route: ContainingAppRoute) {
        cancelOpenAppFallback()
        actionNotice = route.fallbackMessage
        updateUI(force: true)
    }

    private func cancelOpenAppFallback() {
        openAppFallbackWorkItem?.cancel()
        openAppFallbackWorkItem = nil
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
            KeyboardAutoInsertStore.clear()
            actionNotice = pendingAction.timeoutMessage
        }
    }
}

private struct KeyboardUIState: Equatable {
    let pendingAction: PendingKeyboardAction?
    let isKeyboardRecording: Bool
    let isTranscribing: Bool
    let isKeyboardReady: Bool
    let hasFullAccess: Bool
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

private enum ContainingAppRoute {
    case keyboardMic
    case keyboardSetup

    var url: URL? {
        var components = URLComponents()
        components.scheme = AppConstants.appURLScheme
        switch self {
        case .keyboardMic:
            components.host = "keyboard"
            components.queryItems = [URLQueryItem(name: "autostart", value: "1")]
        case .keyboardSetup:
            components.host = "keyboard-setup"
        }
        return components.url
    }

    var fallbackMessage: String {
        switch self {
        case .keyboardMic:
            return "Open VoiceType and tap Turn on keyboard mic."
        case .keyboardSetup:
            return "Open VoiceType and finish keyboard setup."
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
                                 dark: UIColor(red: 0.941, green: 0.380, blue: 0.184, alpha: 1))
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
