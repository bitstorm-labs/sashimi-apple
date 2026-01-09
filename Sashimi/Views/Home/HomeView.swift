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
    @State private var selectedItem: BaseItemDto?
    @State private var selectedItemIsYouTube: Bool = false
    @State private var refreshTimer: Timer?
    @State private var heroIndex: Int = 0
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
                            // Logo at top-left
                            HStack(spacing: 16) {
                                Image("Logo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 120)

                                Text("Sashimi")
                                    .font(.system(size: 56, weight: .bold))
                                    .foregroundStyle(SashimiTheme.textPrimary)
                            }
                            .id("top")

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
            .onChange(of: selectedItem) { oldValue, newValue in
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
    }

    @ViewBuilder
    private func rowView(for config: HomeRowConfig) -> some View {
        if let type = config.type {
            switch type {
            case .hero:
                if !viewModel.heroItems.isEmpty {
                    HeroSection(
                        items: viewModel.heroItems,
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
    @Binding var currentIndex: Int
    let onSelect: (BaseItemDto) -> Void

    @FocusState private var isFocused: Bool
    @State private var autoScrollTimer: Timer?

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

    private func startAutoScroll() {
        autoScrollTimer?.invalidate()
        guard items.count > 1 else { return }
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.6)) {
                currentIndex = (currentIndex + 1) % items.count
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
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
                    if let type = currentItem.type {
                        Text(type.rawValue.uppercased())
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

                    if items.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(0..<items.count, id: \.self) { index in
                                Capsule()
                                    .fill(index == currentIndex ? SashimiTheme.accent : SashimiTheme.textTertiary)
                                    .frame(width: index == currentIndex ? 26 : 10, height: 4)
                                    .animation(.easeInOut(duration: 0.3), value: currentIndex)
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
                        .stroke(Color.white.opacity(isFocused ? 0.6 : 0), lineWidth: 2)
            )
            .padding(.horizontal, 40)
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .onMoveCommand { direction in
            guard items.count > 1 else { return }
            switch direction {
            case .left:
                withAnimation(.easeInOut(duration: 0.4)) {
                    currentIndex = (currentIndex - 1 + items.count) % items.count
                }
                startAutoScroll()
            case .right:
                withAnimation(.easeInOut(duration: 0.4)) {
                    currentIndex = (currentIndex + 1) % items.count
                }
                startAutoScroll()
            default:
                break
            }
        }
        .onAppear {
            startAutoScroll()
        }
        .onDisappear {
            stopAutoScroll()
        }
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
        // Skip if already loaded successfully
        guard items.isEmpty else { return }

        isLoading = true
        loadError = false

        do {
            let latestItems = try await JellyfinClient.shared.getLatestMedia(parentId: library.id, limit: 30)
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
