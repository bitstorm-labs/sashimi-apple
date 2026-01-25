import SwiftUI

// swiftlint:disable file_length
// HomeView contains the main home screen with multiple tightly-coupled components

// MARK: - Scroll Tracking
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var homeSettings = HomeScreenSettings.shared
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var selectedItem: BaseItemDto?
    @State private var selectedItemIsYouTube: Bool = false
    @State private var refreshTimer: Timer?
    @State private var heroIndex: Int = 0
    @State private var showContinueWatchingDetail = false
    @State private var playingItem: BaseItemDto?  // For immediate playback via Play button
    @Binding var resetTrigger: Bool
    @Binding var isAtDefaultState: Bool

    init(resetTrigger: Binding<Bool> = .constant(false), isAtDefaultState: Binding<Bool> = .constant(true)) {
        _resetTrigger = resetTrigger
        _isAtDefaultState = isAtDefaultState
    }

    // Order libraries according to settings
    private var orderedLibraries: [JellyfinLibrary] {
        let orderedIds = homeSettings.orderedLibraryIds()
        if orderedIds.isEmpty {
            return viewModel.libraries
        }
        return viewModel.libraries.sorted { lib1, lib2 in
            let index1 = orderedIds.firstIndex(of: lib1.id) ?? Int.max
            let index2 = orderedIds.firstIndex(of: lib2.id) ?? Int.max
            return index1 < index2
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [SashimiTheme.background, Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 40) {
                            // Header with logo and profile avatar
                            AppHeader()
                                .id("top")
                                .padding(.bottom, -80)

                            // Render rows based on settings order
                            ForEach(homeSettings.rowConfigs) { config in
                                if config.isVisible {
                                    rowView(for: config)
                                }
                            }

                            // Bottom spacing
                            Spacer()
                                .frame(height: 100)
                        }
                    }
                    .coordinateSpace(name: "scroll")
                    .ignoresSafeArea(edges: .top)
                    .refreshable {
                        await viewModel.refresh()
                    }
                    .onChange(of: resetTrigger) { _, _ in
                        withAnimation {
                            proxy.scrollTo("top", anchor: .top)
                        }
                        isAtDefaultState = true
                    }
                }
            }
            .fullScreenCover(item: $selectedItem) { item in
                MediaDetailView(item: item, forceYouTubeStyle: selectedItemIsYouTube)
            }
            .fullScreenCover(item: $playingItem) { item in
                PlayerView(item: item, startFromBeginning: false)
            }
            .fullScreenCover(isPresented: $showContinueWatchingDetail) {
                ContinueWatchingDetailView(
                    items: viewModel.continueWatchingItems,
                    onSelect: { item in
                        let isYouTube = item.type == .episode && (item.parentBackdropImageTags ?? []).isEmpty
                        showContinueWatchingDetail = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            selectedItemIsYouTube = isYouTube
                            selectedItem = item
                        }
                    }
                )
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
        }
        .onAppear {
            startAutoRefresh()
            // Refresh immediately when view appears (e.g., switching tabs)
            Task { await viewModel.refresh() }
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
                if !viewModel.heroItems.isEmpty {
                    HeroSection(
                        items: viewModel.heroItems,
                        libraryNames: viewModel.heroItemLibraryNames,
                        currentIndex: $heroIndex,
                        onSelect: { item in
                            // Check if item comes from a library named YouTube
                            let libraryName = viewModel.heroItemLibraryNames[item.id] ?? ""
                            selectedItemIsYouTube = libraryName.lowercased().contains("youtube")
                            selectedItem = item
                        }
                    )
                    .padding(.top, 20)
                    .focusSection()
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
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
    let onSelect: (BaseItemDto) -> Void

    @FocusState private var isFocused: Bool
    @State private var autoAdvanceTimer: Timer?
    @State private var progress: Double = 0

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
            // For YouTube: only use series banner, don't fall back to episode thumbnail
            if isYouTubeContent {
                if let seriesId = currentItem.seriesId {
                    ids.append(seriesId)
                }
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

    // Image types for hero - YouTube uses Banner, others use Backdrop
    private var heroImageTypes: [String] {
        if isYouTubeContent {
            // YouTube series have banner.jpg stored as Banner image type
            return ["Banner", "Backdrop", "Art", "Thumb"]
        }
        return ["Backdrop", "Art", "Thumb", "Primary"]
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
        Button {
            onSelect(currentItem)
        } label: {
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    // Full-width backdrop image
                    SmartPosterImage(
                        itemIds: heroFallbackIds,
                        maxWidth: 3840,
                        imageTypes: heroImageTypes,
                        contentMode: .fill
                    )
                    .id(currentItem.id)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.6), value: currentItem.id)

                    // Bottom gradient - Netflix style fade
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.3),
                            .init(color: SashimiTheme.background.opacity(0.4), location: 0.5),
                            .init(color: SashimiTheme.background.opacity(0.85), location: 0.75),
                            .init(color: SashimiTheme.background, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Left side gradient for text readability
                    HStack {
                        LinearGradient(
                            colors: [
                                SashimiTheme.background.opacity(0.9),
                                SashimiTheme.background.opacity(0.6),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 600)
                        Spacer()
                    }

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
                                if let dateStr = currentItem.premiereDate {
                                    Text(formatDate(dateStr))
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

                                if let runtime = currentItem.runTimeTicks {
                                    Text(formatRuntime(runtime))
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
                                .lineLimit(2)
                                .frame(maxWidth: 800, alignment: .leading)
                                .padding(.top, 4)
                        }

                        // Page indicators
                        if items.count > 1 {
                            HStack(spacing: 10) {
                                ForEach(0..<items.count, id: \.self) { index in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(.white.opacity(0.3))
                                            .frame(width: index == safeIndex ? 48 : 12, height: 5)
                                        if index == safeIndex {
                                            Capsule()
                                                .fill(.white)
                                                .frame(width: 48 * progress, height: 5)
                                        } else if index < safeIndex {
                                            Capsule()
                                                .fill(.white.opacity(0.7))
                                                .frame(width: 12, height: 5)
                                        }
                                    }
                                    .animation(.easeInOut(duration: 0.3), value: safeIndex)
                                }
                            }
                            .padding(.top, 16)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 50)
                }
            }
            .frame(height: 380)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(SashimiTheme.accent.opacity(isFocused ? 0.6 : 0), lineWidth: 4)
            )
            .padding(.horizontal, 50)
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double-tap to view details")
        .accessibilityAddTraits(.isButton)
        .onAppear {
            startAutoAdvance()
        }
        .onDisappear {
            stopAutoAdvance()
        }
        .onChange(of: currentIndex) { _, _ in
            progress = 0
        }
    }

    private func startAutoAdvance() {
        guard items.count > 1 else { return }
        progress = 0
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            DispatchQueue.main.async {
                progress += 0.1 / 6  // 6 seconds per item
                if progress >= 1.0 {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        currentIndex = (currentIndex + 1) % items.count
                    }
                    progress = 0
                }
            }
        }
    }

    private func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    private func formatRuntime(_ ticks: Int64) -> String {
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func formatEpisodeInfo(_ item: BaseItemDto) -> String {
        let season = item.parentIndexNumber ?? 1
        let episode = item.indexNumber ?? 1
        return "S\(season) E\(episode) • \(item.name)"
    }

    private func formatDate(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "MMMM d, yyyy"
            return displayFormatter.string(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "MMMM d, yyyy"
            return displayFormatter.string(from: date)
        }
        return ""
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
        "Recently Added \(library.name)"
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
                .frame(height: isYouTubeLibrary ? 220 : 340)
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
                .frame(height: isYouTubeLibrary ? 220 : 340)
            } else if items.isEmpty {
                HStack {
                    Spacer()
                    Text("No items")
                        .font(.headline)
                        .foregroundStyle(SashimiTheme.textTertiary)
                    Spacer()
                }
                .frame(height: isYouTubeLibrary ? 220 : 340)
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
                                isLandscape: isYouTubeLibrary,
                                badgeCount: (unplayedCount ?? 0) > 1 ? unplayedCount : nil
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
            // For TV libraries, fetch more items to ensure we get episodes from multiple series
            // even if one series had many episodes added recently
            let isTVLibrary = library.collectionType?.lowercased() == "tvshows"
            let fetchLimit = isTVLibrary && !isYouTubeLibrary ? 100 : 30

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

        // Fetch each series to get its unplayed count
        for seriesId in seriesIds {
            do {
                let series = try await JellyfinClient.shared.getItem(itemId: seriesId)
                if let unplayedCount = series.userData?.unplayedItemCount, unplayedCount > 0 {
                    counts[seriesId] = unplayedCount
                }
            } catch {
                // Ignore errors for individual series
            }
        }

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

#Preview {
    HomeView()
}
