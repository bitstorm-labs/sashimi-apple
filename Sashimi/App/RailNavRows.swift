import Foundation

/// What the tvOS rail lists, apart from how it is drawn. Split out of
/// SashimiApp.swift so MainTabView stays within the length the linter allows,
/// and so the order can be tested.
extension MainTabView {
    struct NavRow: Identifiable, Equatable {
        let id: NavID
        let title: String
        let icon: String
    }

    /// Nav rows follow the Home row order set in Settings, so the rail and the
    /// screen it opens onto agree with each other. Home and Search lead and
    /// Settings trails: they are destinations rather than rows, and have no
    /// place in that ordering. RailOrder decides the middle, with Lists
    /// (shared lists) after the libraries unless hidden (#753).
    static func navRows(
        rowConfigs: [HomeRowConfig],
        libraries: [JellyfinLibrary],
        hidden: Set<RailOrder.Destination>
    ) -> [NavRow] {
        var rows: [NavRow] = [
            NavRow(id: .home, title: "Home", icon: "house"),
            NavRow(id: .search, title: "Search", icon: "magnifyingglass")
        ]

        for destination in RailOrder.railDestinations(
            rowConfigs: rowConfigs,
            libraryIds: libraries.map(\.id),
            hidden: hidden
        ) {
            switch destination {
            case .finTV:
                rows.append(NavRow(id: .finTV, title: "SashimiTV", icon: "antenna.radiowaves.left.and.right"))
            case .library(let id):
                guard let lib = libraries.first(where: { $0.id == id }) else { continue }
                let icon = RailOrder.libraryIcon(name: lib.name, collectionType: lib.collectionType)
                rows.append(NavRow(id: .library(lib.id), title: lib.name, icon: icon))
            case .lists:
                rows.append(NavRow(id: .lists, title: "Lists", icon: "list.bullet.rectangle"))
            }
        }

        rows.append(NavRow(id: .settings, title: "Settings", icon: "gearshape"))
        return rows
    }
}
