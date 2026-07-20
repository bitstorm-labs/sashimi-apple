import SwiftUI
import NukeUI

/// Sort fields for library browsing (mirrors tvOS LibrarySortOption).
private enum LibrarySort: String, CaseIterable, Identifiable {
    case name = "SortName"
    case dateAdded = "DateCreated"
    case releaseDate = "PremiereDate"
    case rating = "CommunityRating"
    case runtime = "Runtime"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .releaseDate: return "Release Date"
        case .rating: return "Rating"
        case .runtime: return "Runtime"
        }
    }
}

/// Watched/favorites filter (mirrors tvOS LibraryFilterOption).
private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case unwatched
    case watched
    case favorites

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .unwatched: return "Unwatched"
        case .watched: return "Watched"
        case .favorites: return "Favorites"
        }
    }

    // swiftlint:disable discouraged_optional_boolean
    var isPlayed: Bool? {
        switch self {
        case .unwatched: return false
        case .watched: return true
        default: return nil
        }
    }

    var isFavorite: Bool? {
        self == .favorites ? true : nil
    }
    // swiftlint:enable discouraged_optional_boolean
}

struct MobileLibraryBrowseView: View {
    let libraryId: String
    let libraryName: String
    let collectionType: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true
    @State private var totalCount = 0
    @State private var sort: LibrarySort = .name
    @State private var sortAscending = true
    @State private var filter: LibraryFilter = .all
    @State private var searchText = ""
    /// Invalidates the in-flight load loop when sort/filter changes mid-fetch.
    @State private var loadGeneration = 0
    /// Set by the Shuffle button to present the player on a random item.
    @State private var shuffleItem: BaseItemDto?

    private var isYouTubeLibrary: Bool {
        libraryName.lowercased().contains("youtube")
    }

    private var includeTypes: [ItemType]? {
        switch collectionType {
        case "movies": return [.movie]
        case "tvshows": return [.series]
        default: return nil
        }
    }

    /// Shuffle: play one random item — a random movie for a movie library, a
    /// random episode for a TV library.
    private func shufflePlay() async {
        let types: [ItemType] = collectionType == "tvshows" ? [.episode] : [.movie]
        if let item = try? await JellyfinClient.shared.getRandomItem(parentId: libraryId, itemTypes: types) {
            shuffleItem = item
        }
    }

    /// Search filters client-side — the whole library is loaded eagerly.
    private var displayedItems: [BaseItemDto] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    // Covers fill their column: derive the column count from the available
    // width, then hand each card the exact column width. The old fixed-width
    // cards left big vertical gaps on smaller iPhones (2 columns ~163pt wide
    // but covers only 110pt).
    private func gridMetrics(availableWidth: CGFloat) -> (columns: [GridItem], cardWidth: CGFloat) {
        let spacing = MobileSpacing.md
        let avail = availableWidth - spacing * 2   // matches the grid's horizontal padding
        let target: CGFloat = sizeClass == .compact ? 118 : 165
        let count = max(2, Int((avail + spacing) / (target + spacing)))
        let cardWidth = floor((avail - spacing * CGFloat(count - 1)) / CGFloat(count))
        let cols = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: count)
        return (cols, cardWidth)
    }

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            if isLoading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if displayedItems.isEmpty {
                emptyState
            } else {
                let metrics = gridMetrics(availableWidth: geo.size.width)
                VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                    Text(countText)
                        .font(MobileTypography.captionSmall)
                        .foregroundStyle(MobileColors.textTertiary)
                        .padding(.horizontal, MobileSpacing.md)

                    LazyVGrid(columns: metrics.columns, spacing: MobileSpacing.md) {
                        ForEach(displayedItems, id: \.id) { item in
                            NavigationLink {
                                AdaptiveDetailView(item: item, libraryName: libraryName)
                            } label: {
                                MobileRecentlyAddedCard(
                                    item: item,
                                    width: metrics.cardWidth,
                                    libraryName: libraryName,
                                    isCircular: isYouTubeLibrary && item.type == .series,
                                    isLandscape: false,
                                    badgeCount: nil
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                ItemContextMenu(item: item)
                            }
                        }
                    }
                    .padding(.horizontal, MobileSpacing.md)
                }
                .padding(.vertical, MobileSpacing.md)
            }
        }
        .background(MobileColors.background)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isYouTubeLibrary {
                    Button {
                        Task { await shufflePlay() }
                    } label: {
                        Image(systemName: "shuffle")
                    }
                }
                sortMenu
                filterMenu
            }
        }
        .fullScreenPlayer(item: $shuffleItem)
        .task {
            await loadItems()
        }
        .onChange(of: sort) { _, _ in reload() }
        .onChange(of: sortAscending) { _, _ in reload() }
        .onChange(of: filter) { _, _ in reload() }
        }
    }

    private var countText: String {
        if !searchText.isEmpty {
            return "\(displayedItems.count) of \(totalCount) items"
        }
        return "\(totalCount) item\(totalCount == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if filter != .all {
            ContentUnavailableView {
                Label("No Items", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing matches the \(filter.label) filter.")
            } actions: {
                Button("Clear Filter") { filter = .all }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            ContentUnavailableView(
                "No Items",
                systemImage: "rectangle.stack",
                description: Text("This library is empty.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(LibrarySort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            Divider()
            Button {
                sortAscending.toggle()
            } label: {
                Label(
                    sortAscending ? "Ascending" : "Descending",
                    systemImage: sortAscending ? "arrow.up" : "arrow.down"
                )
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(LibraryFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Image(systemName: filter == .all
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private func reload() {
        loadGeneration += 1
        items = []
        totalCount = 0
        isLoading = true
        Task { await loadItems() }
    }

    private func loadItems() async {
        let generation = loadGeneration
        do {
            let response = try await JellyfinClient.shared.getItems(
                parentId: libraryId,
                includeTypes: includeTypes,
                sortBy: sort.rawValue,
                sortOrder: sortAscending ? "Ascending" : "Descending",
                limit: 100,
                startIndex: 0,
                isPlayed: filter.isPlayed,
                isFavorite: filter.isFavorite
            )
            guard generation == loadGeneration else { return }
            items = response.items
            totalCount = response.totalRecordCount

            // Load remaining items in background
            while items.count < totalCount {
                let more = try await JellyfinClient.shared.getItems(
                    parentId: libraryId,
                    includeTypes: includeTypes,
                    sortBy: sort.rawValue,
                    sortOrder: sortAscending ? "Ascending" : "Descending",
                    limit: 100,
                    startIndex: items.count,
                    isPlayed: filter.isPlayed,
                    isFavorite: filter.isFavorite
                )
                guard generation == loadGeneration else { return }
                guard !more.items.isEmpty else { break }
                items.append(contentsOf: more.items)
            }
        } catch {
            // Show what we have
        }
        if generation == loadGeneration {
            isLoading = false
        }
    }
}
