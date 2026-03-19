import SwiftUI

struct PhoneTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                PhoneHomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }

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
