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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var searchText = ""
    @State private var searchResults: [BaseItemDto] = []
    @State private var isSearching = false
    @State private var recentSearches: [String] = RecentSearches.load()
    // Only commit a query to history after the user pauses typing on a query
    // that returned results (avoids logging every keystroke prefix).
    @State private var historyTask: Task<Void, Never>?

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
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No results found for \"\(searchText)\"")
                    )
                    .frame(minHeight: 300)
                } else {
                    resultsGrid(metrics: gridMetrics(availableWidth: geo.size.width))
                }
            }
        }
        .background(MobileColors.background)
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Movies, shows, and more")
        .onChange(of: searchText) { _, newValue in
            Task {
                await performSearch(query: newValue)
            }
            // Debounced history commit: only record queries the user settled
            // on (1.5s pause) that produced results.
            historyTask?.cancel()
            let query = newValue
            historyTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, !query.isEmpty, !searchResults.isEmpty else { return }
                recentSearches = RecentSearches.add(query)
            }
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

            LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: MobileSpacing.md) {
                ForEach(searchResults, id: \.id) { item in
                    NavigationLink {
                        AdaptiveDetailView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            MobileRecentlyAddedCard(
                                item: item,
                                width: metrics.cardWidth,
                                libraryName: nil,
                                isCircular: false,
                                isLandscape: false,
                                badgeCount: nil
                            )
                            Text(subtitleText(item))
                                .font(MobileTypography.captionSmall)
                                .foregroundStyle(MobileColors.textTertiary)
                                .lineLimit(1)
                        }
                        .frame(width: metrics.cardWidth)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MobileSpacing.md)
        }
        .padding(.top, MobileSpacing.xs)
    }

    /// "2024 · Movie" secondary line under each result card.
    private func subtitleText(_ item: BaseItemDto) -> String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
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
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            searchResults = try await JellyfinClient.shared.search(query: query, limit: 50)
        } catch {
            searchResults = []
        }
    }
}
