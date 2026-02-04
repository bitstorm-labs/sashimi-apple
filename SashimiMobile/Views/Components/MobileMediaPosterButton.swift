import SwiftUI
import NukeUI

struct MobileMediaPosterButton: View {
    let item: BaseItemDto
    let width: CGFloat
    let showTitle: Bool
    let showProgress: Bool
    let libraryName: String?
    let onSelect: () -> Void

    init(
        item: BaseItemDto,
        width: CGFloat = MobileSizing.posterWidth,
        showTitle: Bool = true,
        showProgress: Bool = true,
        libraryName: String? = nil,
        onSelect: @escaping () -> Void
    ) {
        self.item = item
        self.width = width
        self.showTitle = showTitle
        self.showProgress = showProgress
        self.libraryName = libraryName
        self.onSelect = onSelect
    }

    private var height: CGFloat {
        width * (1 / PosterAspectRatio.portrait)
    }

    private var imageURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }

        let imageId: String
        let imageType: String

        // For episodes, use series poster
        if item.type == .episode, let seriesId = item.seriesId {
            imageId = seriesId
            imageType = "Primary"
        } else {
            imageId = item.id
            imageType = "Primary"
        }

        return URL(string: "\(serverURL)/Items/\(imageId)/Images/\(imageType)?maxWidth=\(Int(width * 2))")
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                // Poster image
                ZStack(alignment: .bottomLeading) {
                    posterImage

                    // Progress bar overlay
                    if showProgress, item.progressPercent > 0 {
                        progressBar
                    }

                    // Unplayed badge
                    if let unplayedCount = item.userData?.unplayedItemCount, unplayedCount > 0 {
                        unplayedBadge(count: unplayedCount)
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))

                // Title
                if showTitle {
                    titleText
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuItems
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
                        .frame(width: geometry.size.width * CGFloat(item.progressPercent / 100))
                }
            }
            .frame(height: 4)
        }
    }

    private func unplayedBadge(count: Int) -> some View {
        VStack {
            HStack {
                Spacer()
                Text("\(count)")
                    .font(MobileTypography.captionSmall)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MobileColors.accent)
                    .clipShape(Capsule())
                    .padding(6)
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
        if item.type == .episode {
            return item.seriesName ?? item.name ?? "Unknown"
        }
        return item.name ?? "Unknown"
    }

    private var displaySubtitle: String? {
        switch item.type {
        case .episode:
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
