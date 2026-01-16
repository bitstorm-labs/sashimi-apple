import SwiftUI

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
                                .padding(.bottom, -140)

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
                        showContinueWatchingDetail = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            selectedItemIsYouTube = false
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
                            selectedItemIsYouTube = false
                            selectedItem = item
                        }
                    )
                    .focusSection()
                }
            case .continueWatching:
                if !viewModel.continueWatchingItems.isEmpty {
                    ContinueWatchingRow(
                        items: viewModel.continueWatchingItems,
                        onSelect: { item in
                            selectedItemIsYouTube = false
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

    // Fallback image IDs for hero display
    private var heroFallbackIds: [String] {
        var ids: [String] = []
        if currentItem.type == .episode {
            // For episodes: try episode, then season, then series
            ids.append(currentItem.id)
            if let seasonId = currentItem.seasonId {
                ids.append(seasonId)
            }
            if let seriesId = currentItem.seriesId {
                ids.append(seriesId)
            }
        } else {
            ids.append(currentItem.id)
        }
        return ids
    }

    // Image types to try for hero (landscape preference)
    private var heroImageTypes: [String] {
        return ["Backdrop", "Primary", "Thumb"]
    }

    // Detect YouTube content by checking library name
    private var isYouTubeContent: Bool {
        guard let libraryName = libraryNames[currentItem.id] else { return false }
        return libraryName.lowercased().contains("youtube")
    }

    // Display label for content type
    private var contentTypeLabel: String {
        if isYouTubeContent {
            return "YouTube"
        }
        return currentItem.type?.rawValue.uppercased() ?? ""
    }

    // VoiceOver accessibility description
    private var accessibilityDescription: String {
        var parts: [String] = []

        if currentItem.type == .episode {
            parts.append(currentItem.seriesName ?? currentItem.name)
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
            ZStack(alignment: .bottomLeading) {
                SmartPosterImage(
                    itemIds: heroFallbackIds,
                    maxWidth: 1920,
                    imageTypes: heroImageTypes,
                    contentMode: .fit
                )
                .id(currentItem.id)
                .frame(maxWidth: .infinity)
                .frame(height: 420)
                .background(Color.black)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.5), value: currentItem.id)

                // Gradient overlay
                LinearGradient(
                    colors: [
                        .clear,
                        .clear,
                        SashimiTheme.background.opacity(0.7),
                        SashimiTheme.background
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Vignette sides
                HStack {
                    LinearGradient(
                        colors: [SashimiTheme.background.opacity(0.8), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 300)
                    Spacer()
                }


                // Content
                VStack(alignment: .leading, spacing: 16) {
                    if !contentTypeLabel.isEmpty {
                        Text(contentTypeLabel)
                            .font(.system(size: 16, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(SashimiTheme.accent)
                    }

                    Text(currentItem.type == .episode ? (currentItem.seriesName ?? currentItem.name) : currentItem.name)
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 3)

                    if currentItem.type == .episode {
                        Text(formatEpisodeInfo(currentItem))
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(SashimiTheme.textSecondary)
                    }

                    HStack(spacing: 14) {
                        if let year = currentItem.productionYear {
                            Text(String(year))
                                .foregroundStyle(SashimiTheme.textSecondary)
                        }

                        if let runtime = currentItem.runTimeTicks {
                            Text(formatRuntime(runtime))
                                .foregroundStyle(SashimiTheme.textSecondary)
                        }

                        if let rating = currentItem.communityRating {
                            HStack(spacing: 6) {
                                Image("TMDBLogo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 26)
                                Text(String(format: "%.1f", rating))
                                    .foregroundStyle(SashimiTheme.textPrimary)
                            }
                        }
                    }
                    .font(.system(size: 22))

                    if let overview = currentItem.overview {
                        Text(overview)
                            .font(.system(size: 20))
                            .foregroundStyle(SashimiTheme.textSecondary)
                            .lineLimit(2)
                            .frame(maxWidth: 700, alignment: .leading)
                    }

                    // Page indicators with progress
                    if items.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(0..<items.count, id: \.self) { index in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(SashimiTheme.textTertiary.opacity(0.5))
                                        .frame(width: index == safeIndex ? 36 : 10, height: 4)
                                    if index == safeIndex {
                                        Capsule()
                                            .fill(SashimiTheme.accent)
                                            .frame(width: 36 * progress, height: 4)
                                    } else if index < safeIndex {
                                        Capsule()
                                            .fill(SashimiTheme.accent)
                                            .frame(width: 10, height: 4)
                                    }
                                }
                                .frame(width: index == safeIndex ? 36 : 10, height: 4)
                                .animation(.easeInOut(duration: 0.3), value: safeIndex)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 35)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(SashimiTheme.accent.opacity(isFocused ? 0.8 : 0), lineWidth: 4)
            )
            .shadow(color: SashimiTheme.accent.opacity(isFocused ? 0.4 : 0), radius: 20)
            .padding(.horizontal, 40)
            .scaleEffect(isFocused ? 1.02 : 1.0)
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
            // Reset progress when index changes
            progress = 0
        }
    }

    private func startAutoAdvance() {
        guard items.count > 1 else { return }
        progress = 0
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            DispatchQueue.main.async {
                progress += 0.1 / 5  // 5 seconds total
                if progress >= 1.0 {
                    withAnimation(.easeInOut(duration: 0.5)) {
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
                            let count = episodeCounts[key] ?? 1
                            MediaPosterButton(
                                item: item,
                                libraryType: library.collectionType,
                                libraryName: library.name,
                                isLandscape: isYouTubeLibrary,
                                badgeCount: count > 1 ? count : nil
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
            let (dedupedItems, counts) = deduplicateBySeries(latestItems)
            items = dedupedItems
            episodeCounts = counts
        } catch is CancellationError {
            // Ignore cancellation errors - expected during navigation
        } catch {
            loadError = true
        }

        isLoading = false
    }

    private func deduplicateBySeries(_ items: [BaseItemDto]) -> (items: [BaseItemDto], counts: [String: Int]) {
        var counts: [String: Int] = [:]
        var seen = Set<String>()
        var result: [BaseItemDto] = []

        // First pass: count episodes per series
        for item in items {
            let key = item.type == .episode ? (item.seriesId ?? item.id) : item.id
            counts[key, default: 0] += 1
        }

        // Second pass: deduplicate
        for item in items {
            let key = item.type == .episode ? (item.seriesId ?? item.id) : item.id
            if !seen.contains(key) {
                seen.insert(key)
                result.append(item)
            }
        }

        return (Array(result.prefix(20)), counts)
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
