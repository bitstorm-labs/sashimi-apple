import Foundation

extension RailOrder {
    /// The tvOS rail's entries between Search and Settings: Home's rows that
    /// are destinations (SashimiTV, the libraries) and the menu-only entries
    /// (Lists, Collections, Playlists) in the one order Settings edits
    /// (#841). Rows that are not destinations — hero, Continue Watching,
    /// shared-list rows — contribute nothing. `hidden` is what the user took
    /// out of the side menu (#753); `savedOrder` is
    /// `HomeScreenSettings.sideMenuOrder` (nil before anything was moved).
    static func destinations(
        rowConfigs: [HomeRowConfig],
        libraryIds: [String],
        hidden: Set<Destination> = [],
        savedOrder: [String]? = nil
    ) -> [Destination] {
        SideMenuOrder.destinations(
            rows: rowConfigs.map(\.sideMenuRow),
            libraryIds: libraryIds,
            saved: savedOrder,
            hidden: hidden
        )
    }
}

extension HomeRowConfig {
    /// The rail entry this row stands for; nil for rows that are not
    /// destinations (Featured, Continue Watching, shared-list rows).
    var railDestination: RailOrder.Destination? {
        if type == .channels { return .finTV }
        return libraryId.map(RailOrder.Destination.library)
    }

    var sideMenuRow: SideMenuOrder.Row {
        SideMenuOrder.Row(id: id, destination: railDestination)
    }
}
