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
                    VoiceTypeActivityLogo(size: 24)
                }
                DynamicIslandExpandedRegion(.center) {
                    VoiceTypeActivityIslandStatus(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoiceTypeActivityTimerPill(state: context.state, compact: true)
                }
            } compactLeading: {
                VoiceTypeActivityLogo(size: 18)
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
        HStack(spacing: 7) {
            VoiceTypeActivityStatusDot(color: state.statusColor, size: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.text)
                    .lineLimit(1)

                Text(state.islandSubtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

private struct VoiceTypeActivityCompactStatus: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState

    var body: some View {
        // The compact pill (shown while using other apps, before it is tapped open)
        // must stay short. A running timer here is several ever-changing monospace
        // digits, which stretched the pill wide left-to-right. A single status dot
        // keeps it to the short, centered shape it had before -- the live timer
        // still lives in the expanded view and on the lock screen.
        VoiceTypeActivityStatusDot(color: state.statusColor, size: 9)
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
        VStack(alignment: .trailing, spacing: compact ? 0 : 2) {
            VoiceTypeActivityTimer(state: state)
                .font(
                    .system(
                        size: compact ? 14 : 17,
                        weight: .semibold,
                        design: .rounded
                    )
                    .monospacedDigit()
                )
                .foregroundStyle(VoiceTypeActivityPalette.text)

            if !compact, state.startedAt != nil {
                Text(state.durationLimit.label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
            }
        }
        .frame(minWidth: compact ? 48 : 58, alignment: .trailing)
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
