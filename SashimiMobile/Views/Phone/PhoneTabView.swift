import SwiftUI

struct PhoneTabView: View {
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    var searchRequest: SashimiIntentCoordinator.SearchRequest?
    var onSearchRequestConsumed: (UUID) -> Void = { _ in }
    @State private var selectedTab: PhoneTab = .home

    private enum PhoneTab: Hashable {
        case home
        case libraries
        case search
        case downloads
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                if networkMonitor.isConnected {
                    PhoneHomeView()
                } else {
                    OfflineHomeView()
                }
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }
            .tag(PhoneTab.home)

            if networkMonitor.isConnected {
                NavigationStack {
                    PhoneLibrariesTab()
                }
                .tabItem {
                    Label("Libraries", systemImage: "folder")
                }
                .tag(PhoneTab.libraries)

                NavigationStack {
                    MobileSearchView(
                        initialQuery: searchRequest?.query,
                        onInitialQueryConsumed: {
                            if let id = searchRequest?.id {
                                onSearchRequestConsumed(id)
                            }
                        }
                    )
                }
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(PhoneTab.search)
            }

            NavigationStack {
                DownloadsListView()
                    .navigationTitle("Downloads")
            }
            .tabItem {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            .tag(PhoneTab.downloads)

            NavigationStack {
                MobileSettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(PhoneTab.settings)
        }
        .tint(MobileColors.accent)
        .onAppear {
            applySearchRequest()
        }
        .onChange(of: searchRequest?.id) { _, _ in
            applySearchRequest()
        }
    }

    private func applySearchRequest() {
        guard searchRequest != nil, networkMonitor.isConnected else { return }
        selectedTab = .search
    }
}
