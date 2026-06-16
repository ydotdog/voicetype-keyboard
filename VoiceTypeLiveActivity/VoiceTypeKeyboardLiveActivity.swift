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
                    VoiceTypeActivityLogo(size: 28)
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
                VoiceTypeActivityCompactStatus(mode: context.state.mode)
            } minimal: {
                VoiceTypeActivityLogo(size: 16)
            }
            .keylineTint(VoiceTypeActivityPalette.gold)
        }
    }
}

private struct VoiceTypeLiveActivityView: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            VoiceTypeActivityLogo(size: 30)

            VoiceTypeActivityLockScreenText(state: state)

            Spacer(minLength: 8)

            VoiceTypeActivityTimerPill(state: state, compact: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(VoiceTypeActivityPalette.readabilityScrim)
        }
        .voiceTypeGlass(cornerRadius: 26)
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(VoiceTypeActivityPalette.glassStroke, lineWidth: 0.8)
        }
    }
}

private struct VoiceTypeActivityLogo: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(VoiceTypeActivityPalette.logoFill)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                        .stroke(VoiceTypeActivityPalette.glassStroke, lineWidth: 0.7)
                }

            HStack(alignment: .center, spacing: max(1, size * 0.07)) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { index, height in
                    Capsule(style: .continuous)
                        .fill(index == barHeights.count - 1 ? VoiceTypeActivityPalette.gold : VoiceTypeActivityPalette.logoInk)
                        .frame(width: max(1.6, size * 0.075), height: size * height)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private var barHeights: [CGFloat] {
        [0.28, 0.48, 0.66, 0.44, 0.72]
    }
}

private struct VoiceTypeActivityLockScreenText: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.statusColor)
                    .frame(width: 6, height: 6)

                Text("VoiceType")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
            }

            Text(state.title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(VoiceTypeActivityPalette.text)
                .lineLimit(1)

            Text(state.subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
                .lineLimit(1)
        }
        .shadow(color: VoiceTypeActivityPalette.textShadow, radius: 3, x: 0, y: 1)
    }
}

private struct VoiceTypeActivityIslandStatus: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.statusColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 0) {
                Text(state.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.text)
                    .lineLimit(1)

                Text(state.islandSubtitle)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(VoiceTypeActivityPalette.islandScrim, in: Capsule(style: .continuous))
        .shadow(color: VoiceTypeActivityPalette.textShadow, radius: 2.5, x: 0, y: 1)
    }
}

private struct VoiceTypeActivityCompactStatus: View {
    let mode: RecordingBridgeMode

    var body: some View {
        Group {
            switch mode {
            case .keyboardRecording:
                Image(systemName: "waveform")
            case .transcribing:
                Image(systemName: "text.badge.checkmark")
            case .keyboardReady:
                Image(systemName: "mic.fill")
            case .standard:
                Image(systemName: "mic")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(VoiceTypeActivityPalette.gold)
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
                        size: compact ? 12.5 : 15,
                        weight: .semibold,
                        design: .rounded
                    )
                    .monospacedDigit()
                )
                .foregroundStyle(VoiceTypeActivityPalette.text)

            if !compact {
                Text(state.durationLimit.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.secondaryText)
            }
        }
        .shadow(color: VoiceTypeActivityPalette.textShadow, radius: 3, x: 0, y: 1)
        .padding(.horizontal, compact ? 8 : 9)
        .frame(minWidth: compact ? 48 : 58, alignment: .trailing)
        .frame(height: compact ? 26 : 32)
        .background(VoiceTypeActivityPalette.islandScrim, in: Capsule(style: .continuous))
        .voiceTypeGlass(cornerRadius: compact ? 13 : 16)
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
    static let secondaryText = Color.white.opacity(0.84)
    static let textShadow = Color.black.opacity(0.85)
    static let gold = Color(red: 0.91, green: 0.62, blue: 0.10)
    static let green = Color(red: 0.45, green: 0.78, blue: 0.48)
    static let blue = Color(red: 0.40, green: 0.66, blue: 0.95)
    static let logoInk = Color.black.opacity(0.90)
    static let logoFill = Color.white.opacity(0.88)
    static let glassStroke = Color.white.opacity(0.32)
    static let readabilityScrim = Color.black.opacity(0.34)
    static let islandScrim = Color.black.opacity(0.38)
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

private extension View {
    @ViewBuilder
    func voiceTypeGlass(cornerRadius: CGFloat) -> some View {
        if #available(iOSApplicationExtension 26.0, *) {
            glassEffect(
                .regular.tint(Color.white.opacity(0.10)),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
