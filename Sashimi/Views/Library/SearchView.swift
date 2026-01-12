import SwiftUI
import os

private let logger = Logger(subsystem: "com.sashimi.app", category: "Search")

// MARK: - Search History Manager

@MainActor
final class SearchHistoryManager: ObservableObject {
    static let shared = SearchHistoryManager()

    @Published private(set) var recentSearches: [String] = []
    private let maxHistory = 10
    private let userDefaultsKey = "searchHistory"

    private init() {
        loadHistory()
    }

    private func loadHistory() {
        recentSearches = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
    }

    func addSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Remove if already exists (we'll re-add at top)
        recentSearches.removeAll { $0.lowercased() == trimmed.lowercased() }

        // Add to beginning
        recentSearches.insert(trimmed, at: 0)

        // Trim to max
        if recentSearches.count > maxHistory {
            recentSearches = Array(recentSearches.prefix(maxHistory))
        }

        saveHistory()
    }

    func removeSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
        saveHistory()
    }

    func clearHistory() {
        recentSearches = []
        saveHistory()
    }

    private func saveHistory() {
        UserDefaults.standard.set(recentSearches, forKey: userDefaultsKey)
    }
}

struct SearchView: View {
    var onBackAtRoot: (() -> Void)?
    @State private var searchText = ""
    @State private var results: [BaseItemDto] = []
    @State private var isSearching = false
    @State private var selectedItem: BaseItemDto?
    @State private var selectedItemIsYouTube = false
    @State private var searchTask: Task<Void, Never>?
    @State private var youtubeLibraryIds: Set<String> = []
    @State private var youtubeItemIds: Set<String> = []
    @StateObject private var historyManager = SearchHistoryManager.shared

    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isClearButtonFocused: Bool

    init(onBackAtRoot: (() -> Void)? = nil) {
        self.onBackAtRoot = onBackAtRoot
    }

    // Detect YouTube content by checking if we've identified it as YouTube
    private func isYouTubeStyle(_ item: BaseItemDto) -> Bool {
        if item.type == .video { return true }
        // Check if this specific item was identified as YouTube
        if youtubeItemIds.contains(item.id) {
            return true
        }
        // Check if the item belongs to a known YouTube library
        if let parentId = item.parentId, youtubeLibraryIds.contains(parentId) {
            return true
        }
        // Also check if "youtube" appears in the file path
        if let path = item.path?.lowercased(), path.contains("youtube") {
            return true
        }
        return false
    }

    private func loadYouTubeLibraryIds() async {
        // Will be populated dynamically when we check item ancestors
    }

    private func detectYouTubeItems(for items: [BaseItemDto]) async {
        // For each Series item, check if any ancestor has "youtube" in the name
        for item in items where item.type == .series {
            // Skip if we already know this item is YouTube
            if youtubeItemIds.contains(item.id) {
                continue
            }

            do {
                let ancestors = try await JellyfinClient.shared.getItemAncestors(itemId: item.id)
                // Check if any ancestor has "youtube" in the name (the library folder)
                for ancestor in ancestors {
                    if ancestor.name.lowercased().contains("youtube") {
                        // Mark this item as YouTube
                        youtubeItemIds.insert(item.id)
                        // Store the ancestor's ID for future matches
                        youtubeLibraryIds.insert(ancestor.id)
                        if let parentId = item.parentId {
                            youtubeLibraryIds.insert(parentId)
                        }
                        break
                    }
                }
            } catch {
                // Ignore - ancestors might not be accessible
            }
        }
    }

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Search field at top with clear button
                HStack(spacing: 16) {
                    TextField("Search movies, shows...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.title3)

                    // Clear button - show when there's text OR results
                    if !searchText.isEmpty || !results.isEmpty {
                        Button {
                            searchText = ""
                            results = []
                            youtubeItemIds = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(isClearButtonFocused ? SashimiTheme.accent : SashimiTheme.textTertiary)
                                .scaleEffect(isClearButtonFocused ? 1.2 : 1.0)
                                .animation(.spring(response: 0.3), value: isClearButtonFocused)
                        }
                        .buttonStyle(PlainNoHighlightButtonStyle())
                        .focused($isClearButtonFocused)
                    }
                }
                .padding(20)
                .background(SashimiTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isSearchFieldFocused ? SashimiTheme.accent : Color.white.opacity(0.1), lineWidth: isSearchFieldFocused ? 3 : 1)
                )
                .focused($isSearchFieldFocused)
                .padding(.horizontal, 80)
                .padding(.top, 60)
                .padding(.bottom, 30)
                .onChange(of: searchText) { _, _ in
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        if !Task.isCancelled {
                            await performSearch()
                        }
                    }
                }
                .onSubmit {
                    if !searchText.isEmpty {
                        historyManager.addSearch(searchText)
                    }
                }

                // Results area
                if isSearching {
                    Spacer()
                    ProgressView()
                        .tint(SashimiTheme.accent)
                        .scaleEffect(1.5)
                    Spacer()
                } else if results.isEmpty && !searchText.isEmpty {
                    Spacer()
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No results found",
                        message: "Try a different search term"
                    )
                    Spacer()
                } else if results.isEmpty {
                    // Show search history or empty state
                    if historyManager.recentSearches.isEmpty {
                        Spacer()
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "Search your library",
                            message: "Find movies and TV shows"
                        )
                        Spacer()
                    } else {
                        // Recent searches
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Text("Recent Searches")
                                    .font(Typography.headlineSmall)
                                    .foregroundStyle(SashimiTheme.textPrimary)

                                Spacer()

                                Button("Clear History") {
                                    historyManager.clearHistory()
                                }
                                .font(Typography.body)
                                .foregroundStyle(SashimiTheme.accent)
                            }
                            .padding(.horizontal, 80)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(historyManager.recentSearches, id: \.self) { query in
                                        RecentSearchButton(query: query) {
                                            searchText = query
                                            historyManager.addSearch(query)
                                        }
                                    }
                                }
                                .padding(.horizontal, 80)
                                .padding(.vertical, 20)
                            }
                            .focusSection()
                        }
                        Spacer()
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // Results count
                            Text("\(results.count) results")
                                .font(.subheadline)
                                .foregroundStyle(SashimiTheme.textTertiary)
                                .padding(.horizontal, 80)
                                .padding(.top, 20)

                            LazyVGrid(columns: [
                                GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 40)
                            ], spacing: 50) {
                                ForEach(results) { item in
                                    MediaPosterButton(
                                        item: item,
                                        isCircular: isYouTubeStyle(item)
                                    ) {
                                        // Compute at tap time to ensure current state
                                        selectedItemIsYouTube = isYouTubeStyle(item)
                                        selectedItem = item
                                    }
                                }
                            }
                            .padding(.horizontal, 80)
                            .padding(.bottom, 100)
                        }
                    }
                    .focusSection()
                }
            }
        }
        .fullScreenCover(item: $selectedItem) { item in
            MediaDetailView(item: item, forceYouTubeStyle: selectedItemIsYouTube)
        }
        .onExitCommand {
            if !searchText.isEmpty {
                // Clear search first
                searchText = ""
                results = []
            } else {
                // At root with empty search
                onBackAtRoot?()
            }
        }
        .task {
            await loadYouTubeLibraryIds()
        }
    }

    private func performSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }

        isSearching = true

        do {
            let searchResults = try await JellyfinClient.shared.search(query: searchText)
            // Detect YouTube items by checking ancestors for "YouTube" library
            await detectYouTubeItems(for: searchResults)
            results = searchResults
            // Add to history on successful search
            if !results.isEmpty {
                historyManager.addSearch(searchText)
            }
        } catch {
            logger.error("Search failed: \(error.localizedDescription)")
            ToastManager.shared.show("Search failed. Try again.")
        }

        isSearching = false
    }
}

// MARK: - Recent Search Button
struct RecentSearchButton: View {
    let query: String
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(isFocused ? SashimiTheme.accent : SashimiTheme.textTertiary)
                Text(query)
                    .foregroundStyle(isFocused ? .white : SashimiTheme.textPrimary)
            }
            .font(Typography.body)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(isFocused ? SashimiTheme.accent.opacity(0.3) : SashimiTheme.cardBackground)
            .clipShape(Capsule())
            .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .hoverEffect(.lift)
        .focused($isFocused)
    }
}

#Preview {
    SearchView()
}
