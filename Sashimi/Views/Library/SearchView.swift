import SwiftUI

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

// MARK: - Result grouping

/// One titled section of search results (e.g. "Movies"), rendered as a row.
struct SearchResultGroup: Identifiable {
    let id: String
    let title: String
    let items: [ServerMediaResultGroup]
}

enum SearchResultGrouping {
    /// Splits a flat result list into ordered, Plex-style sections — Movies
    /// then TV Shows — dropping empty sections and preserving each item's
    /// server order. Anything the server returns that isn't a Movie or Series
    /// (defensive: today's query asks only for those two) collects into a
    /// trailing "Other" section so nothing is silently dropped.
    static func groups(from items: [ServerMediaResultGroup]) -> [SearchResultGroup] {
        let ordered: [(title: String, type: ItemType)] = [
            ("Movies", .movie),
            ("TV Shows", .series)
        ]
        var groups = ordered.compactMap { entry -> SearchResultGroup? in
            let matching = items.filter { $0.primary.item.type == entry.type }
            guard !matching.isEmpty else { return nil }
            return SearchResultGroup(id: entry.title, title: entry.title, items: matching)
        }

        let placed: Set<ItemType> = [.movie, .series]
        let others = items.filter { !placed.contains($0.primary.item.type ?? .unknown) }
        if !others.isEmpty {
            groups.append(SearchResultGroup(id: "Other", title: "Other", items: others))
        }
        return groups
    }
}

// MARK: - Search View

struct SearchView: View {
    var onBackAtRoot: (() -> Void)?
    /// Supplied by the rail so the keyboard can claim default focus in the
    /// shared main scope — without it, pressing Right from the Search rail row
    /// has no designated target and focus never enters this screen.
    var focusNamespace: Namespace.ID?
    @State private var searchText = ""
    @State private var results: [ServerMediaResultGroup] = []
    @State private var isSearching = false
    @State private var selectedSource: ServerMediaResult?
    @State private var searchTask: Task<Void, Never>?
    @StateObject private var historyManager = SearchHistoryManager.shared

    init(onBackAtRoot: (() -> Void)? = nil, focusNamespace: Namespace.ID? = nil) {
        self.onBackAtRoot = onBackAtRoot
        self.focusNamespace = focusNamespace
    }

    private var groups: [SearchResultGroup] {
        SearchResultGrouping.groups(from: results)
    }

    // Detect YouTube content by checking if we've identified it as YouTube
    private func isYouTubeStyle(_ item: BaseItemDto) -> Bool {
        if let path = item.path?.lowercased(), path.contains("youtube") { return true }
        return false
    }

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            HStack(spacing: 0) {
                keyboardPanel
                    .frame(width: 640)
                    .focusSection()

                resultsPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()
            }
        }
        .fullScreenCover(item: $selectedSource) { source in
            NavigationStack {
                ServerScopedTVDetailView(
                    source: source,
                    forceYouTubeStyle: isYouTubeStyle(source.item)
                )
            }
        }
        .onChange(of: searchText) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled {
                    await performSearch()
                }
            }
        }
        .onExitCommand {
            if !searchText.isEmpty {
                // Back clears the query before leaving the screen.
                searchText = ""
                results = []
            } else {
                onBackAtRoot?()
            }
        }
    }

    // MARK: Left panel — query, keyboard, recents

    private var keyboardPanel: some View {
        VStack(alignment: .leading, spacing: 28) {
            QueryDisplayView(text: searchText)

            TVSearchKeyboard(
                defaultFocusNamespace: focusNamespace,
                onCharacter: { character in
                    searchText.append(character)
                },
                onDelete: {
                    if !searchText.isEmpty { searchText.removeLast() }
                }
            )

            if searchText.isEmpty && !historyManager.recentSearches.isEmpty {
                recentSearchesSection
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 60)
    }

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("RECENT")
                    .font(.caption.weight(.bold))
                    .kerning(1.2)
                    .foregroundStyle(SashimiTheme.textTertiary)
                Spacer()
                Button("Clear") {
                    historyManager.clearHistory()
                }
                .font(Typography.caption)
                .foregroundStyle(SashimiTheme.accent)
                .buttonStyle(.plain)
            }

            ForEach(historyManager.recentSearches.prefix(5), id: \.self) { query in
                RecentSearchButton(query: query) {
                    searchText = query
                    historyManager.addSearch(query)
                }
            }
        }
    }

    // MARK: Right panel — live results

    @ViewBuilder
    private var resultsPanel: some View {
        if isSearching && results.isEmpty {
            centeredMessage { ProgressView().tint(SashimiTheme.accent).scaleEffect(1.5) }
        } else if searchText.isEmpty {
            centeredMessage {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Search your library",
                    message: "Find movies and TV shows"
                )
            }
        } else if results.isEmpty {
            centeredMessage {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results found",
                    message: "Try a different search term"
                )
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    Text("\(results.count) result\(results.count == 1 ? "" : "s") for \u{201C}\(searchText)\u{201D}")
                        .font(.subheadline)
                        .foregroundStyle(SashimiTheme.textTertiary)
                        .padding(.horizontal, 60)

                    ForEach(groups) { group in
                        SearchResultRow(
                            group: group,
                            isYouTube: isYouTubeStyle,
                            onSelect: { source in
                                selectedSource = source
                            }
                        )
                    }
                }
                .padding(.top, 60)
                .padding(.bottom, 100)
            }
        }
    }

    private func centeredMessage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Search

    private func performSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        let serverResults = await MultiServerSearchService.search(query: searchText)
        let activeServerID = await MainActor.run { SessionManager.shared.activeServerId }
        // A search cancelled by the next keystroke must not publish its
        // results or clear the spinner — otherwise a slow older query that
        // finishes late overwrites the newer one's results.
        guard !Task.isCancelled else { return }
        results = ServerMediaResultGrouping.groups(
            from: serverResults,
            preferredServerID: activeServerID
        )
        if !results.isEmpty {
            historyManager.addSearch(searchText)
        }
    }
}

// MARK: - Query display

private struct QueryDisplayView: View {
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(text.isEmpty ? SashimiTheme.textTertiary : SashimiTheme.textPrimary)

            Text(text.isEmpty ? "Search" : text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(text.isEmpty ? SashimiTheme.textTertiary : SashimiTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)

            if !text.isEmpty {
                Rectangle()
                    .fill(SashimiTheme.accentSecondary)
                    .frame(width: 2, height: 26)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(SashimiTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SashimiTheme.accent, lineWidth: 2)
        )
    }
}

// MARK: - On-screen keyboard

/// A persistent grid keyboard, the heart of the Plex-style search: it stays on
/// screen so results update live beside it, instead of the system keyboard that
/// covers everything until you finish typing.
private struct TVSearchKeyboard: View {
    var defaultFocusNamespace: Namespace.ID?
    let onCharacter: (Character) -> Void
    let onDelete: () -> Void

    private let rows: [[Character]] = [
        ["A", "B", "C", "D", "E", "F"],
        ["G", "H", "I", "J", "K", "L"],
        ["M", "N", "O", "P", "Q", "R"],
        ["S", "T", "U", "V", "W", "X"],
        ["Y", "Z", "0", "1", "2", "3"],
        ["4", "5", "6", "7", "8", "9"]
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 10) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIndex, key in
                        TVKeyButton(label: String(key)) {
                            onCharacter(key)
                        }
                        // The very first key claims default focus so the
                        // rightward beam from the Search rail lands here.
                        .prefersDefaultFocusIfAvailable(
                            rowIndex == 0 && colIndex == 0,
                            in: defaultFocusNamespace
                        )
                    }
                }
            }

            HStack(spacing: 10) {
                TVKeyButton(label: "space", systemImage: "space", wide: true) {
                    onCharacter(" ")
                }
                TVKeyButton(label: "Delete", systemImage: "delete.left", wide: true) {
                    onDelete()
                }
            }
        }
    }
}

private struct TVKeyButton: View {
    let label: String
    var systemImage: String?
    var wide: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3)
                } else {
                    Text(label)
                        .font(.title3.weight(.semibold))
                }
            }
            .foregroundStyle(isFocused ? Color.white : SashimiTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(isFocused ? SashimiTheme.accent : SashimiTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: isFocused ? SashimiTheme.accent.opacity(0.5) : .clear, radius: 12)
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel(label)
    }
}

// MARK: - Result row

private struct SearchResultRow: View {
    let group: SearchResultGroup
    let isYouTube: (BaseItemDto) -> Bool
    let onSelect: (ServerMediaResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(group.title)
                    .font(Typography.headlineSmall)
                    .foregroundStyle(SashimiTheme.textPrimary)
                Text("\u{00B7} \(group.items.count)")
                    .font(.subheadline)
                    .foregroundStyle(SashimiTheme.textTertiary)
            }
            .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 32) {
                    ForEach(group.items) { result in
                        VStack(spacing: 8) {
                            MediaPosterButton(
                                item: result.primary.item,
                                isCircular: isYouTube(result.primary.item),
                                serverURL: result.primary.serverURL,
                                serverID: result.primary.serverID
                            ) {
                                onSelect(result.primary)
                            }
                            .frame(width: 200)

                            HStack(spacing: 6) {
                                ForEach(result.sources) { source in
                                    Button {
                                        onSelect(source)
                                    } label: {
                                        Text(source.serverName)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(SashimiTheme.textPrimary)
                                            .lineLimit(1)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(SashimiTheme.accent.opacity(0.35))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Open on \(source.serverName)")
                                }
                            }
                            .frame(width: 200)
                        }
                    }
                }
                // Padding lives inside the scroll content (not on the
                // ScrollView) so the leading poster's focus scale has room and
                // isn't clipped at the panel edge.
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .focusSection()
        }
    }
}

private struct ServerScopedTVDetailView: View {
    let source: ServerMediaResult
    let forceYouTubeStyle: Bool

    @State private var isReady = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if isReady {
                MediaDetailView(item: source.item, forceYouTubeStyle: forceYouTubeStyle)
            } else {
                ProgressView("Connecting to \(source.serverName)...")
                    .tint(SashimiTheme.accent)
            }
        }
        .task {
            isReady = await SessionManager.shared.prepareClient(for: source.serverID)
        }
        .onDisappear {
            Task { await SessionManager.shared.restoreActiveClient() }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .accessibilityLabel("Back to search results")
            }
        }
    }
}

// MARK: - Recent Search Button

struct RecentSearchButton: View {
    let query: String
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(isFocused ? SashimiTheme.focus : SashimiTheme.textTertiary)
                Text(query)
                    .foregroundStyle(isFocused ? .white : SashimiTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Typography.body)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFocused ? SashimiTheme.focus.opacity(0.25) : SashimiTheme.cardBackground)
            .clipShape(Capsule())
            .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
            .scaleEffect(isFocused ? 1.03 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

// MARK: - Focus helper

private extension View {
    /// Claims default focus only when the rail supplies its shared namespace,
    /// so the rightward beam from the Search rail row lands on this view.
    /// Previews and other non-rail contexts (no namespace) are untouched.
    @ViewBuilder
    func prefersDefaultFocusIfAvailable(_ condition: Bool, in namespace: Namespace.ID?) -> some View {
        if condition, let namespace {
            prefersDefaultFocus(true, in: namespace)
        } else {
            self
        }
    }
}

#Preview {
    SearchView()
}
