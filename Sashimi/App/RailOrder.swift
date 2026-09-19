import Foundation

/// What the nav rail lists between Home and Search, in order.
///
/// Pure and standalone because the rule is worth testing and the rail itself is
/// a view: given the Home row order the user set and the libraries the server
/// reports, this decides which destinations appear and in what sequence.
enum RailOrder {
    enum Destination: Hashable {
        case finTV
        case library(String)
    }

    /// Row order wins; anything it does not account for follows in server order.
    ///
    /// Rows hidden on Home are still listed. Hiding a row is a statement about
    /// the Home screen, not about the destination, and for a library the rail is
    /// the only way to reach it at all.
    static func destinations(rowConfigs: [HomeRowConfig], libraryIds: [String]) -> [Destination] {
        var ordered: [Destination] = []
        var placed: Set<Destination> = []

        func place(_ destination: Destination) {
            guard !placed.contains(destination) else { return }
            ordered.append(destination)
            placed.insert(destination)
        }

        for config in rowConfigs {
            if config.type == .channels {
                place(.finTV)
            } else if let libraryId = config.libraryId, libraryIds.contains(libraryId) {
                // A config can outlive the library it names — the row order is
                // saved locally and the server is free to drop a library.
                place(.library(libraryId))
            }
        }

        // A library added on the server since the row order was saved, or a
        // first run with nothing saved at all, still needs a way in.
        for libraryId in libraryIds {
            place(.library(libraryId))
        }
        // Likewise FinTV, if the saved order predates the row existing.
        place(.finTV)

        return ordered
    }
}
