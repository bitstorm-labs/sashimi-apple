import Foundation

extension RailOrder {
    /// The tvOS rail's order: Home's rows (the SashimiTV row and the library
    /// rows), then anything they leave out. Rows that are not destinations —
    /// hero, Continue Watching — contribute nothing.
    static func destinations(rowConfigs: [HomeRowConfig], libraryIds: [String]) -> [Destination] {
        let rowOrder: [Destination] = rowConfigs.compactMap { config in
            if config.type == .channels { return .finTV }
            return config.libraryId.map(Destination.library)
        }
        return destinations(rowOrder: rowOrder, libraryIds: libraryIds)
    }
}
