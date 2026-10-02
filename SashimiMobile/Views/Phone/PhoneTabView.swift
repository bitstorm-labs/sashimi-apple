import SwiftUI

struct PhoneTabView: View {
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
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
                if networkMonitor.isOnline {
                    PhoneHomeView()
                } else {
                    OfflineHomeView()
                }
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }
            .tag(PhoneTab.home)

            // The tabs stay put offline (a tab bar that rearranges itself as
            // the connection comes and goes loses the viewer's place); what
            // needs the server says so instead.
            NavigationStack {
                if networkMonitor.isOnline {
                    PhoneLibrariesTab()
                } else {
                    OfflineUnavailableView(title: "Libraries")
                }
            }
            .tabItem {
                Label("Libraries", systemImage: "folder")
            }
            .tag(PhoneTab.libraries)

            NavigationStack {
                if networkMonitor.isOnline {
                    MobileSearchView(
                        initialQuery: searchRequest?.query,
                        onInitialQueryConsumed: {
                            if let id = searchRequest?.id {
                                onSearchRequestConsumed(id)
                            }
                        }
                    )
                } else {
                    OfflineUnavailableView(title: "Search")
                }
            }
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }
            .tag(PhoneTab.search)

            NavigationStack {
                DownloadsListView()
                    .navigationTitle("Downloads")
            }
            .tabItem {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            // Tab items only render an image and text, so the iPad's progress
            // ring can't live here; the badge carries the active/queued count
            // and disappears at zero.
            .badge(downloadManager.activitySnapshot.activeCount)
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
        // The iPad's sidebar has always shown these; the phone had nowhere
        // to say "Will download on Wi-Fi".
        .downloadToast {
            selectedTab = .downloads
        }
        .onAppear {
            applySearchRequest()
        }
        .onChange(of: searchRequest?.id) { _, _ in
            applySearchRequest()
        }
    }

    private func applySearchRequest() {
        guard searchRequest != nil, networkMonitor.isOnline else { return }
        selectedTab = .search
    }
}
