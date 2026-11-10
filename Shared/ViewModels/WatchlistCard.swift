import Foundation

/// Where a Watchlist title's poster comes from.
enum WatchlistArtwork: Equatable {
    /// The server has it: its own poster.
    case library(itemId: String)
    /// Not on the server: the poster the plugin saved with the title.
    case remote(URL)
    /// Nothing to show; the title stands in.
    case none

    init(entry: WatchlistEntry) {
        if let itemId = entry.itemId {
            self = .library(itemId: itemId)
        } else if let url = entry.posterURL {
            self = .remote(url)
        } else {
            self = .none
        }
    }
}

extension WatchlistTile {
    /// The page has looked the title up: an id the server no longer has falls
    /// back to the saved poster.
    var artwork: WatchlistArtwork {
        if let item = libraryItem { return .library(itemId: item.id) }
        return entry.posterURL.map(WatchlistArtwork.remote) ?? .none
    }
}

/// The Watchlist's card on the Lists page.
struct WatchlistCardInfo: Equatable {
    let subtitle: String
    /// The first four titles' posters.
    let cover: [WatchlistArtwork]

    init(_ list: WatchlistResponse) {
        var subtitle = WatchlistText.summary(count: list.entries.count)
        if let plex = list.plex, !plex.needsReconnect { subtitle += " · \(WatchlistText.synced)" }
        self.subtitle = subtitle
        cover = list.entries.prefix(4).map(WatchlistArtwork.init(entry:))
    }
}

extension WatchlistStore {
    /// Nil without the plugin (or before the Watchlist has loaded): no card.
    var card: WatchlistCardInfo? {
        guard isAvailable, let watchlist else { return nil }
        return WatchlistCardInfo(watchlist)
    }
}
