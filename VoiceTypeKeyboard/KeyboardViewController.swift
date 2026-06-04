import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let viewModel = KeyboardViewModel()
    private var hostingController: UIHostingController<KeyboardRootView>?
    private var refreshTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupKeyboard()
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
        let rootView = KeyboardRootView(
            viewModel: viewModel,
            insert: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
            },
            openRecorder: { [weak self] in
                self?.openRecorder()
            },
            stopRecording: {
                RecordingBridgeStore.requestStop()
            },
            nextKeyboard: { [weak self] in
                self?.advanceToNextInputMode()
            }
        )

        let host = UIHostingController(rootView: rootView)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear

        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    private func openRecorder() {
        guard let url = URL(string: "\(AppConstants.appURLScheme)://record?autostart=1") else { return }
        KeyboardAutoInsertStore.arm(baselineTranscriptID: viewModel.snapshot.id)
        extensionContext?.open(url)
    }

    private func startRefreshing() {
        stopRefreshing()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
        guard !viewModel.isRecording, KeyboardAutoInsertStore.shouldInsert(viewModel.snapshot) else { return }
        textDocumentProxy.insertText(viewModel.snapshot.text)
        KeyboardAutoInsertStore.clear()
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

    func refresh() {
        snapshot = SharedTranscriptStore.latest
        recordingState = RecordingBridgeStore.state
        balanceText = SharedAccountStore.balanceText
    }
}
