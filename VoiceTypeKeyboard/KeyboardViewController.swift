import Combine
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let viewModel = KeyboardViewModel()
    private var refreshTimer: Timer?
    private var pendingAction: PendingKeyboardAction?
    private var pendingActionStartedAt: Date?
    private var actionNotice: String?
    private let pendingActionTimeout: TimeInterval = 4

    private let chromeStack = UIStackView()
    private let markView = KeyboardMarkView()
    private let wordmarkLabel = UILabel()
    private let balanceLabel = UILabel()
    private let actionControl = KeyboardActionControl()
    private let actionStack = UIStackView()
    private let actionCircle = UIView()
    private let actionTitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let waveStack = UIStackView()
    private let helperLabel = UILabel()

    private let palette = KeyboardPalette()

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
        startRefreshing()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRefreshing()
    }

    private func setupKeyboard() {
        view.backgroundColor = palette.keyboard

        let height = view.heightAnchor.constraint(equalToConstant: 224)
        height.priority = .defaultHigh
        height.isActive = true

        let rootStack = UIStackView()
        rootStack.axis = .vertical
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        rootStack.isLayoutMarginsRelativeArrangement = true

        chromeStack.axis = .horizontal
        chromeStack.alignment = .center
        chromeStack.spacing = 14

        let nextButton = chromeButton(systemImage: "globe", title: nil, width: 46)
        nextButton.accessibilityLabel = "Next keyboard"
        nextButton.addTarget(self, action: #selector(nextKeyboardTapped), for: .touchUpInside)

        let abcButton = chromeButton(systemImage: nil, title: "ABC", width: 50)
        abcButton.accessibilityLabel = "Switch keyboard"
        abcButton.addTarget(self, action: #selector(nextKeyboardTapped), for: .touchUpInside)

        let brandStack = UIStackView()
        brandStack.axis = .horizontal
        brandStack.alignment = .center
        brandStack.spacing = 7
        brandStack.addArrangedSubview(markView)
        brandStack.addArrangedSubview(wordmarkLabel)
        markView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            markView.widthAnchor.constraint(equalToConstant: 28),
            markView.heightAnchor.constraint(equalToConstant: 24)
        ])

        wordmarkLabel.attributedText = wordmark()
        wordmarkLabel.textColor = palette.ink
        wordmarkLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        balanceLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        balanceLabel.textColor = palette.muted
        balanceLabel.textAlignment = .right
        balanceLabel.adjustsFontSizeToFitWidth = true
        balanceLabel.minimumScaleFactor = 0.68
        balanceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        balanceLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true

        chromeStack.addArrangedSubview(nextButton)
        chromeStack.addArrangedSubview(brandStack)
        chromeStack.addArrangedSubview(balanceLabel)
        chromeStack.addArrangedSubview(abcButton)

        actionControl.translatesAutoresizingMaskIntoConstraints = false
        actionControl.layer.cornerCurve = .continuous
        actionControl.layer.cornerRadius = 22
        actionControl.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        actionControl.isAccessibilityElement = true
        actionControl.accessibilityTraits = .button
        actionControl.heightAnchor.constraint(equalToConstant: 112).isActive = true

        actionStack.axis = .vertical
        actionStack.alignment = .center
        actionStack.spacing = 10
        actionStack.isUserInteractionEnabled = false
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionControl.addSubview(actionStack)
        NSLayoutConstraint.activate([
            actionStack.leadingAnchor.constraint(equalTo: actionControl.leadingAnchor, constant: 12),
            actionStack.trailingAnchor.constraint(equalTo: actionControl.trailingAnchor, constant: -12),
            actionStack.centerYAnchor.constraint(equalTo: actionControl.centerYAnchor)
        ])

        statusLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        statusLabel.textColor = palette.muted
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.isUserInteractionEnabled = false

        actionCircle.backgroundColor = palette.accent
        actionCircle.layer.cornerCurve = .continuous
        actionCircle.layer.cornerRadius = 26
        actionCircle.isUserInteractionEnabled = false
        actionCircle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            actionCircle.widthAnchor.constraint(equalToConstant: 52),
            actionCircle.heightAnchor.constraint(equalToConstant: 52)
        ])

        waveStack.axis = .horizontal
        waveStack.alignment = .center
        waveStack.distribution = .equalCentering
        waveStack.spacing = 4
        waveStack.isUserInteractionEnabled = false
        waveStack.heightAnchor.constraint(equalToConstant: 52).isActive = true
        for height in [18, 30, 42, 24, 49, 35, 20, 45, 39, 26, 48, 31, 19, 40, 34, 22] as [CGFloat] {
            let bar = UIView()
            bar.backgroundColor = palette.live
            bar.layer.cornerCurve = .continuous
            bar.layer.cornerRadius = 1.5
            bar.isUserInteractionEnabled = false
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 3),
                bar.heightAnchor.constraint(equalToConstant: height)
            ])
            waveStack.addArrangedSubview(bar)
        }

        actionTitleLabel.font = .systemFont(ofSize: 28, weight: .regular)
        actionTitleLabel.textAlignment = .center
        actionTitleLabel.adjustsFontSizeToFitWidth = true
        actionTitleLabel.minimumScaleFactor = 0.78
        actionTitleLabel.numberOfLines = 1
        actionTitleLabel.isUserInteractionEnabled = false

        helperLabel.font = .systemFont(ofSize: 20, weight: .regular)
        helperLabel.textColor = palette.muted
        helperLabel.textAlignment = .center
        helperLabel.numberOfLines = 2
        helperLabel.adjustsFontSizeToFitWidth = true
        helperLabel.minimumScaleFactor = 0.78

        rootStack.addArrangedSubview(chromeStack)
        rootStack.addArrangedSubview(actionControl)
        rootStack.addArrangedSubview(helperLabel)

        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func chromeButton(systemImage: String?, title: String?, width: CGFloat) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = palette.surface2
        button.tintColor = palette.ink
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 11
        button.layer.borderWidth = 1
        button.layer.borderColor = palette.lineSoft.cgColor
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 46).isActive = true
        if let systemImage {
            button.setImage(UIImage(systemName: systemImage), for: .normal)
            button.imageView?.contentMode = .scaleAspectFit
        } else {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        }
        return button
    }

    private func wordmark() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3)
            .withDesign(.serif) ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3)
        let voiceFont = UIFont(descriptor: base.withSymbolicTraits([]) ?? base, size: 22)
        let typeFont = UIFont(descriptor: base.withSymbolicTraits(.traitItalic) ?? base, size: 22)
        result.append(NSAttributedString(string: "Voice", attributes: [.font: voiceFont, .foregroundColor: palette.ink]))
        result.append(NSAttributedString(string: "Type", attributes: [.font: typeFont, .foregroundColor: palette.ink]))
        return result
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
        clearResolvedPendingAction()
        updateUI()
        guard !viewModel.isRecording, KeyboardAutoInsertStore.shouldInsert(viewModel.snapshot) else { return }
        textDocumentProxy.insertText(viewModel.snapshot.text)
        KeyboardAutoInsertStore.clear()
    }

    private func updateUI() {
        balanceLabel.text = compactBalanceText()
        actionStack.arrangedSubviews.forEach { view in
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let canUseBridge = viewModel.isKeyboardReady && hasFullAccess
        actionControl.isEnabled = pendingAction == nil && !viewModel.isTranscribing

        if pendingAction == .startingClip {
            actionControl.backgroundColor = palette.surface
            actionControl.layer.borderColor = palette.live.withAlphaComponent(0.18).cgColor
            actionControl.layer.borderWidth = 1
            statusLabel.text = "STARTING"
            statusLabel.textColor = palette.live
            actionTitleLabel.text = "Listening..."
            actionTitleLabel.font = .systemFont(ofSize: 28, weight: .regular)
            actionTitleLabel.textColor = palette.live
            actionControl.accessibilityLabel = "Starting recording"
            actionStack.addArrangedSubview(statusLabel)
            actionStack.addArrangedSubview(waveStack)
            actionStack.addArrangedSubview(actionTitleLabel)
            helperLabel.isHidden = true
        } else if pendingAction == .stoppingClip {
            actionControl.backgroundColor = palette.surface
            actionControl.layer.borderColor = palette.live.withAlphaComponent(0.18).cgColor
            actionControl.layer.borderWidth = 1
            statusLabel.text = "FINISHING"
            statusLabel.textColor = palette.live
            actionTitleLabel.text = "Sending..."
            actionTitleLabel.font = .systemFont(ofSize: 28, weight: .regular)
            actionTitleLabel.textColor = palette.live
            actionControl.accessibilityLabel = "Finishing recording"
            actionStack.addArrangedSubview(statusLabel)
            actionStack.addArrangedSubview(waveStack)
            actionStack.addArrangedSubview(actionTitleLabel)
            helperLabel.isHidden = true
        } else if viewModel.isKeyboardRecording {
            actionControl.backgroundColor = palette.surface
            actionControl.layer.borderColor = palette.live.withAlphaComponent(0.18).cgColor
            actionControl.layer.borderWidth = 1
            statusLabel.text = "RECORDING CLIP"
            statusLabel.textColor = palette.live
            actionTitleLabel.text = "Tap to finish"
            actionTitleLabel.font = .systemFont(ofSize: 28, weight: .regular)
            actionTitleLabel.textColor = palette.live
            actionControl.accessibilityLabel = "Tap to finish recording"
            actionStack.addArrangedSubview(statusLabel)
            actionStack.addArrangedSubview(waveStack)
            actionStack.addArrangedSubview(actionTitleLabel)
            helperLabel.isHidden = true
        } else if viewModel.isTranscribing {
            actionControl.backgroundColor = palette.surface
            actionControl.layer.borderColor = palette.live.withAlphaComponent(0.18).cgColor
            actionControl.layer.borderWidth = 1
            statusLabel.text = "TRANSCRIBING"
            statusLabel.textColor = palette.live
            actionTitleLabel.text = "Setting your words in type"
            actionTitleLabel.font = .systemFont(ofSize: 22, weight: .regular)
            actionTitleLabel.textColor = palette.ink
            actionControl.accessibilityLabel = "Transcribing"
            actionStack.addArrangedSubview(statusLabel)
            actionStack.addArrangedSubview(waveStack)
            actionStack.addArrangedSubview(actionTitleLabel)
            helperLabel.isHidden = true
        } else {
            actionControl.backgroundColor = canUseBridge ? palette.ink : palette.ink.withAlphaComponent(0.62)
            actionControl.layer.borderWidth = 0
            actionCircle.backgroundColor = canUseBridge ? palette.accent : palette.muted.withAlphaComponent(0.38)
            actionTitleLabel.font = .systemFont(ofSize: 28, weight: .regular)
            actionTitleLabel.textColor = palette.onInk
            if !hasFullAccess {
                actionTitleLabel.text = "Enable Full Access"
                helperLabel.text = actionNotice ?? "Settings -> Keyboard -> VoiceType -> Allow Full Access."
                actionControl.accessibilityLabel = "Enable Full Access for VoiceType Keyboard"
            } else if viewModel.isKeyboardReady {
                actionTitleLabel.text = actionNotice == nil ? "Tap to talk" : "Tap to retry"
                helperLabel.text = actionNotice ?? "Tap once to start a clip. Tap again to finish and insert."
                actionControl.accessibilityLabel = "Tap to talk"
            } else {
                actionTitleLabel.text = "Open VoiceType"
                helperLabel.text = actionNotice ?? "Turn on keyboard mic in VoiceType first."
                actionControl.accessibilityLabel = "Open VoiceType to turn on keyboard microphone"
            }
            actionStack.addArrangedSubview(actionCircle)
            actionStack.addArrangedSubview(actionTitleLabel)
            helperLabel.isHidden = false
        }
    }

    private func compactBalanceText() -> String {
        let text = viewModel.balanceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Ready" }
        let digits = text.filter(\.isNumber)
        guard let value = Double(digits), value > 0 else { return text }
        if value >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0fk", value / 1_000)
        }
        return String(format: "%.0f", value)
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
            actionNotice = "Full Access is required so the keyboard can talk to VoiceType."
            openContainingApp()
        } else if viewModel.isKeyboardReady, hasFullAccess {
            setPendingAction(.startingClip)
            KeyboardAutoInsertStore.arm(baselineTranscriptID: viewModel.snapshot.id)
            RecordingBridgeStore.requestStartClip()
        } else {
            setPendingAction(nil)
            actionNotice = "Open VoiceType and turn on keyboard mic before using this key."
            openContainingApp()
        }
        viewModel.refresh()
        clearResolvedPendingAction()
        updateUI()
    }

    @objc private func nextKeyboardTapped() {
        advanceToNextInputMode()
    }

    private func openContainingApp() {
        guard let url = URL(string: "\(AppConstants.appURLScheme)://keyboard") else { return }
        extensionContext?.open(url)
    }

    private func setPendingAction(_ action: PendingKeyboardAction?) {
        pendingAction = action
        pendingActionStartedAt = action == nil ? nil : Date()
    }

    private func clearResolvedPendingAction() {
        guard let pendingAction else {
            if viewModel.isKeyboardRecording || viewModel.isTranscribing {
                actionNotice = nil
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
            return "VoiceType did not respond. Reopen VoiceType and turn keyboard mic on again."
        case .stoppingClip:
            return "VoiceType did not finish this clip. Reopen VoiceType to check the recording."
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
    @Published private(set) var balanceText = SharedAccountStore.balanceText

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
        balanceText = SharedAccountStore.balanceText
    }
}

private struct KeyboardPalette {
    let keyboard = UIColor(red: 0.906, green: 0.882, blue: 0.831, alpha: 1)
    let surface = UIColor(red: 0.984, green: 0.969, blue: 0.937, alpha: 1)
    let surface2 = UIColor.white
    let ink = UIColor(red: 0.106, green: 0.094, blue: 0.075, alpha: 1)
    let onInk = UIColor(red: 0.984, green: 0.969, blue: 0.937, alpha: 1)
    let muted = UIColor(red: 0.549, green: 0.522, blue: 0.463, alpha: 1)
    let accent = UIColor(red: 0.878, green: 0.631, blue: 0.102, alpha: 1)
    let live = UIColor(red: 0.812, green: 0.290, blue: 0.125, alpha: 1)
    let lineSoft = UIColor(red: 0.106, green: 0.094, blue: 0.075, alpha: 0.07)
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
