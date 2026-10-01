import Foundation

extension RailOrder {
    /// The iPad rail's order: Home's rows (the SashimiTV row and the library
    /// rows), then anything they leave out — the same rule as the tvOS rail.
    /// Continue Watching is not a destination and contributes nothing.
    static func destinations(rowConfigs: [HomeRowConfig], libraryIds: [String]) -> [Destination] {
        let rowOrder: [Destination] = rowConfigs.compactMap { config in
            switch config.type {
            case .builtIn(.channels): return .finTV
            case .builtIn: return nil
            case .library(let id, _): return .library(id)
            }
        }
        return destinations(rowOrder: rowOrder, libraryIds: libraryIds)
    }
}
