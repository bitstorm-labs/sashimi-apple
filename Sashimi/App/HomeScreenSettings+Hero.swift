import Foundation

extension HomeScreenSettings {
    /// The rows hidden on Home, so their titles leave the hero too (#836).
    func heroHidden(itemLibraryIds: [String: String]) -> HeroRotation.Hidden {
        HeroRotation.Hidden(
            rows: rowConfigs.map {
                .init(libraryId: $0.libraryId, isChannels: $0.type == .channels, isVisible: $0.isVisible)
            },
            itemLibraryIds: itemLibraryIds
        )
    }
}
