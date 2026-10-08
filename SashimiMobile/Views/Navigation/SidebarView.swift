import SwiftUI
import SwiftData
import NukeUI

enum SidebarSelection: Hashable {
    case home
    case finTV
    case search
    case downloads
    case settings
    case library(id: String, name: String, collectionType: String?)

    var displayName: String {
        switch self {
        case .home: return "Home"
        case .finTV: return "SashimiTV"
        case .search: return "Search"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        case .library(_, let name, _): return name
        }
    }

    /// Sections that work without the server: Home (as the offline Home),
    /// Downloads and Settings.
    var isAvailableOffline: Bool {
        switch self {
        case .home, .downloads, .settings: return true
        case .finTV, .search, .library: return false
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .finTV: return "antenna.radiowaves.left.and.right"
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape"
        case .library(_, let name, let collectionType):
            // Same symbols as the tvOS rail.
            return RailOrder.libraryIcon(name: name, collectionType: collectionType)
        }
    }
}

struct MainNavigationView: View {
    var searchRequest: SashimiIntentCoordinator.SearchRequest?
    var onSearchRequestConsumed: (UUID) -> Void = { _ in }
    @State private var selection: SidebarSelection = .home
    /// The rail is always on screen; this is whether it is expanded to
    /// icon + label over the content.
    @State private var railExpanded = false
    @State private var libraries: [JellyfinLibrary] = []
    @State private var navigationResetId: Int = 0
    @ObservedObject private var sessionManager = SessionManager.shared
    @State private var showAddServer = false
    /// Downloads opened from a download toast is a
    /// sheet over whatever is showing, so Done returns exactly there. Switching
    /// the section instead rebuilt the NavigationStack and left no way back to
    /// the screen the viewer came from (iPad feedback).
    @State private var showingDownloads = false
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    /// The Search tab's query. It lives here, not in MobileSearchView, because
    /// the field that edits it is in `searchHeaderBar` (#126).
    @State private var searchQuery = ""
    @State private var searchSubmitCount = 0
    @FocusState private var searchFieldFocused: Bool
    /// The menu bar's ⌘1…⌘9, ⌘F and ⌘, land here.
    @ObservedObject private var commandCenter = AppCommandCenter.shared
    @ObservedObject private var homeRows = HomeRowSettings.shared

    var body: some View {
        ZStack(alignment: .leading) {
            // Main content, laid out beside the collapsed rail. It never
            // moves: the expanded rail is drawn over it. Only Search has a
            // header strip (its field). Everything stops at the status bar:
            // clipped to the safe area, so full-bleed backdrops and scrolled
            // rows don't run up behind the clock and battery.
            VStack(spacing: 0) {
                if showsHeaderSearch {
                    searchHeaderBar
                }

                NavigationStack {
                    detailView
                        .navigationBarHidden(true)
                }
                .id("\(selection)-\(navigationResetId)")
            }
            // Top edge only: lists still scroll under the home indicator.
            .mask(Rectangle().ignoresSafeArea(edges: .bottom))
            .padding(.leading, SidebarRailMetrics.collapsedWidth)

            // Dims the content while the rail is expanded; tapping it collapses.
            if railExpanded {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { collapseRail() }
                    .transition(.opacity)
                    .accessibilityLabel("Close menu")
                    .accessibilityAddTraits(.isButton)
            }

            SidebarRail(
                libraries: libraries,
                selection: selection,
                downloadActivity: railDownloadActivity,
                isOffline: !networkMonitor.isOnline,
                isExpanded: $railExpanded,
                onSelect: select
            ) { expanded in
                accountMenu(showsName: expanded)
            }
        }
        // Behind the status bar, now that the content stops below it.
        .background(MobileColors.background.ignoresSafeArea())
        .task {
            await loadLibraries()
        }
        .sheet(isPresented: $showAddServer) {
            MobileAddServerSheet()
        }
        .sheet(isPresented: $showingDownloads) {
            NavigationStack {
                DownloadsListView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingDownloads = false }
                        }
                    }
            }
        }
        .downloadToast {
            showingDownloads = true
        }
        .onAppear {
            applySearchRequest()
            if !networkMonitor.isOnline {
                leaveUnavailableSection()
            }
        }
        .onChange(of: searchRequest?.id) { _, _ in
            applySearchRequest()
        }
        .onChange(of: networkMonitor.isOnline) { _, isOnline in
            if isOnline {
                // Launched offline, the rail has no libraries yet.
                if libraries.isEmpty {
                    Task { await loadLibraries() }
                }
            } else {
                leaveUnavailableSection()
            }
        }
        .onChange(of: railItems, initial: true) { _, items in
            commandCenter.updateRailItems(items)
        }
        .onDisappear {
            commandCenter.updateRailItems([])
        }
        .onChange(of: commandCenter.navigationRequest) { _, request in
            handleNavigationRequest(request)
        }
        .onChange(of: selection) { _, newSelection in
            if newSelection == .search {
                focusSearchFieldIfTyping()
            } else {
                // Leaving the tab ends the search, as it did when the query
                // was the search view's own state.
                searchFieldFocused = false
                searchQuery = ""
            }
        }
    }

    private var railItems: [SidebarSelection] {
        SidebarSelection.railItems(rowConfigs: homeRows.rows, libraries: libraries)
    }

    /// A menu-bar section change (⌘1…⌘9, ⌘F, ⌘,). Unlike a rail tap it never
    /// starts the current section over: ⌘F on Search just focuses the field.
    private func handleNavigationRequest(_ request: AppCommandCenter.NavigationRequest?) {
        guard let request else { return }
        commandCenter.consumeNavigationRequest(id: request.id)
        guard networkMonitor.isOnline || request.selection.isAvailableOffline else { return }
        if selection != request.selection {
            selection = request.selection
        } else if request.focusesSearch {
            focusSearchFieldIfTyping()
        }
        collapseRail()
    }

    private var showsHeaderSearch: Bool {
        selection == .search && networkMonitor.isOnline
    }

    /// The connection dropped while on a section that needs the server:
    /// Home (now the offline Home) is where the downloads are.
    private func leaveUnavailableSection() {
        guard !selection.isAvailableOffline else { return }
        selection = .home
    }

    /// Opening Search by hand puts the caret in the field. A Siri/App Intents
    /// search arrives with its query already running, so it keeps the results
    /// uncovered by the keyboard.
    private func focusSearchFieldIfTyping() {
        guard searchRequest == nil else { return }
        // The field is inserted by this same update; focus it on the next
        // pass, once it exists.
        DispatchQueue.main.async {
            searchFieldFocused = true
        }
    }

    /// A rail tap: switch section, or start the current one over when it is
    /// tapped again. Either way the rail collapses back to its icon strip.
    private func select(_ item: SidebarSelection) {
        guard networkMonitor.isOnline || item.isAvailableOffline else { return }
        if selection == item {
            navigationResetId += 1
            if item == .search {
                // Re-selecting Search starts over, as the rebuilt view did
                // when it owned the query.
                searchQuery = ""
                focusSearchFieldIfTyping()
            }
        } else {
            selection = item
        }
        collapseRail()
    }

    private func collapseRail() {
        withAnimation(SidebarRailMetrics.animation) {
            railExpanded = false
        }
    }

    /// Quick server switcher (iPad equivalent of the phone's logo-tap menu),
    /// pinned to the foot of the rail and drawn like the tvOS rail's avatar:
    /// the user's picture, with their name and "Switch server" beside it when
    /// the rail is expanded.
    private func accountMenu(showsName: Bool) -> some View {
        Menu {
            ForEach(sessionManager.servers) { server in
                Button {
                    Task { await sessionManager.switchServer(to: server.id) }
                } label: {
                    if server.id == sessionManager.activeServerId {
                        Label(server.displayName, systemImage: "checkmark")
                    } else {
                        Text(server.displayName)
                    }
                }
            }
            Divider()
            Button {
                showAddServer = true
            } label: {
                Label("Add Server…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 12) {
                userAvatarView
                if showsName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sessionManager.currentUser?.name ?? "Account")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Switch server")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .lineLimit(1)
                    .transition(.opacity)
                }
            }
            // Centres the avatar on the icon column of the rows above.
            .padding(
                .horizontal,
                showsName ? (SidebarRailMetrics.iconWidth - SidebarRailMetrics.avatarSize) / 2
                    + SidebarRailMetrics.expandedRowInset : 0
            )
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Account and servers")
    }

    /// The Search section's field (#126), the one screen with a header strip.
    private var searchHeaderBar: some View {
        HeaderSearchField(
            text: $searchQuery,
            isFocused: $searchFieldFocused,
            onSubmit: { searchSubmitCount += 1 }
        )
        .frame(maxWidth: .infinity)
        .frame(minHeight: SidebarRailMetrics.barContentHeight)
        .padding(.horizontal, MobileSpacing.md + MobileSpacing.xs)
        .padding(.vertical, MobileSpacing.sm)
        .background(MobileColors.background)
    }

    /// The tvOS rail's avatar: the user's picture over an accent gradient,
    /// which shows (with a person glyph) until the picture loads or if it can't.
    private var userAvatarView: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [MobileColors.accent, MobileColors.accent.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "person.fill")
                .font(.system(size: 17))
                .foregroundStyle(.white)
            if let userId = sessionManager.currentUser?.id,
               let imageURL = JellyfinClient.shared.userImageURL(userId: userId) {
                LazyImage(url: imageURL) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    }
                }
                .pipeline(SashimiImagePipeline.shared)
                .clipShape(Circle())
            }
        }
        .frame(width: SidebarRailMetrics.avatarSize, height: SidebarRailMetrics.avatarSize)
    }

    @ViewBuilder
    private var detailView: some View {
        // Offline, Home is the downloads. A section that needs the server is
        // switched to Home as the connection drops; until that lands it shows
        // the same thing rather than a screen of failed requests.
        if !networkMonitor.isOnline && (selection == .home || !selection.isAvailableOffline) {
            OfflineHomeView()
        } else {
            switch selection {
            case .home:
                MobileHomeView()
            case .finTV:
                MobileGuideView()
            case .search:
                MobileSearchView(
                    initialQuery: searchRequest?.query,
                    onInitialQueryConsumed: {
                        if let id = searchRequest?.id {
                            onSearchRequestConsumed(id)
                        }
                    },
                    query: $searchQuery,
                    submitCount: searchSubmitCount
                )
            case .downloads:
                DownloadsListView()
            case .settings:
                MobileSettingsView()
            case .library(let id, let name, let collectionType):
                MobileLibraryBrowseView(
                    libraryId: id,
                    libraryName: name,
                    collectionType: collectionType
                )
            }
        }
    }

    private func applySearchRequest() {
        guard searchRequest != nil, networkMonitor.isOnline else { return }
        if selection != .search {
            selection = .search
        }
        navigationResetId += 1
    }

    /// Global download activity for the rail's Downloads row: the progress
    /// ring with the active + queued count while anything downloads, the
    /// speed, and how many failed.
    private var railDownloadActivity: RailDownloadActivity {
        RailDownloadActivity(
            snapshot: downloadManager.activitySnapshot,
            speed: downloadManager.downloadSpeed,
            failedCount: downloadFailedCount()
        )
    }

    private func downloadFailedCount() -> Int {
        _ = downloadManager.stateVersion
        guard let container = DownloadManager.shared.modelContainer else { return 0 }
        let context = ModelContext(container)
        let predicate = #Predicate<DownloadedItem> { $0.statusRaw == "failed" }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    private func loadLibraries() async {
        do {
            libraries = try await JellyfinClient.shared.getLibraryViews()
        } catch {
            // Silently fail
        }
    }
}
