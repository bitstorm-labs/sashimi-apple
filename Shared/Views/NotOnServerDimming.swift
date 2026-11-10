import SwiftUI

extension View {
    /// A Watchlist title the server doesn't have: its poster grey and at 55%
    /// brightness, as the design's mockups draw it. (Subtracting brightness
    /// instead turned dark posters black.)
    @ViewBuilder
    func notOnServerDimmed(_ isDimmed: Bool = true) -> some View {
        if isDimmed {
            saturation(0).colorMultiply(Color(white: 0.55))
        } else {
            self
        }
    }
}
