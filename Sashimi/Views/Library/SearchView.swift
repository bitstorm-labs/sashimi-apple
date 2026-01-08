import SwiftUI
import os

private let logger = Logger(subsystem: "com.sashimi.app", category: "Search")

private enum SashimiTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let cardBackground = Color(white: 0.12)
    static let accent = Color(red: 0.36, green: 0.68, blue: 0.90)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.65)
    static let textTertiary = Color(white: 0.45)
}

struct SearchView: View {
    var onBackAtRoot: (() -> Void)?
    @State private var searchText = ""
    @State private var results: [BaseItemDto] = []
    @State private var isSearching = false
    @State private var selectedItem: BaseItemDto?
    @State private var searchTask: Task<Void, Never>?

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

                if isSearching {
                    Spacer()
                    ProgressView()
                        .tint(SashimiTheme.accent)
                        .scaleEffect(1.5)
                    Spacer()
                } else if results.isEmpty && !searchText.isEmpty {
                    Spacer()
                    VStack(spacing: 20) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundStyle(SashimiTheme.textTertiary)

                        Text("No results found")
                            .font(.title3)
                            .foregroundStyle(SashimiTheme.textSecondary)

                        Text("Try a different search term")
                            .font(.body)
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    VStack(spacing: 20) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundStyle(SashimiTheme.textTertiary)

                        Text("Search your library")
                            .font(.title3)
                            .foregroundStyle(SashimiTheme.textSecondary)

                        Text("Find movies and TV shows")
                            .font(.body)
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
                    Spacer()
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
