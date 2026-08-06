import SwiftUI

// swiftlint:disable file_length
// LibraryView contains library browsing with filter/sort UI - splitting would fragment related UI code

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
                        } else if libraries.isEmpty {
                            EmptyStateView(
                                icon: "square.grid.2x2",
                                title: "No Libraries",
                                message: "No media libraries found on this server",
                                actionTitle: "Refresh",
                                action: {
                                    Task {
                                        libraries = []
                                        isLoading = true
                                        await loadLibraries()
                                    }
                                }
                            )
                            .frame(maxWidth: .infinity)
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
                    .fill(isFocused ? SashimiTheme.focus.opacity(0.15) : SashimiTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 4)
            )
            .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 15)
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("\(library.name) library")
        .accessibilityHint("Double-tap to browse")
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
// swiftlint:disable type_body_length
// LibraryDetailView manages grid display, pagination, filtering, sorting, and alphabet navigation
struct LibraryDetailView: View {
    let library: LibraryView_Model

    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    /// Bumped whenever the sort/filter changes, so a page that was already in
    /// flight can tell it belongs to a superseded ordering.
    @State private var loadGeneration = 0
    @State private var selectedItem: BaseItemDto?
    @State private var selectedItemIsYouTube = false
    @State private var totalCount = 0
    @State private var selectedLetter: String?
    @State private var sortOption: LibrarySortOption = .name
    @State private var sortOrder: SortOrder = .ascending
    @State private var filterOption: LibraryFilterOption = .all
    @State private var committedLetter: String?
    /// Programmatic grid focus target. On tvOS a ScrollView's position is
    /// driven by the focus engine, so a `proxy.scrollTo` issued while focus
    /// sits on the A-Z bar is ignored and no letter ever jumped. Moving focus
    /// to the target item makes the grid scroll to follow it.
    @FocusState private var focusedGridItem: String?
    /// True while a letter press is pulling the rest of the library so it can
    /// jump to an as-yet-unloaded letter. Drives a loading overlay so the jump
    /// doesn't read as "nothing happened" during the fetch.
    @State private var isJumping = false
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

                            if !isYouTubeLibrary {
                                ShuffleButton {
                                    Task { await shufflePlay() }
                                }
                            }

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
                        } else if items.isEmpty {
                            EmptyStateView(
                                icon: "film",
                                title: "No Items",
                                message: filterOption == .all ? "This library is empty" : "No items match this filter",
                                actionTitle: filterOption == .all ? nil : "Clear Filter",
                                action: filterOption == .all ? nil : {
                                    filterOption = .all
                                    Task { await reloadWithNewSort() }
                                }
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 100)
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: isYouTubeLibrary ? 40 : 60) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    MediaPosterButton(item: item, libraryName: library.name, isCircular: isYouTubeLibrary) {
                                        selectedItemIsYouTube = isYouTubeLibrary
                                        selectedItem = item
                                    }
                                    .id(item.id)
                                    .focused($focusedGridItem, equals: item.id)
                                    .prefersDefaultFocus(index == 0, in: namespace)
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
                            // No blanket animation on items.count. An alphabet
                            // jump can insert several thousand items in one go,
                            // and SwiftUI must resolve the opacity+scale
                            // transition for every inserted identity -- not just
                            // the visible ones -- which froze the UI for
                            // seconds. Paging in 50 at a time never needed an
                            // animation to feel right anyway.

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
                // Hover: scroll only if the letter is already loaded. Pressing
                // is what may pull the rest of the library down.
                .onChange(of: selectedLetter) { _, letter in
                    if let letter = letter {
                        scrollToLetter(letter, proxy: proxy)
                    }
                }
                .onChange(of: committedLetter) { _, letter in
                    if let letter = letter {
                        jumpToLetter(letter, proxy: proxy)
                    }
                }
                .focusSection()
            }

            // Alphabet fast scroll bar (right side, aligned with grid)
            if !isLoading && !items.isEmpty {
                ScrollView(showsIndicators: false) {
                    AlphabetScrollBar(
                        alphabet: alphabet,
                        selectedLetter: $selectedLetter,
                        committedLetter: $committedLetter
                    )
                }
                .focusSection()
                // No .onExitCommand here. It used to set focusedArea = .grid,
                // which moved nothing -- focusedArea is never read, and it was
                // bound to ScrollViews, which aren't focusable on tvOS -- while
                // still CONSUMING the Menu press. So Menu was dead inside the
                // A-Z bar and could not return the user to Home. Left already
                // reaches the grid geometrically.
                .padding(.top, 100)  // Align with grid (below header)
                .padding(.trailing, 20)
            }
        }
        .overlay {
            if isJumping {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(SashimiTheme.accent)
                            .scaleEffect(1.4)
                        Text("Jumping…")
                            .font(Typography.body)
                            .foregroundStyle(SashimiTheme.textSecondary)
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isJumping)
        .focusScope(namespace)
        .ignoresSafeArea(edges: .bottom)
        .task {
            await loadItems()
        }
        .fullScreenCover(item: $selectedItem) { item in
            MediaDetailView(item: item, forceYouTubeStyle: selectedItemIsYouTube)
        }
        .onChange(of: selectedItem) { oldValue, newValue in
            // Refresh only the item that was open, not the whole grid.
            if let dismissed = oldValue, newValue == nil {
                Task { await refreshItem(id: dismissed.id) }
            }
        }
    }

    /// Hover (focus moving through the A-Z bar): best-effort scroll for a
    /// letter already loaded. On tvOS this is a no-op when focus is on the bar
    /// (scroll is focus-driven), so it never loads or moves focus — it just
    /// previews on the platforms where `scrollTo` does take effect.
    private func scrollToLetter(_ letter: String, proxy: ScrollViewProxy) {
        if let item = findItem(for: letter) {
            withAnimation(.easeOut(duration: 0.5)) {
                proxy.scrollTo(item.id, anchor: .top)
            }
        }
    }

    /// Press (a committed letter): jump to the letter by moving focus onto its
    /// first item, which makes the grid scroll to follow. `scrollTo` alone was
    /// ignored on tvOS because the ScrollView follows focus, which sat on the
    /// A-Z bar. Loads the rest of the library first when the letter isn't in
    /// the current page.
    private func jumpToLetter(_ letter: String, proxy: ScrollViewProxy) {
        if let item = findItem(for: letter) {
            focusGridItem(item, proxy: proxy)
            return
        }
        // Not found — pull the rest of the library, then jump. Gated on a press
        // (not focus) so holding Down through the bar can't kick a full fetch
        // at every unloaded letter.
        guard items.count < totalCount else { return }
        Task {
            isJumping = true
            await loadAllRemainingItems()
            if let item = findItem(for: letter) {
                focusGridItem(item, proxy: proxy)
            }
            isJumping = false
        }
    }

    /// Nudge the target into the rendered window (`scrollTo` renders lazy rows),
    /// then move focus to it so the grid settles on it under focus control.
    private func focusGridItem(_ item: BaseItemDto, proxy: ScrollViewProxy) {
        proxy.scrollTo(item.id, anchor: .top)
        focusedGridItem = item.id
    }

    private func findItem(for letter: String) -> BaseItemDto? {
        if letter == "#" {
            return items.first { item in
                guard let firstChar = item.name.first else { return false }
                return !firstChar.isLetter
            }
        }
        return items.first { $0.name.uppercased().hasPrefix(letter) }
    }

    /// Shuffle: play one random item from this library — a random movie for a
    /// movie library, a random episode for a TV library.
    private func shufflePlay() async {
        let types: [ItemType] = switch library.collectionType {
        case "tvshows": [.episode]
        case "movies": [.movie]
        default: [.movie, .episode]
        }
        if let item = try? await JellyfinClient.shared.getRandomItem(parentId: library.id, itemTypes: types) {
            selectedItemIsYouTube = false
            selectedItem = item
        }
    }

    private func loadAllRemainingItems() async {
        guard !isLoadingMore && items.count < totalCount else { return }
        isLoadingMore = true
        let generation = loadGeneration
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
                limit: totalCount - items.count,
                startIndex: items.count,
                isPlayed: filter.isPlayed,
                isFavorite: filter.isFavorite
            )
            // Sort/filter changed mid-flight -- this page is from the old ordering.
            guard generation == loadGeneration else { return }
            items.append(contentsOf: response.items)
        } catch {
            // Silent fail — alphabet jump is best-effort
        }
        isLoadingMore = false
    }

    // Convert filter option to API parameters (nil = no filter, true/false = filter value)
    // swiftlint:disable:next discouraged_optional_boolean
    private var filterParams: (isPlayed: Bool?, isFavorite: Bool?) { // swiftlint:disable:this discouraged_optional_boolean
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
        // Invalidate any page already in flight: its startIndex was computed
        // from the pre-reset count and against the OLD ordering, so appending
        // it would interleave two sorts and duplicate rows.
        loadGeneration &+= 1
        items = []
        totalCount = 0
        await loadItems()
    }

    private func loadMoreItems() async {
        guard !isLoadingMore && hasMore else { return }

        isLoadingMore = true
        let generation = loadGeneration
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
            // Sort/filter changed while this page was in flight -- discard it.
            guard generation == loadGeneration else { return }
            items.append(contentsOf: response.items)
        } catch is CancellationError {
            // Ignore
        } catch {
            ToastManager.shared.show("Failed to load more items")
        }
        isLoadingMore = false
    }

    /// Refresh the single item the user just came back from.
    ///
    /// This used to do what its comment said it didn't: request `limit:
    /// items.count, startIndex: 0` -- the entire loaded grid, with
    /// `Fields=...,MediaStreams` -- and replace the whole array. With 500 items
    /// scrolled in, backing out of a detail view issued one request for 500 full
    /// items and made every `BaseItemDto` a new value, so every cell re-evaluated
    /// and every visible image reloaded. That is the most repeated interaction in
    /// the app.
    ///
    /// Only watched/favourite state can have changed, and only for the item that
    /// was open, so fetch just that one and patch it in place.
    private func refreshItem(id: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        do {
            let refreshed = try await JellyfinClient.shared.getItem(itemId: id)
            // The index can move if a load landed while the detail view was up.
            if let current = items.firstIndex(where: { $0.id == id }) {
                items[current] = refreshed
            } else {
                items[index] = refreshed
            }
        } catch {
            // Silent fail - non-critical refresh
        }
    }
}
// swiftlint:enable type_body_length

// MARK: - Alphabet Scroll Bar
struct AlphabetScrollBar: View {
    let alphabet: [String]
    /// Set on hover as well as press — drives scroll-if-already-loaded.
    @Binding var selectedLetter: String?
    /// Set only on press — the one that may trigger a full-library load.
    @Binding var committedLetter: String?
    @FocusState private var focusedLetter: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(alphabet, id: \.self) { letter in
                Button {
                    // A press is an explicit request, so it may pull in the
                    // rest of the library; hovering must not.
                    selectedLetter = letter
                    committedLetter = letter
                } label: {
                    Text(letter)
                        .font(.system(size: 18, weight: focusedLetter == letter ? .bold : .medium))
                        .foregroundStyle(focusedLetter == letter ? .white : SashimiTheme.textSecondary)
                        .frame(width: 40, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(focusedLetter == letter ? SashimiTheme.focus : .clear)
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
            .background(isFocused ? SashimiTheme.focus.opacity(0.15) : SashimiTheme.cardBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
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

// MARK: - Shuffle Button
struct ShuffleButton: View {
    let onShuffle: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onShuffle) {
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                Text("Shuffle")
            }
            .font(.system(size: 20))
            .foregroundStyle(SashimiTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isFocused ? SashimiTheme.focus.opacity(0.15) : SashimiTheme.cardBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
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
            .background(isFocused ? SashimiTheme.focus.opacity(0.15) : SashimiTheme.cardBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("Sort order: \(sortOrder.displayName)")
        .accessibilityHint("Double-tap to toggle sort direction")
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
            .background(isFocused ? SashimiTheme.focus.opacity(0.15) : SashimiTheme.cardBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
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
