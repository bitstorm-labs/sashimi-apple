import Foundation

/// The picture behind a detail page's header.
///
/// A season has no backdrop or trailer of its own, so its page shows its
/// series' backdrop, exactly as the series page does (#764); the trailer
/// over it is the series' too (`HeroTrailerPolicy.trailerSourceId`).
enum DetailHero {
    struct Image: Equatable {
        let itemId: String
        let type: String
    }

    /// The item whose hero a page shows: a season's series, otherwise the
    /// item itself.
    static func heroItemId(for item: BaseItemDto) -> String {
        guard item.type == .season else { return item.id }
        return item.seriesId ?? item.parentId ?? item.id
    }

    /// Apple TV: the episode's own still, a YouTube channel's banner, or the
    /// backdrop (a season's being its series'). Missing types fall back
    /// through `tvFallbackTypes`.
    static func tvImage(for item: BaseItemDto, isYouTubeSeries: Bool) -> Image {
        if item.type == .episode || item.type == .video {
            return Image(itemId: item.id, type: "Primary")
        }
        return Image(itemId: heroItemId(for: item), type: isYouTubeSeries ? "Banner" : "Backdrop")
    }

    static func tvFallbackTypes(isYouTubeSeries: Bool) -> [String] {
        isYouTubeSeries ? ["Backdrop", "Thumb", "Primary"] : ["Thumb", "Backdrop", "Primary"]
    }

    /// iPhone and iPad pick by the tags the item carries: its own backdrop,
    /// else its series' (a season always shows its series'), else its poster.
    static func mobileImage(for item: BaseItemDto, isYouTubeSeries: Bool) -> Image {
        if item.type == .episode {
            return Image(itemId: item.id, type: "Primary")
        }
        if isYouTubeSeries {
            return Image(itemId: heroItemId(for: item), type: "Banner")
        }
        if item.type == .season {
            return Image(itemId: heroItemId(for: item), type: "Backdrop")
        }
        if item.backdropImageTags?.isEmpty == false {
            return Image(itemId: item.id, type: "Backdrop")
        }
        if item.parentBackdropImageTags?.isEmpty == false, let seriesId = item.seriesId {
            return Image(itemId: seriesId, type: "Backdrop")
        }
        return Image(itemId: item.id, type: "Primary")
    }
}
