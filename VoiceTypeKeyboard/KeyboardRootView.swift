import Foundation
import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var viewModel: KeyboardViewModel
    let insert: (String) -> Void
    let openRecorder: () -> Void
    let stopRecording: () -> Void
    let nextKeyboard: () -> Void
    @State private var didBeginHold = false

    var body: some View {
        VStack(spacing: 12) {
            chrome

            if viewModel.isRecording {
                recordingSurface
            } else {
                holdSurface
                helperLine
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .frame(height: viewModel.isRecording ? 210 : 224)
        .background(KeyboardPalette.keyboard)
        .onAppear {
            didBeginHold = false
        }
    }

    private var chrome: some View {
        HStack(spacing: 14) {
            Button(action: nextKeyboard) {
                Image(systemName: "globe")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(KeyboardChromeButtonStyle())
            .accessibilityLabel("Next keyboard")

            HStack(spacing: 7) {
                KeyboardMark()
                    .frame(width: 28, height: 24)
                wordmark
            }
            .foregroundStyle(KeyboardPalette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(compactBalanceText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(KeyboardPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(minWidth: 46, alignment: .trailing)

            Button(action: nextKeyboard) {
                Text("ABC")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 50, height: 46)
            }
            .buttonStyle(KeyboardChromeButtonStyle())
            .accessibilityLabel("Switch keyboard")
        }
    }

    private var wordmark: some View {
        (Text("Voice")
            .font(.system(size: 22, weight: .medium, design: .serif))
        + Text("Type")
            .font(.system(size: 22, weight: .medium, design: .serif))
            .italic())
    }

    private var holdSurface: some View {
        VStack(spacing: 10) {
            Circle()
                .fill(KeyboardPalette.accent)
                .frame(width: 52, height: 52)

            Text("Hold to talk")
                .font(.system(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(KeyboardPalette.onInk)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .background(KeyboardPalette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .scaleEffect(didBeginHold ? 0.985 : 1)
        .opacity(didBeginHold ? 0.82 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !didBeginHold else { return }
                    didBeginHold = true
                    openRecorder()
                }
                .onEnded { _ in
                    didBeginHold = false
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold to talk")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if !didBeginHold {
                didBeginHold = true
                openRecorder()
            }
        }
    }

    private var helperLine: some View {
        Text("Press & hold, speak, release — your words drop straight in.")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(KeyboardPalette.muted)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
    }

    private var recordingSurface: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(KeyboardPalette.live)
                    .frame(width: 8, height: 8)
                KeyboardKicker("Recording", color: KeyboardPalette.live)
                Spacer()
                Text(viewModel.recordingState.durationLimit.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KeyboardPalette.muted)
            }

            KeyboardWaveform()
                .frame(height: 52)

            Button(action: stopRecording) {
                Label("Stop & transcribe", systemImage: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(KeyboardLiveButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(KeyboardPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(KeyboardPalette.live.opacity(0.18), lineWidth: 1)
        }
    }

    private var compactBalanceText: String {
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
}

private struct KeyboardPalette {
    static let keyboard = Color(red: 0.906, green: 0.882, blue: 0.831)
    static let surface = Color(red: 0.984, green: 0.969, blue: 0.937)
    static let surface2 = Color.white
    static let ink = Color(red: 0.106, green: 0.094, blue: 0.075)
    static let onInk = Color(red: 0.984, green: 0.969, blue: 0.937)
    static let muted = Color(red: 0.549, green: 0.522, blue: 0.463)
    static let accent = Color(red: 0.878, green: 0.631, blue: 0.102)
    static let live = Color(red: 0.812, green: 0.290, blue: 0.125)
    static let lineSoft = Color(red: 0.106, green: 0.094, blue: 0.075).opacity(0.07)
}

private struct KeyboardKicker: View {
    let text: String
    var color = KeyboardPalette.muted

    init(_ text: String, color: Color = KeyboardPalette.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(2.8)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

private struct KeyboardMark: View {
    private let heights: [CGFloat] = [10, 18, 24, 16, 8]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule(style: .continuous)
                    .fill(KeyboardPalette.ink)
                    .frame(width: 2.4, height: height)
            }
            Capsule(style: .continuous)
                .fill(KeyboardPalette.accent)
                .frame(width: 2.4, height: 24)
        }
    }
}

private struct KeyboardWaveform: View {
    private let bars: [CGFloat] = [18, 30, 42, 24, 49, 35, 20, 45, 39, 26, 48, 31, 19, 40, 34, 22]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                Capsule(style: .continuous)
                    .fill(KeyboardPalette.live.opacity(index.isMultiple(of: 4) ? 0.72 : 1))
                    .frame(width: 3, height: height)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct KeyboardChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(KeyboardPalette.ink)
            .background(KeyboardPalette.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(KeyboardPalette.lineSoft, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.66 : 1)
    }
}

private struct KeyboardLiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(KeyboardPalette.live)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
