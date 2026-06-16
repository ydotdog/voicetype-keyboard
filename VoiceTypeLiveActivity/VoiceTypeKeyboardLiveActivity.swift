import ActivityKit
import SwiftUI
import WidgetKit

struct VoiceTypeKeyboardLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceTypeKeyboardActivityAttributes.self) { context in
            VoiceTypeLiveActivityView(state: context.state)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(VoiceTypeActivityPalette.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VoiceTypeActivityLogo(size: 30)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoiceTypeActivityTimerPill(state: context.state, compact: true)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VoiceTypeActivityIslandStatus(state: context.state)
                        .padding(.top, 4)
                }
            } compactLeading: {
                VoiceTypeActivityLogo(size: 20)
            } compactTrailing: {
                VoiceTypeActivityCompactStatus(state: context.state)
            } minimal: {
                VoiceTypeActivityLogo(size: 18)
            }
            .keylineTint(VoiceTypeActivityPalette.gold)
        }
    }
}

private struct VoiceTypeLiveActivityView: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState

    var body: some View {
        ZStack {
            VoiceTypeActivityGlassPanel(cornerRadius: 26, scrim: VoiceTypeActivityPalette.readabilityScrim)

            HStack(spacing: 13) {
                VoiceTypeActivityLogo(size: 40)

                VoiceTypeActivityLockScreenText(state: state)

                Spacer(minLength: 8)

                VoiceTypeActivityTimerPill(state: state, compact: false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .zIndex(1)
        }
        .containerBackground(for: .widget) {
            VoiceTypeActivityGlassPanel(cornerRadius: 26, scrim: VoiceTypeActivityPalette.readabilityScrim)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(VoiceTypeActivityPalette.text)
                .lineLimit(1)

            HStack(spacing: 6) {
                VoiceTypeActivityStatusDot(color: state.statusColor, size: 7)

                Text(state.subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .shadow(color: VoiceTypeActivityPalette.textShadow, radius: 2.5, x: 0, y: 1)
    }
}

private struct VoiceTypeActivityIslandStatus: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            VoiceTypeActivityStatusDot(color: state.statusColor, size: 7)

            Text(state.title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(VoiceTypeActivityPalette.text)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(state.islandSubtitle)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
    }
}

private struct VoiceTypeActivityCompactStatus: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState

    var body: some View {
        if state.startedAt != nil {
            VoiceTypeActivityTimer(state: state)
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(VoiceTypeActivityPalette.gold)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state.statusColor)
        }
    }

    private var iconName: String {
        switch state.mode {
        case .keyboardRecording:
            "waveform"
        case .transcribing:
            "ellipsis"
        case .keyboardReady:
            "mic.fill"
        case .standard:
            "mic"
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

private struct VoiceTypeActivityTimerPill: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState
    let compact: Bool

    var body: some View {
        VStack(alignment: .center, spacing: compact ? 0 : 1) {
            VoiceTypeActivityTimer(state: state)
                .font(
                    .system(
                        size: compact ? 13 : 16,
                        weight: .semibold,
                        design: .rounded
                    )
                    .monospacedDigit()
                )
                .foregroundStyle(VoiceTypeActivityPalette.text)

            if !compact, state.startedAt != nil {
                Text(state.durationLimit.label)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(state.statusColor)
            }
        }
        .padding(.horizontal, compact ? 9 : 12)
        .frame(minWidth: compact ? 48 : 58, alignment: .center)
        .frame(height: compact ? 26 : 40)
        .background(state.statusColor.opacity(0.16), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(state.statusColor.opacity(0.40), lineWidth: 0.8)
        }
        .shadow(color: VoiceTypeActivityPalette.textShadow, radius: 2, x: 0, y: 1)
    }
}

private struct VoiceTypeActivityTimer: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState

    var body: some View {
        if let startedAt = state.startedAt {
            Text(startedAt, style: .timer)
        } else {
            Text(state.durationLimit.label)
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
