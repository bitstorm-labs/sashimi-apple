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
    @State private var searchText = ""
    @State private var searchResults: [BaseItemDto] = []
    @State private var isSearching = false
    @State private var recentSearches: [String] = RecentSearches.load()
    // Only commit a query to history after the user pauses typing on a query
    // that returned results (avoids logging every keystroke prefix).
    @State private var historyTask: Task<Void, Never>?

    var body: some View {
        List {
            if searchText.isEmpty {
                if recentSearches.isEmpty {
                    ContentUnavailableView(
                        "Search",
                        systemImage: "magnifyingglass",
                        description: Text("Search for movies, shows, and more.")
                    )
                } else {
                    Section {
                        ForEach(recentSearches, id: \.self) { query in
                            Button {
                                searchText = query
                            } label: {
                                Label(query, systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(MobileColors.textPrimary)
                            }
                        }
                        Button {
                            recentSearches = RecentSearches.clear()
                        } label: {
                            Text("Clear Recent Searches")
                                .foregroundStyle(MobileColors.link)
                        }
                    } header: {
                        Text("Recent Searches")
                    }
                }
            } else if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if searchResults.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No results found for \"\(searchText)\"")
                )
            } else {
                ForEach(searchResults, id: \.id) { item in
                    NavigationLink {
                        AdaptiveDetailView(item: item)
                    } label: {
                        SearchResultRow(item: item)
                    }
                }
            }
        }
        .listStyle(.plain)
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

private struct SearchResultRow: View {
    let item: BaseItemDto

    private var posterURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=200")
    }

    private func iconForType(_ type: ItemType) -> String {
        switch type {
        case .movie:
            return "film"
        case .series:
            return "tv"
        case .episode:
            return "play.rectangle"
        case .season:
            return "tv"
        case .boxSet:
            return "square.stack"
        default:
            return "photo"
        }
    }

    var body: some View {
        HStack(spacing: MobileSpacing.sm) {
            LazyImage(url: posterURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: MobileCornerRadius.small)
                        .fill(MobileColors.cardBackground)
                        .overlay {
                            Image(systemName: iconForType(item.type ?? .unknown))
                                .font(.system(size: 20))
                                .foregroundStyle(MobileColors.textTertiary)
                        }
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))

            VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
                Text(item.name)
                    .font(MobileTypography.title)
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(2)

                if let year = item.productionYear {
                    Text(String(year))
                        .font(MobileTypography.bodySmall)
                        .foregroundStyle(MobileColors.textSecondary)
                }

                if let type = item.type {
                    Label(type.rawValue.capitalized, systemImage: iconForType(type))
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, MobileSpacing.xxs)
    }
}
