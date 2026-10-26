import SwiftUI

/// How a backdrop or hero picture (and the trailer playing over it) fades into
/// the page: "Lightest" (#765). Fractions of the picture's own frame. Only the
/// left and bottom edges fade; the top and right run off the screen.
///
/// The page under a backdrop is already solid, so there is no darkening wash
/// over the picture. Text drawn on the picture itself gets a scrim confined
/// to the text's area.
enum BackdropFade {
    /// The left edge is transparent at 0 and opaque from here on.
    static let leadingOpaqueAt: CGFloat = 0.10
    /// The bottom edge stays opaque to here, then fades out by the bottom.
    static let bottomFadeStartsAt: CGFloat = 0.92

    static var leadingMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: leadingOpaqueAt)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static var bottomMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white, location: bottomFadeStartsAt),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension View {
    /// A backdrop at the top right of the page: its left and bottom edges fade.
    /// Apply it to the picture and its trailer together so both feather alike.
    func backdropFade() -> some View {
        mask(BackdropFade.leadingMask.mask(BackdropFade.bottomMask))
    }

    /// A full-width banner (iPhone): its left edge is the screen's, so only
    /// the bottom fades.
    func backdropBottomFade() -> some View {
        mask(BackdropFade.bottomMask)
    }
}
