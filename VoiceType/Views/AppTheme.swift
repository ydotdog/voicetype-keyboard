import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.953, green: 0.929, blue: 0.882)
    static let surface = Color(red: 0.984, green: 0.969, blue: 0.937)
    static let surface2 = Color.white
    static let ink = Color(red: 0.106, green: 0.094, blue: 0.075)
    static let inkSoft = Color(red: 0.298, green: 0.275, blue: 0.231)
    static let secondary = Color(red: 0.549, green: 0.522, blue: 0.463)
    static let accent = Color(red: 0.878, green: 0.631, blue: 0.102)
    static let accentDeep = Color(red: 0.698, green: 0.490, blue: 0.031)
    static let accentTint = Color(red: 0.878, green: 0.631, blue: 0.102).opacity(0.16)
    static let coral = Color(red: 0.812, green: 0.290, blue: 0.125)
    static let liveTint = Color(red: 0.812, green: 0.290, blue: 0.125).opacity(0.12)
    static let mint = Color(red: 0.698, green: 0.490, blue: 0.031)
    static let border = Color(red: 0.106, green: 0.094, blue: 0.075).opacity(0.12)
    static let borderSoft = Color(red: 0.106, green: 0.094, blue: 0.075).opacity(0.07)

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
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
    }
}
