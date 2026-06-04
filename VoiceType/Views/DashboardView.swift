import AuthenticationServices
import StoreKit
import SwiftUI
import UIKit

struct DashboardView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var appState: AppState
    @StateObject private var recorder = RecordingController()
    @StateObject private var store = StoreKitService()
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: account.isSignedIn ? 18 : 0) {
                    if account.isSignedIn {
                        AppHeader()
                            .environmentObject(account)
                        BalanceHero(balanceText: account.balanceText, identity: account.email)
                        RecorderPanel(recorder: recorder)
                            .environmentObject(account)
                        RecentTranscriptPanel(snapshot: recorder.lastTranscript, copied: copied) {
                            UIPasteboard.general.string = recorder.lastTranscript.text
                            withAnimation(.snappy) { copied = true }
                            Task {
                                try? await Task.sleep(for: .seconds(1.2))
                                await MainActor.run {
                                    withAnimation(.snappy) { copied = false }
                                }
                            }
                        }
                        StorePanel(store: store)
                            .environmentObject(account)
                        KeyboardSetupPanel()
                        #if DEBUG
                        DeveloperToolsPanel()
                            .environmentObject(account)
                        #endif
                    } else {
                        SignInPanel()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, account.isSignedIn ? 16 : 34)
                .padding(.bottom, 30)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $appState.isRecorderPresented) {
                RecorderSheet(recorder: recorder)
                    .environmentObject(account)
                    .environmentObject(appState)
                    .presentationDetents([.height(360), .medium])
                    .presentationDragIndicator(.visible)
            }
            .task {
                await account.refresh()
                #if DEBUG
                await account.grantDeveloperCreditIfAvailable()
                #endif
                if account.isSignedIn {
                    await store.loadProducts()
                }
                recorder.refreshLatest()
            }
            .onChange(of: account.isSignedIn) { _, isSignedIn in
                guard isSignedIn else { return }
                Task {
                    await account.refresh()
                    #if DEBUG
                    await account.grantDeveloperCreditIfAvailable()
                    #endif
                    await store.loadProducts()
                    recorder.refreshLatest()
                }
            }
        }
    }
}

private struct AppHeader: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        HStack(spacing: 12) {
            VoiceTypeLogo(compact: true)
            Spacer()
            Button {
                account.signOut()
            } label: {
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.surface.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.borderSoft, lineWidth: 1)
                    }
            }
            .accessibilityLabel("Sign out")
        }
    }
}

private struct BalanceHero: View {
    let balanceText: String
    let identity: String

    var body: some View {
        VStack(spacing: 8) {
            KickerText(text: "Balance")

            Text(balanceText)
                .font(AppTheme.serif(56, weight: .regular))
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.46)
                .frame(maxWidth: .infinity)

            Text("Credit never expires")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.secondary)

            Text(identity.isEmpty ? "Signed in" : identity)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.secondary.opacity(0.74))
                .lineLimit(1)
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

private struct SignInPanel: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VoiceTypeLogo()
                .padding(.top, 28)

            VStack(alignment: .leading, spacing: 16) {
                KickerText(text: "Speech to text · paid by use")

                VStack(alignment: .leading, spacing: -2) {
                    Text("Voice,")
                        .font(AppTheme.serif(58, weight: .regular))
                        .foregroundStyle(AppTheme.ink)
                    Text("set in type.")
                        .font(AppTheme.serif(50, weight: .regular))
                        .italic()
                        .foregroundStyle(AppTheme.accentDeep)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.72)

                Text("Dictate anywhere. Your words come back as clean, copy-ready text, and your credit never expires.")
                    .font(.system(size: 17, weight: .regular))
                    .lineSpacing(5)
                    .foregroundStyle(AppTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 12)
            }

            Spacer(minLength: 60)

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email, .fullName]
                } onCompletion: { result in
                    Task { await handle(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                #if DEBUG
                Button {
                    account.enterPreviewMode()
                } label: {
                    Label("Developer Preview", systemImage: "hammer")
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(GhostButtonStyle())
                #endif

                if let error = account.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 690, alignment: .topLeading)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) async {
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
            account.errorMessage = error.localizedDescription
        }
    }
}

private struct RecorderPanel: View {
    @ObservedObject var recorder: RecordingController
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        VStack(spacing: 14) {
            if recorder.isRecording {
                recordingCard
            } else {
                idleRecordButton
            }

            RecordingLimitPicker(
                selection: $recorder.durationLimit,
                isDisabled: recorder.isRecording || recorder.isProcessing
            )

            if recorder.isRecording {
                HStack(spacing: 10) {
                    Button {
                        Task { await recorder.stopAndTranscribe(account: account) }
                    } label: {
                        Label("Stop & transcribe", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(InkButtonStyle(color: AppTheme.coral, foreground: .white))

                    Button {
                        recorder.cancel()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityLabel("Cancel recording")
                }
            }

            if recorder.isProcessing {
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

            if let error = recorder.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var idleRecordButton: some View {
        Button {
            Task { await recorder.startRecording(account: account) }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppTheme.accent)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Record a clip")
                        .font(AppTheme.serif(22, weight: .medium))
                    Text("Tap to dictate · charged by the second")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.surface.opacity(0.72))
                }

                Spacer()
            }
            .foregroundStyle(AppTheme.surface)
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(AppTheme.ink)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .disabled(recorder.isProcessing)
        .opacity(recorder.isProcessing ? 0.72 : 1)
    }

    private var recordingCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(AppTheme.coral)
                    .frame(width: 7, height: 7)
                KickerText(text: "Recording", color: AppTheme.coral)
                Spacer()
                Text(timerText)
                    .font(AppTheme.serif(24, weight: .regular))
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()
            }

            LiveWaveform(dense: true)
                .frame(height: 54)
        }
        .padding(16)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.coral.opacity(0.18), lineWidth: 1)
        }
    }

    private var timerText: String {
        Self.format(recorder.elapsedSeconds)
    }

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

private struct RecorderSheet: View {
    @ObservedObject var recorder: RecordingController
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var handledRequestID: UUID?

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(AppTheme.border)
                .frame(width: 50, height: 5)

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
                    .font(AppTheme.serif(36, weight: .regular))
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()

                LiveWaveform()
                    .frame(height: 94)

                Button {
                    Task {
                        await recorder.stopAndTranscribe(account: account)
                        dismiss()
                    }
                } label: {
                    Label("Stop & transcribe", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(InkButtonStyle(color: AppTheme.coral, foreground: .white))

                Button("Cancel") {
                    recorder.cancel()
                    dismiss()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondary)
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
                            .background(selection == limit ? AppTheme.ink : AppTheme.surface2.opacity(0.58))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selection == limit ? Color.clear : AppTheme.borderSoft, lineWidth: 1)
                            }
                    }
                    .disabled(isDisabled)
                }
            }
        }
        .opacity(isDisabled ? 0.62 : 1)
    }
}

private struct RecentTranscriptPanel: View {
    let snapshot: TranscriptSnapshot
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                KickerText(text: "Latest transcript")
                Spacer()
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .disabled(snapshot.text.isEmpty)
                .foregroundStyle(snapshot.text.isEmpty ? AppTheme.secondary.opacity(0.45) : AppTheme.ink)
                .background(AppTheme.surface2.opacity(0.52))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Copy transcript")
            }

            Text(snapshot.text.isEmpty ? "No transcripts yet." : snapshot.text)
                .font(AppTheme.serif(snapshot.text.isEmpty ? 22 : 21, weight: .regular))
                .foregroundStyle(snapshot.text.isEmpty ? AppTheme.secondary : AppTheme.ink)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let charge = snapshot.chargeText, !charge.isEmpty {
                Text("Charged \(charge)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.secondary)
            }
        }
        .panelStyle()
    }
}

private struct StorePanel: View {
    @ObservedObject var store: StoreKitService
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                KickerText(text: "Credit packs")
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .tint(AppTheme.ink)
                }
            }

            if store.products.isEmpty {
                Button {
                    Task { await store.loadProducts() }
                } label: {
                    Label("Reload packs", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                VStack(spacing: 10) {
                    ForEach(store.products) { product in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(product.displayName)
                                    .font(AppTheme.serif(20, weight: .medium))
                                    .foregroundStyle(AppTheme.ink)
                                Text(product.description)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppTheme.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 12)

                            Button {
                                Task { await store.purchase(product, account: account) }
                            } label: {
                                Text(product.displayPrice)
                                    .font(.system(size: 14, weight: .bold))
                                    .padding(.horizontal, 14)
                                    .frame(height: 38)
                            }
                            .buttonStyle(InkButtonStyle())
                            .disabled(store.isLoading)
                        }
                        .padding(14)
                        .background(AppTheme.surface2.opacity(product.id.contains("medium") ? 0.84 : 0.44))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(product.id.contains("medium") ? AppTheme.accent.opacity(0.48) : AppTheme.borderSoft, lineWidth: 1)
                        }
                    }
                }
            }

            if let error = store.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelStyle()
    }
}

private struct KeyboardSetupPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                KickerText(text: "Keyboard")
                Spacer()
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .foregroundStyle(AppTheme.ink)
                .background(AppTheme.surface2.opacity(0.52))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Open Settings")
            }

            VStack(spacing: 10) {
                SetupRow(index: "1", title: "Open Settings", detail: "General → Keyboard → Keyboards")
                SetupRow(index: "2", title: "Add VoiceType", detail: "Choose VoiceType and enable Full Access")
            }
        }
        .panelStyle()
    }
}

private struct SetupRow: View {
    let index: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Text(index)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 28, height: 28)
                .background(AppTheme.accentTint)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(12)
        .background(AppTheme.surface2.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#if DEBUG
private struct DeveloperToolsPanel: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            KickerText(text: "Developer")

            Text("Debug-only controls for device testing.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.secondary)

            Button {
                Task { await account.grantDeveloperCreditIfAvailable() }
            } label: {
                Label("Grant Test API Credit", systemImage: "server.rack")
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(InkButtonStyle())
            .disabled(!account.isSignedIn || account.isPreviewMode)

            Button {
                if account.isPreviewMode {
                    account.addLocalTestCredit()
                } else {
                    account.enterPreviewMode()
                }
            } label: {
                Label(account.isPreviewMode ? "Add Preview Credit" : "Switch to Preview", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(InkButtonStyle(color: AppTheme.accent, foreground: AppTheme.ink))
        }
        .panelStyle()
    }
}
#endif
