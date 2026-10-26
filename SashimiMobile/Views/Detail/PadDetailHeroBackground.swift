import SwiftUI
import NukeUI

/// iPad and Mac: the picture behind a detail page's header, with its hero
/// trailer, flush to the top-right and fading into the page on its left and
/// bottom, the same way the home hero does. The series, movie, episode and
/// season pages all use it, so they blend into the page identically (#764).
struct PadDetailHeroBackground: View {
    let serverID: String?
    /// The page's item; `HeroTrailerPolicy` picks the trailer from it (a
    /// season's or episode's is its series').
    let trailerItem: BaseItemDto
    /// The picture's URL for a width in pixels.
    let url: (Int) -> URL?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dark background base
                MobileColors.background

                HStack(spacing: 0) {
                    Spacer()
                    let pictureWidth = geometry.size.width * ImageSizing.padDetailPictureFraction
                    if let backdropURL = url(ImageSizing.backdropPixelWidth(points: pictureWidth)) {
                        LazyImage(request: SashimiImagePipeline.request(url: backdropURL, serverID: serverID)) { state in
                            if let image = state.image {
                                image
                                    .resizable().scaledToFit()
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: pictureWidth)
                        .heroTrailer(for: trailerItem, serverID: serverID)
                        // Only the left and bottom edges fade, picture and
                        // trailer alike; the top and right run off the screen.
                        .backdropFade()
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                // Top scrim under the status bar and back button, which are
                // drawn on the backdrop: confined to them, not a page wash.
                LinearGradient(
                    colors: [Color.black.opacity(0.5), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .ignoresSafeArea()
    }
}
