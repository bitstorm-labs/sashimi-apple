import Foundation

/// What the nav rail lists between Home and Search, in order.
///
/// Pure and standalone because the rule is worth testing and the rail itself is
/// a view: given the Home row order the user set and the libraries the server
/// reports, this decides which destinations appear and in what sequence.
///
/// Shared by the tvOS rail and the iPad rail. Each target has its own
/// `HomeRowConfig`, so each maps its row order to `Destination`s (see the
/// `destinations(rowConfigs:libraryIds:)` extension in each target).
enum RailOrder {
    enum Destination: Hashable {
        case finTV
        case library(String)
        /// Shared lists. Not a Home row: it sits wherever the combined order
        /// in `SideMenuOrder` puts it (after the libraries until moved, #841),
        /// and the side-menu setting can hide it like any library (#753).
        case lists
        /// Seerr requests (#845). Menu-only like Lists, and only there while
        /// a Seerr account is connected (or its sign-in has expired).
        case requests
        /// The admin Server dashboard (#845). Menu-only, administrators only.
        case dashboard
    }

    /// The menu-only entries that come and go with the account: what is
    /// available now, in their default order (after Lists). `seerr` is the
    /// Seerr sign-in; an expired one keeps Requests so its page can say so.
    static func conditionalDestinations(seerr: SeerrAuthState, canViewDashboard: Bool) -> [Destination] {
        var result: [Destination] = []
        switch seerr {
        case .signedIn, .expired: result.append(.requests)
        case .notConfigured, .signingIn, .awaitingPlex: break
        }
        if canViewDashboard { result.append(.dashboard) }
        return result
    }

    /// The menu-only entries that trail the list until the user moves them,
    /// in that order.
    static let trailingDestinations: [Destination] = [.lists, .requests, .dashboard]

    /// `rowOrder` (the menu's entries in the user's order, see
    /// `SideMenuOrder`) wins; libraries it does not account for follow in
    /// server order, then SashimiTV, then Lists, then whichever of Requests
    /// and Dashboard `available` holds (`conditionalDestinations`).
    ///
    /// Rows hidden on Home are still listed. Hiding a row is a statement about
    /// the Home screen, not about the destination. What leaves the rail is
    /// what the user hid from the side menu (`hidden`, #753), a setting of its
    /// own; Home, Search and Settings are not destinations, so they can never
    /// be hidden. Anything not in `hidden` — a library added on the server
    /// later included — shows, and hidden ids the server no longer has do
    /// nothing.
    static func destinations(
        rowOrder: [Destination],
        libraryIds: [String],
        hidden: Set<Destination> = [],
        available: [Destination] = []
    ) -> [Destination] {
        var ordered: [Destination] = []
        var placed: Set<Destination> = []

        func place(_ destination: Destination) {
            guard !placed.contains(destination) else { return }
            ordered.append(destination)
            placed.insert(destination)
        }

        for destination in rowOrder {
            switch destination {
            case .finTV, .lists:
                place(destination)
            case .requests, .dashboard:
                // Saved while signed in, say, and not there now.
                if available.contains(destination) { place(destination) }
            case .library(let libraryId) where libraryIds.contains(libraryId):
                // A config can outlive the library it names — the row order is
                // saved locally and the server is free to drop a library.
                place(destination)
            case .library:
                continue
            }
        }

        // A library added on the server since the row order was saved, or a
        // first run with nothing saved at all, still needs a way in.
        for libraryId in libraryIds {
            place(.library(libraryId))
        }
        // Likewise FinTV, if the saved order predates the row existing, and
        // Lists, which has always come last, and the conditional entries
        // after it (#845).
        place(.finTV)
        place(.lists)
        for destination in [Destination.requests, .dashboard] where available.contains(destination) {
            place(destination)
        }

        return ordered.filter { !hidden.contains($0) }
    }

    /// The settings footnote for a destination hidden from both Home and the
    /// side menu, which leaves Search as the only way to it.
    static func reachabilityNote(isOnHome: Bool, isInSideMenu: Bool) -> String? {
        isOnHome || isInSideMenu ? nil : "Only reachable from Search"
    }

    /// The same footnote for one destination. The Dashboard has no other way
    /// in once it leaves the side menu (#845); Requests is still offered by
    /// Search's "Not in your library" row.
    static func reachabilityNote(for destination: Destination?, isOnHome: Bool, isInSideMenu: Bool) -> String? {
        guard destination == .dashboard else { return reachabilityNote(isOnHome: isOnHome, isInSideMenu: isInSideMenu) }
        return isInSideMenu ? nil : "Hidden: the Dashboard has no other way in"
    }

    static let requestsIcon = "tray.and.arrow.down"
    static let dashboardIcon = "gauge.with.dots.needle.67percent"

    /// The rail's SF Symbol for a library. YouTube libraries report
    /// collectionType "tvshows", so they are matched by name.
    static func libraryIcon(name: String, collectionType: String?) -> String {
        if name.lowercased().contains("youtube") { return "play.rectangle.fill" }
        switch collectionType {
        case "movies": return "film.stack"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "musicvideos": return "music.note.tv"
        case "books": return "books.vertical"
        case "photos", "homevideos": return "photo.stack"
        case "playlists": return "list.and.film"
        case "boxsets": return "square.stack.3d.up.fill"
        case "livetv": return "dot.radiowaves.left.and.right"
        default: return "rectangle.stack"
        }
    }
}
