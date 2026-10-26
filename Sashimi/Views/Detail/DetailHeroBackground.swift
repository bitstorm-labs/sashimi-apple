import SwiftUI

/// The picture behind a detail page's header, with its hero trailer: flush to
/// the top-right, fading into the page on its left and bottom the same way
/// the home hero does. The series, movie, episode and season pages all use
/// it, so their pictures and trailers blend into the page identically (#764).
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

    /// Fraction of the layout width the backdrop fills in the top-right corner.
    /// Single source of truth: the frame and the image request both derive from
    /// it, so resizing the layout can't silently leave the request undersized.
    ///
    /// About half the screen, flush to the top and right edges like the home
    /// hero. Its left third fades out, so the part under the info column is a
    /// blend into the background rather than picture behind the title.
    private var widthFraction: CGFloat {
        isYouTubeSeries ? 0.6 : 0.55
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dark background base
                SashimiTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer()
                        AsyncItemImage(
                            itemId: image.itemId,
                            imageType: image.type,
                            // Request at native pixel density: tvOS lays out
                            // in 1920pt but Apple TV 4K renders @2x, so a
                            // point-width frame needs twice that many pixels
                            // or the backdrop is upscaled and reads soft.
                            maxWidth: Int(geometry.size.width * widthFraction * 2),
                            contentMode: .fit,
                            fallbackImageTypes: DetailHero.tvFallbackTypes(isYouTubeSeries: isYouTubeSeries),
                            serverID: serverID,
                            tagSource: tagSource
                        )
                        .id(refreshID)
                        .heroTrailer(for: trailerItem, serverID: serverID)
                        .frame(width: geometry.size.width * widthFraction, alignment: .topTrailing)
                        // Only the left and bottom edges fade, picture and
                        // trailer alike; the top and right run off the screen.
                        .backdropFade()
                    }
                    Spacer()
                }
                .ignoresSafeArea()
            }
        }
    }
}
