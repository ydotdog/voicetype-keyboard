import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var viewModel: KeyboardViewModel
    let insert: (String) -> Void
    let openRecorder: () -> Void
    let nextKeyboard: () -> Void

    private var hasText: Bool {
        !viewModel.snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: nextKeyboard) {
                    Image(systemName: "globe")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(KeyboardIconButtonStyle())
                .accessibilityLabel("Next keyboard")

                VStack(alignment: .leading, spacing: 4) {
                    Text("VoiceType")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(KeyboardPalette.ink)
                    Text(hasText ? viewModel.snapshot.text : "Record in app")
                        .font(.caption)
                        .foregroundStyle(hasText ? KeyboardPalette.ink.opacity(0.72) : KeyboardPalette.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(KeyboardIconButtonStyle())
                .accessibilityLabel("Refresh")
            }

            HStack(spacing: 10) {
                Button {
                    openRecorder()
                } label: {
                    Label("Record", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(KeyboardPrimaryButtonStyle(color: KeyboardPalette.accent))

                Button {
                    insert(viewModel.snapshot.text)
                } label: {
                    Label("Insert", systemImage: "text.insert")
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(KeyboardPrimaryButtonStyle(color: hasText ? KeyboardPalette.ink : KeyboardPalette.disabled))
                .disabled(!hasText)
            }

            HStack {
                if let charge = viewModel.snapshot.chargeText, hasText {
                    Text(charge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(KeyboardPalette.secondary)
                }
                Spacer()
                Image(systemName: hasText ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(hasText ? KeyboardPalette.mint : KeyboardPalette.secondary.opacity(0.4))
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 172)
        .background(KeyboardPalette.background)
    }
}

private enum KeyboardPalette {
    static let background = Color(red: 0.945, green: 0.952, blue: 0.948)
    static let surface = Color.white
    static let ink = Color(red: 0.075, green: 0.086, blue: 0.100)
    static let secondary = Color(red: 0.380, green: 0.405, blue: 0.430)
    static let accent = Color(red: 0.080, green: 0.560, blue: 0.760)
    static let mint = Color(red: 0.060, green: 0.600, blue: 0.430)
    static let disabled = Color(red: 0.600, green: 0.620, blue: 0.640)
}

private struct KeyboardIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(KeyboardPalette.ink)
            .background(KeyboardPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct KeyboardPrimaryButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
