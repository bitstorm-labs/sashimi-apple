import SwiftUI

/// The picture behind a detail page, with its hero trailer, in the
/// Watchlist Spotlight's coverage (#894): flush to the top right, bright
/// across the right two thirds of the screen, fading into the page on its
/// left and bottom. The series, movie, episode and season pages all use it,
/// so their pictures and trailers blend into the page identically (#764).
struct DetailHeroBackground: View {
    let image: DetailHero.Image
    let isYouTubeSeries: Bool
    /// The item whose image tags describe `image` (the page's item).
    let tagSource: BaseItemDto
    /// The page's item; `HeroTrailerPolicy` picks the trailer from it (a
    /// season's or episode's is its series').
    let trailerItem: BaseItemDto
    let serverID: String?
    /// Changed after Refresh Metadata to reload the picture.
    var refreshID = UUID()

    var body: some View {
        ZStack {
            SashimiTheme.background
            SpotlightBackdrop { frame in
                AsyncItemImage(
                    itemId: image.itemId,
                    imageType: image.type,
                    // Its drawn width at the display's scale (1920pt canvas,
                    // @2x at 4K), so the picture is never upscaled.
                    maxWidth: frame.requestPixelWidth,
                    contentMode: .fill,
                    fallbackImageTypes: DetailHero.tvFallbackTypes(isYouTubeSeries: isYouTubeSeries),
                    serverID: serverID,
                    tagSource: tagSource
                )
                .frame(width: frame.width, height: frame.height)
                .id(refreshID)
                // The trailer fills the picture's frame, so the Spotlight's
                // fade covers picture and trailer alike.
                .heroTrailer(for: trailerItem, serverID: serverID)
            }
        }
        .ignoresSafeArea()
    }
}
