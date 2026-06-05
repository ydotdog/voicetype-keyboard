import AuthenticationServices
import StoreKit
import SwiftUI
import UIKit

struct DashboardView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var appState: AppState
    @StateObject private var recorder = RecordingController()
    @StateObject private var store = StoreKitService()
    @State private var selectedTab: VoiceTypeTab = .home
    @State private var isKeyboardSetupPresented = false
    @State private var transcriptHistory = SharedTranscriptStore.history
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AppTheme.background.ignoresSafeArea()

                if account.isSignedIn {
                    signedInContent
                } else {
                    SignInScreen()
                        .environmentObject(account)
                }

                if let toastMessage {
                    ToastView(message: toastMessage)
                        .padding(.bottom, account.isSignedIn ? 92 : 26)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $appState.isRecorderPresented) {
                RecorderSheet(recorder: recorder) {
                    refreshHistory()
                }
                .environmentObject(account)
                .environmentObject(appState)
                .presentationDetents([.height(470), .medium])
                .presentationDragIndicator(.visible)
            }
            .task {
                await initialLoad()
            }
            .task(id: appState.keyboardMicRequestID) {
                await handleKeyboardMicRequest()
            }
            .task(id: appState.keyboardSetupRequestID) {
                handleKeyboardSetupRequest()
            }
            .onChange(of: account.isSignedIn) { _, isSignedIn in
                guard isSignedIn else {
                    transcriptHistory = []
                    selectedTab = .home
                    isKeyboardSetupPresented = false
                    return
                }
                Task { await signedInLoad() }
            }
            .onChange(of: recorder.lastTranscript) { _, _ in
                refreshHistory()
            }
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
        if isKeyboardSetupPresented {
            KeyboardSetupScreen {
                withAnimation(.snappy) {
                    isKeyboardSetupPresented = false
                }
            }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    Group {
                        switch selectedTab {
                        case .home:
                            HomeScreen(
                                account: account,
                                recorder: recorder,
                                latest: recorder.lastTranscript,
                                copyLatest: copyLatestTranscript,
                                openHistory: {
                                    withAnimation(.snappy) { selectedTab = .history }
                                },
                                openSettings: {
                                    withAnimation(.snappy) { selectedTab = .settings }
                                },
                                openRecorder: {
                                    appState.presentRecorder(autoStart: false)
                                }
                            )
                        case .history:
                            HistoryScreen(history: transcriptHistory, copy: copyTranscript)
                        case .credit:
                            CreditScreen(store: store, account: account)
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
                    .padding(.bottom, 106)
                }

                VoiceTypeTabBar(selection: $selectedTab)
            }
        }
    }

    private func initialLoad() async {
        await account.refresh()
        #if DEBUG
        await account.grantDeveloperCreditIfAvailable()
        #endif
        if account.isSignedIn {
            await signedInLoad()
        }
        recorder.refreshLatest()
        refreshHistory()
    }

    private func signedInLoad() async {
        await account.refresh()
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

    private func copyLatestTranscript() {
        copyTranscript(recorder.lastTranscript)
    }

    private func copyTranscript(_ snapshot: TranscriptSnapshot) {
        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UIPasteboard.general.string = snapshot.text
        showToast("Copied")
    }

    private func handleKeyboardMicRequest() async {
        guard appState.keyboardMicRequestID != nil else { return }
        account.errorMessage = nil

        withAnimation(.snappy) {
            selectedTab = .home
            isKeyboardSetupPresented = false
        }

        guard appState.consumeKeyboardMicAutoStart() else { return }
        guard account.isSignedIn else {
            showToast("Sign in to turn on keyboard mic")
            return
        }
        guard !recorder.isKeyboardReady else {
            showToast("Keyboard mic is already on")
            return
        }
        guard !recorder.isRecording, !recorder.isProcessing else {
            showToast("Finish the current recording first")
            return
        }

        await recorder.startKeyboardReady(account: account)
        if recorder.isKeyboardReady {
            showToast("Keyboard mic is on. Return to your app.")
        }
    }

    private func handleKeyboardSetupRequest() {
        guard appState.keyboardSetupRequestID != nil else { return }
        account.errorMessage = nil

        guard account.isSignedIn else {
            showToast("Sign in, then enable Full Access")
            return
        }
        withAnimation(.snappy) {
            selectedTab = .settings
            isKeyboardSetupPresented = true
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.snappy) {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(1.25))
            await MainActor.run {
                withAnimation(.snappy) {
                    if toastMessage == message {
                        toastMessage = nil
                    }
                }
            }
        }
    }
}

private enum VoiceTypeTab: String, CaseIterable, Identifiable {
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

private struct VoiceTypeTabBar: View {
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
        .padding(.bottom, 22)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
        }
    }
}

private struct SignInScreen: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
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
                SignInWithAppleButton(.signIn) { request in
                    account.errorMessage = nil
                    request.requestedScopes = [.email, .fullName]
                } onCompletion: { result in
                    Task { await handle(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .simultaneousGesture(TapGesture().onEnded {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.85)
                })

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
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            await account.signInWithApple(
                identityToken: identityToken,
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

private struct HomeScreen: View {
    @ObservedObject var account: AccountStore
    @ObservedObject var recorder: RecordingController
    let latest: TranscriptSnapshot
    let copyLatest: () -> Void
    let openHistory: () -> Void
    let openSettings: () -> Void
    let openRecorder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HeaderRow(openSettings: openSettings)

            BalanceBlock(balanceText: account.balanceText, identity: account.email)

            VStack(spacing: 12) {
                if recorder.isKeyboardReady {
                    KeyboardMicStatusCard(recorder: recorder)
                    Button {
                        recorder.stopKeyboardReady()
                    } label: {
                        Label("Turn off keyboard mic", systemImage: "mic.slash.fill")
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
                    .disabled(recorder.isProcessing)
                }

                Button {
                    openRecorder()
                } label: {
                    Label("Record a clip in VoiceType", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(GhostButtonStyle())
            }

            RecordingLimitPicker(
                selection: $recorder.durationLimit,
                isDisabled: recorder.isProcessing
            )

            if recorder.isProcessing {
                ProcessingRow()
            }

            if let error = recorder.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LatestTranscriptCard(snapshot: latest, copy: copyLatest, openHistory: openHistory)
        }
    }
}

private struct HeaderRow: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VoiceTypeLogo(compact: true)
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(AppTheme.inkSoft)
            }
            .buttonStyle(PlainHapticButtonStyle())
            .accessibilityLabel("Settings")
        }
    }
}

private struct BalanceBlock: View {
    let balanceText: String
    let identity: String

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

            VStack(spacing: 3) {
                Text("Credit never expires")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(identity.isEmpty ? "Signed in" : identity)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(AppTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
                    text: recorder.isKeyboardRecording ? "Saving clip" : recorder.isKeyboardTranscribing ? "Transcribing" : "Keyboard mic on",
                    color: recorder.isKeyboardRecording || recorder.isKeyboardTranscribing ? AppTheme.coral : AppTheme.accentDeep
                )
                Spacer()
                Text(RecorderPanel.format(recorder.elapsedSeconds))
                    .font(AppTheme.serif(24, weight: .regular))
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()
            }

            if recorder.isKeyboardRecording || recorder.isKeyboardTranscribing {
                LiveWaveform(dense: true)
                    .frame(height: 56)
            } else {
                Text("Switch to any app and tap VoiceType Keyboard to start and finish a clip.")
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(4)
                    .foregroundStyle(AppTheme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panelStyle()
    }
}

private struct LatestTranscriptCard: View {
    let snapshot: TranscriptSnapshot
    let copy: () -> Void
    let openHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                KickerText(text: "Latest transcript")
                Spacer()
                if !snapshot.text.isEmpty {
                    Button("History", action: openHistory)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AppTheme.accentDeep)
                        .buttonStyle(PlainHapticButtonStyle())
                }
            }

            if snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No transcripts yet. Turn on keyboard mic or record a clip to make your first.")
                    .font(.system(size: 14.5, weight: .medium))
                    .lineSpacing(4)
                    .foregroundStyle(AppTheme.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 10)
            } else {
                Text(snapshot.text)
                    .font(AppTheme.serif(20, weight: .regular))
                    .lineSpacing(5)
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if let charge = snapshot.chargeText, !charge.isEmpty {
                        Text("Charged \(charge)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.secondary)
                    }
                    Spacer()
                    Button(action: copy) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 13)
                            .frame(height: 36)
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
        }
        .panelStyle()
    }
}

private struct HistoryScreen: View {
    let history: [TranscriptSnapshot]
    let copy: (TranscriptSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(kicker: "Transcripts", title: "History")

            if history.isEmpty {
                EmptyStateCard(
                    systemName: "clock",
                    title: "Nothing here yet",
                    detail: "Your latest transcripts will appear here after the first recording."
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
                                    HistoryRow(snapshot: item) {
                                        copy(item)
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

    private var groupedHistory: [(day: String, items: [TranscriptSnapshot])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: history) { snapshot in
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
                    .frame(width: 34, height: 34)
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

private struct CreditScreen: View {
    @ObservedObject var store: StoreKitService
    @ObservedObject var account: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(
                kicker: "Pay as you go",
                title: "Add credit",
                detail: "Buy once, use whenever. Each clip is billed against your credit balance and your credit never expires."
            )

            VStack(spacing: 12) {
                if store.products.isEmpty {
                    Button {
                        Task { await store.loadProducts() }
                    } label: {
                        Label("Reload packs", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(GhostButtonStyle())
                } else {
                    ForEach(store.products) { product in
                        CreditPackCard(product: product, isPopular: product.id.contains("medium")) {
                            Task { await store.purchase(product, account: account) }
                        }
                        .disabled(store.isLoading)
                    }
                }
            }

            LedgerNoteCard()

            if let error = store.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CreditPackCard: View {
    let product: Product
    let isPopular: Bool
    let buy: () -> Void

    var body: some View {
        Button(action: buy) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Text(product.displayPrice)
                            .font(AppTheme.serif(30, weight: .regular))
                        if isPopular {
                            Text("POPULAR")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.8)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppTheme.accent)
                                .foregroundStyle(AppTheme.ink)
                                .clipShape(Capsule())
                        }
                    }

                    Text(product.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(product.description)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                }
                .foregroundStyle(isPopular ? AppTheme.surface : AppTheme.ink)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isPopular ? AppTheme.surface.opacity(0.58) : AppTheme.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(isPopular ? AppTheme.ink : AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isPopular ? Color.clear : AppTheme.border, lineWidth: 1)
            }
        }
        .buttonStyle(PlainHapticButtonStyle())
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
                    SettingsRow(title: "Restore purchases", detail: "", systemName: "arrow.clockwise") {
                        Task { await store.syncUnfinishedTransactions(account: account) }
                    }
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
            }
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .buttonStyle(PlainHapticButtonStyle())

            Text("VoiceType · v0.1")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppTheme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
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
                        .frame(width: 40, height: 40, alignment: .leading)
                }
                .buttonStyle(PlainHapticButtonStyle())

                ScreenTitle(kicker: "Keyboard", title: "Add the keyboard\nin three steps")

                KeyboardToggleIllustration()

                VStack(spacing: 0) {
                    SetupStep(index: "01", title: "Open Settings", detail: "Settings -> General -> Keyboard -> Keyboards.")
                    Divider().background(AppTheme.borderSoft)
                    SetupStep(index: "02", title: "Add VoiceType", detail: "Tap Add New Keyboard and choose VoiceType.")
                    Divider().background(AppTheme.borderSoft)
                    SetupStep(index: "03", title: "Allow Full Access", detail: "Enable Full Access so the keyboard can read VoiceType's latest transcript and recording state.")
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.accentDeep)
                    Text("Full Access is used for VoiceType's shared App Group state. The keyboard still cannot use the microphone directly; the VoiceType app owns the audio session.")
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

private struct RecorderSheet: View {
    @ObservedObject var recorder: RecordingController
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var handledRequestID: UUID?
    let onTranscript: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(AppTheme.border)
                .frame(width: 44, height: 5)

            if recorder.isProcessing {
                ProgressView()
                    .tint(AppTheme.coral)
                    .scaleEffect(1.12)
                KickerText(text: "Transcribing", color: AppTheme.coral)
                Text("Setting your words in type.")
                    .font(AppTheme.serif(26, weight: .regular))
                    .foregroundStyle(AppTheme.ink)
            } else if recorder.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(AppTheme.coral)
                        .frame(width: 7, height: 7)
                    KickerText(text: "Recording", color: AppTheme.coral)
                }

                Text(RecorderPanel.format(recorder.elapsedSeconds))
                    .font(AppTheme.serif(38, weight: .regular))
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()

                LiveWaveform()
                    .frame(height: 78)

                RecordingLimitPicker(selection: $recorder.durationLimit, isDisabled: false)
                    .padding(.horizontal, 2)

                Button {
                    Task {
                        await recorder.stopAndTranscribe(account: account)
                        onTranscript()
                        dismiss()
                    }
                } label: {
                    Label("Stop & transcribe", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(InkButtonStyle(color: AppTheme.coral, foreground: .white))

                Button("Cancel") {
                    recorder.cancel()
                    dismiss()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondary)
                .buttonStyle(PlainHapticButtonStyle())
            } else {
                VoiceTypeMark()
                    .frame(width: 42, height: 34)

                Text("Record a clip")
                    .font(AppTheme.serif(30, weight: .regular))
                    .foregroundStyle(AppTheme.ink)

                RecordingLimitPicker(selection: $recorder.durationLimit, isDisabled: false)
                    .padding(.horizontal, 2)

                Button {
                    Task { await recorder.startRecording(account: account) }
                } label: {
                    Label("Start recording", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(InkButtonStyle())
            }

            if let error = recorder.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.surface)
        .task(id: appState.recorderRequestID) {
            await handleRecorderRequest()
        }
    }

    private func handleRecorderRequest() async {
        guard handledRequestID != appState.recorderRequestID else { return }
        handledRequestID = appState.recorderRequestID
        guard appState.consumeRecorderAutoStart() else { return }
        guard account.isSignedIn else {
            KeyboardAutoInsertStore.clear()
            recorder.errorMessage = "Sign in before recording."
            return
        }
        guard !recorder.isRecording, !recorder.isProcessing else { return }
        await recorder.startRecording(account: account)
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
                            .frame(height: 36)
                            .background(selection == limit ? AppTheme.ink : AppTheme.surface.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selection == limit ? Color.clear : AppTheme.borderSoft, lineWidth: 1)
                            }
                    }
                    .disabled(isDisabled)
                    .buttonStyle(PlainHapticButtonStyle())
                }
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
