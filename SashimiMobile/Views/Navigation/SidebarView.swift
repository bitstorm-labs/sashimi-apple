import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case home = "Home"
    case library = "Library"
    case search = "Search"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house"
        case .library: return "rectangle.stack"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(SidebarItem.allCases, selection: $selection) { item in
            Label(item.rawValue, systemImage: item.icon)
                .tag(item)
        }
        .navigationTitle("Sashimi")
        .listStyle(.sidebar)
    }
}

struct MainNavigationView: View {
    @State private var selection: SidebarItem? = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
        } detail: {
            NavigationStack {
                detailView
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .home:
            MobileHomeView()
        case .library:
            MobileLibraryView()
        case .search:
            MobileSearchView()
        case .settings:
            MobileSettingsView()
        case nil:
            MobileHomeView()
        }
    }
}
