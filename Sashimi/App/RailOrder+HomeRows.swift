import Foundation

extension RailOrder {
    /// The tvOS rail's order: Home's rows (the SashimiTV row and the library
    /// rows), then anything they leave out. Rows that are not destinations —
    /// hero, Continue Watching — contribute nothing.
    /// `hidden` is what the user took out of the side menu (#753).
    static func destinations(
        rowConfigs: [HomeRowConfig],
        libraryIds: [String],
        hidden: Set<Destination> = []
    ) -> [Destination] {
        destinations(rowOrder: rowConfigs.compactMap(\.railDestination), libraryIds: libraryIds, hidden: hidden)
    }
}

extension RailOrder {
    /// Everything between Search and Settings: Home's destinations, then
    /// Lists (shared lists), which is not a Home row but can be hidden from
    /// the side menu like a library (#753).
    static func railDestinations(
        rowConfigs: [HomeRowConfig],
        libraryIds: [String],
        hidden: Set<Destination> = []
    ) -> [Destination] {
        destinations(rowConfigs: rowConfigs, libraryIds: libraryIds, hidden: hidden)
            + (hidden.contains(.lists) ? [] : [.lists])
    }
}

extension HomeRowConfig {
    /// The rail entry this row stands for; nil for rows that are not
    /// destinations (Featured, Continue Watching).
    var railDestination: RailOrder.Destination? {
        if type == .channels { return .finTV }
        return libraryId.map(RailOrder.Destination.library)
    }
}
