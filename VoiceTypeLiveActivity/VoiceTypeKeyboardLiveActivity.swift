import ActivityKit
import SwiftUI
import WidgetKit

struct VoiceTypeKeyboardLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceTypeKeyboardActivityAttributes.self) { context in
            VoiceTypeLiveActivityView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(VoiceTypeActivityPalette.text)
                .widgetURL(URL(string: "voicetype://keyboard"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VoiceTypeActivityLogo(size: 24)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoiceTypeActivityIslandStatus(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                VoiceTypeActivityLogo(size: 18)
            } compactTrailing: {
                VoiceTypeActivityCompactStatus(state: context.state, isStale: context.isStale)
            } minimal: {
                if context.isStale {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
                        .accessibilityLabel("Mic status unavailable. Open VoiceType to check.")
                } else {
                    VoiceTypeActivityLogo(size: 18)
                }
            }
            .keylineTint(context.isStale ? VoiceTypeActivityPalette.secondaryText : VoiceTypeActivityPalette.gold)
            .widgetURL(URL(string: "voicetype://keyboard"))
        }
    }
}

private struct VoiceTypeLiveActivityView: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        ZStack {
            VoiceTypeActivityGlassPanel(cornerRadius: 26, scrim: VoiceTypeActivityPalette.readabilityScrim)

            HStack(spacing: 13) {
                VoiceTypeActivityLogo(size: 40)

                VoiceTypeActivityLockScreenText(state: state, isStale: isStale)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .zIndex(1)
        }
        .containerBackground(for: .widget) {
            VoiceTypeActivityGlassPanel(cornerRadius: 26, scrim: VoiceTypeActivityPalette.readabilityScrim)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(isStale ? "Open VoiceType to check microphone status" : "Open VoiceType to manage the microphone")
    }
}

private struct VoiceTypeActivityLogo: View {
    let size: CGFloat

    private let barHeights: [CGFloat] = [0.30, 0.55, 0.80, 0.55, 0.30]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            VoiceTypeActivityPalette.logoFillTop,
                            VoiceTypeActivityPalette.logoFillBottom
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .strokeBorder(VoiceTypeActivityPalette.glassStroke, lineWidth: 0.6)
                }
                .shadow(color: Color.black.opacity(0.22), radius: size * 0.06, x: 0, y: size * 0.03)

            HStack(alignment: .center, spacing: max(1.2, size * 0.085)) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { index, height in
                    Capsule(style: .continuous)
                        .fill(index == 2 ? VoiceTypeActivityPalette.gold : VoiceTypeActivityPalette.logoInk)
                        .frame(width: max(1.8, size * 0.085), height: size * height)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

private struct VoiceTypeActivityStatusDot: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: size * 0.5, x: 0, y: 0)
    }
}

private struct VoiceTypeActivityLockScreenText: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isStale ? "Mic status unavailable" : state.title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(VoiceTypeActivityPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: 6) {
                VoiceTypeActivityStatusDot(color: isStale ? VoiceTypeActivityPalette.secondaryText : state.statusColor, size: 7)

                Text(isStale ? "Open VoiceType to check" : state.subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .shadow(color: VoiceTypeActivityPalette.textShadow, radius: 2.5, x: 0, y: 1)
    }
}

private struct VoiceTypeActivityIslandStatus: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 7) {
            VoiceTypeActivityStatusDot(color: isStale ? VoiceTypeActivityPalette.secondaryText : state.statusColor, size: 7)

            HStack(spacing: 4) {
                Text(isStale ? "Mic status unavailable" : state.islandSubtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
                    .lineLimit(1)

                if !isStale {
                    Text(state.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(VoiceTypeActivityPalette.text)
                        .lineLimit(1)
                }
            }
        }
        .frame(minWidth: 86, alignment: .trailing)
        .shadow(color: VoiceTypeActivityPalette.textShadow, radius: 2, x: 0, y: 1)
        .accessibilityHint("Open VoiceType to check microphone status")
    }
}

private struct VoiceTypeActivityCompactStatus: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
                .accessibilityLabel("Mic status unavailable. Open VoiceType to check.")
        } else {
            VoiceTypeActivityStatusDot(color: state.statusColor, size: 9)
                .accessibilityLabel(state.islandSubtitle)
        }
    }
}

private struct VoiceTypeActivityGlassPanel: View {
    let cornerRadius: CGFloat
    let scrim: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if #available(iOSApplicationExtension 26.0, *) {
                shape
                    .fill(VoiceTypeActivityPalette.glassBase)
                    .glassEffect(
                        .regular.tint(VoiceTypeActivityPalette.glassTint),
                        in: shape
                    )
            } else {
                shape
                    .fill(.ultraThinMaterial)
            }

            shape
                .fill(scrim)

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            VoiceTypeActivityPalette.glassHighlight,
                            VoiceTypeActivityPalette.glassStroke
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        }
    }
}

private enum VoiceTypeActivityPalette {
    static let text = Color.white
    static let secondaryText = Color.white.opacity(0.80)
    static let textShadow = Color.black.opacity(0.55)
    static let gold = Color(red: 0.99, green: 0.76, blue: 0.30)
    static let green = Color(red: 0.38, green: 0.85, blue: 0.55)
    static let blue = Color(red: 0.44, green: 0.72, blue: 1.0)
    static let logoInk = Color(red: 0.08, green: 0.09, blue: 0.12)
    static let logoFillTop = Color.white
    static let logoFillBottom = Color.white.opacity(0.85)
    static let glassBase = Color.white.opacity(0.06)
    static let glassTint = Color.white.opacity(0.12)
    static let glassStroke = Color.white.opacity(0.18)
    static let glassHighlight = Color.white.opacity(0.45)
    static let readabilityScrim = Color.black.opacity(0.30)
}

private extension VoiceTypeKeyboardActivityAttributes.ContentState {
    var statusColor: Color {
        switch mode {
        case .keyboardRecording:
            VoiceTypeActivityPalette.gold
        case .transcribing:
            VoiceTypeActivityPalette.blue
        case .keyboardReady, .standard:
            VoiceTypeActivityPalette.green
        }
    }

    var islandSubtitle: String {
        switch mode {
        case .keyboardRecording:
            "Recording"
        case .transcribing:
            "Finishing"
        case .keyboardReady:
            "Mic on"
        case .standard:
            "Keyboard"
        }
    }
}
