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
                VStack(spacing: 16) {
                    header

                    if account.isSignedIn {
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
                    } else {
                        SignInPanel()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("VoiceType")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                }
                if account.isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            account.signOut()
                        } label: {
                            Image(systemName: "person.crop.circle.badge.xmark")
                        }
                        .foregroundStyle(AppTheme.secondary)
                        .accessibilityLabel("Sign out")
                    }
                }
            }
            .sheet(isPresented: $appState.isRecorderPresented) {
                RecorderSheet(recorder: recorder)
                    .environmentObject(account)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .task {
                await account.refresh()
                await store.loadProducts()
                recorder.refreshLatest()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(account.isSignedIn ? account.balanceText : "$0.0000")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()
                Text(account.isSignedIn ? account.email : "Signed out")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondary)
                    .lineLimit(1)
            }

            Spacer()

            ZStack {
                Circle()
                    .fill(AppTheme.appGradient)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 66, height: 66)
            .shadow(color: AppTheme.accent.opacity(0.22), radius: 16, y: 8)
        }
        .panelStyle()
    }
}

private struct SignInPanel: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speech-to-text, paid by use")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text("Your credit balance stays available until you use it.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondary)
            }

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email, .fullName]
            } onCompletion: { result in
                Task { await handle(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button {
                account.enterPreviewMode()
            } label: {
                Label("Preview", systemImage: "eye")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(AppTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let error = account.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelStyle()
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
        case let .failure(error):
            account.errorMessage = error.localizedDescription
        }
    }
}

private struct RecorderPanel: View {
    @ObservedObject var recorder: RecordingController
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recorder.statusText)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text(recorder.isRecording ? "Tap stop when you are done" : "Start a short dictation")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondary)
                }
                Spacer()
                if recorder.isProcessing {
                    ProgressView()
                }
            }

            Button {
                Task {
                    if recorder.isRecording {
                        await recorder.stopAndTranscribe(account: account)
                    } else {
                        await recorder.startRecording()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    Text(recorder.isRecording ? "Stop" : "Record")
                }
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(recorder.isRecording ? AppTheme.coral : AppTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .disabled(recorder.isProcessing)

            if recorder.isRecording {
                Button {
                    recorder.cancel()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark")
                        Text("Cancel")
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(AppTheme.secondary)
            }

            if let error = recorder.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelStyle()
    }
}

private struct RecorderSheet: View {
    @ObservedObject var recorder: RecordingController
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(recorder.isRecording ? AppTheme.coral : AppTheme.accent)
                .frame(width: 72, height: 6)
            Text(recorder.statusText)
                .font(.title2.weight(.bold))
                .foregroundStyle(AppTheme.ink)

            Button {
                Task {
                    if recorder.isRecording {
                        await recorder.stopAndTranscribe(account: account)
                        dismiss()
                    } else {
                        await recorder.startRecording()
                    }
                }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(recorder.isRecording ? AppTheme.coral : AppTheme.accent)
                    .clipShape(Circle())
            }
            .disabled(recorder.isProcessing)

            if recorder.isProcessing {
                ProgressView()
            }

            if let error = recorder.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.coral)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }
}

private struct RecentTranscriptPanel: View {
    let snapshot: TranscriptSnapshot
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Latest text", systemImage: "text.quote")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(snapshot.text.isEmpty)
                .foregroundStyle(snapshot.text.isEmpty ? AppTheme.secondary.opacity(0.45) : AppTheme.accent)
                .accessibilityLabel("Copy transcript")
            }

            Text(snapshot.text.isEmpty ? "No transcript yet" : snapshot.text)
                .font(.body)
                .foregroundStyle(snapshot.text.isEmpty ? AppTheme.secondary : AppTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let charge = snapshot.chargeText, !charge.isEmpty {
                Text("Charged \(charge)")
                    .font(.caption)
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
                Label("Add credit", systemImage: "creditcard")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                if store.isLoading {
                    ProgressView()
                }
            }

            if store.products.isEmpty {
                Button {
                    Task { await store.loadProducts() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                VStack(spacing: 10) {
                    ForEach(store.products) { product in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(product.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                Text(product.description)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button {
                                Task { await store.purchase(product, account: account) }
                            } label: {
                                Text(product.displayPrice)
                                    .font(.subheadline.weight(.bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.ink)
                            .disabled(store.isLoading)
                        }
                        .padding(12)
                        .background(AppTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
