import Foundation
import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var viewModel: KeyboardViewModel
    let insert: (String) -> Void
    let startClip: () -> Void
    let stopClip: () -> Void
    let nextKeyboard: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            chrome

            if viewModel.isKeyboardRecording {
                recordingSurface
            } else if viewModel.isTranscribing {
                transcribingSurface
            } else {
                tapSurface
                helperLine
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .frame(height: viewModel.isRecording ? 210 : 224)
        .background(KeyboardPalette.keyboard)
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

    private var tapSurface: some View {
        Button {
            guard viewModel.isKeyboardReady else { return }
            startClip()
        } label: {
            VStack(spacing: 10) {
                Circle()
                    .fill(viewModel.isKeyboardReady ? KeyboardPalette.accent : KeyboardPalette.muted.opacity(0.38))
                    .frame(width: 52, height: 52)

                Text(viewModel.isKeyboardReady ? "Tap to talk" : "Open VoiceType")
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundStyle(KeyboardPalette.onInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 112)
        }
        .buttonStyle(KeyboardTapButtonStyle(enabled: viewModel.isKeyboardReady))
        .disabled(!viewModel.isKeyboardReady)
        .accessibilityLabel(viewModel.isKeyboardReady ? "Tap to talk" : "Open VoiceType to turn on keyboard microphone")
    }

    private var helperLine: some View {
        Text(viewModel.isKeyboardReady ? "Tap once to start a clip. Tap again to finish and insert." : "Turn on keyboard mic in VoiceType first.")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(KeyboardPalette.muted)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
    }

    private var recordingSurface: some View {
        Button(action: stopClip) {
            VStack(spacing: 12) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(KeyboardPalette.live)
                        .frame(width: 8, height: 8)
                    KeyboardKicker("Recording clip", color: KeyboardPalette.live)
                    Spacer()
                    Text(viewModel.recordingState.durationLimit.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KeyboardPalette.muted)
                }

                KeyboardWaveform()
                    .frame(height: 52)

                Text("Tap to finish")
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundStyle(KeyboardPalette.live)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(KeyboardRecordingButtonStyle())
        .accessibilityLabel("Tap to finish recording")
    }

    private var transcribingSurface: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(KeyboardPalette.live)
                    .frame(width: 8, height: 8)
                KeyboardKicker("Transcribing", color: KeyboardPalette.live)
                Spacer()
                Text(viewModel.recordingState.durationLimit.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KeyboardPalette.muted)
            }

            KeyboardWaveform()
                .frame(height: 52)

            Text("Setting your words in type")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(KeyboardPalette.ink)
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

private struct KeyboardTapButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(enabled ? KeyboardPalette.ink : KeyboardPalette.ink.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct KeyboardRecordingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(KeyboardPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(KeyboardPalette.live.opacity(0.18), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
