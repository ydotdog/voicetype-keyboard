import ActivityKit
import SwiftUI
import WidgetKit

struct VoiceTypeKeyboardLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceTypeKeyboardActivityAttributes.self) { context in
            VoiceTypeLiveActivityView(state: context.state)
                .activityBackgroundTint(Color(red: 0.98, green: 0.97, blue: 0.94))
                .activitySystemActionForegroundColor(Color(red: 0.10, green: 0.11, blue: 0.12))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VoiceTypeActivityLogo(size: 34)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.title)
                            .font(.headline)
                        Text(context.state.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoiceTypeActivityTimer(state: context.state)
                        .font(.caption.monospacedDigit())
                }
            } compactLeading: {
                VoiceTypeActivityLogo(size: 20)
            } compactTrailing: {
                VoiceTypeActivityCompactStatus(mode: context.state.mode)
            } minimal: {
                VoiceTypeActivityLogo(size: 18)
            }
            .keylineTint(Color(red: 0.98, green: 0.55, blue: 0.32))
        }
    }
}

private struct VoiceTypeLiveActivityView: View {
    let state: VoiceTypeKeyboardActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            VoiceTypeActivityLogo(size: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.10, green: 0.11, blue: 0.12))
                Text(state.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.32, green: 0.34, blue: 0.38))
            }

            Spacer(minLength: 8)

            VoiceTypeActivityTimer(state: state)
                .font(.headline.monospacedDigit())
                .foregroundStyle(Color(red: 0.10, green: 0.11, blue: 0.12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct VoiceTypeActivityLogo: View {
    let size: CGFloat

    var body: some View {
        Image("LiveActivityLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private struct VoiceTypeActivityCompactStatus: View {
    let mode: RecordingBridgeMode

    var body: some View {
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
