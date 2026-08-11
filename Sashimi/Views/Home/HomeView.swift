import SwiftUI

// swiftlint:disable file_length
// HomeView contains the main home screen with multiple tightly-coupled components

struct HomeView: View {
    /// The parent focus scope (from MainTabView) so the hero can claim default
    /// focus on Home — otherwise focus lands on the nav rail instead.
    var focusNamespace: Namespace.ID?
    /// Fired when the hero first has content — lets the parent pull focus off
    /// the rail (which grabbed it while the hero was still loading).
    var onHeroReady: (() -> Void)?
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var homeSettings = HomeScreenSettings.shared
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var selectedItem: BaseItemDto?
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
                if !viewModel.heroItems.isEmpty {
                    HeroSection(
                        items: viewModel.heroItems,
                        libraryNames: viewModel.heroItemLibraryNames,
                        currentIndex: $heroIndex
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
        }
        .onChange(of: viewModel.heroItems.count) { _, count in
            if count > 0 { onHeroReady?() }
        }
        .onAppear {
            // Initial load happens in .task above (and .task re-runs when the
            // view re-enters the hierarchy), so no extra refresh here — it
            // used to double-fetch everything on first appearance.
            startAutoRefresh()
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
    }

    @ViewBuilder
    private func rowView(for config: HomeRowConfig) -> some View {
        if let type = config.type {
            switch type {
            case .hero:
                // The hero is rendered as a fixed backdrop in the body (behind the
                // scrolling rows), so it is never a scrolling row here.
                EmptyView()
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

// MARK: - Hero Section
struct HeroSection: View {
    let items: [BaseItemDto]
    let libraryNames: [String: String]
    @Binding var currentIndex: Int

    @State private var autoAdvanceTimer: Timer?

    /// Seconds each hero item stays on screen before auto-advancing
    private let slideDuration: Double = 6

    private var safeIndex: Int {
        guard !items.isEmpty else { return 0 }
        return min(currentIndex, items.count - 1)
    }

    private var currentItem: BaseItemDto {
        items[safeIndex]
    }

    // Detect YouTube content by checking library name
    private var isYouTubeContent: Bool {
        guard let libraryName = libraryNames[currentItem.id] else { return false }
        return libraryName.lowercased().contains("youtube")
    }

    // Fallback image IDs for hero display - prefer series backdrop for episodes
    private var heroFallbackIds: [String] {
        var ids: [String] = []
        if currentItem.type == .episode {
            // For YouTube: use episode thumbnail
            if isYouTubeContent {
                ids.append(currentItem.id)
            } else {
                // For regular episodes: try series first for high-res backdrop
                if let seriesId = currentItem.seriesId {
                    ids.append(seriesId)
                }
                if let seasonId = currentItem.seasonId {
                    ids.append(seasonId)
                }
                ids.append(currentItem.id)
            }
        } else {
            ids.append(currentItem.id)
        }
        return ids
    }

    // Image types for hero - YouTube uses episode thumbnail, others use Backdrop
    private var heroImageTypes: [String] {
        if isYouTubeContent {
            // YouTube episodes have thumbnails as Primary or Thumb
            return ["Primary", "Thumb", "Backdrop"]
        }
        return ["Backdrop", "Art", "Thumb"]
    }

    // Display title (channel/series name for episodes, item name for movies)
    private var displayTitle: String {
        if currentItem.type == .episode {
            return (currentItem.seriesName ?? currentItem.name).cleanedYouTubeTitle
        }
        return currentItem.name
    }

    // VoiceOver accessibility description
    private var accessibilityDescription: String {
        var parts: [String] = []

        if currentItem.type == .episode {
            parts.append((currentItem.seriesName ?? currentItem.name).cleanedYouTubeTitle)
            parts.append(formatEpisodeInfo(currentItem))
        } else {
            parts.append(currentItem.name)
        }

        if let type = currentItem.type {
            parts.append(type.rawValue)
        }

        if let year = currentItem.productionYear {
            parts.append("from \(year)")
        }

        if items.count > 1 {
            parts.append("Item \(safeIndex + 1) of \(items.count)")
            parts.append("Swipe left or right to browse")
        }

        return parts.joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    // Transparent base so the page gradient behind the hero shows
                    // through — a solid SashimiTheme.background fill read lighter
                    // than the rest of the screen (which fades to pure black).
                    Color.clear

                    // Backdrop image positioned on the right with soft left edge.
                    // The fade mask is applied to the IMAGE, not the 0.7-width
                    // container: a .fit image sizes to its fitted bounds (a 16:9
                    // backdrop fills ~0.5 of the hero width), so a container-
                    // relative ramp over the leftmost 25% never reached the
                    // image's actual left edge — leaving a harsh vertical line
                    // mid-hero. Image-relative, the ramp always covers the edge.
                    HStack(spacing: 0) {
                        Spacer()
                        SmartPosterImage(
                            itemIds: heroFallbackIds,
                            // 1920, not 3840. tvOS lays out in a 1920x1080 space
                            // and this slot renders ~910x512pt, so a 4K request
                            // was a 33 MB RGBA decode (3840*2160*4) for an image
                            // that is downsampled on sight. Jellyfin treats
                            // maxWidth as a cap, so any item with 4K artwork
                            // really did return 4K -- and the hero rotates every
                            // 6 seconds.
                            maxWidth: 1920,
                            imageTypes: heroImageTypes,
                            contentMode: .fit
                        )
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .white, location: 0.35)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .id(currentItem.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .frame(width: geometry.size.width * 0.7, height: geometry.size.height)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.6), value: currentItem.id)
                    }

                    // Left text scrim: black (not charcoal) so the text area
                    // matches the page's fade-to-black rather than reading lighter.
                    // The title is white with a shadow, so a light scrim isn't
                    // needed for legibility over the dark background.
                    HStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.5), location: 0.0),
                                .init(color: .black.opacity(0.4), location: 0.6),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.35)
                        Spacer()
                    }

                    // Bottom gradient — fade to black (not charcoal) so the title
                    // area and the hero's lower edge match the page's fade-to-black.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.4),
                            .init(color: .black.opacity(0.6), location: 0.7),
                            .init(color: .black, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Content overlay
                    VStack(alignment: .leading, spacing: 20) {
                        Spacer()

                        // Title
                        Text(displayTitle)
                            .font(.system(size: 64, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.8), radius: 10, x: 0, y: 4)

                        // Episode info for TV shows, video title for YouTube
                        if currentItem.type == .episode {
                            if isYouTubeContent {
                                // YouTube: show video title
                                Text(currentItem.name)
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
                                    .lineLimit(2)
                            } else {
                                // Regular TV: show S:E info
                                Text(formatEpisodeInfo(currentItem))
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
                            }
                        }

                        // Metadata row
                        HStack(spacing: 20) {
                            if let rating = currentItem.communityRating {
                                HStack(spacing: 8) {
                                    Image("TMDBLogo")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(height: 24)
                                    Text(String(format: "%.1f", rating))
                                        .fontWeight(.semibold)
                                }
                            }

                            if let criticRating = currentItem.criticRating {
                                HStack(spacing: 6) {
                                    Text("🍅")
                                    Text("\(criticRating)%")
                                        .fontWeight(.semibold)
                                }
                            }

                            if isYouTubeContent {
                                // Show full date for YouTube
                                if let dateStr = DateFormatting.formatDate(currentItem.premiereDate) {
                                    Text(dateStr)
                                }
                                HStack(spacing: 6) {
                                    Image(systemName: "play.rectangle.fill")
                                    Text("YouTube")
                                }
                                .foregroundStyle(.red)
                            } else {
                                if let year = currentItem.productionYear {
                                    Text(String(year))
                                }

                                if let runtime = DateFormatting.formatRuntime(currentItem.runTimeTicks) {
                                    Text(runtime)
                                }
                            }
                        }
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))

                        // Description
                        if let overview = currentItem.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(3)
                                .frame(maxWidth: 800, alignment: .leading)
                                .padding(.top, 4)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 80)
                }
            }
            .aspectRatio(32/9, contentMode: .fit)
            // Non-interactive ambient wallpaper: full-bleed (edge to edge), not a
            // card — no focus, no border, no scale (focus skips it to the first
            // row). Fade only the bottom edge to transparent so the hero dissolves
            // into the page background instead of ending on a hard horizontal seam
            // (its fill is lighter than the page gradient lower down). Fade starts
            // at 0.9 so the title/metadata above it stay fully opaque.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0.0),
                        .init(color: .white, location: 0.9),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)
        .onAppear {
            startAutoAdvance()
        }
        .onDisappear {
            stopAutoAdvance()
        }
    }

    private func startAutoAdvance() {
        guard items.count > 1 else { return }
        // A second onAppear without an intervening onDisappear (tab switch,
        // navigation pop) would otherwise orphan the previous timer, which
        // keeps mutating currentIndex — the hero then advances at a multiple
        // of the intended rate and never settles.
        autoAdvanceTimer?.invalidate()
        // One tick per slide advances the hero.
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: slideDuration, repeats: true) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.6)) {
                    currentIndex = (currentIndex + 1) % items.count
                }
            }
        }
    }

    private func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    private func formatEpisodeInfo(_ item: BaseItemDto) -> String {
        let season = item.parentIndexNumber ?? 1
        let episode = item.indexNumber ?? 1
        return "S\(season) E\(episode) • \(item.name)"
    }
}

// MARK: - Recently Added Library Row
struct RecentlyAddedLibraryRow: View {
    let library: JellyfinLibrary
    let onSelect: (BaseItemDto) -> Void
    @State private var items: [BaseItemDto] = []
    @State private var episodeCounts: [String: Int] = [:]  // seriesId -> count of new episodes
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
                .padding(.horizontal, 80)

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
                                onSelect(item)
                            }
                        }
                    }
                    .padding(.horizontal, 80)
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
                collectionType: library.collectionType,
                isYouTubeLibrary: isYouTubeLibrary
            )
            let dedupedItems = deduplicateBySeries(latestItems)
            items = dedupedItems

            // Fetch actual unplayed counts from series (for TV shows)
            if isTVLibrary {
                await loadUnplayedCounts(for: dedupedItems)
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
