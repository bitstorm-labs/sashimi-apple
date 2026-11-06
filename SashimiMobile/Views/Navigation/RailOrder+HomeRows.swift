import Foundation

extension RailOrder {
    /// The iPad rail's entries between Home and Search: Home's rows that are
    /// destinations (SashimiTV, the libraries) and the menu-only entries
    /// (Lists, Collections, Playlists) in the one order Settings edits
    /// (#841) — the same rule as the tvOS rail. Continue Watching and
    /// shared-list rows are not destinations and contribute nothing.
    /// `hidden` is what the user took out of the side menu (#753);
    /// `available` is `RailOrder.conditionalDestinations` (Requests,
    /// Dashboard, #845); `savedOrder` is `HomeRowSettings.sideMenuOrder`.
    static func destinations(
        rowConfigs: [HomeRowConfig],
        libraryIds: [String],
        hidden: Set<Destination> = [],
        savedOrder: [String]? = nil,
        available: [Destination] = []
    ) -> [Destination] {
        SideMenuOrder.destinations(
            rows: rowConfigs.map(\.sideMenuRow),
            libraryIds: libraryIds,
            saved: savedOrder,
            hidden: hidden,
            available: available
        )
    }
}

extension HomeRowConfig {
    /// The side-menu entry this row stands for; nil for Continue Watching
    /// and shared-list rows.
    var railDestination: RailOrder.Destination? {
        switch type {
        case .builtIn(.channels): return .finTV
        case .builtIn: return nil
        case .library(let id, _): return .library(id)
        case .list: return nil
        }
    }

    var sideMenuRow: SideMenuOrder.Row {
        SideMenuOrder.Row(id: id, destination: railDestination)
    }
}
