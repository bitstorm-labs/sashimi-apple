import SwiftUI
import NukeUI

/// iPhone: the full-width picture at the top of a detail page, with its hero
/// trailer, fading into the page at the bottom (`BackdropFade`). The series, movie, episode
/// and season pages all use it, so they blend into the page identically (#764).
struct PhoneHeroBanner: View {
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
        // A definite screen-width × 220 frame (Color.clear) with the image
        // as an OVERLAY. Critical: a resizable `.aspectRatio(.fill)` image
        // reports an oversized intrinsic width for a PORTRAIT poster
        // fallback (missing-backdrop items like Ratatouille), and if it
        // sizes the container that width propagates to the whole detail
        // column — shoving the title and Play button off the left edge.
        // Overlaying it on a fixed-size Color.clear stops the image from
        // dictating layout width.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .overlay {
                // Read the drawn width so the request matches it: full
                // width is 440pt in portrait but ~950pt in landscape.
                GeometryReader { geo in
                    LazyImage(request: request(geo.size.width)) { state in
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
            // The bottom edge fades into the page, picture and trailer
            // alike; the sides are the screen's.
            .backdropBottomFade()
    }
}
