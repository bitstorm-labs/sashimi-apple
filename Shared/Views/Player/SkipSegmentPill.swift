import SwiftUI

/// Sizes for the skip pill on each screen.
struct SkipSegmentPillMetrics {
    let fontSize: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let spacing: CGFloat

    static let tv = SkipSegmentPillMetrics(fontSize: 30, horizontalPadding: 34, verticalPadding: 18, spacing: 14)
    static let pad = SkipSegmentPillMetrics(fontSize: 18, horizontalPadding: 22, verticalPadding: 13, spacing: 9)
    static let phone = SkipSegmentPillMetrics(fontSize: 16, horizontalPadding: 18, verticalPadding: 11, spacing: 8)
}

private struct SkipPillHighlightedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Focused (tvOS) or pressed (iOS): the pill lifts, rings and fills solid.
    var skipPillHighlighted: Bool {
        get { self[SkipPillHighlightedKey.self] }
        set { self[SkipPillHighlightedKey.self] = newValue }
    }
}

/// The Skip Intro / Skip Credits pill: glyph, label and time left, over a
/// purple fill that sweeps left to right as the segment plays.
struct SkipSegmentPill: View {
    let countdown: SkipSegmentCountdown
    /// The app's purple (SashimiTheme.accent / MobileColors.accent).
    let accent: Color
    let metrics: SkipSegmentPillMetrics

    @Environment(\.skipPillHighlighted) private var isHighlighted
    @Environment(\.displayScale) private var displayScale

    /// How long one fill step animates: the live pill reads the clock this
    /// often, so each step lands as the next begins and the sweep is continuous.
    static let tick: TimeInterval = 0.25

    var body: some View {
        HStack(spacing: metrics.spacing) {
            Image(systemName: "forward.end.fill")
            Text(countdown.label)
            Text(countdown.remainingText)
                .monospacedDigit()
                .opacity(0.8)
        }
        .font(.system(size: metrics.fontSize, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
        .background { background }
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1 / max(displayScale, 1))
        }
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                .opacity(isHighlighted ? 1 : 0)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(isHighlighted ? 0.5 : 0), radius: isHighlighted ? 18 : 0, y: isHighlighted ? 8 : 0)
        .scaleEffect(isHighlighted ? 1.08 : 1)
        .animation(.easeOut(duration: 0.18), value: isHighlighted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(countdown.accessibilityLabel)
    }

    private var background: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            Capsule()
                .fill(Color(red: 20 / 255, green: 18 / 255, blue: 28 / 255).opacity(0.7))
            GeometryReader { proxy in
                Rectangle()
                    .fill(accent.opacity(isHighlighted ? 1 : 0.55))
                    .frame(width: proxy.size.width * countdown.fractionElapsed)
                    .animation(.linear(duration: Self.tick), value: countdown.fractionElapsed)
            }
        }
        .clipShape(Capsule())
    }
}

/// The pill bound to a playing segment: re-reads the player's clock every
/// `SkipSegmentPill.tick`, so the fill and countdown follow playback, pauses
/// and seeks without the view model publishing anything.
struct LiveSkipSegmentPill: View {
    let segment: MediaSegmentDto
    let accent: Color
    let metrics: SkipSegmentPillMetrics
    /// The player's current position in seconds (NaN when unknown).
    let currentTime: @MainActor () -> Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: SkipSegmentPill.tick)) { _ in
            SkipSegmentPill(
                countdown: SkipSegmentCountdown(segment: segment, current: currentTime()),
                accent: accent,
                metrics: metrics
            )
        }
    }
}

/// Pressing the button highlights the pill the way focus does on tvOS.
struct SkipSegmentPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.skipPillHighlighted, configuration.isPressed)
    }
}
