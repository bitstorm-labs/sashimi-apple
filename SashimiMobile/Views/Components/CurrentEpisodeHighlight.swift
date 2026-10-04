import SwiftUI

/// The "you are here" ring on an episode thumbnail: a white outline that
/// breathes, with a soft glow — the same treatment as tvOS's EpisodeCard, so
/// the current episode reads the same on every device. Reduce Motion gets a
/// steady ring.
struct CurrentEpisodeHighlight: ViewModifier {
    let isCurrent: Bool
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isCurrent ? Color.white : .clear, lineWidth: 2)
                    .opacity(isCurrent && !reduceMotion ? (pulse ? 1.0 : 0.4) : 1.0)
            )
            .shadow(color: isCurrent ? Color.white.opacity(pulse || reduceMotion ? 0.5 : 0.15) : .clear, radius: 8)
            .onAppear { startPulse() }
            .onChange(of: isCurrent) { _, _ in startPulse() }
    }

    private func startPulse() {
        guard isCurrent, !reduceMotion else {
            pulse = false
            return
        }
        pulse = false
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

extension View {
    func currentEpisodeHighlight(_ isCurrent: Bool, cornerRadius: CGFloat = MobileCornerRadius.small) -> some View {
        modifier(CurrentEpisodeHighlight(isCurrent: isCurrent, cornerRadius: cornerRadius))
    }
}
