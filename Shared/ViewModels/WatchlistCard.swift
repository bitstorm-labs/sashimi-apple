import Foundation

/// Where a Watchlist title's poster comes from.
enum WatchlistArtwork: Equatable {
    /// The server has it: its own poster, or `fallback` (the poster the plugin
    /// saved) when the server has none for that id.
    case library(itemId: String, fallback: URL? = nil)
    /// Not on the server: the poster the plugin saved with the title.
    case remote(URL)
    /// Nothing to show; the title stands in.
    case none

    /// The saved poster to show when the server's image doesn't load.
    var fallback: URL? {
        if case .library(_, let fallback) = self { return fallback }
        return nil
    }

    init(entry: WatchlistEntry) {
        if let itemId = entry.itemId {
            self = .library(itemId: itemId, fallback: entry.posterURL)
        } else if let url = entry.posterURL {
            self = .remote(url)
        } else {
            self = .none
        }
    }
}

extension WatchlistTile {
    /// The page has looked the title up: an id the server no longer has falls
    /// back to the saved poster, and a title saved without one to Requests'.
    var artwork: WatchlistArtwork {
        if let item = libraryItem { return .library(itemId: item.id) }
        return (entry.posterURL ?? seerrPoster).map(WatchlistArtwork.remote) ?? .none
    }
}

/// The Watchlist's card on the Lists page.
struct WatchlistCardInfo: Equatable {
    let subtitle: String
    /// The posters of the first three titles that have one, those the server
    /// doesn't have dimmed; empty when none do (both apps then draw the bookmark).
    let cover: [ListCoverPoster]

    init(_ list: WatchlistResponse) {
        var subtitle = WatchlistText.summary(count: list.entries.count)
        if let plex = list.plex, !plex.needsReconnect { subtitle += " · \(WatchlistText.synced)" }
        self.subtitle = subtitle
        cover = Array(list.entries.lazy
            .map { ListCoverPoster(artwork: WatchlistArtwork(entry: $0), title: $0.title, isDimmed: $0.itemId == nil) }
            .filter { $0.artwork != .none }
            .prefix(PosterStack.maxPosters))
    }
}

extension WatchlistStore {
    /// Nil without the plugin (or before the Watchlist has loaded): no card.
    var card: WatchlistCardInfo? {
        guard isAvailable, let watchlist else { return nil }
        return WatchlistCardInfo(watchlist)
    }
}
