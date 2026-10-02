import SwiftUI
import UIKit

enum AppTheme {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let surface2 = Color(uiColor: .tertiarySystemGroupedBackground)
    static let ink = Color(uiColor: .label)
    static let inkSoft = Color(uiColor: .secondaryLabel)
    static let secondary = Color(uiColor: .secondaryLabel)
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
    let sessionID: String
    var color = AppTheme.coral
    var dense = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels = Array(repeating: 0.0, count: 18)
    @State private var currentLevel = 0.0

    private var samplingMode: Int {
        scenePhase == .active ? (reduceMotion ? 1 : 2) : 0
    }

    var body: some View {
        Group {
            if reduceMotion {
                ProgressView(value: currentLevel)
                    .progressViewStyle(.linear)
                    .tint(color)
                    .frame(maxWidth: 180)
            } else {
                HStack(alignment: .center, spacing: dense ? 3 : 5) {
                    ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                        Capsule(style: .continuous)
                            .fill(color)
                            .frame(width: dense ? 3 : 4, height: 3 + CGFloat(level) * (dense ? 29 : 69))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue("\(Int(currentLevel * 100)) percent")
        .transaction { $0.animation = nil }
        .task(id: "\(sessionID)-\(samplingMode)") {
            levels = Array(repeating: 0, count: 18)
            currentLevel = 0
            guard samplingMode != 0, !sessionID.isEmpty else { return }
            var lastSampleAt: TimeInterval?
            while !Task.isCancelled {
                if let sample = RecordingAudioLevelStore.latest(for: sessionID) {
                    currentLevel = sample.level
                    if sample.sampledAt != lastSampleAt {
                        levels.removeFirst()
                        levels.append(sample.level)
                        lastSampleAt = sample.sampledAt
                    }
                } else {
                    currentLevel = 0
                    levels = Array(repeating: 0, count: 18)
                    lastSampleAt = nil
                }
                do {
                    try await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 50))
                } catch {
                    return
                }
            }
        }
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
    @State private var feedback: UIImpactFeedbackGenerator?

    func body(content: Content) -> some View {
        content
            .onAppear {
                let generator = UIImpactFeedbackGenerator(style: style)
                feedback = generator
                generator.prepare()
            }
            .onChange(of: isPressed) { _, newValue in
                guard newValue else { return }
                feedback?.impactOccurred(intensity: 0.85)
                feedback?.prepare()
            }
            .onDisappear { feedback = nil }
    }
}

/// Use Apple's glass material for the primary control; older iOS retains a native button.
struct PrimaryControlStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .tint(Color(red: 0.290, green: 0.337, blue: 0.239))
                .controlSize(.large)
        } else {
            content
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.290, green: 0.337, blue: 0.239))
                .controlSize(.large)
        }
    }
}

struct SecondaryControlStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass).controlSize(.regular)
        } else {
            content.buttonStyle(.bordered).controlSize(.regular)
        }
    }
}
