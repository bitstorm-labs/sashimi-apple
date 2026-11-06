import SwiftUI

/// What the tvOS rail lists, apart from how it is drawn (and the bits of its
/// drawing that need none of MainTabView's state). Split out of
/// SashimiApp.swift so MainTabView stays within the length the linter allows,
/// and so the order can be tested.
extension MainTabView {
    /// A destination in the rail. Libraries are dynamic, so this is an enum
    /// rather than a tab index.
    enum NavID: Hashable {
        case home, finTV, search, settings, avatar, lists
        /// Seerr requests and the admin Server dashboard (#845).
        case requests, dashboard
        case library(String)
    }

    /// Soft accent highlight in place of the tvOS default white focus platter:
    /// the same tinted fill + accent ring the settings rows use.
    static func railFocusHighlight(_ isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(SashimiTheme.focus.opacity(isFocused ? 0.18 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(SashimiTheme.focus.opacity(isFocused ? 1 : 0), lineWidth: 3)
            )
    }

    /// Jellyfin purple, sampled from the logo — the selected-item highlight.
    static let jellyfinPurple = Color(red: 189 / 255, green: 62 / 255, blue: 237 / 255)

    static var appVersion: String {
        "v" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
    }

    struct NavRow: Identifiable, Equatable {
        let id: NavID
        let title: String
        let icon: String
    }

    /// Nav rows follow the order set in Settings › Home & Side Menu, so the
    /// rail and the screen it opens onto agree with each other. Home and
    /// Search lead and Settings trails: they are destinations rather than
    /// rows, and have no place in that ordering. RailOrder decides the
    /// middle: Home's rows with Lists and the menu-only libraries among them
    /// (#841), Requests and Dashboard when `available` (#845), less what the
    /// user hid (#753).
    static func navRows(
        rowConfigs: [HomeRowConfig],
        libraries: [JellyfinLibrary],
        hidden: Set<RailOrder.Destination>,
        savedOrder: [String]? = nil,
        available: [RailOrder.Destination] = []
    ) -> [NavRow] {
        var rows: [NavRow] = [
            NavRow(id: .home, title: "Home", icon: "house"),
            NavRow(id: .search, title: "Search", icon: "magnifyingglass")
        ]

        for destination in RailOrder.destinations(
            rowConfigs: rowConfigs,
            libraryIds: libraries.map(\.id),
            hidden: hidden,
            savedOrder: savedOrder,
            available: available
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
            case .requests:
                rows.append(NavRow(id: .requests, title: "Requests", icon: RailOrder.requestsIcon))
            case .dashboard:
                rows.append(NavRow(id: .dashboard, title: "Dashboard", icon: RailOrder.dashboardIcon))
            }
        }

        rows.append(NavRow(id: .settings, title: "Settings", icon: "gearshape"))
        return rows
    }
}
