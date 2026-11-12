import SwiftUI
import NukeUI

/// iPad and Mac: the picture behind a detail page, with its hero trailer, in
/// the Watchlist Spotlight's coverage (#894): on a landscape page bright
/// across the right two thirds, fading into the page on the left and the
/// bottom; on a portrait page across the top, fading into the content. The
/// series, movie, episode and season pages all use it, so they blend into
/// the page identically (#764).
struct PadDetailHeroBackground: View {
    let serverID: String?
    /// The page's item; `HeroTrailerPolicy` picks the trailer from it (a
    /// season's or episode's is its series').
    let trailerItem: BaseItemDto
    /// The picture's URL for a width in pixels.
    let url: (Int) -> URL?

    var body: some View {
        ZStack {
            // Dark background base
            MobileColors.background

            SpotlightBackdrop(layout: nil) { frame in
                if let backdropURL = url(frame.requestPixelWidth) {
                    LazyImage(request: SashimiImagePipeline.request(url: backdropURL, serverID: serverID)) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    // The trailer fills the picture's frame, so the fade
                    // covers picture and trailer alike.
                    .heroTrailer(for: trailerItem, serverID: serverID)
                }
            }

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
        .ignoresSafeArea()
    }
}

extension View {
    /// For the scroll view of an iPad or Mac detail page over
    /// `PadDetailHeroBackground`: on a portrait page the details start over
    /// the backdrop's faded lower part, as the Spotlight's do (#894); on a
    /// landscape page they start at the top, beside the picture.
    func padSpotlightContentInset() -> some View {
        modifier(PadSpotlightContentInset())
    }
}

private struct PadSpotlightContentInset: ViewModifier {
    @State private var pageSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, SpotlightBackdropLayout.fitting(pageSize).contentInset(in: pageSize), for: .scrollContent)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { pageSize = $0 }
    }
}

extension View {
    /// `padSpotlightContentInset()` when `isPad`; a page with the iPhone
    /// banner places its details itself.
    @ViewBuilder
    func padSpotlightContentInsetOnPad(_ isPad: Bool) -> some View {
        if isPad { padSpotlightContentInset() } else { self }
    }
}
