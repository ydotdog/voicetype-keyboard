import AuthenticationServices
import StoreKit
import SwiftUI
import UIKit

struct DashboardView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = RecordingController()
    @StateObject private var store = StoreKitService()
    @State private var selectedTab: VoiceTypeTab = .home
    @State private var isKeyboardSetupPresented = false
    @State private var transcriptHistory = SharedTranscriptStore.history
    @State private var toastMessage: String?
    @State private var toastDismissID = UUID()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AppTheme.background.ignoresSafeArea()

                if isKeyboardSetupPresented {
                    KeyboardSetupScreen {
                        withAnimation(.snappy) { isKeyboardSetupPresented = false }
                    }
                } else if account.isSignedIn {
                    signedInContent
                } else {
                    SignInScreen {
                        isKeyboardSetupPresented = true
                    }
                        .environmentObject(account)
                }

                if let toastMessage {
                    ToastView(message: toastMessage)
                        .padding(.bottom, account.isSignedIn ? 92 : 26)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await initialLoad()
            }
            .onChange(of: appState.keyboardMicRequestID, initial: true) { _, requestID in
                guard requestID != nil else { return }
                // A repeated URL must not cancel an in-flight permission prompt.
                Task { await handleKeyboardMicRequest(navigateToHome: true) }
            }
            .task(id: appState.keyboardSetupRequestID) {
                handleKeyboardSetupRequest()
            }
            .onChange(of: account.sessionID) { _, _ in
                store.accountDidChange()
                recorder.cancel(discardFailed: account.shouldDiscardPendingRecording)
                recorder.reconcileFailedTranscription(account: account)
                recorder.refreshLatest()
                KeyboardAutoInsertStore.clear()
                transcriptHistory = []
                selectedTab = .home
                isKeyboardSetupPresented = false
                if account.isSignedIn {
                    Task {
                        await handleKeyboardMicRequest()
                        await signedInLoad()
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await handleKeyboardMicRequest()
                    await account.refresh()
                    await store.syncUnfinishedTransactions(account: account)
                    recorder.refreshLatest()
                    refreshHistory()
                }
            }
            .onChange(of: recorder.lastTranscript) { _, _ in
                refreshHistory()
            }
            .onChange(of: recorder.failedTranscriptions.map(\.id)) { _, _ in
                refreshHistory()
            }
            .onChange(of: recorder.retryingTranscriptionID) { _, _ in
                refreshHistory()
            }
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
            ScrollView {
                Group {
                    switch selectedTab {
                    case .home:
                        HomeScreen(
                            account: account,
                            recorder: recorder
                        )
                    case .history:
                        HistoryScreen(recorder: recorder, account: account, history: transcriptHistory, copy: copyTranscript)
                    case .credit:
                        CreditScreen(store: store, account: account)
                            .task {
                                guard store.products.isEmpty, !store.isLoading else { return }
                                await store.loadProducts()
                            }
                    case .settings:
                        SettingsScreen(
                            account: account,
                            store: store,
                            openKeyboardSetup: {
                                withAnimation(.snappy) {
                                    isKeyboardSetupPresented = true
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .refreshable {
                await account.refresh()
                refreshHistory()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VoiceTypeTabBar(selection: $selectedTab)
            }
    }

    private func initialLoad() async {
        store.startObservingTransactions(account: account)
        if account.isSignedIn {
            await signedInLoad()
        }
        recorder.reconcileFailedTranscription(account: account)
        recorder.refreshLatest()
        refreshHistory()
    }

    private func signedInLoad() async {
        await account.refresh()
        recorder.reconcileFailedTranscription(account: account)
        #if DEBUG
        await account.grantDeveloperCreditIfAvailable()
        #endif
        await store.loadProducts()
        await store.syncUnfinishedTransactions(account: account)
        recorder.refreshLatest()
        refreshHistory()
    }

    private func refreshHistory() {
        transcriptHistory = SharedTranscriptStore.history
    }

    private func copyTranscript(_ snapshot: TranscriptSnapshot) {
        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UIPasteboard.general.string = snapshot.text
        showToast("Copied")
    }

    private func handleKeyboardMicRequest(navigateToHome: Bool = false) async {
        if navigateToHome {
            account.errorMessage = nil
            withAnimation(.snappy) {
                selectedTab = .home
                isKeyboardSetupPresented = false
            }
        }
        let outcome = await KeyboardMicActivation.continuePendingRequest(
            appState: appState, account: account, recorder: recorder,
            isAppActive: scenePhase == .active
        )
        switch outcome {
        case .none, .failed:
            break // RecordingController exposes any actionable error on Home.
        case .needsSignIn:
            showToast("Sign in to turn on keyboard mic")
        case .ready:
            showToast("Microphone is on. Return to your app.")
        case .recording:
            showToast("VoiceType is recording from the keyboard.")
        case .transcribing:
            showToast("VoiceType is finishing your clip.")
        case .busy:
            showToast("Finish the current recording first")
        }
    }

    private func handleKeyboardSetupRequest() {
        guard appState.keyboardSetupRequestID != nil else { return }
        account.errorMessage = nil

        withAnimation(.snappy) {
            selectedTab = .settings
            isKeyboardSetupPresented = true
        }
    }

    private func showToast(_ message: String) {
        let dismissID = UUID()
        toastDismissID = dismissID
        withAnimation(.snappy) {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(1.25))
            await MainActor.run {
                guard toastDismissID == dismissID else { return }
                withAnimation(.snappy) {
                    toastMessage = nil
                }
            }
        }
    }
}

enum VoiceTypeTab: String, CaseIterable, Identifiable {
    case home
    case history
    case credit
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .credit: "Credit"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .credit: "dollarsign.circle"
        case .settings: "gearshape"
        }
    }
}

struct VoiceTypeTabBar: View {
    @Binding var selection: VoiceTypeTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(VoiceTypeTab.allCases) { tab in
                Button {
                    withAnimation(.snappy) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 21, weight: .medium))
                            .symbolVariant(selection == tab ? .fill : .none)
                        Text(tab.title)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selection == tab ? AppTheme.accentDeep : AppTheme.secondary)
                }
                .buttonStyle(PlainHapticButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
        }
    }
}

private struct SignInScreen: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.colorScheme) private var colorScheme
    let openKeyboardSetup: () -> Void

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            VoiceTypeLogo()
                .padding(.top, 62)

            Spacer(minLength: 70)

            VStack(alignment: .leading, spacing: 16) {
                KickerText(text: "Speech to text · paid by use")

                VStack(alignment: .leading, spacing: -3) {
                    Text("Voice,")
                        .font(AppTheme.serif(58, weight: .regular))
                        .foregroundStyle(AppTheme.ink)
                    Text("set in type.")
                        .font(AppTheme.serif(52, weight: .regular))
                        .italic()
                        .foregroundStyle(AppTheme.accentDeep)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.72)

                Text("Dictate anywhere. Your words come back as clean, copy-ready text, and your credit never expires.")
                    .font(.system(size: 16.5, weight: .regular))
                    .lineSpacing(5)
                    .foregroundStyle(AppTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 18)
            }

            Spacer(minLength: 84)

            VStack(spacing: 12) {
                AppleSignInControl(style: colorScheme == .dark ? .white : .black) {
                    account.errorMessage = nil
                } onCompletion: { result in
                    Task { await handle(result) }
                }
                .frame(height: 56)
                .id(colorScheme)
                .disabled(account.isLoading)

                if account.isLoading {
                    ProgressView("Signing in…")
                        .font(.footnote)
                }

                Text("No subscription. Buy credit only when you want it.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                if let error = account.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("How to set up and use the keyboard", action: openKeyboardSetup)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.accentDeep)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(PlainHapticButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: 560, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        }
        .background(AppTheme.background.ignoresSafeArea())
    }

    private func handle(_ result: Result<ASAuthorization, Error>) async {
        account.errorMessage = nil

        switch result {
        case let .success(authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                account.errorMessage = "Apple did not return an identity token."
                return
            }

            let formatter = PersonNameComponentsFormatter()
            let fullName = credential.fullName.map { formatter.string(from: $0) }
            let authorizationCode = credential.authorizationCode
                .flatMap { String(data: $0, encoding: .utf8) }
            await account.signInWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                email: credential.email,
                fullName: fullName
            )
            #if DEBUG
            await account.grantDeveloperCreditIfAvailable()
            #endif
        case let .failure(error):
            account.errorMessage = signInErrorMessage(for: error)
        }
    }

    private func signInErrorMessage(for error: Error) -> String? {
        let nsError = error as NSError
        guard nsError.domain == ASAuthorizationError.errorDomain else {
            return error.localizedDescription
        }

        guard let code = ASAuthorizationError.Code(rawValue: nsError.code) else {
            return "Apple sign-in could not be completed. Try again."
        }

        switch code {
        case .canceled:
            return nil
        case .unknown, .notHandled, .failed:
            return "Sign in to your Apple Account in Settings, then try again."
        case .invalidResponse:
            return "Apple did not return a valid sign-in response. Try again."
        case .notInteractive:
            return "Apple sign-in needs VoiceType to stay open. Try again here."
        default:
            return "Apple sign-in could not be completed. Try again."
        }
    }
}

private struct AppleSignInControl: UIViewRepresentable {
    let style: ASAuthorizationAppleIDButton.Style
    let onRequest: () -> Void
    let onCompletion: (Result<ASAuthorization, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRequest: onRequest, onCompletion: onCompletion)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: style)
        button.cornerRadius = 12
        context.coordinator.signInButton = button
        button.addTarget(context.coordinator, action: #selector(Coordinator.startSignIn), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.onRequest = onRequest
        context.coordinator.onCompletion = onCompletion
    }

    final class Coordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        var onRequest: () -> Void
        var onCompletion: (Result<ASAuthorization, Error>) -> Void
        weak var signInButton: ASAuthorizationAppleIDButton?
        private var authorizationController: ASAuthorizationController?

        init(
            onRequest: @escaping () -> Void,
            onCompletion: @escaping (Result<ASAuthorization, Error>) -> Void
        ) {
            self.onRequest = onRequest
            self.onCompletion = onCompletion
        }

        @objc func startSignIn() {
            guard authorizationController == nil else { return }
            onRequest()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.85)

            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.email, .fullName]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            authorizationController = controller
            controller.performRequests()
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            signInButton?.window ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }

        func authorizationController(
            controller: ASAuthorizationController,
            didCompleteWithAuthorization authorization: ASAuthorization
        ) {
            authorizationController = nil
            onCompletion(.success(authorization))
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            authorizationController = nil
            onCompletion(.failure(error))
        }
    }
}

struct HomeScreen: View {
    @ObservedObject var account: AccountStore
    @ObservedObject var recorder: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VoiceTypeLogo()
                .frame(height: 44, alignment: .leading)

            if account.balanceUSDMicros < 0 {
                BalanceAdjustmentNotice()
            }

            VStack(spacing: 12) {
                if recorder.isKeyboardSessionActive {
                    KeyboardMicStatusCard(recorder: recorder)
                    Button {
                        Task { await recorder.finishKeyboardSession() }
                    } label: {
                        Label(recorder.isKeyboardRecording ? "Finish clip & turn off mic" : "Turn off keyboard mic", systemImage: "mic.slash.fill")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(GhostButtonStyle())
                } else {
                    Button {
                        Task { await recorder.startKeyboardReady(account: account) }
                    } label: {
                        HStack(spacing: 18) {
                            CircleIcon(systemName: "mic.fill", foreground: AppTheme.ink, background: AppTheme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Turn on keyboard mic")
                                    .font(AppTheme.serif(22, weight: .medium))
                                Text("Keep VoiceType ready in other apps")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppTheme.surface.opacity(0.72))
                            }
                            Spacer()
                        }
                        .foregroundStyle(AppTheme.surface)
                        .padding(16)
                    }
                    .buttonStyle(InkButtonStyle())
                    .disabled(recorder.isStarting || recorder.isProcessing || recorder.isRecording)
                }

                if recorder.isStarting {
                    ProgressView("Turning on microphone…")
                        .font(.footnote)
                }

                Text("While enabled, your microphone stays active in the background. Only clips you record from the keyboard are sent for transcription.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

            }

            RecordingLimitPicker(
                selection: $recorder.durationLimit,
                isDisabled: recorder.isStarting || recorder.isProcessing
            )

            if recorder.isProcessing && !recorder.isKeyboardTranscribing {
                ProcessingRow()
            }

            if let error = recorder.errorMessage ?? account.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }
}

private struct BalanceBlock: View {
    let balanceText: String

    var body: some View {
        VStack(spacing: 10) {
            KickerText(text: "Balance")
            Text(balanceText.isEmpty ? "0 credits" : balanceText)
                .font(AppTheme.serif(58, weight: .regular))
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.42)
                .frame(maxWidth: .infinity)

            Text("Credit never expires")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(AppTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct BalanceAdjustmentNotice: View {
    var body: some View {
        Text("Your balance is below zero after a credit adjustment. Add enough credit to bring it above zero before transcribing. VoiceType never charges you automatically.")
            .font(.footnote)
            .foregroundStyle(AppTheme.coral)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyboardMicStatusCard: View {
    @ObservedObject var recorder: RecordingController

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(recorder.isKeyboardRecording ? AppTheme.coral : AppTheme.accent)
                    .frame(width: 8, height: 8)
                KickerText(
                    text: recorder.isKeyboardRecording ? "Recording clip" : recorder.isKeyboardTranscribing ? "Transcribing" : "Keyboard mic on",
                    color: recorder.isKeyboardRecording || recorder.isKeyboardTranscribing ? AppTheme.coral : AppTheme.accentDeep
                )
                Spacer()
                Text(RecorderPanel.format(recorder.elapsedSeconds))
                    .font(AppTheme.serif(24, weight: .regular))
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()
            }

            if recorder.isKeyboardTranscribing {
                ProgressView()
                    .tint(AppTheme.accentDeep)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .accessibilityLabel("Transcribing audio")
            } else if recorder.isKeyboardRecording {
                LiveWaveform(sessionID: RecordingBridgeStore.state.sessionID, dense: true)
                    .frame(height: 36)
            } else {
                Text("Open a text field in another app and select VoiceType with the globe key. Tap the microphone icon to start a clip and the waveform to finish. The microphone stays active until this session ends or you turn it off.")
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(4)
                    .foregroundStyle(AppTheme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panelStyle()
    }
}

private struct HistoryScreen: View {
    @ObservedObject var recorder: RecordingController
    @ObservedObject var account: AccountStore
    let history: [TranscriptSnapshot]
    let copy: (TranscriptSnapshot) -> Void

    var body: some View {
        HistoryContent(
            history: history,
            failedTranscriptions: recorder.failedTranscriptions,
            retryingTranscriptionID: recorder.retryingTranscriptionID,
            retryErrorMessage: recorder.retryErrorMessage,
            isSignedIn: account.isSignedIn,
            copy: copy,
            retry: { id in
                Task { await recorder.retryFailedTranscription(id: id, account: account) }
            },
            delete: { id in recorder.discardFailedTranscription(id: id) }
        )
    }
}

struct HistoryContent: View {
    let history: [TranscriptSnapshot]
    let failedTranscriptions: [FailedTranscriptionSnapshot]
    let retryingTranscriptionID: UUID?
    let retryErrorMessage: String?
    let isSignedIn: Bool
    let copy: (TranscriptSnapshot) -> Void
    let retry: (UUID) -> Void
    let delete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(kicker: "Transcripts", title: "History")

            if let retryErrorMessage {
                Text(retryErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if history.isEmpty && failedTranscriptions.isEmpty {
                EmptyStateCard(
                    systemName: "clock",
                    title: "Nothing here yet",
                    detail: "Your transcripts and recordings saved for retry will appear here."
                )
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groupedHistory, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.day.uppercased())
                                .font(.system(size: 11.5, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(AppTheme.secondary)

                            VStack(spacing: 0) {
                                ForEach(group.items, id: \.id) { item in
                                    switch item {
                                    case .transcript(let snapshot):
                                        HistoryRow(snapshot: snapshot) {
                                            copy(snapshot)
                                        }
                                    case .failed(let snapshot):
                                        FailedTranscriptionHistoryRow(
                                            snapshot: snapshot,
                                            isRetrying: retryingTranscriptionID == snapshot.id,
                                            canRetry: isSignedIn && retryingTranscriptionID == nil,
                                            retry: { retry(snapshot.id) },
                                            delete: { delete(snapshot.id) }
                                        )
                                    }
                                    if item.id != group.items.last?.id {
                                        Divider()
                                            .background(AppTheme.borderSoft)
                                    }
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 2)
                            .background(AppTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(AppTheme.border, lineWidth: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var groupedHistory: [(day: String, items: [HistoryEntry])] {
        let calendar = Calendar.current
        let entries = history.map(HistoryEntry.transcript) + failedTranscriptions.map(HistoryEntry.failed)
        let grouped = Dictionary(grouping: entries) { snapshot in
            if calendar.isDateInToday(snapshot.createdAt) {
                return "Today"
            }
            if calendar.isDateInYesterday(snapshot.createdAt) {
                return "Yesterday"
            }
            return Self.dayFormatter.string(from: snapshot.createdAt)
        }
        return grouped
            .map { (day: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { ($0.items.first?.createdAt ?? .distantPast) > ($1.items.first?.createdAt ?? .distantPast) }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private enum HistoryEntry: Identifiable {
    case transcript(TranscriptSnapshot)
    case failed(FailedTranscriptionSnapshot)

    var id: String {
        switch self {
        case .transcript(let snapshot): "transcript-\(snapshot.id)"
        case .failed(let snapshot): "failed-\(snapshot.id.uuidString)"
        }
    }

    var createdAt: Date {
        switch self {
        case .transcript(let snapshot): snapshot.createdAt
        case .failed(let snapshot): snapshot.createdAt
        }
    }
}

private struct FailedTranscriptionHistoryRow: View {
    let snapshot: FailedTranscriptionSnapshot
    let isRetrying: Bool
    let canRetry: Bool
    let retry: () -> Void
    let delete: () -> Void
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(isRetrying ? "Transcribing saved audio" : "Transcription failed", systemImage: isRetrying ? "waveform" : "exclamationmark.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isRetrying ? AppTheme.inkSoft : AppTheme.coral)

            Text("\(snapshot.createdAt.formatted(date: .omitted, time: .shortened)) · \(RecorderPanel.format(snapshot.duration)) audio saved on this device")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: retry) {
                    HStack(spacing: 7) {
                        if isRetrying {
                            ProgressView()
                                .tint(AppTheme.ink)
                            Text("Retrying…")
                        } else {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(!canRetry)
                .opacity(canRetry || isRetrying ? 1 : 0.5)
                .accessibilityLabel(isRetrying ? "Retrying transcription" : "Retry transcription")

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(PlainHapticButtonStyle())
                .foregroundStyle(AppTheme.coral)
                .disabled(isRetrying)
                .opacity(isRetrying ? 0.5 : 1)
                .accessibilityLabel("Delete saved recording")
            }
        }
        .padding(.vertical, 16)
        .alert("Delete this recording?", isPresented: $isConfirmingDelete) {
            Button("Keep recording", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("The saved audio will be deleted from this device. This cannot be undone.")
        }
    }
}

private struct HistoryRow: View {
    let snapshot: TranscriptSnapshot
    let copy: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(snapshot.text)
                    .font(AppTheme.serif(17, weight: .regular))
                    .lineSpacing(3)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(Self.timeFormatter.string(from: snapshot.createdAt))
                    if let charge = snapshot.chargeText, !charge.isEmpty {
                        Text("·")
                        Text(charge)
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppTheme.secondary)
            }

            Spacer()

            Button(action: copy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GhostButtonStyle())
            .accessibilityLabel("Copy transcript")
        }
        .padding(.vertical, 14)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

struct CreditScreen: View {
    @ObservedObject var store: StoreKitService
    @ObservedObject var account: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BalanceBlock(balanceText: account.balanceText)

            ScreenTitle(
                kicker: "Pay as you go",
                title: "Add credit",
                detail: "Buy once, use whenever. Each clip is billed against your credit balance and your credit never expires."
            )

            if account.balanceUSDMicros < 0 {
                BalanceAdjustmentNotice()
            }

            VStack(spacing: 12) {
                ForEach(FallbackCreditPack.all) { pack in
                    CreditPackCard(pack: pack, product: store.product(for: pack.id)) {
                        Task { await store.purchase(productID: pack.id, account: account) }
                    }
                    .disabled(store.isLoading || store.product(for: pack.id) == nil || account.isLoading)
                }
            }

            if store.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(AppTheme.accentDeep)
                    Text("Connecting to the App Store…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.inkSoft)
                    Spacer()
                }
                .padding(14)
                .background(AppTheme.surface2.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button {
                Task { await store.loadProducts() }
            } label: {
                Label(store.products.isEmpty ? "Reload credit packs" : "Refresh credit packs", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(store.isLoading)

            LedgerNoteCard()

            if let message = store.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = store.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FallbackCreditPack: Identifiable {
    let id: String
    let displayPrice: String
    let displayName: String
    let description: String
    let isPopular: Bool

    static let all = [
        FallbackCreditPack(
            id: ProductIDs.small,
            displayPrice: "$0.99",
            displayName: "990,000 Credits",
            description: "Starter pack for quick dictation",
            isPopular: false
        ),
        FallbackCreditPack(
            id: ProductIDs.medium,
            displayPrice: "$4.99",
            displayName: "4,990,000 Credits",
            description: "Best for regular dictation",
            isPopular: true
        ),
        FallbackCreditPack(
            id: ProductIDs.large,
            displayPrice: "$19.99",
            displayName: "19,990,000 Credits",
            description: "For longer or frequent dictation",
            isPopular: false
        )
    ]
}

private struct CreditPackCard: View {
    let pack: FallbackCreditPack
    let product: Product?
    let buy: () -> Void

    var body: some View {
        Button(action: buy) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 9) {
                            priceLabel.fixedSize()
                            popularBadge
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            priceLabel
                            popularBadge
                        }
                    }

                    Text(product?.displayName ?? pack.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(product?.description ?? pack.description)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                }
                .foregroundStyle(pack.isPopular ? AppTheme.surface : AppTheme.ink)

                Spacer()

                Text(product == nil ? "—" : "Buy")
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(pack.isPopular ? AppTheme.surface.opacity(0.16) : AppTheme.surface2)
                    .clipShape(Capsule())
                    .foregroundStyle(pack.isPopular ? AppTheme.surface : AppTheme.accentDeep)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(pack.isPopular ? AppTheme.ink : AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(pack.isPopular ? Color.clear : AppTheme.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PlainHapticButtonStyle())
    }

    private var priceLabel: some View {
        Text(product?.displayPrice ?? "Unavailable")
            .font(AppTheme.serif(30, weight: .regular))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private var popularBadge: some View {
        if pack.isPopular {
            Text("POPULAR")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppTheme.accent)
                .foregroundStyle(Color.black.opacity(0.85))
                .clipShape(Capsule())
                .fixedSize()
        }
    }
}

private struct LedgerNoteCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.accentDeep)
                .padding(.top, 1)
            Text("Every credit and debit is tied to your account, so users never share API quota or billing history.")
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(AppTheme.inkSoft)
        }
        .padding(16)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }
}

private struct SettingsScreen: View {
    @ObservedObject var account: AccountStore
    @ObservedObject var store: StoreKitService
    let openKeyboardSetup: () -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(kicker: "Account", title: "Settings")

            AccountSummaryCard(account: account)

            VStack(alignment: .leading, spacing: 8) {
                Text("PREFERENCES")
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.secondary)

                VStack(spacing: 0) {
                    SettingsRow(title: "VoiceType keyboard", detail: "Set up", systemName: "keyboard", action: openKeyboardSetup)
                    Divider().background(AppTheme.borderSoft)
                    SettingsRow(title: "Open iOS Settings", detail: "", systemName: "gearshape") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    Divider().background(AppTheme.borderSoft)
                    SettingsRow(title: "Check purchases", detail: "", systemName: "arrow.clockwise") {
                        Task { await store.checkPurchases(account: account) }
                    }
                    .disabled(store.isLoading || account.isLoading)
                }
                .padding(.horizontal, 18)
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                }
            }

            #if DEBUG
            DeveloperToolsSection(account: account)
            #endif

            Button {
                account.signOut()
            } label: {
                Text("Sign out")
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(AppTheme.coral)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Rectangle())
            }
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .buttonStyle(PlainHapticButtonStyle())
            .disabled(account.isLoading || store.isLoading)

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Text("Delete account")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.coral)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainHapticButtonStyle())
            .disabled(account.isLoading || store.isLoading)

            if let message = store.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = account.errorMessage ?? store.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("VoiceType · v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppTheme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .alert("Delete account?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await account.deleteAccount() }
            }
        } message: {
            Text("This permanently deletes your VoiceType account, your remaining credit, and your transcription history. This can't be undone.")
        }
    }
}

private struct AccountSummaryCard: View {
    @ObservedObject var account: AccountStore

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(AppTheme.accent)
                .frame(width: 48, height: 48)
                .overlay {
                    VoiceTypeMark()
                        .frame(width: 25, height: 22)
                        .foregroundStyle(AppTheme.ink)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(account.email.isEmpty ? "Signed in" : account.email)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(account.balanceText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondary)
            }

            Spacer()
        }
        .panelStyle()
    }
}

private struct SettingsRow: View {
    let title: String
    let detail: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.inkSoft)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.secondary.opacity(0.72))
            }
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainHapticButtonStyle())
    }
}

#if DEBUG
private struct DeveloperToolsSection: View {
    @ObservedObject var account: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEVELOPER")
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.secondary)

            VStack(spacing: 10) {
                Button {
                    Task { await account.grantDeveloperCreditIfAvailable() }
                } label: {
                    Label("Grant Test API Credit", systemImage: "server.rack")
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(InkButtonStyle())
                .disabled(!account.isSignedIn)
            }
            .panelStyle()
        }
    }
}
#endif

private struct KeyboardSetupScreen: View {
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button(action: close) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppTheme.ink)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainHapticButtonStyle())
                .accessibilityLabel("Back")

                ScreenTitle(kicker: "Keyboard", title: "Set up voice typing", detail: "VoiceType uses the microphone in the background so you can dictate into text fields in other apps.")

                KeyboardToggleIllustration()
                    .accessibilityHidden(true)
                Text("Example settings — enable these in the Settings app.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondary)

                VStack(spacing: 0) {
                    SetupStep(index: "01", title: "Open Settings", detail: "Go to Settings → General → Keyboard → Keyboards.")
                    Divider().background(AppTheme.borderSoft)
                    SetupStep(index: "02", title: "Add VoiceType", detail: "Tap Add New Keyboard and choose VoiceType.")
                    Divider().background(AppTheme.borderSoft)
                    SetupStep(index: "03", title: "Allow Full Access", detail: "Tap VoiceType, then enable Allow Full Access so your keyboard can receive transcripts and control recording.")
                    Divider().background(AppTheme.borderSoft)
                    SetupStep(index: "04", title: "Turn on the background microphone", detail: "Return to VoiceType, sign in, and on Home tap Turn on keyboard mic. Allow microphone access when asked. You need credit to transcribe a clip.")
                    Divider().background(AppTheme.borderSoft)
                    SetupStep(index: "05", title: "Dictate in another app", detail: "Open a text field and use the globe key to select VoiceType. Tap the microphone icon to start, then the waveform to finish. Keep that field open until your text appears. You can also copy your transcript from History.")
                }

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(InkButtonStyle())

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.accentDeep)
                    Text("The microphone stays active until the selected session ends or you tap Turn off keyboard mic on Home. Only clips you start are sent for transcription. A phone call or another audio interruption can end the session; return to VoiceType to turn it on again. Some apps and secure text fields use the system keyboard instead.")
                        .font(.system(size: 12.5, weight: .medium))
                        .lineSpacing(3)
                        .foregroundStyle(AppTheme.inkSoft)
                }
                .padding(14)
                .background(AppTheme.accentTint)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 30)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.background.ignoresSafeArea())
    }
}

private struct KeyboardToggleIllustration: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 10) {
                    VoiceTypeMark()
                        .frame(width: 25, height: 22)
                    Text("VoiceType")
                        .font(.system(size: 15, weight: .medium))
                }
                Spacer()
                TogglePill()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 11)

            Divider().background(AppTheme.borderSoft)

            HStack {
                Text("Allow Full Access")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                TogglePill()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 11)
        }
        .padding(18)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }
}

private struct TogglePill: View {
    var body: some View {
        Capsule()
            .fill(AppTheme.accent)
            .frame(width: 44, height: 26)
            .overlay(alignment: .trailing) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 3)
            }
    }
}

private struct SetupStep: View {
    let index: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(index)
                .font(AppTheme.serif(26, weight: .regular))
                .foregroundStyle(AppTheme.accentDeep)
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(detail)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(AppTheme.inkSoft)
            }
            Spacer()
        }
        .padding(.vertical, 14)
    }
}

private struct RecordingLimitPicker: View {
    @Binding var selection: RecordingDurationLimit
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session length")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(AppTheme.secondary)

            HStack(spacing: 6) {
                ForEach(RecordingDurationLimit.allCases) { limit in
                    Button {
                        guard !isDisabled else { return }
                        withAnimation(.snappy) {
                            selection = limit
                        }
                    } label: {
                        Text(limit.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selection == limit ? AppTheme.surface : AppTheme.inkSoft)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .background(selection == limit ? AppTheme.ink : AppTheme.surface.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selection == limit ? Color.clear : AppTheme.borderSoft, lineWidth: 1)
                            }
                    }
                    .disabled(isDisabled)
                    .buttonStyle(PlainHapticButtonStyle())
                    .accessibilityAddTraits(selection == limit ? .isSelected : [])
                }
            }

            Text("Keeps keyboard mic available for repeated clips. Time starts when you turn on the mic; starting or stopping a clip does not reset it. Changes apply to the current session.")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if selection == .always {
                Text("Forever lasts until you turn off the mic or iOS ends the session.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(isDisabled ? 0.62 : 1)
    }
}

private enum RecorderPanel {
    static func format(_ elapsedSeconds: TimeInterval) -> String {
        let total = max(0, Int(elapsedSeconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
        }
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

private struct ProcessingRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(AppTheme.coral)
            Text("Transcribing")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.inkSoft)
            Spacer()
        }
        .padding(12)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ScreenTitle: View {
    let kicker: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KickerText(text: kicker)
            Text(title)
                .font(AppTheme.serif(34, weight: .regular))
                .foregroundStyle(AppTheme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: 14.5, weight: .regular))
                    .lineSpacing(4)
                    .foregroundStyle(AppTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct EmptyStateCard: View {
    let systemName: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(AppTheme.secondary)
            Text(title)
                .font(AppTheme.serif(24, weight: .regular))
                .foregroundStyle(AppTheme.ink)
            Text(detail)
                .font(.system(size: 14, weight: .medium))
                .lineSpacing(4)
                .foregroundStyle(AppTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(26)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }
}

private struct CircleIcon: View {
    let systemName: String
    let foreground: Color
    let background: Color

    var body: some View {
        Circle()
            .fill(background)
            .frame(width: 54, height: 54)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(foreground)
            }
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.surface)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(AppTheme.ink)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 8)
    }
}
