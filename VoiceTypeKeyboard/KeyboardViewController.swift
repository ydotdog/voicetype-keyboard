import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let viewModel = KeyboardViewModel()
    private var hostingController: UIHostingController<KeyboardRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupKeyboard()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.refresh()
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
        guard let url = URL(string: "\(AppConstants.appURLScheme)://record") else { return }
        extensionContext?.open(url)
    }
}

@MainActor
final class KeyboardViewModel: ObservableObject {
    @Published private(set) var snapshot = SharedTranscriptStore.latest

    func refresh() {
        snapshot = SharedTranscriptStore.latest
    }
}
