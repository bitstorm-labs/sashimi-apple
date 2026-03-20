import SwiftUI

struct PhoneTabView: View {
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        TabView {
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

            if networkMonitor.isConnected {
                NavigationStack {
                    PhoneLibrariesTab()
                }
                .tabItem {
                    Label("Libraries", systemImage: "folder")
                }

                NavigationStack {
                    MobileSearchView()
                }
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }

            NavigationStack {
                DownloadsListView()
                    .navigationTitle("Downloads")
            }
            .tabItem {
                Label("Downloads", systemImage: "arrow.down.circle")
            }

            NavigationStack {
                MobileSettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(MobileColors.accent)
    }
}
