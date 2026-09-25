import SwiftUI

/// The tvOS focus treatment shared by settings-style rows: a card fill that
/// tints toward the focus colour, a focus-coloured stroke, and a small spring
/// lift. Rows that deliberately differ (glow shadows, solid focused fills)
/// keep their own styling rather than bending this modifier to fit them.
struct FocusHighlight: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    /// Rows inside a `.card` button style already get the system lift, so they
    /// opt out of the extra scale and its animation.
    let scales: Bool

    func body(content: Content) -> some View {
        let highlighted = content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isFocused ? SashimiTheme.focus.opacity(0.15) : SashimiTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(SashimiTheme.focus.opacity(isFocused ? 1.0 : 0), lineWidth: lineWidth)
            )
        if scales {
            highlighted
                .scaleEffect(isFocused ? 1.02 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        } else {
            highlighted
        }
    }
}

/// The capsule variant used by the library toolbar pills (sort, order,
/// filter, shuffle).
struct FocusPillHighlight: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .background(isFocused ? SashimiTheme.focus.opacity(0.15) : SashimiTheme.cardBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

extension View {
    func focusHighlight(
        _ isFocused: Bool,
        cornerRadius: CGFloat,
        lineWidth: CGFloat = 3,
        scales: Bool = true
    ) -> some View {
        modifier(FocusHighlight(isFocused: isFocused, cornerRadius: cornerRadius, lineWidth: lineWidth, scales: scales))
    }

    func focusPillHighlight(_ isFocused: Bool) -> some View {
        modifier(FocusPillHighlight(isFocused: isFocused))
    }
}
