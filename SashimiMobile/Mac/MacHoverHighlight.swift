import SwiftUI

/// The Mac's pointer stand-in for the Apple TV's focus: a card under the
/// mouse lifts a little (scale and shadow) and brightens. iPhone and iPad are
/// unchanged — touch has nothing to hover, and iPad pointer effects are the
/// system's.
private struct MacHoverHighlight: ViewModifier {
    var scale: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        if MacPlatform.isMac {
            content
                .brightness(isHovered ? 0.06 : 0)
                .scaleEffect(isHovered ? scale : 1)
                .shadow(color: .black.opacity(isHovered ? 0.45 : 0), radius: 12, y: 6)
                .animation(.easeOut(duration: 0.15), value: isHovered)
                .onHover { isHovered = $0 }
        } else {
            content
        }
    }
}

extension View {
    func macHoverHighlight(scale: CGFloat = 1.04) -> some View {
        modifier(MacHoverHighlight(scale: scale))
    }
}
