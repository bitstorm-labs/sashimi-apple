import SwiftUI
import NukeUI

/// iPhone: the full-width picture at the top of a detail page, with its hero
/// trailer, fading into the page over its lower half: the Watchlist
/// Spotlight's portrait form (#894). The page's details start over the faded
/// part (`contentOverlap`). The series, movie, episode and season pages all
/// use it, so they blend into the page identically (#764).
struct PhoneHeroBanner: View {
    /// Taller than the old 220pt strip: the picture covers the top of the
    /// page, as the Spotlight's does.
    static let height: CGFloat = 260
    /// How far the details below ride up over the faded lower part: they
    /// start where the Spotlight's portrait layout starts them.
    static let contentOverlap: CGFloat = height * (1 - (SpotlightBackdropLayout.portrait.contentStartsAt ?? 1))

    let serverID: String?
    /// The page's item; `HeroTrailerPolicy` picks the trailer from it (a
    /// season's or episode's is its series').
    let trailerItem: BaseItemDto
    /// No real backdrop: the picture is the portrait poster, blurred and
    /// darkened so it reads as an ambient backdrop, not a sliced strip.
    var isBlurred = false
    /// The picture's request for a drawn width in points.
    let request: (CGFloat) -> ImageRequest?

    var body: some View {
        // A definite screen-width × `height` frame (Color.clear) with the image
        // as an OVERLAY. Critical: a resizable `.aspectRatio(.fill)` image
        // reports an oversized intrinsic width for a PORTRAIT poster
        // fallback (missing-backdrop items like Ratatouille), and if it
        // sizes the container that width propagates to the whole detail
        // column — shoving the title and Play button off the left edge.
        // Overlaying it on a fixed-size Color.clear stops the image from
        // dictating layout width.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .overlay {
                // Read the drawn width so the request matches it: full
                // width is 440pt in portrait but ~950pt in landscape. The
                // picture fills the banner, so a 16:9 one is drawn at least
                // `height` × 16/9 wide (462pt on a 393pt-wide iPhone).
                GeometryReader { geo in
                    LazyImage(request: request(max(geo.size.width, geo.size.height * 16 / 9))) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                                .blur(radius: isBlurred ? 32 : 0)
                                .overlay(isBlurred ? Color.black.opacity(0.4) : Color.clear)
                        } else {
                            Rectangle().fill(MobileColors.cardBackground)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .heroTrailer(for: trailerItem, serverID: serverID)
            .clipped()
            // The lower part fades into the page, picture and trailer alike;
            // the sides are the screen's.
            .spotlightFade(.portrait)
    }
}
