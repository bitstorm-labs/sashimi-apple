import SwiftUI

struct MobileSettingsView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @StateObject private var playbackSettings = PlaybackSettings.shared
    @StateObject private var serverPlugins = ServerPluginsViewModel()
    @StateObject private var quickConnectApproval = QuickConnectApprovalViewModel()
    @ObservedObject private var seerr = SeerrSession.shared
    @StateObject private var plexSettings = PlexSettingsModel()

    /// Same list as the tvOS LanguagePickerView.
    private static let languages: [(code: String, name: String)] = [
        ("", "System Default"), ("en", "English"), ("es", "Spanish"),
        ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"),
        ("zh", "Chinese"), ("ru", "Russian"), ("ar", "Arabic"),
        ("hi", "Hindi"), ("nl", "Dutch"), ("pl", "Polish"),
        ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"),
        ("fi", "Finnish")
    ]
    @State private var showingDeleteAllDownloads = false
    @AppStorage(DownloadWatchPolicy.deleteAfterWatchingKey) private var deleteDownloadsAfterWatching = false
    @AppStorage(DownloadNetworkPolicy.allowCellularKey) private var downloadOverCellular = false
    @State private var showAddServer = false
    @State private var serverBeingEdited: ServerConfig?

    var body: some View {
        List {
            Section("Server") {
                // Which of the plugins Sashimi uses this server has; admins
                // also see versions and status.
                NavigationLink {
                    MobileServerPluginsView(model: serverPlugins)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Server Plugins")
                            Text(serverPlugins.subtitle(for: sessionManager))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "puzzlepiece.extension")
                    }
                }
                // Approve the Quick Connect code a TV shows (#801); only when
                // the server has Quick Connect turned on.
                if quickConnectApproval.isAvailable {
                    NavigationLink {
                        MobileQuickConnectApprovalView(
                            model: quickConnectApproval,
                            userName: sessionManager.currentUser?.name ?? "you",
                            serverName: sessionManager.activeServer?.displayName ?? "this server"
                        )
                    } label: {
                        Label("Sign In a TV", systemImage: "tv")
                    }
                }
            }

            // Seerr: request titles that aren't on the server.
            Section {
                NavigationLink {
                    MobileRequestsSettingsView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Requests")
                            Text(seerr.state.user.map { "Signed in as \($0.name)" }
                                 ?? "Request movies and shows through \(seerr.applicationTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                }
            }

            // Settings › Plex: keeps the Watchlist in sync with Plex. Hidden
            // without the Watchlist plugin; needs nothing from Requests.
            MobilePlexSettingsSection(model: plexSettings)

            // Servers (multi-server switcher; swipe to remove)
            Section("Servers") {
                ForEach(sessionManager.servers) { server in
                    HStack {
                        Button {
                            Task { await sessionManager.switchServer(to: server.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .center, spacing: 6) {
                                    Text(server.displayName)
                                        .foregroundStyle(.primary)
                                    if sessionManager.shouldShowDefaultServerBadge,
                                       sessionManager.isDefaultServer(server.id) {
                                        DefaultServerBadge(tint: MobileColors.accent)
                                    }
                                }
                                Text("\(server.username) • \(server.url.absoluteString)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            serverBeingEdited = server
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(.tint)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit \(server.displayName)")

                        if server.id == sessionManager.activeServerId {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { sessionManager.servers[$0].id }
                    Task { for id in ids { await sessionManager.removeServer(id: id) } }
                }

                Button {
                    showAddServer = true
                } label: {
                    Label("Add Server", systemImage: "plus.circle.fill")
                }
            }

            // Home Screen Section
            Section("Home Screen") {
                NavigationLink(MobileLayoutIdiom.usesPadLayout ? "Home & Side Menu" : "Customize Row Order") {
                    HomeRowOrderView()
                }
            }

            // Display Section
            Section("Display") {
                Toggle("Show Quality Badges", isOn: $playbackSettings.showQualityBadges)
                Toggle("Show Review Ratings", isOn: $playbackSettings.showReviewRatings)
                Toggle("Use Episode Ratings", isOn: $playbackSettings.useEpisodeRatings)
            }

            // Video Player Section
            Section("Video Player") {
                Toggle("Show Episode Navigation Controls", isOn: $playbackSettings.showEpisodeNavigationControls)
            }

            // Playback Section
            Section("Playback") {
                Toggle("Auto-Play Next Episode", isOn: $playbackSettings.autoPlayNextEpisode)
                Toggle("Auto-Skip Intro", isOn: $playbackSettings.autoSkipIntro)
                Toggle("Auto-Skip Credits", isOn: $playbackSettings.autoSkipCredits)
                Toggle("Play Theme Songs", isOn: $playbackSettings.playThemeSongs)
                Toggle("Play Trailers on Detail Pages", isOn: $playbackSettings.playHeroTrailers)
                Toggle("Always Play Original", isOn: $playbackSettings.forceDirectPlay)
                // tvOS parity — same values as the tvOS Resume Threshold screen
                Picker("Resume Threshold", selection: $playbackSettings.resumeThresholdSeconds) {
                    Text("Always resume").tag(0)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                }
                Picker("TV Shuffle", selection: $playbackSettings.tvShuffleMode) {
                    ForEach(TVShuffleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            // Language Section (tvOS parity — same AppStorage keys, so the
            // shared PlayerViewModel track selection honors these)
            Section("Language") {
                Picker("Audio Language", selection: $playbackSettings.preferredAudioLanguage) {
                    ForEach(Self.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Toggle("Enable Subtitles", isOn: $playbackSettings.subtitlesEnabled)
                if playbackSettings.subtitlesEnabled {
                    Picker("Subtitle Language", selection: $playbackSettings.preferredSubtitleLanguage) {
                        ForEach(Self.languages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                }
            }

            // Video Quality Section
            Section("Video Quality") {
                Picker("Maximum Bitrate", selection: $playbackSettings.maxBitrate) {
                    Text("Auto").tag(0)
                    Text("4K (80 Mbps)").tag(80_000_000)
                    Text("1080p (20 Mbps)").tag(20_000_000)
                    Text("720p (8 Mbps)").tag(8_000_000)
                    Text("480p (3 Mbps)").tag(3_000_000)
                    Text("720p (2 Mbps)").tag(2_000_000)
                    Text("480p (1 Mbps)").tag(1_000_000)
                    Text("360p (720 kbps)").tag(720_000)
                }
            }

            // Downloads Section
            Section {
                LabeledContent("Storage Used", value: DownloadFileManager.formattedTotalSize())
                LabeledContent("Available Space", value: ByteCountFormatter.string(
                    fromByteCount: DownloadFileManager.availableDiskSpace(),
                    countStyle: .file
                ))
                Toggle("Download over Cellular", isOn: $downloadOverCellular)
                    .onChange(of: downloadOverCellular) { _, _ in
                        DownloadManager.shared.downloadNetworkSettingChanged()
                    }
                Toggle("Delete Downloads After Watching", isOn: $deleteDownloadsAfterWatching)
                Button("Delete All Downloads", role: .destructive) {
                    showingDeleteAllDownloads = true
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text(
                    "With Download over Cellular off, downloads wait for Wi-Fi that isn't a hotspot or in Low Data Mode. "
                        + "Delete After Watching removes a download once you've watched it: "
                        + "played to the end, or stopped past the point the server marks it watched (about 90%). "
                        + "Its watched state still reaches the server, even if you were offline."
                )
            }

            // About Section
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
            }

            // Sign Out
            Section {
                Button("Sign Out", role: .destructive) {
                    sessionManager.logout()
                }
            }
        }
        .sheet(isPresented: $showAddServer) {
            MobileAddServerSheet()
                .dismissesOnOutsideTap()
        }
        .fullScreenCover(item: $serverBeingEdited) { server in
            ServerEditView(server: server)
                .environmentObject(sessionManager)
        }
        .navigationTitle("Settings")
        // Read once when Settings opens (and again on a server switch) for
        // the Server Plugins subtitle; that screen only adds Refresh.
        .task(id: ServerPluginsViewModel.key(for: sessionManager)) {
            await serverPlugins.loadIfNeeded(for: sessionManager)
        }
        .task(id: ServerPluginsViewModel.key(for: sessionManager)) {
            await quickConnectApproval.refreshAvailability()
        }
        .task(id: ServerPluginsViewModel.key(for: sessionManager)) {
            await plexSettings.load()
        }
        .confirmationDialog("Delete All Downloads?", isPresented: $showingDeleteAllDownloads) {
            Button("Delete All", role: .destructive) {
                Task { await DownloadManager.shared.deleteAllDownloads() }
            }
        } message: {
            Text("This will remove all downloaded files from your device.")
        }
    }
}

struct HomeRowOrderView: View {
    @ObservedObject private var settings = HomeRowSettings.shared
    @ObservedObject private var sideMenu = SideMenuSettings.shared
    @ObservedObject private var seerr = SeerrSession.shared
    @ObservedObject private var watchlist = WatchlistStore.shared
    @ObservedObject private var sessionManager = SessionManager.shared
    /// Every library the side menu can list, for the ones Home has no row for.
    @State private var railLibraries: [JellyfinLibrary] = []

    /// Only iPad and Mac have a side menu; iPhone uses tabs.
    private var showsSideMenu: Bool { MobileLayoutIdiom.usesPadLayout }

    /// Whether the libraries for the menu-only entries have been asked for:
    /// dragging before then would save an order without them.
    @State private var libraryLoadFinished = false

    /// iPad/Mac's one list (#841): Home's rows with Lists and the menu-only
    /// libraries among them, in side-menu order. iPhone lists Home rows only.
    /// Either way the Requests row only while Seerr is connected (#861).
    private var entries: [SideMenuOrder.Entry] {
        let available = RailOrder.conditionalDestinations(
            seerr: seerr.state,
            canViewDashboard: sessionManager.canViewServerDashboard,
            hasWatchlist: RailOrder.hasWatchlist(watchlist.availability),
            hasDownloads: showsSideMenu
        )
        return showsSideMenu
            ? settings.sideMenuEntries(libraryIds: railLibraries.map(\.id), available: available)
            : settings.homeRowEntries(available: available)
    }

    private func name(of destination: RailOrder.Destination) -> String {
        switch destination {
        case .lists: return "Lists"
        case .requests: return "Requests"
        case .dashboard: return "Dashboard"
        case .watchlist: return WatchlistText.name
        case .search: return "Search"
        case .downloads: return "Downloads"
        case .finTV: return HomeRowType.channels.displayName
        case .library(let id): return railLibraries.first { $0.id == id }?.name ?? "Library"
        }
    }

    @ViewBuilder
    private func sideMenuSwitch(_ destination: RailOrder.Destination?) -> some View {
        if let destination {
            let isOn = sideMenu.isShown(destination)
            Image(systemName: "sidebar.left")
                .foregroundColor(isOn ? .accentColor : .gray)
                .opacity(isOn ? 1 : 0.35)
                .onTapGesture { sideMenu.toggle(destination) }
                .accessibilityLabel("Side menu")
                .accessibilityValue(isOn ? "Shown" : "Hidden")
                .accessibilityAddTraits(.isButton)
        } else {
            Text("\u{2014}")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not in the side menu")
        }
    }

    @ViewBuilder
    private func note(isOnHome: Bool, destination: RailOrder.Destination?) -> some View {
        if showsSideMenu, let text = RailOrder.reachabilityNote(
            for: destination,
            isOnHome: isOnHome,
            isInSideMenu: destination.map(sideMenu.isShown) ?? true
        ) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rowItem(_ row: HomeRowConfig) -> some View {
        HStack {
            Image(systemName: row.isEnabled ? "checkmark.circle.fill" : "circle")
                .foregroundColor(row.isEnabled ? .green : .gray)
                .onTapGesture {
                    if let index = settings.rows.firstIndex(where: { $0.id == row.id }) {
                        settings.toggleRow(at: index)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                note(isOnHome: row.isEnabled, destination: row.railDestination)
            }

            Spacer()

            if showsSideMenu {
                sideMenuSwitch(row.railDestination)
            }

            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
        }
    }

    /// Lists, Collections, Playlists: no Home switch, but they drag like rows.
    private func menuOnlyItem(_ destination: RailOrder.Destination) -> some View {
        HStack {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name(of: destination))
                Text("Side menu only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                note(isOnHome: false, destination: destination)
            }

            Spacer()

            sideMenuSwitch(destination)

            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(entries, id: \.self) { entry in
                    switch entry {
                    case .row(let id):
                        if let row = settings.rows.first(where: { $0.id == id }) {
                            rowItem(row)
                        }
                    case .menuOnly(let destination):
                        menuOnlyItem(destination)
                    }
                }
                .onMove { source, destination in
                    if showsSideMenu {
                        settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: source, to: destination))
                    } else {
                        settings.applyRowOrder(SideMenuOrder.moving(entries, from: source, to: destination))
                    }
                }
                .moveDisabled(showsSideMenu && !libraryLoadFinished)
            } header: {
                Text(showsSideMenu
                     ? "Left: on Home. Right: in the side menu. Drag to reorder both."
                     : "Drag to reorder, tap to enable/disable")
            } footer: {
                if showsSideMenu {
                    Text("Home and Settings stay where they are in the side menu.")
                }
            }
        }
        .navigationTitle(showsSideMenu ? "Home & Side Menu" : "Row Order")
        .task {
            if showsSideMenu {
                railLibraries = (try? await JellyfinClient.shared.getLibraryViews()) ?? []
            }
            libraryLoadFinished = true
        }
        .onAppear { settings.use(serverID: SessionManager.shared.activeServerId) }
        .environment(\.editMode, .constant(.active))
    }
}

/// Auth flow presented for adding an additional server; dismisses once the
/// server list grows.
struct MobileAddServerSheet: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var initialCount = 0

    var body: some View {
        NavigationStack {
            MobileAuthView(onCancel: { dismiss() })
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { initialCount = sessionManager.servers.count }
        .onChange(of: sessionManager.servers.count) { _, newCount in
            if newCount > initialCount { dismiss() }
        }
        .onDisappear {
            // The probe repointed the shared client at the candidate server;
            // re-point it at whatever server is active now so the session works.
            Task { await sessionManager.restoreActiveClient() }
        }
    }
}
