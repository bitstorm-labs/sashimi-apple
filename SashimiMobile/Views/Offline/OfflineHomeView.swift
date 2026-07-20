import SwiftUI
import SwiftData
import NukeUI

struct OfflineHomeView: View {
    @Query(
        filter: #Predicate<DownloadedItem> { $0.statusRaw == "completed" },
        sort: \DownloadedItem.dateCompleted,
        order: .reverse
    ) private var downloads: [DownloadedItem]
    @State private var playingItem: BaseItemDto?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var continueWatchingItems: [DownloadedItem] {
        downloads.filter { $0.lastPlaybackPositionTicks > 0 }
    }

    private var movieItems: [DownloadedItem] {
        downloads.filter { $0.itemType == .movie }
    }

    private struct SeriesGroup {
        let name: String
        let representative: DownloadedItem
        let episodes: [DownloadedItem]
    }

    private var seriesGroups: [SeriesGroup] {
        let episodes = downloads.filter { $0.itemType == .episode }
        let grouped = Dictionary(grouping: episodes) { $0.seriesName ?? "Unknown" }
        return grouped.keys.sorted().compactMap { name in
            guard let eps = grouped[name], let first = eps.first else { return nil }
            let sorted = eps.sorted {
                ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) <
                    ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
            }
            return SeriesGroup(name: name, representative: first, episodes: sorted)
        }
    }

    private var posterWidth: CGFloat {
        sizeClass == .compact ? PhoneSizing.posterWidth : MobileSizing.posterWidth
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileSpacing.xl) {
                offlineBanner

                if downloads.isEmpty {
                    emptyState
                } else {
                    // Continue Watching
                    if !continueWatchingItems.isEmpty {
                        continueWatchingSection
                    }

                    // Movies
                    if !movieItems.isEmpty {
                        movieSection
                    }

                    // TV Shows
                    if !seriesGroups.isEmpty {
                        tvShowsSection
                    }
                }

                Spacer().frame(height: 40)
            }
            .padding(.vertical, MobileSpacing.md)
        }
        .background(MobileColors.background)
        .navigationTitle("Downloads")
        .fullScreenPlayer(item: $playingItem)
    }

    // MARK: - Continue Watching

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("Continue Watching")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.horizontal, MobileSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileSpacing.md) {
                    ForEach(continueWatchingItems, id: \.itemId) { item in
                        Button { playingItem = item.asBaseItemDto } label: {
                            offlineContinueCard(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }

    private func offlineContinueCard(_ item: DownloadedItem) -> some View {
        let width: CGFloat = sizeClass == .compact ? PhoneSizing.continueWatchingWidth : 280
        let height = width * (9 / 16)

        return VStack(alignment: .leading, spacing: MobileSpacing.xs) {
            ZStack(alignment: .bottom) {
                localImage(itemId: item.itemId, fileNames: ["backdrop.jpg", "poster.jpg"])
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.large))

                // Progress overlay
                if let total = item.runTimeTicks, total > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        let remaining = total - item.lastPlaybackPositionTicks
                        let minutes = remaining / 10_000_000 / 60

                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(MobileColors.accent)
                            Text("\(minutes)m left")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(MobileColors.textSecondary)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(MobileColors.progressBackground)
                                Capsule()
                                    .fill(MobileColors.accent)
                                    .frame(width: geo.size.width * CGFloat(item.lastPlaybackPositionTicks) / CGFloat(total))
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .frame(width: width, alignment: .leading)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 60)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    )
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.large))

            Text(item.displayTitle)
                .font(MobileTypography.title)
                .foregroundStyle(MobileColors.textPrimary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)

            if item.seriesName != nil {
                Text(item.name)
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
    }

    // MARK: - Movies

    private var movieSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("Movies")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.horizontal, MobileSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileSpacing.sm) {
                    ForEach(movieItems, id: \.itemId) { item in
                        Button { playingItem = item.asBaseItemDto } label: {
                            offlinePosterCard(itemId: item.itemId, title: item.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }

    // MARK: - TV Shows (one card per series, navigates to detail)

    private var tvShowsSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("TV Shows")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.horizontal, MobileSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileSpacing.sm) {
                    ForEach(seriesGroups, id: \.name) { group in
                        NavigationLink {
                            AdaptiveDetailView(
                                item: group.representative.asSeriesDto
                            )
                        } label: {
                            offlineSeriesCard(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }

    private func offlineSeriesCard(group: SeriesGroup) -> some View {
        let height = posterWidth * (1 / PosterAspectRatio.portrait)

        return VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
            ZStack(alignment: .topTrailing) {
                // Use series_poster.jpg if available, fall back to episode poster
                localImage(itemId: group.representative.itemId, fileNames: ["series_poster.jpg", "poster.jpg"])
                    .frame(width: posterWidth, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))

                Text("\(group.episodes.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(MobileColors.accent)
                    .clipShape(Capsule())
                    .padding(6)
            }

            Text(group.name)
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textPrimary)
                .lineLimit(1)
                .frame(width: posterWidth, alignment: .leading)
        }
    }

    // MARK: - Poster Card

    private func offlinePosterCard(itemId: String, title: String) -> some View {
        let height = posterWidth * (1 / PosterAspectRatio.portrait)

        return VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
            localImage(itemId: itemId, fileNames: ["poster.jpg"])
                .frame(width: posterWidth, height: height)
                .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))

            Text(title)
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textPrimary)
                .lineLimit(1)
                .frame(width: posterWidth, alignment: .leading)
        }
    }

    // MARK: - Local Image Helper (UIImage for reliable file:// loading)

    @ViewBuilder
    private func localImage(itemId: String, fileNames: [String]) -> some View {
        if let uiImage = loadLocalImage(itemId: itemId, fileNames: fileNames) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(MobileColors.cardBackground)
                .overlay {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(MobileColors.textTertiary)
                }
        }
    }

    private func loadLocalImage(itemId: String, fileNames: [String]) -> UIImage? {
        let dir = DownloadFileManager.itemDirectory(for: itemId)
        for fileName in fileNames {
            let path = dir.appendingPathComponent(fileName).path
            if let image = UIImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }

    // MARK: - Offline Banner

    private var offlineBanner: some View {
        HStack(spacing: MobileSpacing.sm) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14))
            Text("You're offline. Showing downloaded content.")
                .font(MobileTypography.caption)
        }
        .foregroundStyle(MobileColors.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MobileSpacing.md)
        .background(MobileColors.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
        .padding(.horizontal, MobileSpacing.md)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: MobileSpacing.md) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(MobileColors.textTertiary)
            Text("No Downloads")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
            Text("Download movies and episodes while online to watch them offline.")
                .font(MobileTypography.body)
                .foregroundStyle(MobileColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

// MARK: - DownloadedItem → BaseItemDto

extension DownloadedItem {
    /// Create a series-type DTO from an episode (for navigating to series detail offline)
    var asSeriesDto: BaseItemDto {
        BaseItemDto(
            id: seriesId ?? itemId,
            name: seriesName ?? name,
            type: .series,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil, runTimeTicks: nil,
            userData: nil, imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil, taglines: nil,
            people: nil, criticRating: nil, premiereDate: nil, chapters: nil,
            path: nil, remoteTrailers: nil, localTrailerCount: nil, mediaStreams: nil
        )
    }

    var asBaseItemDto: BaseItemDto {
        BaseItemDto(
            id: itemId,
            name: name,
            type: itemType,
            seriesName: seriesName,
            seriesId: seriesId,
            seasonId: seasonId,
            parentId: nil,
            indexNumber: episodeNumber,
            parentIndexNumber: seasonNumber,
            overview: overview,
            runTimeTicks: runTimeTicks,
            userData: lastPlaybackPositionTicks > 0
                ? UserItemDataDto(
                    playbackPositionTicks: lastPlaybackPositionTicks,
                    playCount: 0,
                    isFavorite: false,
                    played: false,
                    lastPlayedDate: nil,
                    unplayedItemCount: nil
                )
                : nil,
            imageTags: nil,
            backdropImageTags: nil,
            parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil,
            mediaType: nil,
            productionYear: productionYear,
            communityRating: nil,
            officialRating: nil,
            genres: nil,
            taglines: nil,
            people: nil,
            criticRating: nil,
            premiereDate: nil,
            chapters: nil,
            path: nil,
            remoteTrailers: nil,
            localTrailerCount: nil,
            mediaStreams: nil
        )
    }
}
