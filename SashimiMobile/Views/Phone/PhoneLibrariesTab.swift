import SwiftUI

struct PhoneLibrariesTab: View {
    @State private var libraries: [JellyfinLibrary] = []
    @ObservedObject private var seerr = SeerrSession.shared
    @ObservedObject private var sessionManager = SessionManager.shared
    @ObservedObject private var watchlist = WatchlistStore.shared

    /// What the iPad's side menu lists besides the libraries and Lists: the
    /// Watchlist unless the server has none (#894), Requests with a Seerr
    /// account, Dashboard for administrators (#845).
    private var extras: [RailOrder.Destination] {
        RailOrder.conditionalDestinations(
            seerr: seerr.state,
            canViewDashboard: sessionManager.canViewServerDashboard,
            hasWatchlist: RailOrder.hasWatchlist(watchlist.availability)
        )
    }

    var body: some View {
        List {
            // The Watchlist first, as the iPad's side menu has it (#894).
            if extras.contains(.watchlist) {
                NavigationLink {
                    MobileWatchlistView()
                } label: {
                    Label(WatchlistText.name, systemImage: RailOrder.watchlistIcon)
                }
                .listRowBackground(MobileColors.cardBackground)
            }

            // Shared lists live here on iPhone: the tab bar has no room for a
            // sixth tab without hiding Settings behind More.
            NavigationLink {
                MobileListsView()
            } label: {
                Label("Lists", systemImage: "list.bullet.rectangle")
            }
            .listRowBackground(MobileColors.cardBackground)

            // Requests and the Dashboard too (#845): the iPad has them in the
            // side menu, and the tab bar has no room for them either.
            if extras.contains(.requests) {
                NavigationLink {
                    MobileRequestsPage()
                } label: {
                    Label("Requests", systemImage: RailOrder.requestsIcon)
                }
                .listRowBackground(MobileColors.cardBackground)
            }
            if extras.contains(.dashboard) {
                NavigationLink {
                    MobileServerDashboardView()
                } label: {
                    Label("Dashboard", systemImage: RailOrder.dashboardIcon)
                }
                .listRowBackground(MobileColors.cardBackground)
            }

            ForEach(libraries) { library in
                NavigationLink {
                    MobileLibraryBrowseView(
                        libraryId: library.id,
                        libraryName: library.name,
                        collectionType: library.collectionType
                    )
                    .navigationTitle(library.name)
                } label: {
                    Label(library.name, systemImage: iconFor(library.collectionType))
                }
                .listRowBackground(MobileColors.cardBackground)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MobileColors.background)
        .navigationTitle("Libraries")
        .task {
            do {
                libraries = try await JellyfinClient.shared.getLibraryViews()
            } catch {
                // Silently fail
            }
        }
    }

    private func iconFor(_ collectionType: String?) -> String {
        switch collectionType {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        default: return "folder"
        }
    }
}
