import SwiftUI
import NukeUI

struct MobileRecentlyAddedRow<Destination: View>: View {
    let libraryId: String
    let libraryName: String
    let collectionType: String?
    let cardWidth: CGFloat
    let destination: (BaseItemDto) -> Destination

    init(
        libraryId: String,
        libraryName: String,
        collectionType: String?,
        cardWidth: CGFloat = MobileSizing.posterWidth,
        @ViewBuilder destination: @escaping (BaseItemDto) -> Destination
    ) {
        self.libraryId = libraryId
        self.libraryName = libraryName
        self.collectionType = collectionType
        self.cardWidth = cardWidth
        self.destination = destination
    }

    @State private var items: [BaseItemDto] = []
    @State private var episodeCounts: [String: Int] = [:]  // seriesId -> unplayed count
    @State private var isLoading = true

    private var isYouTubeLibrary: Bool {
        libraryName.lowercased().contains("youtube")
    }

    private var isTVLibrary: Bool {
        collectionType?.lowercased() == "tvshows"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            // Section header
            HStack {
                Text("Recently Added \(libraryName)".cleanedYouTubeTitle)
                    .font(MobileTypography.headline)
                    .foregroundStyle(MobileColors.textPrimary)

                Spacer()

                if items.count > 6 {
                    NavigationLink {
                        MobileRecentlyAddedGridView(
                            title: "Recently Added \(libraryName)",
                            items: items,
                            libraryName: libraryName,
                            episodeCounts: episodeCounts,
                            destination: destination
                        )
                    } label: {
                        Text("See All")
                            .font(MobileTypography.body)
                            .foregroundStyle(MobileColors.accent)
                    }
                }
            }
            .padding(.horizontal, MobileSpacing.md)

            if isLoading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            } else if items.isEmpty {
                Text("No items")
                    .font(MobileTypography.body)
                    .foregroundStyle(MobileColors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MobileSpacing.sm) {
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
        .task {
            await loadItems()
        }
    }

    private func posterCard(for item: BaseItemDto) -> some View {
        let key = item.seriesId ?? item.id
        let unplayedCount = episodeCounts[key]

        return MobileRecentlyAddedCard(
            item: item,
            width: cardWidth,
            libraryName: libraryName,
            isCircular: isYouTubeLibrary,
            isLandscape: false,
            badgeCount: (unplayedCount ?? 0) >= 1 ? unplayedCount : nil
        )
    }

    private func loadItems() async {
        do {
            let fetchLimit = 30

            let latestItems = try await JellyfinClient.shared.getLatestMedia(
                parentId: libraryId,
                limit: fetchLimit,
                includeWatched: true,
                collectionType: collectionType,
                isYouTubeLibrary: isYouTubeLibrary
            )
            let dedupedItems = deduplicateBySeries(latestItems)
            items = dedupedItems

            // Fetch unplayed counts from series (for TV shows)
            if isTVLibrary {
                await loadUnplayedCounts(for: dedupedItems)
            }
        } catch {
            // Ignore errors
        }
        isLoading = false
    }

    private func loadUnplayedCounts(for items: [BaseItemDto]) async {
        var counts: [String: Int] = [:]

        let seriesIds = Set(items.compactMap { item -> String? in
            if item.type == .episode { return item.seriesId }
            if item.type == .video { return item.seriesId }
            if item.type == .series { return item.id }
            return nil
        })

        for seriesId in seriesIds {
            do {
                let series = try await JellyfinClient.shared.getItem(itemId: seriesId)
                if let unplayedCount = series.userData?.unplayedItemCount, unplayedCount >= 1 {
                    counts[seriesId] = unplayedCount
                }
            } catch {
                // Ignore
            }
        }

        episodeCounts = counts
    }

    private func deduplicateBySeries(_ items: [BaseItemDto]) -> [BaseItemDto] {
        var seen = Set<String>()
        var result: [BaseItemDto] = []

        for item in items {
            let key: String
            if item.type == .episode || item.type == .video {
                key = item.seriesId ?? item.id
            } else {
                key = item.id
            }
            if !seen.contains(key) {
                seen.insert(key)
                result.append(item)
            }
        }

        return Array(result.prefix(20))
    }
}

// MARK: - Recently Added Card (with badge support)

struct MobileRecentlyAddedCard: View {
    let item: BaseItemDto
    let width: CGFloat
    let libraryName: String?
    let isCircular: Bool
    let isLandscape: Bool
    let badgeCount: Int?

    @AppStorage("showQualityBadges") private var showQualityBadges = true

    private var isYouTube: Bool {
        if let name = libraryName, name.lowercased().contains("youtube") {
            return true
        }
        return false
    }

    private var height: CGFloat {
        if isCircular {
            return width
        } else if isLandscape {
            return width * (9 / 16)
        } else {
            return width * (1 / PosterAspectRatio.portrait)
        }
    }

    private var imageURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }

        let imageId: String
        let imageType: String

        if isLandscape && item.type == .episode {
            // YouTube episodes: use episode's own thumbnail
            imageId = item.id
            imageType = "Primary"
        } else if item.type == .episode, let seriesId = item.seriesId {
            // Regular episodes: use series poster
            imageId = seriesId
            imageType = "Primary"
        } else {
            imageId = item.id
            imageType = "Primary"
        }

        return URL(string: "\(serverURL)/Items/\(imageId)/Images/\(imageType)?maxWidth=\(Int(width * 2))")
    }

    // Title only, no subtitle (matches tvOS)
    private var displayTitle: String {
        if isLandscape {
            // YouTube landscape: show video title
            return item.name
        }
        switch item.type {
        case .movie:
            return item.name
        case .series:
            return item.name.cleanedYouTubeTitle
        case .episode:
            return (item.seriesName ?? item.name).cleanedYouTubeTitle
        default:
            return item.name
        }
    }

    var body: some View {
        VStack(alignment: isCircular ? .center : .leading, spacing: MobileSpacing.xs) {
            ZStack(alignment: .topTrailing) {
                // Image
                posterImage
                    .frame(width: width, height: height)
                    .clipShape(isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium)))

                // Watched checkmark
                if item.userData?.played == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, Color(red: 0.29, green: 0.73, blue: 0.47))
                        .padding(4)
                }

                // "X new" badge
                if let count = badgeCount, count >= 1 {
                    Text("\(count) new")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.29, green: 0.55, blue: 0.73))
                        .clipShape(Capsule())
                        .padding(4)
                }

                // Quality badge (bottom-right; top-right holds watched/new)
                if showQualityBadges, !isCircular, !isLandscape, let quality = item.qualityBadge {
                    QualityBadge(label: quality, fontSize: 11,
                                 horizontalPadding: 6, verticalPadding: 3, cornerRadius: 5)
                        .padding(4)
                        .frame(width: width, height: height, alignment: .bottomTrailing)
                }
            }

            // Title
            Text(displayTitle)
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textPrimary)
                .lineLimit(1)
                .frame(width: width, height: 16, alignment: isCircular ? .center : .leading)
        }
    }

    private var posterImage: some View {
        Group {
            if let url = imageURL {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if state.error != nil {
                        placeholderImage
                    } else {
                        Rectangle()
                            .fill(MobileColors.cardBackground)
                    }
                }
            } else {
                placeholderImage
            }
        }
    }

    private var placeholderImage: some View {
        Rectangle()
            .fill(MobileColors.cardBackground)
            .overlay {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(MobileColors.textTertiary)
            }
    }
}

// MARK: - Grid View for "See All"

struct MobileRecentlyAddedGridView<Destination: View>: View {
    let title: String
    let items: [BaseItemDto]
    let libraryName: String
    let episodeCounts: [String: Int]
    let destination: (BaseItemDto) -> Destination

    private var isYouTubeLibrary: Bool {
        libraryName.lowercased().contains("youtube")
    }

    private var columns: [GridItem] {
        return [GridItem(.adaptive(minimum: MobileSizing.posterWidth), spacing: MobileSpacing.md)]
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

    private func gridCard(for item: BaseItemDto) -> some View {
        let key = item.seriesId ?? item.id
        let unplayedCount = episodeCounts[key]

        return MobileRecentlyAddedCard(
            item: item,
            width: MobileSizing.posterWidth,
            libraryName: libraryName,
            isCircular: isYouTubeLibrary,
            isLandscape: false,
            badgeCount: (unplayedCount ?? 0) >= 1 ? unplayedCount : nil
        )
    }
}
