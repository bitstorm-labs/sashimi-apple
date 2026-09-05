import NukeUI
import SwiftUI

/// Last-10 search queries, persisted to UserDefaults (tvOS/Roku parity).
private enum RecentSearches {
    private static let key = "recentSearches"
    private static let maxCount = 10

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }
        var list = load().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        list = Array(list.prefix(maxCount))
        UserDefaults.standard.set(list, forKey: key)
        return list
    }

    static func clear() -> [String] {
        UserDefaults.standard.removeObject(forKey: key)
        return []
    }
}

struct MobileSearchView: View {
    private let initialQuery: String?
    private let onInitialQueryConsumed: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var searchText = ""
    @State private var searchResults: [ServerMediaResultGroup] = []
    @State private var isSearching = false
    @State private var selectedGroup: ServerMediaResultGroup?
    @State private var selectedSource: ServerMediaResult?
    @State private var searchServerWarning: String?
    @State private var recentSearches: [String] = RecentSearches.load()
    @State private var searchTask: Task<Void, Never>?
    @State private var isApplyingInitialQuery = false
    // Only commit a query to history after the user pauses typing on a query
    // that returned results (avoids logging every keystroke prefix).
    @State private var historyTask: Task<Void, Never>?

    init(initialQuery: String? = nil, onInitialQueryConsumed: (() -> Void)? = nil) {
        self.initialQuery = initialQuery
        self.onInitialQueryConsumed = onInitialQueryConsumed
        _searchText = State(
            initialValue: SashimiMediaSearchQuery.normalizedTerm(initialQuery ?? "")
        )
    }

    // Same column math as MobileLibraryBrowseView so search results read as
    // the same surface as library browsing.
    private func gridMetrics(availableWidth: CGFloat) -> (columns: [GridItem], cardWidth: CGFloat) {
        let spacing = MobileSpacing.md
        let avail = availableWidth - spacing * 2
        let target: CGFloat = sizeClass == .compact ? 118 : 165
        let count = max(2, Int((avail + spacing) / (target + spacing)))
        let cardWidth = floor((avail - spacing * CGFloat(count - 1)) / CGFloat(count))
        let cols = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: count)
        return (cols, cardWidth)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                if searchText.isEmpty {
                    if recentSearches.isEmpty {
                        ContentUnavailableView(
                            "Search",
                            systemImage: "magnifyingglass",
                            description: Text("Search for movies, shows, and more.")
                        )
                        .frame(minHeight: 300)
                    } else {
                        recentSearchesSection
                    }
                } else if isSearching && searchResults.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if searchResults.isEmpty {
                    Group {
                        if let searchServerWarning {
                            ContentUnavailableView(
                                "Servers Unavailable",
                                systemImage: "server.rack",
                                description: Text(searchServerWarning)
                            )
                        } else {
                            ContentUnavailableView(
                                "No Results",
                                systemImage: "magnifyingglass",
                                description: Text("No results found for \"\(searchText)\"")
                            )
                        }
                    }
                    .frame(minHeight: 300)
                } else {
                    resultsGrid(metrics: gridMetrics(availableWidth: geo.size.width))
                }
            }
        }
        .background(MobileColors.background)
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Movies, shows, and more")
        .fullScreenCover(item: $selectedSource) { source in
            NavigationStack {
                ServerScopedMediaDetailView(source: source)
            }
        }
        .sheet(item: $selectedGroup) { group in
            ServerMediaSourcePickerView(group: group) { source in
                selectedSource = source
            }
        }
        .onChange(of: searchText) { _, newValue in
            guard !isApplyingInitialQuery else { return }
            searchTask?.cancel()
            let query = newValue
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await performSearch(query: query)
            }
            // Debounced history commit: only record queries the user settled
            // on (1.5s pause) that produced results.
            historyTask?.cancel()
            historyTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled,
                      searchText == query,
                      !query.isEmpty,
                      !searchResults.isEmpty else { return }
                recentSearches = RecentSearches.add(query)
            }
        }
        .task(id: initialQuery) {
            guard let initialQuery, !initialQuery.isEmpty else { return }
            let normalizedQuery = SashimiMediaSearchQuery.normalizedTerm(initialQuery)
            guard !normalizedQuery.isEmpty else {
                onInitialQueryConsumed?()
                return
            }

            isApplyingInitialQuery = searchText != normalizedQuery
            if isApplyingInitialQuery {
                searchText = normalizedQuery
            }
            defer {
                isApplyingInitialQuery = false
                // A canceled task must still acknowledge the one-shot route;
                // otherwise a recreated search view replays the same request.
                onInitialQueryConsumed?()
            }
            await performSearch(query: normalizedQuery)
            guard !Task.isCancelled else { return }
        }
        .onDisappear {
            searchTask?.cancel()
            historyTask?.cancel()
            // Covers a view that disappears before its .task is scheduled.
            onInitialQueryConsumed?()
        }
    }

    // MARK: - Recent searches (chips)

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("Recent Searches")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MobileSpacing.xs) {
                    ForEach(recentSearches, id: \.self) { query in
                        Button {
                            searchText = query
                        } label: {
                            Label(query, systemImage: "clock.arrow.circlepath")
                                .font(MobileTypography.bodySmall)
                                .foregroundStyle(MobileColors.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(MobileColors.cardBackground)
                                .clipShape(Capsule())
                        }
                    }

                    Button {
                        recentSearches = RecentSearches.clear()
                    } label: {
                        Text("Clear")
                            .font(MobileTypography.bodySmall)
                            .foregroundStyle(MobileColors.link)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .overlay(Capsule().stroke(MobileColors.cardBackground, lineWidth: 1))
                    }
                }
            }
        }
        .padding(.horizontal, MobileSpacing.md)
        .padding(.top, MobileSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Results grid

    private func resultsGrid(metrics: (columns: [GridItem], cardWidth: CGFloat)) -> some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text(searchResults.count == 1 ? "1 result" : "\(searchResults.count) results")
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textTertiary)
                .padding(.horizontal, MobileSpacing.md)

            if let searchServerWarning {
                Label(searchServerWarning, systemImage: "exclamationmark.triangle")
                    .font(MobileTypography.captionSmall)
                    .foregroundStyle(MobileColors.textSecondary)
                    .padding(.horizontal, MobileSpacing.md)
            }

            LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: MobileSpacing.md) {
                ForEach(searchResults) { result in
                    VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                        Button {
                            select(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                MobileRecentlyAddedCard(
                                    item: result.primary.item,
                                    width: metrics.cardWidth,
                                    libraryName: result.primary.item.libraryName,
                                    isCircular: result.primary.item.libraryName?
                                        .localizedCaseInsensitiveContains("youtube") == true,
                                    isLandscape: false,
                                    badgeCount: nil,
                                    serverURL: result.primary.serverURL,
                                    serverID: result.primary.serverID
                                )
                                Text(subtitleText(result.primary.item))
                                    .font(MobileTypography.captionSmall)
                                    .foregroundStyle(MobileColors.textTertiary)
                                    .lineLimit(1)
                            }
                            .frame(width: metrics.cardWidth)
                        }
                        .buttonStyle(.plain)

                        ServerAvailabilityBadgeView(sources: result.sources)
                            .frame(width: metrics.cardWidth, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, MobileSpacing.md)
        }
        .padding(.top, MobileSpacing.xs)
    }

    /// "2024 · Movie" secondary line under each result card.
    private func subtitleText(_ item: BaseItemDto) -> String {
        var parts: [String] = []
        if let year = item.displayYear { parts.append(String(year)) }
        if let type = item.type {
            switch type {
            case .movie: parts.append("Movie")
            case .series: parts.append("Series")
            case .episode: parts.append("Episode")
            case .boxSet: parts.append("Collection")
            default: break
            }
        }
        return parts.joined(separator: " · ")
    }

    private func performSearch(query: String) async {
        guard !query.isEmpty else {
            if searchText == query {
                searchResults = []
                searchServerWarning = nil
                isSearching = false
            }
            return
        }

        guard searchText == query else { return }

        isSearching = true
        searchServerWarning = nil
        defer {
            if searchText == query {
                isSearching = false
            }
        }

        let search = await MultiServerSearchService.searchWithStatus(query: query, limit: 50)
        guard !Task.isCancelled, searchText == query else { return }
        let activeServerID = await MainActor.run { SessionManager.shared.activeServerId }
        searchResults = ServerMediaResultGrouping.groups(
            from: search.results,
            preferredServerID: activeServerID
        )
        searchServerWarning = search.hasServerFailures
            ? "Some saved servers could not be reached. Results may be incomplete."
            : nil
    }

    private func select(_ group: ServerMediaResultGroup) {
        if group.sources.count == 1, let source = group.sources.first {
            selectedSource = source
        } else {
            selectedGroup = group
        }
    }
}
