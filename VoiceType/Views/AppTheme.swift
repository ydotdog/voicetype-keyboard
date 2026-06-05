import SwiftUI
import UIKit

enum AppTheme {
    static let background = dynamicColor(light: UIColor(red: 0.953, green: 0.929, blue: 0.882, alpha: 1),
                                         dark: UIColor(red: 0.082, green: 0.075, blue: 0.055, alpha: 1))
    static let surface = dynamicColor(light: UIColor(red: 0.984, green: 0.969, blue: 0.937, alpha: 1),
                                      dark: UIColor(red: 0.118, green: 0.106, blue: 0.078, alpha: 1))
    static let surface2 = dynamicColor(light: .white,
                                       dark: UIColor(red: 0.149, green: 0.133, blue: 0.090, alpha: 1))
    static let ink = dynamicColor(light: UIColor(red: 0.106, green: 0.094, blue: 0.075, alpha: 1),
                                  dark: UIColor(red: 0.945, green: 0.922, blue: 0.863, alpha: 1))
    static let inkSoft = dynamicColor(light: UIColor(red: 0.298, green: 0.275, blue: 0.231, alpha: 1),
                                      dark: UIColor(red: 0.733, green: 0.698, blue: 0.627, alpha: 1))
    static let secondary = dynamicColor(light: UIColor(red: 0.549, green: 0.522, blue: 0.463, alpha: 1),
                                        dark: UIColor(red: 0.518, green: 0.486, blue: 0.424, alpha: 1))
    static let accent = dynamicColor(light: UIColor(red: 0.878, green: 0.631, blue: 0.102, alpha: 1),
                                     dark: UIColor(red: 0.941, green: 0.737, blue: 0.271, alpha: 1))
    static let accentDeep = dynamicColor(light: UIColor(red: 0.290, green: 0.337, blue: 0.239, alpha: 1),
                                         dark: UIColor(red: 0.941, green: 0.737, blue: 0.271, alpha: 1))
    static let accentTint = accent.opacity(0.16)
    static let coral = dynamicColor(light: UIColor(red: 0.812, green: 0.290, blue: 0.125, alpha: 1),
                                    dark: UIColor(red: 0.941, green: 0.380, blue: 0.184, alpha: 1))
    static let liveTint = coral.opacity(0.12)
    static let mint = accentDeep
    static let border = ink.opacity(0.12)
    static let borderSoft = ink.opacity(0.07)

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        })
    }
}

extension View {
    func panelStyle() -> some View {
        padding(18)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
    }
}

struct VoiceTypeLogo: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            VoiceTypeMark()
                .frame(width: compact ? 26 : 34, height: compact ? 22 : 28)
            wordmark
        }
    }

    private var wordmark: some View {
        (Text("Voice")
            .font(AppTheme.serif(compact ? 15 : 22, weight: .medium))
            .foregroundStyle(AppTheme.ink)
        + Text("Type")
            .font(AppTheme.serif(compact ? 15 : 22, weight: .medium))
            .italic()
            .foregroundStyle(AppTheme.ink))
    }
}

struct VoiceTypeMark: View {
    private let barHeights: [CGFloat] = [10, 18, 24, 16, 8]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(barHeights.enumerated()), id: \.offset) { _, height in
                Capsule(style: .continuous)
                    .fill(AppTheme.ink)
                    .frame(width: 2.5, height: height)
            }

            Capsule(style: .continuous)
                .fill(AppTheme.accent)
                .frame(width: 2.5, height: 24)
        }
    }
}

struct LiveWaveform: View {
    var color = AppTheme.coral
    var dense = false

    private let bars: [CGFloat] = [18, 34, 48, 26, 58, 68, 34, 50, 72, 40, 24, 52, 62, 28, 44, 56, 22, 48]

    var body: some View {
        HStack(alignment: .center, spacing: dense ? 3 : 5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                Capsule(style: .continuous)
                    .fill(color.opacity(index.isMultiple(of: 3) ? 0.72 : 1))
                    .frame(width: dense ? 3 : 4, height: dense ? height * 0.54 : height)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct KickerText: View {
    let text: String
    var color = AppTheme.secondary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(3.2)
            .foregroundStyle(color)
    }
}

struct InkButtonStyle: ButtonStyle {
    var color = AppTheme.ink
    var foreground = AppTheme.surface

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(foreground)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .modifier(HapticPressModifier(isPressed: configuration.isPressed, style: .medium))
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
            .background(AppTheme.surface2.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .modifier(HapticPressModifier(isPressed: configuration.isPressed, style: .light))
    }
}

struct PlainHapticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .modifier(HapticPressModifier(isPressed: configuration.isPressed, style: .light))
    }
}

private struct HapticPressModifier: ViewModifier {
    let isPressed: Bool
    let style: UIImpactFeedbackGenerator.FeedbackStyle

    func body(content: Content) -> some View {
        content.onChange(of: isPressed) { _, newValue in
            guard newValue else { return }
            UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: 0.85)
        }
    }
}
