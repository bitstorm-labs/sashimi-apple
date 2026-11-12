import SwiftUI

/// Where a Spotlight backdrop sits and how it fades (design §6): the Watchlist
/// and list pages', which every detail page shares since #894. Fractions of
/// the page. Pure numbers so the coverage is testable and both apps agree.
struct SpotlightBackdropLayout: Equatable {
    /// The picture's width, flush to the right edge.
    let widthFraction: CGFloat
    /// The picture's height, flush to the top edge.
    let heightFraction: CGFloat
    /// The left edge is transparent at 0 and opaque from here on (fractions
    /// of the picture's width); 0 for a picture whose left edge is the
    /// screen's.
    let leadingOpaqueAt: CGFloat
    /// The picture is opaque to here, then fades out by its bottom.
    let bottomFadeStartsAt: CGFloat
    /// At most this tall for its width, so a full-width picture on a tall
    /// page keeps most of a 16:9 backdrop rather than a sliver of its middle.
    var maxHeightPerWidth: CGFloat?
    /// Where the page's details start, as a fraction of the picture's height:
    /// over its faded lower part. Nil when they sit beside the picture, on
    /// the page's dark left side.
    var contentStartsAt: CGFloat?

    /// Apple TV, and iPad and Mac in landscape: bright across the right two
    /// thirds, fading into the page on the left and the bottom.
    static let landscape = SpotlightBackdropLayout(
        widthFraction: 0.7,
        heightFraction: 0.8,
        leadingOpaqueAt: 0.45,
        bottomFadeStartsAt: 0.5
    )

    /// iPhone, and an iPad page taller than it is wide: the full width at
    /// the top, fading into the content below it.
    static let portrait = SpotlightBackdropLayout(
        widthFraction: 1,
        heightFraction: 0.6,
        leadingOpaqueAt: 0,
        bottomFadeStartsAt: 0.5,
        maxHeightPerWidth: 2 / 3,
        contentStartsAt: 0.75
    )

    /// Landscape for a page wider than it is tall, portrait otherwise.
    static func fitting(_ size: CGSize) -> SpotlightBackdropLayout {
        size.width > size.height ? .landscape : .portrait
    }

    /// The picture's size on a page of `size`.
    func frame(in size: CGSize) -> CGSize {
        let width = size.width * widthFraction
        var height = size.height * heightFraction
        if let maxHeightPerWidth { height = min(height, width * maxHeightPerWidth) }
        return CGSize(width: width, height: height)
    }

    /// The picture's drawn width on a page of `size`. It fills its frame, so a
    /// 16:9 backdrop in the landscape frame (1344×864 on Apple TV) is drawn
    /// 864 × 16/9 = 1536pt wide, wider than the frame, with the sides cropped.
    func imagePointWidth(in size: CGSize, imageAspect: CGFloat = 16 / 9) -> CGFloat {
        let frame = frame(in: size)
        return max(frame.width, frame.height * imageAspect)
    }

    /// The backdrop's request width in pixels: its drawn width at `scale`
    /// (1 on a 1080p Apple TV, 2 at 4K), capped at a 4K screen's width. Asking
    /// for the frame's width instead upscaled the picture about 1.13× and read
    /// soft on the TV.
    func requestPixelWidth(in size: CGSize, scale: CGFloat) -> Int {
        min(ImageSizing.pixelWidth(points: imagePointWidth(in: size), scale: scale), ImageSizing.maxSpotlightBackdropWidth)
    }

    /// How far down a page of `size` its details start.
    func contentInset(in size: CGSize) -> CGFloat {
        contentStartsAt.map { frame(in: size).height * $0 } ?? 0
    }
}

/// Where a Spotlight backdrop's picture goes, and how big to ask for it.
struct SpotlightBackdropSlot {
    /// The picture's frame.
    let width: CGFloat
    let height: CGFloat
    /// Pixels to request at the display's scale: the drawn width, which for a
    /// filled 16:9 picture is wider than the frame.
    let requestPixelWidth: Int
}

/// A Spotlight backdrop: `content` (a picture, and a trailer over it) laid out
/// and faded by `layout`. The Watchlist and list pages and every detail page
/// draw their backdrop with it, so they cover the same area (#894).
///
/// The fade is applied to the picture's own frame, never to a container
/// wider than the picture, so a picture never shows a hard left edge.
struct SpotlightBackdrop<Content: View>: View {
    /// Nil: `.fitting` the page, landscape or portrait.
    var layout: SpotlightBackdropLayout? = .landscape
    @ViewBuilder let content: (SpotlightBackdropSlot) -> Content

    var body: some View {
        GeometryReader { geometry in
            let layout = layout ?? .fitting(geometry.size)
            let frame = layout.frame(in: geometry.size)
            let slot = SpotlightBackdropSlot(
                width: frame.width,
                height: frame.height,
                requestPixelWidth: layout.requestPixelWidth(in: geometry.size, scale: ImageSizing.displayScale)
            )
            ZStack(alignment: .topTrailing) {
                Color.clear
                content(slot)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .spotlightFade(layout)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The Spotlight's fade: the left edge (when `layout` fades it) and the
    /// lower part, into the page.
    func spotlightFade(_ layout: SpotlightBackdropLayout = .landscape) -> some View {
        mask(
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: layout.leadingOpaqueAt)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .mask(
            LinearGradient(
                stops: [.init(color: .black, location: layout.bottomFadeStartsAt), .init(color: .clear, location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

extension SpotlightBackdropLayout {
    /// How wide a list page's details may run on a page of `size`: on a
    /// landscape page, the dark left side beside the picture; on a portrait
    /// page, the page's width (they sit under the picture).
    func detailsMaxWidth(in size: CGSize) -> CGFloat {
        contentStartsAt == nil ? size.width * 0.5 : size.width
    }

    /// The least height of a list page's details on a page of `size`, so the
    /// posters below start over the picture's faded lower part, never over
    /// its bright middle.
    func detailsMinHeight(in size: CGSize) -> CGFloat {
        frame(in: size).height * (bottomFadeStartsAt + 0.1)
    }
}
