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
                    VoiceTypeActivityIslandText(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoiceTypeActivityTimer(state: context.state)
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
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

            VStack(alignment: .trailing, spacing: 2) {
                VoiceTypeActivityTimer(state: state)
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(VoiceTypeActivityPalette.text)
                Text(state.durationLimit.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .voiceTypeGlass(cornerRadius: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text("VoiceType")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(VoiceTypeActivityPalette.secondary)
            }

            Text(state.title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(VoiceTypeActivityPalette.text)
                .lineLimit(1)

            Text(state.subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(VoiceTypeActivityPalette.secondary)
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        switch state.mode {
        case .keyboardRecording:
            VoiceTypeActivityPalette.gold
        case .transcribing:
            VoiceTypeActivityPalette.blue
        case .keyboardReady, .standard:
            VoiceTypeActivityPalette.green
        }
    }
}

private struct VoiceTypeActivityIslandText: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(state.subtitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
    static let text = Color.primary
    static let secondary = Color.secondary
    static let gold = Color(red: 0.91, green: 0.62, blue: 0.10)
    static let green = Color(red: 0.45, green: 0.78, blue: 0.48)
    static let blue = Color(red: 0.40, green: 0.66, blue: 0.95)
    static let logoInk = Color.primary.opacity(0.92)
    static let logoFill = Color.white.opacity(0.20)
    static let glassStroke = Color.white.opacity(0.28)
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
