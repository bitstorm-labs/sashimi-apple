import SwiftUI
import os

// swiftlint:disable file_length
// SettingsView contains multiple related settings views - splitting would fragment related UI code

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "SettingsView")

struct SettingsView: View {
    // App icon picker is hidden: alternate icons are temporarily disabled for
    // the first TestFlight beta (see project.yml — each icon needs a 1280x768
    // App Store variant) and SashimiApp resets to the default icon at every
    // launch, so any selection would silently revert. Re-enable post-beta.
    private static let appIconPickerEnabled = false

    var showSignOut: Bool = true
    var onBackAtRoot: (() -> Void)?
    /// Supplied by the rail so the first settings row can claim default focus
    /// in the shared main scope — without it, pressing Right from the Settings
    /// rail row has no designated target and focus never enters this screen.
    var focusNamespace: Namespace.ID?
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var showingLogoutConfirmation = false
    @State private var navigationPath = NavigationPath()
    @StateObject private var serverPlugins = ServerPluginsViewModel()
    @ObservedObject private var seerr = SeerrSession.shared
    @StateObject private var plexSettings = PlexSettingsModel()
    /// WORK-106. Never synced itself; turning it on syncs straight away.
    @AppStorage(SettingsSyncService.enabledKey) private var settingsSyncEnabled = true

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                SashimiTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 30) {
                        // Settings content with constrained width
                        VStack(spacing: 24) {
                            SettingsOptionRow(
                                icon: "server.rack",
                                title: "Servers",
                                subtitle: "Add or switch Jellyfin servers"
                            ) {
                                navigationPath.append(SettingsDestination.servers)
                            }
                            .defaultFocus(in: focusNamespace)

                            // Which of the plugins Sashimi uses this server
                            // has; admins also see versions and status.
                            SettingsOptionRow(
                                icon: "puzzlepiece.extension",
                                title: "Server Plugins",
                                subtitle: serverPlugins.subtitle(for: sessionManager)
                            ) {
                                navigationPath.append(SettingsDestination.serverPlugins)
                            }

                            // Seerr: connect an account; the requests themselves
                            // are the side menu's Requests page (#845).
                            SettingsOptionRow(
                                icon: "tray.and.arrow.down",
                                title: "Requests",
                                subtitle: seerr.state.user.map { "Signed in as \($0.name)" }
                                    ?? "Request movies and shows through \(seerr.applicationTitle)"
                            ) {
                                navigationPath.append(SettingsDestination.requests)
                            }

                            // Settings › Plex: keeps the Watchlist in sync with
                            // Plex. Hidden without the Watchlist plugin; needs
                            // nothing from Requests.
                            PlexSettingsRow(model: plexSettings)

                            SettingsSection(title: "General") {
                                SettingsToggleRow(title: "Sync Settings Across Devices", isOn: $settingsSyncEnabled)
                                Text(SettingsSyncService.toggleFooter)
                                    .font(Typography.captionSmall)
                                    .foregroundStyle(SashimiTheme.textTertiary)
                                    .padding(.horizontal, 8)
                            }

                            SettingsOptionRow(
                                icon: "house",
                                title: "Home & Side Menu",
                                subtitle: "Row order, and what the side menu lists"
                            ) {
                                navigationPath.append(SettingsDestination.homeScreen)
                            }

                            SettingsOptionRow(
                                icon: "play.circle",
                                title: "Playback",
                                subtitle: "Quality and behavior"
                            ) {
                                navigationPath.append(SettingsDestination.playback)
                            }

                            SettingsOptionRow(
                                icon: "checkmark.shield",
                                title: "Security",
                                subtitle: "Certificate settings"
                            ) {
                                navigationPath.append(SettingsDestination.certificates)
                            }

                            if Self.appIconPickerEnabled {
                                SettingsOptionRow(
                                    icon: "app.badge",
                                    title: "App Icon",
                                    subtitle: "Change app icon"
                                ) {
                                    navigationPath.append(SettingsDestination.appIcon)
                                }
                            }

                            // About section
                            VStack(spacing: 12) {
                                SettingsInfoRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                                SettingsInfoRow(label: "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
                            }
                            .padding(.top, 20)

                            if showSignOut {
                                SettingsSignOutButton {
                                    showingLogoutConfirmation = true
                                }
                                .padding(.top, 20)
                            }
                        }
                        .frame(maxWidth: 800)
                        .padding(.horizontal, 80)
                        .padding(.top, 40)
                        .padding(.bottom, 60)
                    }
                }
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .servers:
                    ServersSettingsView()
                case .homeScreen:
                    HomeScreenSettingsView()
                case .playback:
                    PlaybackSettingsView()
                case .certificates:
                    CertificateSettingsView()
                case .appIcon:
                    AppIconSettingsView()
                case .serverPlugins:
                    ServerPluginsView(model: serverPlugins)
                case .requests:
                    RequestsSettingsView()
                }
            }
        }
        // Read once when Settings opens (and again on a server switch) for
        // the row's subtitle; the screen itself only adds Refresh.
        .task(id: ServerPluginsViewModel.key(for: sessionManager)) {
            await serverPlugins.loadIfNeeded(for: sessionManager)
        }
        .task(id: ServerPluginsViewModel.key(for: sessionManager)) {
            await plexSettings.load()
        }
        .confirmationDialog(
            "Sign Out",
            isPresented: $showingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                sessionManager.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .onExitCommand {
            if !navigationPath.isEmpty {
                navigationPath.removeLast()
            } else {
                onBackAtRoot?()
            }
        }
    }
}

enum SettingsDestination: Hashable {
    case servers
    case homeScreen
    case playback
    case certificates
    case appIcon
    case serverPlugins
    case requests
}

struct SettingsOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(Typography.title)
                    .foregroundStyle(isFocused ? .white : SashimiTheme.accent)
                    .frame(width: 50)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Typography.title)
                        .foregroundStyle(isFocused ? .white : SashimiTheme.textPrimary)

                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(isFocused ? .white.opacity(0.8) : SashimiTheme.textTertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(Typography.bodySmall)
                    .foregroundStyle(isFocused ? .white.opacity(0.8) : SashimiTheme.textTertiary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            // Shared focus treatment: a faint accent fill + accent ring
            // (matches every other row — HomeRowToggleButton, etc.). A solid
            // focus fill would swallow the white-on-focus text.
            .focusHighlight(isFocused, cornerRadius: 16)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

struct SettingsInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(Typography.bodySmall)
                .foregroundStyle(SashimiTheme.textSecondary)

            Spacer()

            Text(value)
                .font(Typography.bodySmall.weight(.medium))
                .foregroundStyle(SashimiTheme.textPrimary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SashimiTheme.cardBackground)
        )
    }
}

struct SettingsSignOutButton: View {
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(Typography.titleSmall)
                Text("Sign Out")
                    .font(Typography.titleSmall)
            }
            .foregroundStyle(isFocused ? .white : .red.opacity(0.9))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isFocused ? Color.red : Color.red.opacity(0.15))
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

// MARK: - Home Screen Settings

enum HomeRowType: String, Codable, CaseIterable {
    case hero
    case continueWatching
    /// Seerr requests (#861). A saved order without it gets it right after
    /// Continue Watching (`withRequestsRow`), where Home drew it before it
    /// was a row. The raw value must never change once shipped.
    case requests
    // Added after release. updateWithLibraries() appends any built-in type the
    // saved config lacks, so existing users gain the row without a bespoke
    // migration, and the raw value must never change once shipped.
    case channels

    var displayName: String {
        switch self {
        case .hero: return "Featured"
        case .continueWatching: return "Continue Watching"
        case .requests: return "Requests"
        case .channels: return "SashimiTV"
        }
    }
}

struct HomeRowConfig: Codable, Identifiable, Equatable {
    let id: String
    let type: HomeRowType?  // nil for library and list rows
    let libraryId: String?  // for library rows
    let libraryName: String?
    var isVisible: Bool
    /// A subscribed shared list's row. Optional so configs saved before lists
    /// existed still decode.
    var listId: String?
    var listTitle: String?

    var displayName: String {
        if let type = type {
            return type.displayName
        }
        if listId != nil { return listTitle ?? "Shared list" }
        return libraryName ?? "Unknown Library"
    }

    static func list(id: String, title: String, visible: Bool = true) -> HomeRowConfig {
        HomeRowConfig(id: listRowKey(id), type: nil, libraryId: nil, libraryName: nil, isVisible: visible, listId: id, listTitle: title)
    }

    static func listRowKey(_ listId: String) -> String { "list_\(listId)" }

    static func builtIn(_ type: HomeRowType, visible: Bool = true) -> HomeRowConfig {
        HomeRowConfig(id: type.rawValue, type: type, libraryId: nil, libraryName: nil, isVisible: visible)
    }

    static func library(id: String, name: String, visible: Bool = true) -> HomeRowConfig {
        HomeRowConfig(id: "library_\(id)", type: nil, libraryId: id, libraryName: name, isVisible: visible)
    }
}

@MainActor
class HomeScreenSettings: ObservableObject {
    static let shared = HomeScreenSettings()

    @Published var rowConfigs: [HomeRowConfig] = []
    @Published var needsRefresh = false
    /// Where Lists and the menu-only libraries sit among the rows in the side
    /// menu (#841): `SideMenuOrder` keys, nil until the user moves anything.
    /// Kept apart from `rowConfigs` so Home never sees those entries.
    @Published private(set) var sideMenuOrder: [String]?

    private let userDefaultsKey = "homeScreenRowOrder"
    static let sideMenuOrderKey = "sideMenuOrder"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadSettings()
    }

    func loadSettings() {
        sideMenuOrder = defaults.stringArray(forKey: Self.sideMenuOrderKey)
        // Falling back to defaults is correct, but doing it silently made a
        // schema change indistinguishable from "user never customised".
        guard let data = defaults.data(forKey: userDefaultsKey),
              let configs = decodeSavedConfigs(data) else { return }
        rowConfigs = Self.withRequestsRow(configs)
    }

    /// `configs` with the Requests row (#861), straight after Continue
    /// Watching if they were saved without it.
    static func withRequestsRow(_ configs: [HomeRowConfig]) -> [HomeRowConfig] {
        guard !configs.contains(where: { $0.type == .requests }) else { return configs }
        var result = configs
        let index = result.firstIndex { $0.type == .continueWatching }.map { $0 + 1 } ?? 0
        result.insert(.builtIn(.requests), at: index)
        return result
    }

    private func decodeSavedConfigs(_ data: Data) -> [HomeRowConfig]? {
        do {
            return try JSONDecoder().decode([HomeRowConfig].self, from: data)
        } catch {
            logger.error("Failed to decode home row config: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func saveSettings() {
        do {
            let data = try JSONEncoder().encode(rowConfigs)
            defaults.set(data, forKey: userDefaultsKey)
        } catch {
            // The user's row layout is silently dropped if this throws.
            logger.error("Failed to encode home row config: \(error.localizedDescription, privacy: .public)")
        }
        needsRefresh = true
    }

    func updateWithLibraries(_ libraries: [JellyfinLibrary]) {
        var newConfigs: [HomeRowConfig] = []

        // Add built-in rows if not already present. Requests follows the
        // libraries: the side menu's default order is Search, Watchlist,
        // SashimiTV, libraries, Lists, Requests, Dashboard (A1 parity). Saved
        // orders keep theirs (the sort below).
        func builtIn(_ type: HomeRowType) -> HomeRowConfig {
            rowConfigs.first { $0.type == type } ?? .builtIn(type)
        }
        for type in HomeRowType.allCases where type != .requests {
            newConfigs.append(builtIn(type))
        }

        // Add library rows
        for library in libraries {
            if let existing = rowConfigs.first(where: { $0.libraryId == library.id }) {
                // Update name in case it changed
                var updated = existing
                if updated.libraryName != library.name {
                    updated = .library(id: library.id, name: library.name, visible: existing.isVisible)
                }
                newConfigs.append(updated)
            } else {
                newConfigs.append(.library(id: library.id, name: library.name))
            }
        }

        newConfigs.append(builtIn(.requests))

        // Subscribed lists keep their rows; updateWithLists owns them.
        newConfigs += rowConfigs.filter { $0.listId != nil }

        // Remove library rows that no longer exist
        rowConfigs = newConfigs.filter { config in
            if config.libraryId != nil {
                return libraries.contains { $0.id == config.libraryId }
            }
            return true
        }

        // Preserve order from saved settings
        if let data = defaults.data(forKey: userDefaultsKey),
           let savedConfigs = decodeSavedConfigs(data) {
            let savedOrder = Self.withRequestsRow(savedConfigs).map { $0.id }
            // Stable: rows the saved order lacks (new libraries) keep the
            // order built above instead of whatever sort() leaves them in.
            rowConfigs = rowConfigs.enumerated().sorted { a, b in
                let indexA = savedOrder.firstIndex(of: a.element.id) ?? Int.max
                let indexB = savedOrder.firstIndex(of: b.element.id) ?? Int.max
                return indexA != indexB ? indexA < indexB : a.offset < b.offset
            }.map(\.element)
        }
    }

    /// Follows the subscribed lists: a new one's row goes after Continue
    /// Watching, an unsubscribed one's row goes, and the rest stay where the
    /// user put them. Saves only when something changed.
    func updateWithLists(_ lists: [SharedList], titles: [String: String]) {
        let keys = SharedLists.syncedRowKeys(
            current: rowConfigs.map(\.id),
            listKeys: lists.map { HomeRowConfig.listRowKey($0.id) },
            isListKey: { $0.hasPrefix("list_") },
            continueWatchingKey: HomeRowType.continueWatching.rawValue,
            heroKey: HomeRowType.hero.rawValue
        )
        let synced: [HomeRowConfig] = keys.compactMap { key in
            if let list = lists.first(where: { HomeRowConfig.listRowKey($0.id) == key }) {
                let title = titles[list.id] ?? list.name
                let existing = rowConfigs.first { $0.id == key }
                return .list(id: list.id, title: title, visible: existing?.isVisible ?? true)
            }
            return rowConfigs.first { $0.id == key }
        }
        guard synced != rowConfigs else { return }
        rowConfigs = synced
        saveSettings()
    }

    func toggleVisibility(for config: HomeRowConfig) {
        if let index = rowConfigs.firstIndex(where: { $0.id == config.id }) {
            rowConfigs[index].isVisible.toggle()
            saveSettings()
        }
    }

    func isRowVisible(_ type: HomeRowType) -> Bool {
        rowConfigs.first { $0.type == type }?.isVisible ?? true
    }

    func isLibraryVisible(_ libraryId: String) -> Bool {
        rowConfigs.first { $0.libraryId == libraryId }?.isVisible ?? true
    }

    func orderedLibraryIds() -> [String] {
        rowConfigs.compactMap { $0.libraryId }
    }

    /// Settings' one list (#841): the rows, with Lists and the libraries Home
    /// has no row for among them.
    /// `available`: Requests and Dashboard while the account allows them (#845).
    func sideMenuEntries(libraryIds: [String], available: [RailOrder.Destination] = []) -> [SideMenuOrder.Entry] {
        SideMenuOrder.entries(rows: rowConfigs.map(\.sideMenuRow), libraryIds: libraryIds, saved: sideMenuOrder, available: available)
    }

    /// Saves a new order from Settings: the rows in their new order, as
    /// always, and where the menu-only entries sit among them. Home reloads
    /// only when its own rows moved.
    func applySideMenuOrder(_ entries: [SideMenuOrder.Entry]) {
        let keys = SideMenuOrder.savedKeys(entries)
        sideMenuOrder = keys
        defaults.set(keys, forKey: Self.sideMenuOrderKey)
        let reordered = SideMenuOrder.reordered(rowConfigs, id: \.id, by: entries)
        guard reordered != rowConfigs else { return }
        rowConfigs = reordered
        saveSettings()
    }
}

struct HomeScreenSettingsView: View {
    @StateObject private var settings = HomeScreenSettings.shared
    @ObservedObject private var sideMenu = SideMenuSettings.shared
    @ObservedObject private var seerr = SeerrSession.shared
    @ObservedObject private var watchlist = WatchlistStore.shared
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var isLoading = true
    /// Every library the rail can list, for the ones Home has no row for.
    @State private var railLibraries: [JellyfinLibrary] = []

    /// One list (#841): Home's rows with Lists and the menu-only libraries
    /// among them, in side-menu order.
    private var entries: [SideMenuOrder.Entry] {
        settings.sideMenuEntries(
            libraryIds: railLibraries.map(\.id),
            available: RailOrder.conditionalDestinations(
                seerr: seerr.state,
                canViewDashboard: sessionManager.canViewServerDashboard,
                hasWatchlist: RailOrder.hasWatchlist(watchlist.availability)
            )
        )
    }

    var body: some View {
        SettingsContainer {
            if isLoading {
                ProgressView("Loading...")
                    .padding(.top, 60)
            } else if settings.rowConfigs.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    Text("No rows configured")
                        .font(Typography.titleSmall)
                        .foregroundStyle(.secondary)
                    Text("Visit the Home tab first to load your libraries")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Home & Side Menu")
                        .font(Typography.headline)
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .padding(.bottom, 8)

                    Text("Arrows move an item on Home and in the side menu. Home and Settings stay where they are.")
                        .font(Typography.caption)
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .padding(.bottom, 16)

                    let entries = entries
                    ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                        entryRow(entry, index: index, entries: entries)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.bottom, 60)
            }
        }
        .task {
            // Wait for the libraries before listing: moving anything before
            // the menu-only ones are known would save an order without them.
            railLibraries = (try? await JellyfinClient.shared.getLibraryViews()) ?? []
            if settings.rowConfigs.isEmpty {
                for type in HomeRowType.allCases {
                    settings.rowConfigs.append(.builtIn(type))
                }
            }
            isLoading = false
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: SideMenuOrder.Entry, index: Int, entries: [SideMenuOrder.Entry]) -> some View {
        switch entry {
        case .row(let id):
            if let config = settings.rowConfigs.first(where: { $0.id == id }) {
                HomeScreenRowItem(
                    config: config,
                    index: index,
                    totalCount: entries.count,
                    isInSideMenu: config.railDestination.map(sideMenu.isShown) ?? true,
                    onToggle: { settings.toggleVisibility(for: config) },
                    onToggleSideMenu: { config.railDestination.map(sideMenu.toggle) },
                    onMoveUp: { move(entries, from: index, by: -1) },
                    onMoveDown: { move(entries, from: index, by: 1) }
                )
            }
        case .menuOnly(let destination):
            SideMenuOnlyRow(
                name: name(of: destination),
                destination: destination,
                index: index,
                totalCount: entries.count,
                isOn: sideMenu.isShown(destination),
                onToggle: { sideMenu.toggle(destination) },
                onMoveUp: { move(entries, from: index, by: -1) },
                onMoveDown: { move(entries, from: index, by: 1) }
            )
        }
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

    private func move(_ entries: [SideMenuOrder.Entry], from index: Int, by offset: Int) {
        let target = index + offset
        guard entries.indices.contains(target) else { return }
        // Array.move semantics: moving down lands after the next entry.
        let moved = SideMenuOrder.moving(entries, from: [index], to: offset > 0 ? target + 1 : target)
        settings.applySideMenuOrder(moved)
    }
}

struct HomeScreenRowItem: View {
    let config: HomeRowConfig
    let index: Int
    let totalCount: Int
    /// Rows that are not side-menu destinations (Featured, Continue Watching)
    /// show a dash instead of a switch.
    let isInSideMenu: Bool
    let onToggle: () -> Void
    let onToggleSideMenu: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            if let note = RailOrder.reachabilityNote(isOnHome: config.isVisible, isInSideMenu: isInSideMenu) {
                ReachabilityNote(text: note)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            // Move up button
            HomeRowMoveButton(
                direction: .up,
                isEnabled: index > 0,
                action: onMoveUp
            )

            // Move down button
            HomeRowMoveButton(
                direction: .down,
                isEnabled: index < totalCount - 1,
                action: onMoveDown
            )

            // Toggle visibility button
            HomeRowToggleButton(config: config, onToggle: onToggle)

            // Side menu (#753): only rows that are menu destinations.
            if config.railDestination != nil {
                HomeRowSideMenuButton(isOn: isInSideMenu, action: onToggleSideMenu)
            } else {
                Text("\u{2014}")
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .frame(width: 190)
                    .accessibilityLabel("Not in the side menu")
            }
        }
    }
}

/// A side-menu entry Home has no row for (Lists, Collections, Playlists):
/// it moves like a row, but says "Side menu only" where the Home switch would be.
struct SideMenuOnlyRow: View {
    let name: String
    let destination: RailOrder.Destination
    let index: Int
    let totalCount: Int
    let isOn: Bool
    let onToggle: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                HomeRowMoveButton(direction: .up, isEnabled: index > 0, action: onMoveUp)
                HomeRowMoveButton(direction: .down, isEnabled: index < totalCount - 1, action: onMoveDown)

                HStack(spacing: 16) {
                    Image(systemName: "minus.circle")
                        .font(Typography.title)
                        .foregroundStyle(SashimiTheme.textTertiary)
                    Text(name)
                        .font(Typography.body)
                        .foregroundStyle(SashimiTheme.textPrimary)
                    Spacer()
                    Text("Side menu only")
                        .font(Typography.captionSmall)
                        .foregroundStyle(SashimiTheme.textTertiary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .accessibilityElement(children: .combine)

                HomeRowSideMenuButton(isOn: isOn, action: onToggle)
            }
            if let note = RailOrder.reachabilityNote(for: destination, isOnHome: false, isInSideMenu: isOn) {
                ReachabilityNote(text: note)
            }
        }
    }
}

struct ReachabilityNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.captionSmall)
            .foregroundStyle(SashimiTheme.textTertiary)
            .padding(.leading, 136)
    }
}

/// "Side Menu" on/off for one row.
struct HomeRowSideMenuButton: View {
    let isOn: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? SashimiTheme.accent : SashimiTheme.textTertiary)
                Text("Side Menu")
                    .foregroundStyle(isOn ? SashimiTheme.textPrimary : SashimiTheme.textSecondary)
            }
            .font(Typography.bodySmall)
            .frame(width: 190)
            .padding(.vertical, 18)
        }
        .buttonStyle(.card)
        .focusHighlight(isFocused, cornerRadius: 14)
        .focused($isFocused)
        .accessibilityLabel("Side menu")
        .accessibilityValue(isOn ? "Shown" : "Hidden")
    }
}

enum MoveDirection {
    case up, down

    var icon: String {
        switch self {
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        }
    }
}

struct HomeRowMoveButton: View {
    let direction: MoveDirection
    let isEnabled: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: direction.icon)
                .font(Typography.bodySmall.weight(.semibold))
                .foregroundStyle(isEnabled ? (isFocused ? .white : SashimiTheme.textSecondary) : SashimiTheme.textTertiary.opacity(0.3))
                .frame(width: 50, height: 50)
                .focusHighlight(isFocused, cornerRadius: 10, lineWidth: 2, scales: false)
        }
        .buttonStyle(.card)
        .focused($isFocused)
        .disabled(!isEnabled)
    }
}

struct HomeRowToggleButton: View {
    let config: HomeRowConfig
    let onToggle: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 16) {
                Image(systemName: config.isVisible ? "checkmark.circle.fill" : "circle")
                    .font(Typography.title)
                    .foregroundStyle(config.isVisible ? SashimiTheme.accent : SashimiTheme.textTertiary)

                Text(config.displayName)
                    .font(Typography.body)
                    .foregroundStyle(config.isVisible ? SashimiTheme.textPrimary : SashimiTheme.textSecondary)

                Spacer()

                if config.type != nil {
                    Text("Built-in")
                        .font(Typography.captionSmall)
                        .foregroundStyle(SashimiTheme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(SashimiTheme.cardBackground.opacity(0.5)))
                }
            }
        }
        .buttonStyle(.card)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .focusHighlight(isFocused, cornerRadius: 14)
        .focused($isFocused)
    }
}

// MARK: - Settings Container (styled background + width constraint)

struct SettingsContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    content
                        .frame(maxWidth: 900)
                        .padding(.top, 40)
                }
            }
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack {
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textPrimary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(Typography.titleSmall)
                    .foregroundStyle(isOn ? SashimiTheme.accent : SashimiTheme.textTertiary)
            }
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusHighlight(isFocused, cornerRadius: 12)
        .focused($isFocused)
    }
}

// MARK: - Playback Settings View

struct PlaybackSettingsView: View {
    @StateObject private var settings = PlaybackSettings.shared
    @ObservedObject private var viewModes = VideoViewModeStore.shared
    /// Nil until the client answers; drives the Auto-quality diagnostics row.
    @State private var bandwidthStatus: JellyfinClient.BandwidthStatus?

    var body: some View {
        SettingsContainer {
            VStack(alignment: .leading, spacing: 24) {
                Text("Playback Settings")
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .padding(.bottom, 8)

                // Video Quality Section
                SettingsSection(title: "Video Quality") {
                    SettingsNavigationRow(title: "Maximum Bitrate", subtitle: bitrateLabel) {
                        VideoQualitySettingsView()
                    }
                    SettingsToggleRow(title: "Always Play Original", isOn: $settings.forceDirectPlay)
                    // Auto's real ceiling was invisible: a stream capped by a
                    // failed bandwidth probe looked like a struggling server.
                    if settings.maxBitrate == 0 {
                        SettingsInfoRow(label: "Auto Limit", value: autoLimitLabel)
                    }
                }

                Text("Plays the original file untouched, never converted. If your connection cannot keep up, playback may stall rather than drop quality.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .padding(.horizontal, 8)

                // Video Player Section
                SettingsSection(title: "Video Player") {
                    SettingsToggleRow(title: "Show Episode Navigation Controls", isOn: $settings.showEpisodeNavigationControls)
                    SettingsNavigationRow(title: "Default View Mode", subtitle: viewModes.defaultMode.displayName) {
                        ViewModeSettingsView()
                    }
                }

                // Playback Behavior Section
                SettingsSection(title: "Playback Behavior") {
                    SettingsToggleRow(title: "Auto-Play Next Episode", isOn: $settings.autoPlayNextEpisode)
                    SettingsToggleRow(title: "Auto-Skip Intro", isOn: $settings.autoSkipIntro)
                    SettingsToggleRow(title: "Auto-Skip Credits", isOn: $settings.autoSkipCredits)
                    SettingsToggleRow(title: "Play Theme Songs", isOn: $settings.playThemeSongs)
                    SettingsToggleRow(title: "Play Trailers on Detail Pages", isOn: $settings.playHeroTrailers)
                    SettingsNavigationRow(title: "TV Shuffle", subtitle: settings.tvShuffleMode.title) {
                        TVShuffleSettingsView()
                    }
                }

                Text("Auto-skip requires the intro-skipper plugin on your server.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .padding(.horizontal, 8)

                // Resume Section
                SettingsSection(title: "Resume Playback") {
                    SettingsNavigationRow(title: "Resume Threshold", subtitle: resumeLabel) {
                        ResumeThresholdSettingsView()
                    }
                }

                // Audio Section
                SettingsSection(title: "Audio") {
                    SettingsNavigationRow(title: "Preferred Language", subtitle: audioLanguageLabel) {
                        LanguagePickerView(title: "Audio Language", selection: $settings.preferredAudioLanguage)
                    }
                }

                // Subtitles Section
                SettingsSection(title: "Subtitles") {
                    SettingsToggleRow(title: "Enable Subtitles", isOn: $settings.subtitlesEnabled)
                    if settings.subtitlesEnabled {
                        SettingsNavigationRow(title: "Preferred Language", subtitle: subtitleLanguageLabel) {
                            LanguagePickerView(title: "Subtitle Language", selection: $settings.preferredSubtitleLanguage)
                        }
                    }
                }

                // Display Section
                SettingsSection(title: "Display") {
                    SettingsToggleRow(title: "24-Hour Time", isOn: $settings.use24HourTime)
                    SettingsToggleRow(title: "Show Quality Badges", isOn: $settings.showQualityBadges)
                    SettingsToggleRow(title: "Show Review Ratings", isOn: $settings.showReviewRatings)
                    SettingsToggleRow(title: "Use Episode Ratings", isOn: $settings.useEpisodeRatings)
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .task { bandwidthStatus = await JellyfinClient.shared.bandwidthStatus }
    }

    /// The cap Auto is actually sending, and whether it came from a real
    /// measurement or the fallback default.
    private var autoLimitLabel: String {
        guard let bandwidthStatus else { return "Checking…" }
        let mbps = Int(round(Double(bandwidthStatus.cap) / 1_000_000))
        if bandwidthStatus.isMeasured { return "\(mbps) Mbps measured" }
        return bandwidthStatus.skippedOnMeteredNetwork
            ? "\(mbps) Mbps (not measured: metered network)"
            : "\(mbps) Mbps (not measured)"
    }

    private var bitrateLabel: String {
        let bitrate = settings.maxBitrate
        if bitrate == 0 { return "Auto" }
        if bitrate >= 1_000_000 { return "\(bitrate / 1_000_000) Mbps" }
        return "\(bitrate / 1000) Kbps"
    }

    private var resumeLabel: String {
        let seconds = settings.resumeThresholdSeconds
        if seconds == 0 { return "Always ask" }
        if seconds >= 60 { return "\(seconds / 60) minute\(seconds >= 120 ? "s" : "")" }
        return "\(seconds) seconds"
    }

    private var audioLanguageLabel: String {
        settings.preferredAudioLanguage.isEmpty ? "System Default" : languageName(for: settings.preferredAudioLanguage)
    }

    private var subtitleLanguageLabel: String {
        settings.preferredSubtitleLanguage.isEmpty ? "System Default" : languageName(for: settings.preferredSubtitleLanguage)
    }

    private func languageName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

// MARK: - Settings Section Container

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Typography.bodySmall.weight(.semibold))
                .foregroundStyle(SashimiTheme.textSecondary)
                .padding(.leading, 8)

            VStack(spacing: 8) {
                content()
            }
        }
    }
}

// MARK: - Settings Navigation Row

struct SettingsNavigationRow<Destination: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let destination: () -> Destination
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textPrimary)

                Spacer()

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(SashimiTheme.textTertiary)
                }

                Image(systemName: "chevron.right")
                    .font(Typography.captionSmall.weight(.semibold))
                    .foregroundStyle(SashimiTheme.textTertiary)
            }
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .focusHighlight(isFocused, cornerRadius: 14)
        .focused($isFocused)
    }
}

struct VideoQualitySettingsView: View {
    // Default must match PlaybackSettings.maxBitrate (0 = Auto).
    @AppStorage("maxBitrate") private var maxBitrate = 0

    let bitrateOptions = [
        (label: "Auto", value: 0),
        (label: "4K - 120 Mbps", value: 120_000_000),
        (label: "4K - 80 Mbps", value: 80_000_000),
        (label: "1080p - 40 Mbps", value: 40_000_000),
        (label: "1080p - 20 Mbps", value: 20_000_000),
        (label: "720p - 8 Mbps", value: 8_000_000),
        (label: "480p - 3 Mbps", value: 3_000_000),
        // Low bandwidth: for connections that cannot sustain 3 Mbps.
        (label: "720p - 2 Mbps", value: 2_000_000),
        (label: "480p - 1 Mbps", value: 1_000_000),
        (label: "360p - 720 kbps", value: 720_000),
    ]

    var body: some View {
        SettingsContainer {
            VStack(alignment: .leading, spacing: 16) {
                Text("Video Quality")
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .padding(.bottom, 8)

                ForEach(bitrateOptions, id: \.value) { option in
                    SettingsPickerOptionRow(
                        title: option.label,
                        isSelected: maxBitrate == option.value
                    ) {
                        maxBitrate = option.value
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
    }
}

// MARK: - Settings Picker Option Row (for selection lists)

struct SettingsPickerOptionRow: View {
    let title: String
    var subtitle: String = ""
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Typography.body)
                        .foregroundStyle(SashimiTheme.textPrimary)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Typography.captionSmall)
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Typography.title)
                        .foregroundStyle(SashimiTheme.accent)
                }
            }
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .focusHighlight(isFocused, cornerRadius: 14)
        .focused($isFocused)
    }
}

struct ResumeThresholdSettingsView: View {
    @AppStorage("resumeThresholdSeconds") private var resumeThresholdSeconds = 30

    let thresholdOptions = [
        (label: "Always ask", value: 0),
        (label: "10 seconds", value: 10),
        (label: "30 seconds", value: 30),
        (label: "1 minute", value: 60),
        (label: "2 minutes", value: 120),
        (label: "5 minutes", value: 300),
        (label: "10 minutes", value: 600),
    ]

    var body: some View {
        SettingsContainer {
            VStack(alignment: .leading, spacing: 16) {
                Text("Resume Threshold")
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .padding(.bottom, 8)

                Text("Only ask to resume if watched more than this amount")
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .padding(.bottom, 16)

                ForEach(thresholdOptions, id: \.value) { option in
                    SettingsPickerOptionRow(
                        title: option.label,
                        isSelected: resumeThresholdSeconds == option.value
                    ) {
                        resumeThresholdSeconds = option.value
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
    }
}

struct TVShuffleSettingsView: View {
    @StateObject private var settings = PlaybackSettings.shared

    var body: some View {
        SettingsContainer {
            VStack(alignment: .leading, spacing: 16) {
                Text("TV Shuffle")
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .padding(.bottom, 8)

                Text("What a TV library's Shuffle button plays. A show's own Shuffle always picks a random episode.")
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .padding(.bottom, 16)

                ForEach(TVShuffleMode.allCases) { mode in
                    SettingsPickerOptionRow(
                        title: mode.title,
                        subtitle: mode.detail,
                        isSelected: settings.tvShuffleMode == mode
                    ) {
                        settings.tvShuffleMode = mode
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
    }
}

struct LanguagePickerView: View {
    let title: String
    @Binding var selection: String

    let languages = [
        (code: "", name: "System Default"),
        (code: "en", name: "English"),
        (code: "es", name: "Spanish"),
        (code: "fr", name: "French"),
        (code: "de", name: "German"),
        (code: "it", name: "Italian"),
        (code: "pt", name: "Portuguese"),
        (code: "ja", name: "Japanese"),
        (code: "ko", name: "Korean"),
        (code: "zh", name: "Chinese"),
        (code: "ru", name: "Russian"),
        (code: "ar", name: "Arabic"),
        (code: "hi", name: "Hindi"),
        (code: "nl", name: "Dutch"),
        (code: "pl", name: "Polish"),
        (code: "sv", name: "Swedish"),
        (code: "da", name: "Danish"),
        (code: "no", name: "Norwegian"),
        (code: "fi", name: "Finnish"),
    ]

    var body: some View {
        SettingsContainer {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .padding(.bottom, 8)

                ForEach(languages, id: \.code) { language in
                    SettingsPickerOptionRow(
                        title: language.name,
                        isSelected: selection == language.code
                    ) {
                        selection = language.code
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SessionManager.shared)
}

// MARK: - App Icon Settings

private struct AppIconOption {
    let id: String?
    let name: String
    let previewImage: String
}

struct AppIconSettingsView: View {
    @State private var currentIcon: String? = UIApplication.shared.alternateIconName
    @FocusState private var focusedIcon: String?
    @State private var showingErrorAlert = false
    @State private var showingSuccessAlert = false
    @State private var alertMessage = ""
    @State private var successIconName = ""

    private let icons: [AppIconOption] = [
        AppIconOption(id: nil, name: "Default", previewImage: "AppIconPreviewDefault"),
        AppIconOption(id: "CatIcon", name: "Cat", previewImage: "AppIconPreviewCat"),
        AppIconOption(id: "ChopsticksIcon", name: "Chopsticks", previewImage: "AppIconPreviewChopsticks"),
        AppIconOption(id: "WhitefishIcon", name: "Whitefish", previewImage: "AppIconPreviewWhitefish"),
        AppIconOption(id: "FoxIcon", name: "Fox", previewImage: "AppIconPreviewFoxIcon"),
        AppIconOption(id: "PandaIcon", name: "Panda", previewImage: "AppIconPreviewPandaIcon"),
        AppIconOption(id: "RacoonIcon", name: "Racoon", previewImage: "AppIconPreviewRacoonIcon"),
        AppIconOption(id: "ShrimpIcon", name: "Shrimp", previewImage: "AppIconPreviewShrimpIcon"),
        AppIconOption(id: "TunaIcon", name: "Tuna", previewImage: "AppIconPreviewTunaIcon")
    ]

    private let columns = [
        GridItem(.fixed(180), spacing: 20),
        GridItem(.fixed(180), spacing: 20),
        GridItem(.fixed(180), spacing: 20)
    ]

    var body: some View {
        SettingsContainer {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(icons, id: \.name) { icon in
                    AppIconButton(
                        name: icon.name,
                        previewImage: icon.previewImage,
                        isSelected: currentIcon == icon.id,
                        isFocused: focusedIcon == icon.name
                    ) {
                        changeIcon(to: icon.id, name: icon.name)
                    }
                    .focused($focusedIcon, equals: icon.name)
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .alert("Error", isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .alert("Icon Updated", isPresented: $showingSuccessAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("App icon changed to \(successIconName)")
        }
    }

    private func changeIcon(to iconName: String?, name: String) {
        // Public API only — the previous private-selector workaround
        // (_setAlternateIconName:completionHandler:) is an App Review
        // rejection risk. See issue #174.
        guard UIApplication.shared.supportsAlternateIcons else { return }

        UIApplication.shared.setAlternateIconName(iconName) { error in
            DispatchQueue.main.async {
                if let error = error {
                    alertMessage = error.localizedDescription
                    showingErrorAlert = true
                } else {
                    currentIcon = iconName
                    successIconName = name
                    showingSuccessAlert = true
                }
            }
        }
    }
}

struct AppIconButton: View {
    let name: String
    let previewImage: String
    let isSelected: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Image(previewImage)
                    .resizable().scaledToFit()
                    .frame(width: 170, height: 102)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
                    )
                    .shadow(color: isFocused ? SashimiTheme.focus.opacity(0.5) : .clear, radius: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .green)
                        .padding(6)
                }
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(.card)
    }
}

// MARK: - Servers (multi-server management)

struct ServersSettingsView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var showAddServer = false
    @State private var serverBeingEdited: ServerConfig?
    @State private var serverPendingRemoval: ServerConfig?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Servers")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Select a server to switch, or edit its details. Hold to remove.")
                    .font(.callout)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(sessionManager.servers) { server in
                    HStack(spacing: 18) {
                        Button {
                            Task { await sessionManager.switchServer(to: server.id) }
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(SashimiTheme.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .center, spacing: 8) {
                                        Text(server.displayName)
                                            .foregroundStyle(SashimiTheme.textPrimary)
                                        if sessionManager.shouldShowDefaultServerBadge,
                                           sessionManager.isDefaultServer(server.id) {
                                            DefaultServerBadge(tint: SashimiTheme.accent)
                                        }
                                    }
                                    Text("\(server.username) • \(server.url.absoluteString)")
                                        .font(.caption)
                                        .foregroundStyle(SashimiTheme.textTertiary)
                                }
                                Spacer()
                                if server.id == sessionManager.activeServerId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(SashimiTheme.accent)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            serverBeingEdited = server
                        } label: {
                            Image(systemName: "pencil")
                                .font(.title3)
                                .foregroundStyle(SashimiTheme.textSecondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(server.displayName)")
                    }
                    .padding()
                    .background(SashimiTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contextMenu {
                        Button(role: .destructive) {
                            serverPendingRemoval = server
                        } label: {
                            Label("Remove Server", systemImage: "trash")
                        }
                    }
                }

                Button {
                    showAddServer = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Server")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }
            .frame(maxWidth: 900)
            .padding(60)
        }
        .fullScreenCover(isPresented: $showAddServer) {
            AddServerSheet()
        }
        .fullScreenCover(item: $serverBeingEdited) { server in
            ServerEditView(server: server)
                .environmentObject(sessionManager)
        }
        .alert(
            "Remove \(serverPendingRemoval?.displayName ?? "server")?",
            isPresented: Binding(
                get: { serverPendingRemoval != nil },
                set: { if !$0 { serverPendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let server = serverPendingRemoval {
                    Task { await sessionManager.removeServer(id: server.id) }
                }
                serverPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { serverPendingRemoval = nil }
        } message: {
            Text("This signs out of the server on this device.")
        }
    }
}

/// ServerConnectionView presented modally for adding an additional server.
/// Dismisses itself when the server list grows (login adds + activates).
struct AddServerSheet: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var initialCount = 0

    var body: some View {
        ServerConnectionView(onCancel: { dismiss() })
            .onAppear { initialCount = sessionManager.servers.count }
            .onChange(of: sessionManager.servers.count) { _, newCount in
                if newCount > initialCount { dismiss() }
            }
            .onDisappear {
                // Re-point the shared client at the active server after the
                // probe, so the live session keeps working.
                Task { await sessionManager.restoreActiveClient() }
            }
            .onExitCommand { dismiss() }
    }
}

private extension View {
    /// Claims default focus only when the rail supplies its shared namespace,
    /// so the rightward beam from the Settings rail row lands here. Callers
    /// without a namespace (previews) are untouched.
    @ViewBuilder
    func defaultFocus(in namespace: Namespace.ID?) -> some View {
        if let namespace {
            prefersDefaultFocus(true, in: namespace)
        } else {
            self
        }
    }
}
