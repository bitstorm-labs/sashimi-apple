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
    @State private var searchTask: Task<Void, Never>?
    @StateObject private var historyManager = SearchHistoryManager.shared

    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            VStack(spacing: 40) {
                Text("Search")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 80)
                    .padding(.top, 40)

                TextField("Search movies, shows...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(20)
                    .background(SashimiTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isSearchFieldFocused ? SashimiTheme.accent : Color.white.opacity(0.1), lineWidth: isSearchFieldFocused ? 3 : 1)
                    )
                    .focused($isSearchFieldFocused)
                    .padding(.horizontal, 80)
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

                                Button("Clear") {
                                    historyManager.clearHistory()
                                }
                                .font(Typography.body)
                                .foregroundStyle(SashimiTheme.accent)
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 80)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(historyManager.recentSearches, id: \.self) { query in
                                        Button {
                                            searchText = query
                                            historyManager.addSearch(query)
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: "clock.arrow.circlepath")
                                                    .foregroundStyle(SashimiTheme.textTertiary)
                                                Text(query)
                                                    .foregroundStyle(SashimiTheme.textPrimary)
                                            }
                                            .font(Typography.body)
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 12)
                                            .background(SashimiTheme.cardBackground)
                                            .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 80)
                            }
                        }
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 40)
                        ], spacing: 50) {
                            ForEach(results) { item in
                                MediaPosterButton(item: item) {
                                    selectedItem = item
                                }
                            }
                        }
                        .padding(.horizontal, 80)
                        .padding(.bottom, 60)
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedItem) { item in
            MediaDetailView(item: item)
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
    }

    private func performSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }

        isSearching = true

        do {
            results = try await JellyfinClient.shared.search(query: searchText)
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

#Preview {
    SearchView()
}
