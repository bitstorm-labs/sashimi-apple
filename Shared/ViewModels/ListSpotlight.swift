import CoreGraphics
import Foundation

/// One poster in a list's cover stack on the Lists page.
struct ListCoverPoster: Equatable {
    let artwork: WatchlistArtwork
    /// Stands in when there is no picture; empty on a list's cover.
    let title: String
    /// A Watchlist title the server doesn't have.
    let isDimmed: Bool
}

/// The "Poster stack" cover (design §6, option A): the first poster full size
/// and sharp, the next two fanned behind it, smaller, to the right and rotated,
/// the back one faded. Both apps draw it from these layers.
enum PosterStack {
    struct Layer: Equatable {
        /// Which poster (0 is the first title).
        let index: Int
        /// Of the front poster's size.
        let scale: CGFloat
        /// Of the front poster's width, centre to centre.
        let xOffset: CGFloat
        /// Degrees, clockwise.
        let rotation: Double
        let opacity: Double
    }

    static let maxPosters = 3
    /// The cover's width over its height.
    static let aspectRatio: CGFloat = 1.15
    /// The front poster's height, of the cover's.
    static let frontHeight: CGFloat = 0.92
    /// The front poster's left edge, of the cover's width.
    static let leadingInset: CGFloat = 0.04

    /// Back to front, so the first title is drawn last, on top.
    static func layers(count: Int, fanned: Bool) -> [Layer] {
        let behind: [Layer] = [
            Layer(index: 1, scale: 0.92, xOffset: fanned ? 0.30 : 0.23, rotation: fanned ? 5 : 3, opacity: 1),
            Layer(index: 2, scale: 0.88, xOffset: fanned ? 0.58 : 0.44, rotation: fanned ? 10 : 7, opacity: 0.85)
        ]
        let front = Layer(index: 0, scale: 1, xOffset: 0, rotation: 0, opacity: 1)
        let shown = min(max(count, 0), maxPosters)
        guard shown > 0 else { return [] }
        return Array(behind.prefix(shown - 1).reversed()) + [front]
    }
}

extension ListCard {
    /// The cover's posters, all the server's own.
    var coverPosters: [ListCoverPoster] {
        coverIds.map { ListCoverPoster(artwork: .library(itemId: $0), title: "", isDimmed: false) }
    }
}

/// What a list's page shows for its focused (Apple TV) or selected (phone)
/// title: "Spotlight" (design §6). Built from a library item, or from a
/// Watchlist title the server may not have.
struct ListSpotlight: Equatable {
    enum Backdrop: Equatable {
        case library(itemId: String, imageType: String)
        case remote(URL)
        case none
    }

    enum Action: Equatable {
        case play(BaseItemDto)
        /// Requests' page for the title, with Request.
        case request(SeerrTarget)
        /// Requests settings, to sign in.
        case signInToRequests
        case none
    }

    let id: String
    let title: String
    /// "1983 · 3h 13m · PG · Drama, History"; parts the item lacks are left out.
    let details: String
    let overview: String?
    let backdrop: Backdrop
    /// "Not on server" or "Requested".
    let tag: String?
    let action: Action

    var isMissing: Bool { tag != nil }

    init(item: BaseItemDto) {
        id = item.id
        title = item.name
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        // A show's runtime is one episode's: not what the title is.
        if item.type != .series, let runtime = DateFormatting.formatRuntime(item.runTimeTicks) { parts.append(runtime) }
        if let rating = item.officialRating, !rating.isEmpty { parts.append(rating) }
        if let genres = item.genres, !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        details = parts.joined(separator: " · ")
        overview = item.overview.flatMap { $0.isEmpty ? nil : $0 }
        let isYouTube = item.libraryName?.lowercased().contains("youtube") == true
        let image = DetailHero.mobileImage(for: item, isYouTubeSeries: isYouTube && item.type == .series)
        backdrop = .library(itemId: image.itemId, imageType: image.type)
        tag = nil
        action = .play(item)
    }

    init(tile: WatchlistTile, signedIntoRequests: Bool) {
        if let item = tile.libraryItem {
            self.init(item: item)
            return
        }
        let entry = tile.entry
        let kind = entry.kind == .movie ? "Movie" : "Show"
        var backdrop = Backdrop.none
        if case .remote(let url) = tile.artwork { backdrop = .remote(url) }
        var action = Action.none
        if let target = Watchlist.seerrTarget(for: entry) {
            action = signedIntoRequests ? .request(target) : .signInToRequests
        }
        self.init(
            id: entry.id,
            title: entry.title,
            details: ([entry.year.map(String.init)] + [kind]).compactMap { $0 }.joined(separator: " · "),
            overview: nil,
            backdrop: backdrop,
            tag: (tile.missingTag ?? .notOnServer).label,
            action: action
        )
    }

    private init(id: String, title: String, details: String, overview: String?, backdrop: Backdrop, tag: String?,
                 action: Action) {
        self.id = id
        self.title = title
        self.details = details
        self.overview = overview
        self.backdrop = backdrop
        self.tag = tag
        self.action = action
    }
}

enum ListSpotlightText {
    static let play = "Play"
    static let request = "Request"
    static let signInToRequests = "Sign in to Requests"
}
