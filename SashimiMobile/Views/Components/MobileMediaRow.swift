import SwiftUI

struct MobileMediaRow<Destination: View>: View {
    let title: String
    let items: [BaseItemDto]
    let libraryName: String?
    let libraryNames: [String: String]?  // itemId -> libraryName for per-item lookup
    let cardWidth: CGFloat
    let showProgress: Bool
    let destination: (BaseItemDto) -> Destination

    init(
        title: String,
        items: [BaseItemDto],
        libraryName: String? = nil,
        libraryNames: [String: String]? = nil,
        cardWidth: CGFloat = MobileSizing.posterWidth,
        showProgress: Bool = true,
        @ViewBuilder destination: @escaping (BaseItemDto) -> Destination
    ) {
        self.title = title
        self.items = items
        self.libraryName = libraryName
        self.libraryNames = libraryNames
        self.cardWidth = cardWidth
        self.showProgress = showProgress
        self.destination = destination
    }

    // Get library name for a specific item (per-item lookup takes precedence)
    private func libraryNameFor(_ item: BaseItemDto) -> String? {
        libraryNames?[item.id] ?? libraryName
    }

    // Check if a specific item is from a YouTube library
    private func isYouTubeItem(_ item: BaseItemDto) -> Bool {
        if let name = libraryNameFor(item), name.lowercased().contains("youtube") {
            return true
        }
        if let path = item.path?.lowercased(), path.contains("youtube") {
            return true
        }
        return false
    }

    // Detect YouTube library by name
    private var isYouTubeLibrary: Bool {
        guard let name = libraryName else { return false }
        return name.lowercased().contains("youtube")
    }

    // Effective card width - use landscape for YouTube
    private var effectiveCardWidth: CGFloat {
        if isYouTubeLibrary {
            return MobileSizing.landscapeCardWidth
        }
        return cardWidth
    }

    // For YouTube series (channels), use circular covers
    private var isCircularStyle: Bool {
        guard isYouTubeLibrary else { return false }
        // Check if items are series (channels)
        return items.first?.type == .series
    }

    // Check if any items in the row are from YouTube (for mixed rows like Continue Watching)
    private var hasAnyYouTubeItems: Bool {
        isYouTubeLibrary || items.contains { isYouTubeItem($0) }
    }

    // Calculate card width for a specific item
    private func itemCardWidth(for item: BaseItemDto) -> CGFloat {
        let isYouTube = isYouTubeItem(item)
        let isCircular = isYouTube && item.type == .series
        let isLandscape = isYouTube && item.type == .episode

        if isCircular {
            return MobileSizing.posterWidth
        } else if isLandscape {
            return MobileSizing.landscapeCardWidth
        } else if isYouTubeLibrary {
            return isCircularStyle ? MobileSizing.posterWidth : effectiveCardWidth
        } else {
            return cardWidth
        }
    }

    private func posterCard(for item: BaseItemDto) -> some View {
        let itemLibraryName = libraryNameFor(item)
        let isYouTube = isYouTubeItem(item)
        let isCircular = isYouTube && item.type == .series
        let isLandscape = isYouTube && item.type == .episode
        let itemWidth = itemCardWidth(for: item)

        return MobilePosterCard(
            item: item,
            width: itemWidth,
            showProgress: showProgress,
            libraryName: itemLibraryName,
            isCircular: isCircular,
            isLandscape: isLandscape,
            forceYouTube: isYouTube
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            // Section header
            HStack {
                Text(title.cleanedYouTubeTitle)
                    .font(MobileTypography.headline)
                    .foregroundStyle(MobileColors.textPrimary)

                Spacer()

                if items.count > 6 {
                    NavigationLink {
                        MobileMediaGridView(title: title, items: items, libraryName: libraryName, libraryNames: libraryNames, destination: destination)
                    } label: {
                        Text("See All")
                            .font(MobileTypography.body)
                            .foregroundStyle(MobileColors.accent)
                    }
                }
            }
            .padding(.horizontal, MobileSpacing.md)

            // Horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: hasAnyYouTubeItems ? MobileSpacing.md : MobileSpacing.sm) {
                    ForEach(items, id: \.id) { item in
                        NavigationLink {
                            destination(item)
                        } label: {
                            posterCard(for: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            ItemContextMenu(item: item)
                        }
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }
}

// MARK: - Grid View for "See All"

struct MobileMediaGridView<Destination: View>: View {
    let title: String
    let items: [BaseItemDto]
    let libraryName: String?
    let libraryNames: [String: String]?
    let destination: (BaseItemDto) -> Destination
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(
        title: String,
        items: [BaseItemDto],
        libraryName: String? = nil,
        libraryNames: [String: String]? = nil,
        @ViewBuilder destination: @escaping (BaseItemDto) -> Destination
    ) {
        self.title = title
        self.items = items
        self.libraryName = libraryName
        self.libraryNames = libraryNames
        self.destination = destination
    }

    // Get library name for a specific item
    private func libraryNameFor(_ item: BaseItemDto) -> String? {
        libraryNames?[item.id] ?? libraryName
    }

    // Check if a specific item is from YouTube
    private func isYouTubeItem(_ item: BaseItemDto) -> Bool {
        if let name = libraryNameFor(item), name.lowercased().contains("youtube") {
            return true
        }
        if let path = item.path?.lowercased(), path.contains("youtube") {
            return true
        }
        return false
    }

    // Detect YouTube library by name
    private var isYouTubeLibrary: Bool {
        guard let name = libraryName else { return false }
        return name.lowercased().contains("youtube")
    }

    // For YouTube series (channels), use circular covers
    private var isCircularStyle: Bool {
        guard isYouTubeLibrary else { return false }
        return items.first?.type == .series
    }

    private var columns: [GridItem] {
        let defaultWidth = sizeClass == .compact ? PhoneSizing.posterWidth : MobileSizing.posterWidth
        let minWidth = isYouTubeLibrary && !isCircularStyle ? MobileSizing.landscapeCardWidth : defaultWidth
        return [GridItem(.adaptive(minimum: minWidth), spacing: MobileSpacing.md)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: MobileSpacing.md) {
                ForEach(items, id: \.id) { item in
                    NavigationLink {
                        destination(item)
                    } label: {
                        gridCard(for: item)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ItemContextMenu(item: item)
                    }
                }
            }
            .padding(MobileSpacing.md)
        }
        .navigationTitle(title.cleanedYouTubeTitle)
    }

    @ViewBuilder
    private func gridCard(for item: BaseItemDto) -> some View {
        let itemLibraryName = libraryNameFor(item)
        let isYouTube = isYouTubeItem(item)
        let isCircular = isYouTube && item.type == .series
        let isLandscape = isYouTube && item.type == .episode

        MobilePosterCard(
            item: item,
            libraryName: itemLibraryName,
            isCircular: isCircular,
            isLandscape: isLandscape,
            forceYouTube: isYouTube
        )
    }
}

// MARK: - Shared Context Menu

struct ItemContextMenu: View {
    let item: BaseItemDto

    var body: some View {
        if item.userData?.played == true {
            Button {
                Task { try? await JellyfinClient.shared.markUnplayed(itemId: item.id) }
            } label: {
                Label("Mark as Unwatched", systemImage: "eye.slash")
            }
        } else {
            Button {
                Task { try? await JellyfinClient.shared.markPlayed(itemId: item.id) }
            } label: {
                Label("Mark as Watched", systemImage: "eye")
            }
        }

        if item.userData?.isFavorite == true {
            Button {
                Task { try? await JellyfinClient.shared.removeFavorite(itemId: item.id) }
            } label: {
                Label("Remove from Favorites", systemImage: "heart.slash")
            }
        } else {
            Button {
                Task { try? await JellyfinClient.shared.markFavorite(itemId: item.id) }
            } label: {
                Label("Add to Favorites", systemImage: "heart")
            }
        }
    }
}
