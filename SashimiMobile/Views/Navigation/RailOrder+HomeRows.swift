import Foundation

extension RailOrder {
    /// The iPad rail's order: Home's rows (the SashimiTV row and the library
    /// rows), then anything they leave out — the same rule as the tvOS rail.
    /// Continue Watching is not a destination and contributes nothing.
    /// `hidden` is what the user took out of the side menu (#753).
    static func destinations(
        rowConfigs: [HomeRowConfig],
        libraryIds: [String],
        hidden: Set<Destination> = []
    ) -> [Destination] {
        destinations(rowOrder: rowConfigs.compactMap(\.railDestination), libraryIds: libraryIds, hidden: hidden)
    }
}

extension HomeRowConfig {
    /// The side-menu entry this row stands for; nil for Continue Watching.
    var railDestination: RailOrder.Destination? {
        switch type {
        case .builtIn(.channels): return .finTV
        case .builtIn: return nil
        case .library(let id, _): return .library(id)
        }
    }
}
