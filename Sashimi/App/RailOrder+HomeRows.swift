import Foundation

extension RailOrder {
    /// The tvOS rail's entries between Home and Settings: Search, Home's rows that
    /// are destinations (SashimiTV, the libraries) and the menu-only entries
    /// (Lists, Collections, Playlists) in the one order Settings edits
    /// (#841). Rows that are not destinations — hero, Continue Watching,
    /// shared-list rows — contribute nothing. `hidden` is what the user took
    /// out of the side menu (#753); `available` is `RailOrder.conditionalDestinations` (Requests,
    /// Dashboard, #845); `savedOrder` is
    /// `HomeScreenSettings.sideMenuOrder` (nil before anything was moved).
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
    /// The rail entry this row stands for; nil for rows that are not
    /// destinations (Featured, Continue Watching, shared-list rows). The
    /// Requests row carries the Requests entry (#861).
    var railDestination: RailOrder.Destination? {
        if type == .channels { return .finTV }
        if type == .requests { return .requests }
        return libraryId.map(RailOrder.Destination.library)
    }

    var sideMenuRow: SideMenuOrder.Row {
        SideMenuOrder.Row(id: id, destination: railDestination)
    }
}
