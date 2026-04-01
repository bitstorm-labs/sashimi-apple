import SwiftUI
import NukeUI

// MARK: - Continue Watching Card

struct MobileContinueWatchingCard: View {
    let item: BaseItemDto
    let libraryName: String?
    let width: CGFloat

    init(
        item: BaseItemDto,
        libraryName: String? = nil,
        width: CGFloat = 280
    ) {
        self.item = item
        self.libraryName = libraryName
        self.width = width
    }

    // Check if this is YouTube content
    private var isYouTube: Bool {
        if let name = libraryName, name.lowercased().contains("youtube") {
            return true
        }
        if let path = item.path?.lowercased(), path.contains("youtube") {
            return true
        }
        return false
    }

    // Check if parent series has backdrop images (regular shows have it, YouTube doesn't)
    private var seriesHasBackdrop: Bool {
        if let tags = item.parentBackdropImageTags, !tags.isEmpty {
            return true
        }
        return false
    }

    private var imageId: String {
        // For episodes with backdrops (regular shows), use series backdrop
        // For episodes without backdrops (YouTube), use episode's own thumbnail
        if item.type == .episode {
            return seriesHasBackdrop ? (item.seriesId ?? item.id) : item.id
        }
        return item.id
    }

    private var imageType: String {
        switch item.type {
        case .episode:
            return seriesHasBackdrop ? "Backdrop" : "Primary"
        case .video:
            return "Primary"
        default:
            return "Backdrop"
        }
    }

    private var height: CGFloat {
        width * (9 / 16)  // 16:9 aspect ratio
    }

    private var imageURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(imageId)/Images/\(imageType)?maxWidth=\(Int(width * 3))")
    }

    private var displayTitle: String {
        switch item.type {
        case .movie, .video:
            return item.name
        case .series:
            return item.name.cleanedYouTubeTitle
        case .episode:
            return (item.seriesName ?? item.name).cleanedYouTubeTitle
        default:
            return item.name
        }
    }

    // Episode info like tvOS: "S1:E1 - Episode Name" or "date - Episode Name" for YouTube
    private var episodeInfoText: String? {
        guard item.type == .episode else { return nil }

        if isYouTube, let dateStr = item.premiereDate {
            return "\(formatDate(dateStr)) - \(item.name)"
        }

        let season = item.parentIndexNumber ?? 1
        let episode = item.indexNumber ?? 1
        return "S\(season):E\(episode) - \(item.name)"
    }

    // For non-episodes (movies), show year
    private var yearText: String? {
        guard item.type != .episode else { return nil }
        if let year = item.productionYear {
            return String(year)
        }
        return nil
    }

    private var remainingTimeText: String {
        guard let total = item.runTimeTicks else { return "" }
        let played = item.userData?.playbackPositionTicks ?? 0
        let remaining = total - played
        let seconds = remaining / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        }
        return "\(minutes)m left"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.xs) {
            // Backdrop image with progress
            ZStack(alignment: .bottom) {
                backdropImage

                // Bottom overlay with time remaining and progress
                VStack(alignment: .leading, spacing: 6) {
                    // Time remaining
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(MobileColors.accent)

                        Text(remainingTimeText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MobileColors.textSecondary)
                    }

                    // Progress bar
                    progressBar
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .frame(width: width, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 60)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                )
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.large))

            // Title and episode info
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(MobileTypography.title)
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(1)
                    .frame(height: 20)

                if let episodeInfo = episodeInfoText {
                    Text(episodeInfo)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                        .frame(height: 16)
                } else if let year = yearText {
                    Text(year)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    private var backdropImage: some View {
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
        default: return "photo"
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MobileColors.progressBackground)
                Capsule()
                    .fill(MobileColors.accent)
                    .frame(width: geometry.size.width * CGFloat(item.progressPercent / 100))
            }
        }
        .frame(height: 4)
    }

    private func formatDate(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "M-d-yyyy"
            return displayFormatter.string(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "M-d-yyyy"
            return displayFormatter.string(from: date)
        }
        return ""
    }
}

// MARK: - Continue Watching Row

struct MobileContinueWatchingRow<Destination: View>: View {
    let title: String
    let items: [BaseItemDto]
    let libraryNames: [String: String]?
    let cardWidth: CGFloat
    let destination: (BaseItemDto) -> Destination

    init(
        title: String = "Continue Watching",
        items: [BaseItemDto],
        libraryNames: [String: String]? = nil,
        cardWidth: CGFloat = 280,
        @ViewBuilder destination: @escaping (BaseItemDto) -> Destination
    ) {
        self.title = title
        self.items = items
        self.libraryNames = libraryNames
        self.cardWidth = cardWidth
        self.destination = destination
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            // Section header
            Text(title)
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.horizontal, MobileSpacing.md)

            // Horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileSpacing.md) {
                    ForEach(items, id: \.id) { item in
                        NavigationLink {
                            destination(item)
                        } label: {
                            MobileContinueWatchingCard(
                                item: item,
                                libraryName: libraryNames?[item.id],
                                width: cardWidth
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
        }
    }
}
