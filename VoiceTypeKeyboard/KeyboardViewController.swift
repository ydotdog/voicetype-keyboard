import UIKit

final class KeyboardViewController: UIInputViewController {
    private let viewModel = KeyboardViewModel()
    private var refreshTimer: Timer?
    private var pendingAction: PendingKeyboardAction?
    private var pendingActionStartedAt: Date?
    private var actionNotice: String?
    private let pendingActionTimeout: TimeInterval = 4
    private let keyboardChromeCornerRadius: CGFloat = 32

    private let contentView = UIView()
    private let topRow = UIStackView()
    private let brandStack = UIStackView()
    private let markView = KeyboardMarkView()
    private let wordmarkLabel = UILabel()
    private let promptLabel = UILabel()
    private let actionControl = KeyboardActionControl()
    private let actionStack = UIStackView()
    private let micImageView = UIImageView()
    private let waveStack = UIStackView()
    private let helperLabel = UILabel()
    private let bottomRow = UIStackView()
    private let switchKeyboardButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let keyFeedback = UIImpactFeedbackGenerator(style: .light)
    private let actionFeedback = UIImpactFeedbackGenerator(style: .medium)
    private var deleteRepeatTimer: Timer?
    private var openAppFallbackWorkItem: DispatchWorkItem?

    private let palette = KeyboardPalette()
    private let keyboardHeight: CGFloat = 344

    override func viewDidLoad() {
        super.viewDidLoad()
        setupKeyboard()
        refreshKeyboardState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshKeyboardState()
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
    }

    private func setupKeyboard() {
        view.backgroundColor = palette.keyboard
        view.isOpaque = true
        view.clipsToBounds = true
        inputView?.backgroundColor = palette.keyboard
        view.insetsLayoutMarginsFromSafeArea = false

        let height = view.heightAnchor.constraint(equalToConstant: keyboardHeight)
        height.priority = .defaultHigh
        height.isActive = true

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = palette.keyboard
        contentView.layer.cornerCurve = .continuous
        contentView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        contentView.layer.masksToBounds = true
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
    }

    private func updateKeyboardChrome() {
        contentView.layer.cornerRadius = keyboardChromeCornerRadius
        view.backgroundColor = palette.keyboard
        inputView?.backgroundColor = palette.keyboard
        view.superview?.backgroundColor = palette.keyboard
        inputView?.superview?.backgroundColor = palette.keyboard
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
            topRow.heightAnchor.constraint(equalToConstant: 54)
        ])
    }

    private func setupActionArea() {
        promptLabel.font = .systemFont(ofSize: 24, weight: .regular)
        promptLabel.textColor = palette.inkSoft
        promptLabel.textAlignment = .center
        promptLabel.adjustsFontSizeToFitWidth = true
        promptLabel.minimumScaleFactor = 0.72
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(promptLabel)

        actionControl.translatesAutoresizingMaskIntoConstraints = false
        actionControl.layer.cornerCurve = .continuous
        actionControl.layer.cornerRadius = 36
        actionControl.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        installActionPressFeedback(on: actionControl)
        actionControl.isAccessibilityElement = true
        actionControl.accessibilityTraits = .button
        contentView.addSubview(actionControl)

        actionStack.axis = .horizontal
        actionStack.alignment = .center
        actionStack.distribution = .equalCentering
        actionStack.spacing = 5
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
            micImageView.widthAnchor.constraint(equalToConstant: 44),
            micImageView.heightAnchor.constraint(equalToConstant: 44)
        ])

        waveStack.axis = .horizontal
        waveStack.alignment = .center
        waveStack.distribution = .equalCentering
        waveStack.spacing = 5
        waveStack.isUserInteractionEnabled = false
        waveStack.translatesAutoresizingMaskIntoConstraints = false
        waveStack.heightAnchor.constraint(equalToConstant: 46).isActive = true
        for height in [18, 30, 42, 24, 49, 35, 20, 45, 39, 26] as [CGFloat] {
            let bar = UIView()
            bar.backgroundColor = palette.live
            bar.layer.cornerCurve = .continuous
            bar.layer.cornerRadius = 2
            bar.isUserInteractionEnabled = false
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 4),
                bar.heightAnchor.constraint(equalToConstant: height)
            ])
            waveStack.addArrangedSubview(bar)
        }

        helperLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
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
            promptLabel.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 6),
            promptLabel.heightAnchor.constraint(equalToConstant: 30),

            helperLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            helperLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            helperLabel.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 2),
            helperLabel.heightAnchor.constraint(equalToConstant: 32),

            actionControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            actionControl.topAnchor.constraint(equalTo: helperLabel.bottomAnchor, constant: 7),
            actionControl.widthAnchor.constraint(equalToConstant: 204),
            actionControl.heightAnchor.constraint(equalToConstant: 70)
        ])
    }

    private func setupBottomRow() {
        bottomRow.axis = .horizontal
        bottomRow.alignment = .center
        bottomRow.distribution = .equalSpacing
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomRow)

        configureIconKey(switchKeyboardButton, systemName: "globe", accessibilityLabel: "Next keyboard")
        installKeyPressFeedback(on: switchKeyboardButton)
        switchKeyboardButton.addTarget(self, action: #selector(nextKeyboardTapped), for: .touchUpInside)

        configureTextKey(returnButton, text: "return", accessibilityLabel: "Return")
        installKeyPressFeedback(on: returnButton)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)

        configureIconKey(deleteButton, systemName: "delete.left", accessibilityLabel: "Delete")
        installKeyPressFeedback(on: deleteButton)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        let deleteLongPress = UILongPressGestureRecognizer(target: self, action: #selector(deleteLongPressed(_:)))
        deleteLongPress.minimumPressDuration = 0.35
        deleteButton.addGestureRecognizer(deleteLongPress)

        bottomRow.addArrangedSubview(switchKeyboardButton)
        bottomRow.addArrangedSubview(returnButton)
        bottomRow.addArrangedSubview(deleteButton)

        NSLayoutConstraint.activate([
            bottomRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            bottomRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            bottomRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            bottomRow.heightAnchor.constraint(equalToConstant: 58),

            switchKeyboardButton.widthAnchor.constraint(equalToConstant: 58),
            switchKeyboardButton.heightAnchor.constraint(equalToConstant: 58),
            returnButton.widthAnchor.constraint(equalToConstant: 158),
            returnButton.heightAnchor.constraint(equalToConstant: 54),
            deleteButton.widthAnchor.constraint(equalToConstant: 58),
            deleteButton.heightAnchor.constraint(equalToConstant: 58)
        ])
    }

    private func configureIconKey(_ button: UIButton, systemName: String, accessibilityLabel: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = palette.keyGray
        button.tintColor = palette.inkSoft
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 29
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.accessibilityLabel = accessibilityLabel
    }

    private func configureTextKey(_ button: UIButton, text: String, accessibilityLabel: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = palette.keySurface
        button.tintColor = palette.ink
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 27
        button.setTitle(text, for: .normal)
        button.setTitleColor(palette.ink, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 26, weight: .regular)
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
        keyFeedback.impactOccurred(intensity: 0.85)
        keyFeedback.prepare()
        setPressed(true, for: sender)
    }

    @objc private func actionPressBegan(_ sender: UIControl) {
        actionFeedback.impactOccurred(intensity: 0.9)
        actionFeedback.prepare()
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
        guard !viewModel.isRecording, KeyboardAutoInsertStore.shouldInsert(viewModel.snapshot) else { return }
        textDocumentProxy.insertText(viewModel.snapshot.text)
        KeyboardAutoInsertStore.clear()
    }

    private func updateUI() {
        actionStack.arrangedSubviews.forEach { view in
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let canUseBridge = viewModel.isKeyboardReady && hasFullAccess
        actionControl.isEnabled = pendingAction == nil && !viewModel.isTranscribing
        helperLabel.isHidden = false
        helperLabel.text = nil

        if pendingAction == .startingClip {
            setLiveAction(prompt: "Listening...", accessibilityLabel: "Starting recording")
        } else if pendingAction == .stoppingClip {
            setLiveAction(prompt: "Sending...", accessibilityLabel: "Finishing recording")
        } else if viewModel.isKeyboardRecording {
            setLiveAction(prompt: "Tap to finish", accessibilityLabel: "Tap to finish recording")
        } else if viewModel.isTranscribing {
            setLiveAction(prompt: "Transcribing", accessibilityLabel: "Transcribing")
        } else {
            promptLabel.textColor = palette.inkSoft
            actionControl.backgroundColor = canUseBridge ? palette.ink : palette.disabledInk
            actionControl.layer.borderWidth = 0
            micImageView.image = UIImage(systemName: canUseBridge ? "mic.fill" : "arrow.up.forward.app.fill")
            micImageView.tintColor = palette.keySurface
            actionStack.addArrangedSubview(micImageView)

            if !hasFullAccess {
                promptLabel.text = "Enable Full Access"
                helperLabel.text = actionNotice ?? "Open Settings, enable Full Access, then return here."
                actionControl.accessibilityLabel = "Enable Full Access for VoiceType Keyboard"
            } else if viewModel.isKeyboardReady {
                promptLabel.text = actionNotice == nil ? "Tap to speak" : "Tap to retry"
                helperLabel.text = actionNotice
                actionControl.accessibilityLabel = "Tap to speak"
            } else {
                promptLabel.text = "Open VoiceType"
                helperLabel.text = actionNotice ?? "Turn on keyboard mic in VoiceType first."
                actionControl.accessibilityLabel = "Open VoiceType to turn on keyboard microphone"
            }
            helperLabel.isHidden = helperLabel.text?.isEmpty ?? true
        }
    }

    private func setLiveAction(prompt: String, accessibilityLabel: String) {
        actionControl.backgroundColor = palette.keySurface
        actionControl.layer.borderColor = palette.live.withAlphaComponent(0.22).cgColor
        actionControl.layer.borderWidth = 1
        promptLabel.text = prompt
        promptLabel.textColor = palette.live
        actionControl.accessibilityLabel = accessibilityLabel
        actionStack.addArrangedSubview(waveStack)
        helperLabel.isHidden = true
    }

    @objc private func actionTapped() {
        viewModel.refresh()
        clearResolvedPendingAction()
        guard pendingAction == nil else {
            updateUI()
            return
        }
        actionNotice = nil

        if viewModel.isKeyboardRecording {
            setPendingAction(.stoppingClip)
            RecordingBridgeStore.requestStopClip()
        } else if !hasFullAccess {
            setPendingAction(nil)
            actionNotice = "Enable Full Access in VoiceType."
            openContainingApp(route: .keyboardSetup)
        } else if viewModel.isKeyboardReady, hasFullAccess {
            setPendingAction(.startingClip)
            KeyboardAutoInsertStore.arm(baselineTranscriptID: viewModel.snapshot.id)
            RecordingBridgeStore.requestStartClip()
        } else {
            setPendingAction(nil)
            actionNotice = "Opening VoiceType..."
            openContainingApp(route: .keyboardMic)
        }
        viewModel.refresh()
        clearResolvedPendingAction()
        updateUI()
    }

    @objc private func nextKeyboardTapped() {
        advanceToNextInputMode()
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func deleteLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            keyFeedback.impactOccurred(intensity: 0.9)
            keyFeedback.prepare()
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
        keyFeedback.impactOccurred(intensity: 0.45)
        keyFeedback.prepare()
    }

    private func stopDeleteRepeat() {
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }

    private func openContainingApp(route: ContainingAppRoute) {
        guard let url = route.url else { return }
        scheduleOpenAppFallback(route: route)

        if let extensionContext {
            extensionContext.open(url) { [weak self] didOpen in
                guard !didOpen else { return }
                DispatchQueue.main.async {
                    self?.openURLThroughResponderChain(url)
                }
            }
        } else {
            openURLThroughResponderChain(url)
        }
    }

    private func scheduleOpenAppFallback(route: ContainingAppRoute) {
        cancelOpenAppFallback()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.viewModel.isKeyboardReady else { return }
            self.actionNotice = route.fallbackMessage
            self.updateUI()
        }
        openAppFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
    }

    private func cancelOpenAppFallback() {
        openAppFallbackWorkItem?.cancel()
        openAppFallbackWorkItem = nil
    }

    private func openURLThroughResponderChain(_ url: URL) {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
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
            return "Open VoiceType from Home, then return here."
        case .keyboardSetup:
            return "Open VoiceType from Home to finish setup."
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
    let keyboard = UIColor(red: 0.895, green: 0.899, blue: 0.910, alpha: 1)
    let keySurface = UIColor.white
    let keyGray = UIColor(red: 0.835, green: 0.843, blue: 0.855, alpha: 1)
    let ink = UIColor(red: 0.060, green: 0.060, blue: 0.060, alpha: 1)
    let disabledInk = UIColor(red: 0.060, green: 0.060, blue: 0.060, alpha: 0.48)
    let inkSoft = UIColor(red: 0.245, green: 0.245, blue: 0.245, alpha: 1)
    let muted = UIColor(red: 0.480, green: 0.480, blue: 0.480, alpha: 1)
    let accent = UIColor(red: 0.369, green: 0.420, blue: 0.306, alpha: 1)
    let live = UIColor(red: 0.812, green: 0.290, blue: 0.125, alpha: 1)
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
