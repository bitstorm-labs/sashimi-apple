import SwiftUI
import NukeUI

// MARK: - Poster Card (View only, no button behavior)

struct MobilePosterCard: View {
    let item: BaseItemDto
    let width: CGFloat
    let showTitle: Bool
    let showProgress: Bool
    let libraryName: String?
    let isCircular: Bool
    let isLandscape: Bool
    let forceYouTube: Bool

    init(
        item: BaseItemDto,
        width: CGFloat = MobileSizing.posterWidth,
        showTitle: Bool = true,
        showProgress: Bool = true,
        libraryName: String? = nil,
        isCircular: Bool = false,
        isLandscape: Bool = false,
        forceYouTube: Bool = false
    ) {
        self.item = item
        self.width = width
        self.showTitle = showTitle
        self.showProgress = showProgress
        self.libraryName = libraryName
        self.isCircular = isCircular
        self.isLandscape = isLandscape
        self.forceYouTube = forceYouTube
    }

    // Detect YouTube content by library name, path, or forced flag
    private var isYouTubeStyle: Bool {
        if forceYouTube {
            return true
        }
        if let name = libraryName, name.lowercased().contains("youtube") {
            return true
        }
        if let path = item.path?.lowercased(), path.contains("youtube") {
            return true
        }
        return false
    }

    private var effectiveIsLandscape: Bool {
        isLandscape || (isYouTubeStyle && item.type == .episode)
    }

    private var effectiveIsCircular: Bool {
        isCircular || (isYouTubeStyle && item.type == .series)
    }

    private var height: CGFloat {
        if effectiveIsCircular {
            return width
        } else if effectiveIsLandscape {
            return width * (9 / 16) // 16:9 aspect ratio
        } else {
            return width * (1 / PosterAspectRatio.portrait)
        }
    }

    private var imageURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }

        let imageId: String
        let imageType: String

        if effectiveIsLandscape && item.type == .episode {
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

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.xs) {
            // Poster image
            ZStack(alignment: .bottomLeading) {
                posterImage

                // Progress bar overlay
                if showProgress, item.progressPercent > 0 {
                    progressBar
                }

                // Watched checkmark (top-right, green)
                if item.userData?.played == true {
                    watchedCheckmark
                }

                // Unplayed badge (only show if > 1, shows "X new")
                if let unplayedCount = item.userData?.unplayedItemCount, unplayedCount > 1 {
                    unplayedBadge(count: unplayedCount)
                }
            }
            .frame(width: width, height: height)
            .clipShape(effectiveIsCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium)))
            .offlineIndicator(itemId: item.id)

            // Title
            if showTitle {
                titleText
            }
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
        .frame(width: width, height: height)
    }

    private var placeholderImage: some View {
        Rectangle()
            .fill(MobileColors.cardBackground)
            .overlay {
                Image(systemName: placeholderIcon)
                    .font(.title)
                    .foregroundStyle(MobileColors.textTertiary)
            }
    }

    private var placeholderIcon: String {
        switch item.type {
        case .movie: return "film"
        case .series: return "tv"
        case .episode: return "play.rectangle"
        case .season: return "list.and.film"
        default: return "photo"
        }
    }

    private var progressBar: some View {
        VStack {
            Spacer()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(MobileColors.progressBackground)
                    Rectangle()
                        .fill(MobileColors.accent)
                        // progressPercent is a 0-1 fraction, not 0-100
                        .frame(width: geometry.size.width * CGFloat(item.progressPercent))
                }
            }
            .frame(height: 4)
        }
    }

    // Green checkmark for watched items
    private var watchedCheckmark: some View {
        VStack {
            HStack {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, Color(red: 0.29, green: 0.73, blue: 0.47))
                    .padding(4)
            }
            Spacer()
        }
    }

    // "X new" badge for unplayed items (like tvOS)
    private func unplayedBadge(count: Int) -> some View {
        VStack {
            HStack {
                Spacer()
                Text("\(count) new")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.29, green: 0.55, blue: 0.73))
                    .clipShape(Capsule())
                    .padding(4)
            }
            Spacer()
        }
    }

    private var titleText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textPrimary)
                .lineLimit(2)

            if let subtitle = displaySubtitle {
                Text(subtitle)
                    .font(MobileTypography.captionSmall)
                    .foregroundStyle(MobileColors.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var displayTitle: String {
        if effectiveIsLandscape && item.type == .episode {
            // YouTube: show video title
            return (item.name ?? "Unknown").cleanedYouTubeTitle
        } else if item.type == .episode {
            return (item.seriesName ?? item.name ?? "Unknown").cleanedYouTubeTitle
        }
        return (item.name ?? "Unknown").cleanedYouTubeTitle
    }

    private var displaySubtitle: String? {
        switch item.type {
        case .episode:
            // For YouTube, show date instead of S#:E#
            if isYouTubeStyle, let dateStr = item.premiereDate {
                return formatYouTubeDate(dateStr)
            }
            if let season = item.parentIndexNumber, let episode = item.indexNumber {
                return "S\(season):E\(episode)"
            }
            return nil
        case .movie:
            if let year = item.productionYear {
                return String(year)
            }
            return nil
        default:
            return nil
        }
    }

    private func formatYouTubeDate(_ dateString: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var date = formatter.date(from: dateString)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: dateString)
        }

        guard let date = date else { return nil }

        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .none
        return displayFormatter.string(from: date)
    }
}

// MARK: - Poster Button (for standalone use with tap action)

struct MobileMediaPosterButton: View {
    let item: BaseItemDto
    let width: CGFloat
    let showTitle: Bool
    let showProgress: Bool
    let libraryName: String?
    let isCircular: Bool
    let isLandscape: Bool
    let forceYouTube: Bool
    let onSelect: () -> Void

    init(
        item: BaseItemDto,
        width: CGFloat = MobileSizing.posterWidth,
        showTitle: Bool = true,
        showProgress: Bool = true,
        libraryName: String? = nil,
        isCircular: Bool = false,
        isLandscape: Bool = false,
        forceYouTube: Bool = false,
        onSelect: @escaping () -> Void
    ) {
        self.item = item
        self.width = width
        self.showTitle = showTitle
        self.showProgress = showProgress
        self.libraryName = libraryName
        self.isCircular = isCircular
        self.isLandscape = isLandscape
        self.forceYouTube = forceYouTube
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: onSelect) {
            MobilePosterCard(
                item: item,
                width: width,
                showTitle: showTitle,
                showProgress: showProgress,
                libraryName: libraryName,
                isCircular: isCircular,
                isLandscape: isLandscape,
                forceYouTube: forceYouTube
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuItems
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
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
