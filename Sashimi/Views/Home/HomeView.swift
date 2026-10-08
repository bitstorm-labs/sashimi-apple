import SwiftUI

struct HomeView: View {
    /// The parent focus scope (from MainTabView) so the hero can claim default
    /// focus on Home — otherwise focus lands on the nav rail instead.
    var focusNamespace: Namespace.ID?
    /// Fired when the hero first has content — lets the parent pull focus off
    /// the rail (which grabbed it while the hero was still loading).
    var onHeroReady: (() -> Void)?
    @StateObject private var viewModel = HomeViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var channelsViewModel = ChannelsViewModel()
    @StateObject private var homeSettings = HomeScreenSettings.shared
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var selectedItem: BaseItemDto?
    /// Set when a channel is tuned to. Carries the item and the context that
    /// makes playback ephemeral, so the player opens directly — a channel has
    /// no resume position, and a detail screen would only offer choices that do
    /// not apply to one.
    @State private var tunedChannel: TunedChannel?
    @State private var selectedItemIsYouTube: Bool = false
    @State private var refreshTimer: Timer?
    @State private var heroIndex: Int = 0
    @State private var playingItem: BaseItemDto?  // For immediate playback via Play button
    // Fixed hero wallpaper: dims to black as the rows scroll up over it.
    @State private var heroScrollFade: Double = 0
    // Seeded near the real 32:9 full-width height so the reveal spacer is correct
    // on first render; the GeometryReader corrects it once laid out.
    @State private var heroHeight: CGFloat = 500
    // The id of the item scrolled to the top (0 = hero reveal spacer = "at top").
    @State private var homeTopID: Int?

    // Order libraries according to settings

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [SashimiTheme.background, Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                // Fixed hero wallpaper pinned to the top, BEHIND the scrolling
                // rows. It dims to black as the rows scroll up over it, so the
                // content stays readable and the art never fights the cards.
                if !heroSlides.isEmpty {
                    HeroSection(
                        slides: heroSlides,
                        libraryNames: viewModel.heroItemLibraryNames,
                        currentIndex: $heroIndex,
                        layout: .tv
                    )
                    .overlay(Color.black.opacity(heroScrollFade))
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { heroHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, newHeight in
                                    heroHeight = newHeight
                                }
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .top)
                    // Full-bleed to the top edge too — it's a wallpaper pinned to
                    // the top, so no top inset. Nothing important sits at the very
                    // top (the title is at the hero's bottom), so overscan bleed is
                    // fine and looks cleaner than a gap.
                    .ignoresSafeArea(edges: [.top, .horizontal])
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 40) {
                        // Clear spacer revealing the fixed hero above the first row
                        // (a touch less than the hero height so the first row
                        // overlaps the hero's faded bottom edge). id 0 = "at top".
                        Color.clear
                            .frame(height: max(0, heroHeight - 48))
                            .id(0)

                        // Rows in settings order; the hero is a fixed backdrop, so
                        // its config is skipped here. Each row is id'd so the scroll
                        // position can report which one is at the top.
                        ForEach(
                            Array(homeSettings.rowConfigs
                                .filter { $0.isVisible && $0.type != .hero }
                                .enumerated()),
                            id: \.element.id
                        ) { index, config in
                            rowView(for: config)
                                .id(index + 1)
                        }

                        // Bottom spacing
                        Spacer()
                            .frame(height: 100)
                    }
                    .scrollTargetLayout()
                }
                // tvOS focus-scroll doesn't expose a smooth offset, but it does
                // report which laid-out item is at the top. id 0 is the hero reveal
                // spacer; anything past it means the rows scrolled up over the hero,
                // so dim the wallpaper to black.
                .scrollPosition(id: $homeTopID, anchor: .top)
                .onChange(of: homeTopID) { _, newID in
                    withAnimation(.easeOut(duration: 0.3)) {
                        heroScrollFade = (newID ?? 0) == 0 ? 0 : 1
                    }
                }
                .ignoresSafeArea(edges: .horizontal)
            }
            .fullScreenCover(item: $selectedItem) { item in
                MediaDetailView(item: item, forceYouTubeStyle: selectedItemIsYouTube)
            }
            .fullScreenCover(item: $playingItem) { item in
                PlayerView(item: item, startFromBeginning: false)
            }
            .fullScreenCover(item: $tunedChannel) { tuned in
                PlayerView(item: tuned.item, channelContext: tuned.context)
            }
            #if DEBUG
            // Test harness: SASHIMI_TUNE_STATION=<channel id> tunes that station
            // straight after launch, so on-device tests of channel flipping do
            // not depend on steering the remote blind through the rail. Debug
            // builds only.
            .task {
                // SASHIMI_TEST_REMINDER=<channel id>: a reminder for that station
                // three minutes out, so the reminder banner can be exercised
                // without waiting for a real airtime.
                if let station = ProcessInfo.processInfo.environment["SASHIMI_TEST_REMINDER"] {
                    StationReminders.shared.toggle(.init(
                        channelID: station, channelName: "Unscripted",
                        title: "Survivor", startsAt: Date().addingTimeInterval(180)))
                    StationReminders.shared.tick()
                }
                guard let station = ProcessInfo.processInfo.environment["SASHIMI_TUNE_STATION"] else { return }
                try? await Task.sleep(nanoseconds: 8 * NSEC_PER_SEC)
                let guide = GuideViewModel()
                guard let tuned = await guide.tuneIn(to: station),
                      let item = try? await JellyfinClient.shared.getItem(itemId: tuned.itemID) else {
                    return
                }
                tunedChannel = TunedChannel(item: item, context: tuned.context)
            }
            #endif
            .onChange(of: selectedItem) { oldValue, newValue in
                if oldValue != nil && newValue == nil {
                    Task { await viewModel.refresh() }
                }
            }
            .onChange(of: playingItem) { oldValue, newValue in
                if oldValue != nil && newValue == nil {
                    Task { await viewModel.refresh() }
                }
            }
        }
        .task {
            await viewModel.loadContent()
            homeSettings.updateWithLibraries(viewModel.libraries)
            if !viewModel.heroItems.isEmpty { onHeroReady?() }
            // After the main content: a server without the Channels plugin
            // answers 404 and yields an empty row, so this must never gate the
            // rest of Home on it.
            await channelsViewModel.load()
            await keepChannelsCurrent()
        }
        .onChange(of: viewModel.heroItems.count) { _, count in
            if count > 0 { onHeroReady?() }
        }
        .onAppear {
            // Initial load happens in .task above. Home stays in the hierarchy
            // when another section is shown, so .task does not re-run on the
            // way back; reload then only if what is on screen has gone stale
            // (e.g. something was watched on another device).
            startAutoRefresh()
            Task { await viewModel.refreshIfStale() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from the screensaver, sleep or another app: the 30 s timer
            // does not run while suspended, so reload now if stale.
            guard phase == .active, selectedItem == nil, playingItem == nil else { return }
            Task { await viewModel.refreshIfStale() }
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .onChange(of: homeSettings.needsRefresh) { _, needsRefresh in
            if needsRefresh {
                homeSettings.needsRefresh = false
                Task { await viewModel.refresh() }
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.continueWatchingItems.isEmpty {
                LoadingOverlay()
                    .allowsHitTesting(false) // Allow navigation while loading
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidEnd)) { _ in
            Task { await viewModel.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sashimiChannelsDidChange)) { _ in
            Task { await channelsViewModel.load() }
        }
    }

    /// Keep the FinTV row honest while Home is on screen.
    ///
    /// A channel moves on whether or not anyone is looking at Home, so a row
    /// rendered once is wrong within minutes: the thumbnail still shows a
    /// finished programme and the countdown keeps ticking past zero.
    ///
    /// Wake when the soonest programme actually ends rather than on a fixed
    /// tick — a poll shows a finished programme for up to its whole interval,
    /// and that is exactly the moment someone is looking at it. Five minutes is
    /// only a ceiling, for when nothing ends soon and because the schedule can
    /// be rebuilt underneath us when the library changes.
    private func keepChannelsCurrent() async {
        let ceiling: Double = 300

        while !Task.isCancelled {
            let soonest = channelsViewModel.cards.compactMap(\.endsAt).min()
            // +1s so we wake just after the boundary, not exactly on it, and
            // the server has already rolled over when we ask.
            let wait = soonest.map { max(1, $0.timeIntervalSinceNow + 1) } ?? ceiling
            try? await Task.sleep(nanoseconds: UInt64(min(wait, ceiling) * Double(NSEC_PER_SEC)))
            guard !Task.isCancelled else { break }
            await channelsViewModel.load()
        }
    }

    /// The hero rotation: what each library last added, with the channels that
    /// are on air right now spread through it (see `HeroRotation.slides`).
    private var heroSlides: [HeroSlide] {
        HeroRotation.slides(libraryItems: viewModel.heroItems, channels: channelsViewModel.cards)
    }

    /// Resolve what the channel is airing and open the player on it.
    ///
    /// Resolved fresh at the moment of tuning rather than reusing the card's
    /// data: the row may have been on screen for a while, and a channel moves
    /// on whether or not anyone is looking at it.
    private func tuneToChannel(_ card: ChannelCard) {
        Task {
            guard let tuned = await channelsViewModel.tuneIn(to: card.channel) else {
                // Went off air between rendering and pressing. Refresh so the
                // row tells the truth rather than silently doing nothing.
                await channelsViewModel.load()
                return
            }
            guard let item = try? await JellyfinClient.shared.getItem(itemId: tuned.itemID) else { return }
            tunedChannel = TunedChannel(item: item, context: tuned.context)
        }
    }

    @ViewBuilder
    private func rowView(for config: HomeRowConfig) -> some View {
        if let type = config.type {
            switch type {
            case .hero:
                // The hero is rendered as a fixed backdrop in the body (behind the
                // scrolling rows), so it is never a scrolling row here.
                EmptyView()
            case .channels:
                if !channelsViewModel.cards.isEmpty {
                    ChannelsRow(cards: channelsViewModel.cards) { card in
                        tuneToChannel(card)
                    }
                }
            case .continueWatching:
                if !viewModel.continueWatchingItems.isEmpty {
                    ContinueWatchingRow(
                        items: viewModel.continueWatchingItems,
                        libraryNames: viewModel.continueWatchingLibraryNames,
                        onSelect: { item in
                            // Check if item comes from a library named YouTube
                            let libraryName = viewModel.continueWatchingLibraryNames[item.id] ?? ""
                            let isYouTube = libraryName.lowercased().contains("youtube")
                            selectedItemIsYouTube = isYouTube
                            selectedItem = item
                        },
                        onPlay: { item in
                            playingItem = item
                        }
                    )
                    .focusSection()
                }
            }
        } else if let libraryId = config.libraryId,
                  let library = viewModel.libraries.first(where: { $0.id == libraryId }) {
            RecentlyAddedLibraryRow(library: library, onSelect: { item in
                selectedItemIsYouTube = library.name.lowercased().contains("youtube")
                selectedItem = item
            })
            .focusSection()
        }
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            // Skip while something is presented over Home. The player and the
            // detail view are fullScreenCovers, which do NOT remove the
            // presenting view -- so .onDisappear never fires and this timer used
            // to keep running for the entire duration of a movie, firing ~25
            // requests every 30 seconds at the same server that is transcoding
            // it. Each tick also republished every @Published on the view model,
            // re-evaluating the whole LazyVStack behind the cover.
            guard selectedItem == nil, playingItem == nil else { return }
            Task {
                await viewModel.refresh()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Hero Layout

extension HeroLayout {
    /// The ten-foot hero the shared `HeroSection` was drawn for: 32:9 of the
    /// content width, every size at its original value. The picture starts
    /// 30pt below the top edge (chosen by eye on the living-room TV); the hero
    /// itself still bleeds to the top edge.
    static let tv = HeroLayout(imageTopInset: 30, accent: SashimiTheme.accent)
}

// MARK: - Recently Added Library Row
struct RecentlyAddedLibraryRow: View {
    let library: JellyfinLibrary
    let onSelect: (BaseItemDto) -> Void
    @State private var items: [BaseItemDto] = []
    @State private var episodeCounts: [String: Int] = [:]  // seriesId -> count of new episodes
    @State private var newestEpisodes: [String: BaseItemDto] = [:]  // channelId -> newest video
    @State private var isLoading = true
    @State private var loadError = false

    private var sectionTitle: String {
        "Recently Added \(library.name)".cleanedYouTubeTitle
    }

    // Detect YouTube library by name
    private var isYouTubeLibrary: Bool {
        library.name.lowercased().contains("youtube")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(sectionTitle)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 40)

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(SashimiTheme.accent)
                    Spacer()
                }
                .frame(height: isYouTubeLibrary ? 260 : 340)
            } else if loadError {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(SashimiTheme.textTertiary)
                        Text("Failed to load")
                            .font(.headline)
                            .foregroundStyle(SashimiTheme.textSecondary)
                        Button("Retry") {
                            Task { await loadItems() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(SashimiTheme.accent)
                    }
                    Spacer()
                }
                .frame(height: isYouTubeLibrary ? 260 : 340)
            } else if items.isEmpty {
                HStack {
                    Spacer()
                    Text("No items")
                        .font(.headline)
                        .foregroundStyle(SashimiTheme.textTertiary)
                    Spacer()
                }
                .frame(height: isYouTubeLibrary ? 260 : 340)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: isYouTubeLibrary ? 24 : 40) {
                        ForEach(items) { item in
                            let key = item.seriesId ?? item.id
                            // Use actual unplayed count from series (nil means no unwatched or not a series)
                            let unplayedCount = episodeCounts[key]
                            MediaPosterButton(
                                item: item,
                                libraryType: library.collectionType,
                                libraryName: library.name,
                                isCircular: isYouTubeLibrary,
                                badgeCount: (unplayedCount ?? 0) >= 1 ? unplayedCount : nil
                            ) {
                                // The row lists channels (so one prolific uploader
                                // can't crowd the others out), but opening a channel
                                // page isn't what you want from "Recently Added" —
                                // jump to the video that put it here. Falls back to
                                // the channel if the prefetch hasn't landed.
                                onSelect(newestEpisodes[item.id] ?? item)
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 20)
                }
            }
        }
        .task {
            await loadItems()
        }
    }

    private func loadItems() async {
        isLoading = items.isEmpty  // Only show loading on first load
        loadError = false

        do {
            let isTVLibrary = library.collectionType?.lowercased() == "tvshows"
            let fetchLimit = 30

            let latestItems = try await JellyfinClient.shared.getLatestMedia(
                parentId: library.id,
                limit: fetchLimit,
                includeWatched: true,
                collectionType: library.collectionType
            )
            let dedupedItems = deduplicateBySeries(latestItems)
            items = dedupedItems

            // Fetch actual unplayed counts from series (for TV shows)
            if isTVLibrary {
                await loadUnplayedCounts(for: dedupedItems)
            }
            if isYouTubeLibrary {
                await loadNewestEpisodes(for: dedupedItems)
            }
        } catch is CancellationError {
            // Ignore cancellation errors - expected during navigation
        } catch {
            loadError = true
        }

        isLoading = false
    }

    private func loadUnplayedCounts(for items: [BaseItemDto]) async {
        var counts: [String: Int] = [:]

        // Collect unique series IDs (handles both regular TV episodes and YouTube videos)
        let seriesIds = Set(items.compactMap { item -> String? in
            if item.type == .episode { return item.seriesId }
            if item.type == .video { return item.seriesId }
            if item.type == .series { return item.id }
            return nil
        })

        // Fetch each series' unplayed count CONCURRENTLY. Serially this was up
        // to 20 round-trips per Recently-Added row, per TV library, purely to
        // decorate a badge -- and it re-ran on every return to Home, delaying
        // the images the user is actually looking at.
        let fetched = await withTaskGroup(of: (String, Int)?.self) { group in
            for seriesId in seriesIds {
                group.addTask {
                    do {
                        let series = try await JellyfinClient.shared.getItem(itemId: seriesId)
                        guard let unplayedCount = series.userData?.unplayedItemCount, unplayedCount > 0 else { return nil }
                        return (seriesId, unplayedCount)
                    } catch {
                        // Ignore errors for individual series
                        return nil
                    }
                }
            }
            var out: [String: Int] = [:]
            for await result in group {
                if let (seriesId, count) = result { out[seriesId] = count }
            }
            return out
        }
        counts.merge(fetched) { _, new in new }

        episodeCounts = counts
    }

    /// Resolve each channel's most recently added video, so selecting a card in a
    /// YouTube row opens that video rather than the channel page. Prefetched
    /// concurrently while the row renders, so the press itself never waits on a
    /// round-trip.
    private func loadNewestEpisodes(for items: [BaseItemDto]) async {
        let channelIds = items.compactMap { $0.type == .series ? $0.id : nil }

        let fetched = await withTaskGroup(of: (String, BaseItemDto)?.self) { group in
            for channelId in channelIds {
                group.addTask {
                    do {
                        let response = try await JellyfinClient.shared.getItems(
                            parentId: channelId,
                            includeTypes: [.episode],
                            sortBy: "DateCreated",
                            sortOrder: "Descending",
                            limit: 1
                        )
                        guard let newest = response.items.first else { return nil }
                        return (channelId, newest)
                    } catch {
                        // A channel that fails to resolve just falls back to
                        // opening the channel page.
                        return nil
                    }
                }
            }
            var out: [String: BaseItemDto] = [:]
            for await result in group {
                if let (channelId, episode) = result { out[channelId] = episode }
            }
            return out
        }

        newestEpisodes = fetched
    }

    private func deduplicateBySeries(_ items: [BaseItemDto]) -> [BaseItemDto] {
        var seen = Set<String>()
        var result: [BaseItemDto] = []

        for item in items {
            // Group episodes and videos by their series
            let key: String
            if item.type == .episode || item.type == .video {
                key = item.seriesId ?? item.id
            } else {
                key = item.id
            }
            if !seen.contains(key) {
                seen.insert(key)
                result.append(item)
            }
        }

        return Array(result.prefix(20))
    }
}

// MARK: - Loading Overlay
struct LoadingOverlay: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            SashimiTheme.background.opacity(0.9)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(SashimiTheme.textTertiary.opacity(0.3), lineWidth: 4)
                        .frame(width: 60, height: 60)

                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(SashimiTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(rotation))
                        .onAppear {
                            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        }
                }

                Text("Loading your library...")
                    .font(.headline)
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
        }
    }
}

private extension View {
    /// Applies `prefersDefaultFocus` only when a namespace is supplied, so the
    /// hero claims default focus on Home while leaving previews/other callers
    /// (no namespace) untouched.
    @ViewBuilder
    func defaultFocus(in namespace: Namespace.ID?) -> some View {
        if let namespace {
            prefersDefaultFocus(true, in: namespace)
        } else {
            self
        }
    }
}

#Preview {
    HomeView()
}
