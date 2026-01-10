import SwiftUI

struct LibraryView: View {
    var onBackAtRoot: (() -> Void)?
    @Binding var showProfile: Bool
    @State private var libraries: [LibraryView_Model] = []
    @State private var isLoading = true
    @State private var navigationPath = NavigationPath()

    init(onBackAtRoot: (() -> Void)? = nil, showProfile: Binding<Bool> = .constant(false)) {
        self.onBackAtRoot = onBackAtRoot
        _showProfile = showProfile
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                SashimiTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 30) {
                        AppHeader(showProfile: $showProfile)

                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.top, 100)
                        } else {
                            // Use HStack for small number of libraries to center them
                            if libraries.count <= 4 {
                                HStack(spacing: 40) {
                                    ForEach(libraries) { library in
                                        LibraryCardButton(library: library) {
                                            navigationPath.append(library)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 60)
                                .padding(.bottom, 60)
                            } else {
                                LazyVGrid(columns: [
                                    GridItem(.flexible(), spacing: 40),
                                    GridItem(.flexible(), spacing: 40),
                                    GridItem(.flexible(), spacing: 40),
                                    GridItem(.flexible(), spacing: 40)
                                ], spacing: 40) {
                                    ForEach(libraries) { library in
                                        LibraryCardButton(library: library) {
                                            navigationPath.append(library)
                                        }
                                    }
                                }
                                .padding(.horizontal, 60)
                                .padding(.bottom, 60)
                            }
                        }
                    }
                }
            }
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
    @State private var showSortOptions = false
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
            return [GridItem(.adaptive(minimum: 300, maximum: 340), spacing: 40)]
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
                        // Header with title, count, and sort
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text(library.name)
                                    .font(.system(size: 48, weight: .bold))
                                    .foregroundStyle(SashimiTheme.textPrimary)

                                Spacer()

                                if totalCount > 0 {
                                    Text("\(totalCount) items")
                                        .font(.system(size: 24))
                                        .foregroundStyle(SashimiTheme.textSecondary)
                                }
                            }

                            // Sort options row
                            HStack(spacing: 16) {
                                Menu {
                                    ForEach(LibrarySortOption.allCases, id: \.self) { option in
                                        Button {
                                            if sortOption != option {
                                                sortOption = option
                                                Task { await reloadWithNewSort() }
                                            }
                                        } label: {
                                            Label(option.displayName, systemImage: option.icon)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: sortOption.icon)
                                        Text(sortOption.displayName)
                                        Image(systemName: "chevron.down")
                                            .font(.caption)
                                    }
                                    .font(.system(size: 20))
                                    .foregroundStyle(SashimiTheme.textPrimary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(SashimiTheme.cardBackground)
                                    .clipShape(Capsule())
                                }

                                Button {
                                    sortOrder = sortOrder == .ascending ? .descending : .ascending
                                    Task { await reloadWithNewSort() }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: sortOrder.icon)
                                        Text(sortOrder.displayName)
                                    }
                                    .font(.system(size: 20))
                                    .foregroundStyle(SashimiTheme.textPrimary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(SashimiTheme.cardBackground)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)

                                Spacer()
                            }
                        }
                        .padding(.horizontal, 80)
                        .padding(.top, 40)

                        if isLoading && items.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 100)
                                .transition(.opacity)
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: isYouTubeLibrary ? 40 : 60) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    MediaPosterButton(item: item, libraryName: library.name, isLandscape: isYouTubeLibrary) {
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

            // Alphabet fast scroll bar (right side)
            if !isLoading && !items.isEmpty {
                ScrollView(showsIndicators: false) {
                    AlphabetScrollBar(
                        alphabet: alphabet,
                        selectedLetter: $selectedLetter
                    )
                }
                .focusSection()
                .focused($focusedArea, equals: .alphabet)
                .frame(maxHeight: .infinity)
                .padding(.trailing, 20)
                .padding(.vertical, 20)
                .onExitCommand {
                    focusedArea = .grid
                }
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

    private func loadItems() async {
        guard items.isEmpty else { return }

        isLoading = true
        do {
            let includeTypes: [ItemType]? = switch library.collectionType {
            case "tvshows": [.series]
            case "movies": [.movie]
            default: nil
            }

            let response = try await JellyfinClient.shared.getItems(
                parentId: library.id,
                includeTypes: includeTypes,
                sortBy: sortOption.rawValue,
                sortOrder: sortOrder.rawValue,
                limit: pageSize,
                startIndex: 0
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

            let response = try await JellyfinClient.shared.getItems(
                parentId: library.id,
                includeTypes: includeTypes,
                sortBy: sortOption.rawValue,
                sortOrder: sortOrder.rawValue,
                limit: pageSize,
                startIndex: items.count
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

            let response = try await JellyfinClient.shared.getItems(
                parentId: library.id,
                includeTypes: includeTypes,
                sortBy: sortOption.rawValue,
                sortOrder: sortOrder.rawValue,
                limit: items.count,
                startIndex: 0
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
