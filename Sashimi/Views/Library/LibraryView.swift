import SwiftUI

struct LibraryView: View {
    var onBackAtRoot: (() -> Void)?
    @State private var libraries: [LibraryView_Model] = []
    @State private var isLoading = true
    @State private var navigationPath = NavigationPath()

    init(onBackAtRoot: (() -> Void)? = nil) {
        self.onBackAtRoot = onBackAtRoot
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                SashimiTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 30) {
                        Spacer().frame(height: 120)

                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.top, 100)
                        } else {
                            VStack(spacing: 24) {
                                ForEach(libraries) { library in
                                    LibraryRowButton(library: library) {
                                        navigationPath.append(library)
                                    }
                                }
                            }
                            .frame(maxWidth: 800)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 60)
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
            .navigationDestination(for: LibraryView_Model.self) { library in
                LibraryDetailView(library: library)
            }
        }
        .task {
            await loadLibraries()
        }
        .onExitCommand {
            if navigationPath.isEmpty {
                onBackAtRoot?()
            } else {
                navigationPath.removeLast()
            }
        }
    }

    private func loadLibraries() async {
        // Skip if already loaded
        guard libraries.isEmpty else {
            isLoading = false
            return
        }

        do {
            let views = try await JellyfinClient.shared.getLibraryViews()
            libraries = views.map { LibraryView_Model(from: $0) }
        } catch is CancellationError {
            // Ignore cancellation - expected during navigation
        } catch {
            ToastManager.shared.show("Failed to load libraries")
        }
        isLoading = false
    }
}

struct LibraryView_Model: Identifiable, Hashable {
    let id: String
    let name: String
    let collectionType: String?

    init(from library: JellyfinLibrary) {
        self.id = library.id
        self.name = library.name
        self.collectionType = library.collectionType
    }
}

// MARK: - Library Card Button (with proper focus)
struct LibraryCardButton: View {
    let library: LibraryView_Model
    let onSelect: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                AsyncItemImage(
                    itemId: library.id,
                    imageType: "Primary",
                    maxWidth: 400
                )
                .frame(width: 300, height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 4)
                )
                .shadow(color: isFocused ? SashimiTheme.accent.opacity(0.6) : .clear, radius: 20)

                Text(library.name)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(1)
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

struct LibraryRowButton: View {
    let library: LibraryView_Model
    let onSelect: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 20) {
                AsyncItemImage(
                    itemId: library.id,
                    imageType: "Primary",
                    maxWidth: 300
                )
                .frame(width: 120, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(library.name)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 24))
                    .foregroundStyle(SashimiTheme.textTertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isFocused ? SashimiTheme.accent.opacity(0.15) : SashimiTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 4)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

// MARK: - Sort Options

enum LibrarySortOption: String, CaseIterable {
    case name = "SortName"
    case dateAdded = "DateCreated"
    case releaseDate = "PremiereDate"
    case rating = "CommunityRating"
    case runtime = "Runtime"

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .releaseDate: return "Release Date"
        case .rating: return "Rating"
        case .runtime: return "Runtime"
        }
    }

    var icon: String {
        switch self {
        case .name: return "textformat.abc"
        case .dateAdded: return "calendar.badge.plus"
        case .releaseDate: return "calendar"
        case .rating: return "star.fill"
        case .runtime: return "clock"
        }
    }
}

enum SortOrder: String, CaseIterable {
    case ascending = "Ascending"
    case descending = "Descending"

    var displayName: String {
        switch self {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }

    var icon: String {
        switch self {
        case .ascending: return "arrow.up"
        case .descending: return "arrow.down"
        }
    }
}

// MARK: - Filter Options

enum LibraryFilterOption: String, CaseIterable {
    case all = "All"
    case unwatched = "Unwatched"
    case watched = "Watched"
    case favorites = "Favorites"

    var displayName: String {
        rawValue
    }
}

// MARK: - Library Detail View
struct LibraryDetailView: View {
    enum FocusArea: Hashable {
        case grid
        case alphabet
        case sortPicker
    }

    let library: LibraryView_Model

    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var selectedItem: BaseItemDto?
    @State private var totalCount = 0
    @State private var selectedLetter: String?
    @State private var sortOption: LibrarySortOption = .name
    @State private var sortOrder: SortOrder = .ascending
    @State private var filterOption: LibraryFilterOption = .all
    @FocusState private var focusedArea: FocusArea?
    private let pageSize = 50

    // Alphabet for fast scroll
    private let alphabet = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

    // Detect YouTube library by name
    private var isYouTubeLibrary: Bool {
        library.name.lowercased().contains("youtube")
    }

    private var hasMore: Bool {
        items.count < totalCount
    }

    private var gridColumns: [GridItem] {
        if isYouTubeLibrary {
            // Circular covers for YouTube channels
            return [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 50)]
        }
        return [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 50)]
    }

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            // Main content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        // Header with sort, filter options and count
                        HStack(spacing: 16) {
                            SortMenuButton(
                                currentOption: sortOption,
                                onSelect: { option in
                                    if sortOption != option {
                                        sortOption = option
                                        Task { await reloadWithNewSort() }
                                    }
                                }
                            )

                            SortOrderButton(
                                sortOrder: sortOrder,
                                onToggle: {
                                    sortOrder = sortOrder == .ascending ? .descending : .ascending
                                    Task { await reloadWithNewSort() }
                                }
                            )

                            FilterMenuButton(
                                currentFilter: filterOption,
                                onSelect: { filter in
                                    if filterOption != filter {
                                        filterOption = filter
                                        Task { await reloadWithNewSort() }
                                    }
                                }
                            )

                            Spacer()

                            if totalCount > 0 {
                                Text("\(totalCount) items")
                                    .font(.system(size: 20))
                                    .foregroundStyle(SashimiTheme.textSecondary)
                            }
                        }
                        .padding(.horizontal, 50)
                        .padding(.top, 40)

                        if isLoading && items.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 100)
                                .transition(.opacity)
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: isYouTubeLibrary ? 40 : 60) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    MediaPosterButton(item: item, libraryName: library.name, isCircular: isYouTubeLibrary) {
                                        selectedItem = item
                                    }
                                    .id(item.id)
                                    .prefersDefaultFocus(index == 0, in: namespace)
                                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                                    .onAppear {
                                        // Load more when approaching the end
                                        if item.id == items.last?.id && hasMore && !isLoadingMore {
                                            Task { await loadMoreItems() }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 60)
                            .padding(.bottom, 60)
                            .animation(.easeOut(duration: 0.3), value: items.count)

                            // Loading indicator for infinite scroll
                            if isLoadingMore {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 20)
                                    .transition(.opacity)
                            }
                        }
                    }
                }
                .onChange(of: selectedLetter) { _, letter in
                    if let letter = letter {
                        scrollToLetter(letter, proxy: proxy)
                    }
                }
                .focusSection()
                .focused($focusedArea, equals: .grid)
            }

            // Alphabet fast scroll bar (right side, aligned with grid)
            if !isLoading && !items.isEmpty {
                ScrollView(showsIndicators: false) {
                    AlphabetScrollBar(
                        alphabet: alphabet,
                        selectedLetter: $selectedLetter
                    )
                }
                .focusSection()
                .focused($focusedArea, equals: .alphabet)
                .onExitCommand {
                    focusedArea = .grid
                }
                .padding(.top, 100)  // Align with grid (below header)
                .padding(.trailing, 20)
            }
        }
        .focusScope(namespace)
        .ignoresSafeArea(edges: .bottom)
        .task {
            await loadItems()
        }
        .fullScreenCover(item: $selectedItem) { item in
            MediaDetailView(item: item, forceYouTubeStyle: isYouTubeLibrary)
        }
        .onChange(of: selectedItem) { oldValue, newValue in
            // Refresh item data when returning from detail view
            if oldValue != nil && newValue == nil {
                Task { await refreshCurrentItems() }
            }
        }
    }

    private func scrollToLetter(_ letter: String, proxy: ScrollViewProxy) {
        var targetItem: BaseItemDto?
        if letter == "#" {
            // Numbers and special characters
            for item in items {
                guard let firstChar = item.name.first else { continue }
                if !firstChar.isLetter {
                    targetItem = item
                    break
                }
            }
        } else {
            for item in items {
                if item.name.uppercased().hasPrefix(letter) {
                    targetItem = item
                    break
                }
            }
        }

        if let item = targetItem {
            withAnimation(.easeOut(duration: 0.5)) {
                proxy.scrollTo(item.id, anchor: .top)
            }
        }
    }

    // Convert filter option to API parameters
    private var filterParams: (isPlayed: Bool?, isFavorite: Bool?) {
        switch filterOption {
        case .all:
            return (nil, nil)
        case .unwatched:
            return (false, nil)
        case .watched:
            return (true, nil)
        case .favorites:
            return (nil, true)
        }
    }

    private func loadItems() async {
        guard items.isEmpty else { return }

        isLoading = true
        do {
            let includeTypes: [ItemType]? = switch library.collectionType {
            case "tvshows": [.series]
            case "movies": [.movie]
            default: nil
            }

            let filter = filterParams
            let response = try await JellyfinClient.shared.getItems(
                parentId: library.id,
                includeTypes: includeTypes,
                sortBy: sortOption.rawValue,
                sortOrder: sortOrder.rawValue,
                limit: pageSize,
                startIndex: 0,
                isPlayed: filter.isPlayed,
                isFavorite: filter.isFavorite
            )
            items = response.items
            totalCount = response.totalRecordCount
        } catch is CancellationError {
            // Ignore
        } catch {
            ToastManager.shared.show("Failed to load library items")
        }
        isLoading = false
    }

    private func reloadWithNewSort() async {
        items = []
        totalCount = 0
        await loadItems()
    }

    private func loadMoreItems() async {
        guard !isLoadingMore && hasMore else { return }

        isLoadingMore = true
        do {
            let includeTypes: [ItemType]? = switch library.collectionType {
            case "tvshows": [.series]
            case "movies": [.movie]
            default: nil
            }

            let filter = filterParams
            let response = try await JellyfinClient.shared.getItems(
                parentId: library.id,
                includeTypes: includeTypes,
                sortBy: sortOption.rawValue,
                sortOrder: sortOrder.rawValue,
                limit: pageSize,
                startIndex: items.count,
                isPlayed: filter.isPlayed,
                isFavorite: filter.isFavorite
            )
            items.append(contentsOf: response.items)
        } catch is CancellationError {
            // Ignore
        } catch {
            ToastManager.shared.show("Failed to load more items")
        }
        isLoadingMore = false
    }

    private func refreshCurrentItems() async {
        // Just refresh userData for watched status, don't reload all
        do {
            let includeTypes: [ItemType]? = switch library.collectionType {
            case "tvshows": [.series]
            case "movies": [.movie]
            default: nil
            }

            let filter = filterParams
            let response = try await JellyfinClient.shared.getItems(
                parentId: library.id,
                includeTypes: includeTypes,
                sortBy: sortOption.rawValue,
                sortOrder: sortOrder.rawValue,
                limit: items.count,
                startIndex: 0,
                isPlayed: filter.isPlayed,
                isFavorite: filter.isFavorite
            )
            items = response.items
        } catch {
            // Silent fail - non-critical refresh
        }
    }
}

// MARK: - Alphabet Scroll Bar
struct AlphabetScrollBar: View {
    let alphabet: [String]
    @Binding var selectedLetter: String?
    @FocusState private var focusedLetter: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(alphabet, id: \.self) { letter in
                Button {
                    selectedLetter = letter
                } label: {
                    Text(letter)
                        .font(.system(size: 18, weight: focusedLetter == letter ? .bold : .medium))
                        .foregroundStyle(focusedLetter == letter ? .white : SashimiTheme.textSecondary)
                        .frame(width: 40, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(focusedLetter == letter ? SashimiTheme.accent : .clear)
                        )
                        .animation(.easeOut(duration: 0.15), value: focusedLetter)
                }
                .buttonStyle(PlainNoHighlightButtonStyle())
                .focused($focusedLetter, equals: letter)
                .onChange(of: focusedLetter) { _, newLetter in
                    if let newLetter = newLetter {
                        selectedLetter = newLetter
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(SashimiTheme.cardBackground.opacity(0.85))
        )
    }
}

// MARK: - Sort Menu Button
struct SortMenuButton: View {
    let currentOption: LibrarySortOption
    let onSelect: (LibrarySortOption) -> Void
    @State private var showingOptions = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            showingOptions = true
        } label: {
            HStack(spacing: 8) {
                Text(currentOption.displayName)
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
            .font(.system(size: 20))
            .foregroundStyle(SashimiTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isFocused ? SashimiTheme.accent.opacity(0.15) : SashimiTheme.cardBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .confirmationDialog("Sort By", isPresented: $showingOptions) {
            ForEach(LibrarySortOption.allCases, id: \.self) { option in
                Button(option.displayName) {
                    onSelect(option)
                }
            }
        }
    }
}

// MARK: - Sort Order Button
struct SortOrderButton: View {
    let sortOrder: SortOrder
    let onToggle: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: sortOrder.icon)
                Text(sortOrder.displayName)
            }
            .font(.system(size: 20))
            .foregroundStyle(SashimiTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isFocused ? SashimiTheme.accent.opacity(0.15) : SashimiTheme.cardBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

// MARK: - Filter Menu Button
struct FilterMenuButton: View {
    let currentFilter: LibraryFilterOption
    let onSelect: (LibraryFilterOption) -> Void
    @State private var showingOptions = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            showingOptions = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(currentFilter.displayName)
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
            .font(.system(size: 20))
            .foregroundStyle(currentFilter != .all ? SashimiTheme.accent : SashimiTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isFocused ? SashimiTheme.accent.opacity(0.15) : SashimiTheme.cardBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .confirmationDialog("Filter", isPresented: $showingOptions) {
            ForEach(LibraryFilterOption.allCases, id: \.self) { option in
                Button(option.displayName) {
                    onSelect(option)
                }
            }
        }
    }
}
