import SwiftUI

/// How a backdrop or hero picture (and the trailer playing over it) fades into
/// the page: "Lightest" (#765). Fractions of the picture's own frame. The left
/// and bottom edges fade; the right runs off the screen, and so does the top,
/// except where the picture starts below the screen's top edge (the home
/// hero), which feathers its top like its bottom (#787).
///
/// The page under a backdrop is already solid, so there is no darkening wash
/// over the picture. Text drawn on the picture itself gets a scrim confined
/// to the text's area.
enum BackdropFade {
    /// The left edge is transparent at 0 and opaque from here on.
    static let leadingOpaqueAt: CGFloat = 0.10
    /// The bottom edge stays opaque to here, then fades out by the bottom.
    static let bottomFadeStartsAt: CGFloat = 0.92
    /// A top edge that is on screen is transparent at 0 and opaque from here
    /// on: the bottom's feather, mirrored.
    static let topOpaqueAt: CGFloat = 1 - bottomFadeStartsAt

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

    /// Opaque except for the feathered edges `fadesTop` picks. Pure, so the
    /// ramp is testable: (location, opacity) top to bottom.
    static func verticalStops(fadesTop: Bool) -> [(location: CGFloat, opacity: Double)] {
        let top: [(location: CGFloat, opacity: Double)] = fadesTop ? [(0, 0), (topOpaqueAt, 1)] : [(0, 1)]
        return top + [(bottomFadeStartsAt, 1), (1, 0)]
    }

    static func verticalMask(fadesTop: Bool) -> LinearGradient {
        LinearGradient(
            stops: verticalStops(fadesTop: fadesTop).map { .init(color: .white.opacity($0.opacity), location: $0.location) },
            startPoint: .top,
            endPoint: .bottom
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
    /// A backdrop at the top right of the page: its left and bottom edges fade,
    /// and its top too when `fadesTop` (a picture that starts below the
    /// screen's top edge). Apply it to the picture and its trailer together so
    /// both feather alike.
    func backdropFade(fadesTop: Bool = false) -> some View {
        mask(BackdropFade.leadingMask.mask(BackdropFade.verticalMask(fadesTop: fadesTop)))
    }

    /// A full-width banner (iPhone): its left edge is the screen's, so only
    /// the bottom fades.
    func backdropBottomFade() -> some View {
        mask(BackdropFade.bottomMask)
    }
}
