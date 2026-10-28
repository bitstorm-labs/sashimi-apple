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
        /// Shared lists. Not a Home row, so it never comes out of
        /// `destinations`; each rail places it after the libraries, and the
        /// side-menu setting can hide it like any library (#753).
        case lists
    }

    /// `rowOrder` (the Home rows that are destinations, in the user's order)
    /// wins; anything it does not account for follows in server order.
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
        hidden: Set<Destination> = []
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
            case .finTV:
                place(.finTV)
            case .library(let libraryId) where libraryIds.contains(libraryId):
                // A config can outlive the library it names — the row order is
                // saved locally and the server is free to drop a library.
                place(destination)
            case .library, .lists:
                continue
            }
        }

        // A library added on the server since the row order was saved, or a
        // first run with nothing saved at all, still needs a way in.
        for libraryId in libraryIds {
            place(.library(libraryId))
        }
        // Likewise FinTV, if the saved order predates the row existing.
        place(.finTV)

        return ordered.filter { !hidden.contains($0) }
    }

    /// Libraries the rail lists that Home has no row for (Collections,
    /// Playlists): their side-menu switch needs a row of its own in settings.
    static func menuOnlyLibraries(_ libraries: [JellyfinLibrary], homeDestinations: [Destination]) -> [JellyfinLibrary] {
        let onHome = Set(homeDestinations)
        return libraries.filter { !onHome.contains(.library($0.id)) }
    }

    /// The settings footnote for a destination hidden from both Home and the
    /// side menu, which leaves Search as the only way to it.
    static func reachabilityNote(isOnHome: Bool, isInSideMenu: Bool) -> String? {
        isOnHome || isInSideMenu ? nil : "Only reachable from Search"
    }

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
