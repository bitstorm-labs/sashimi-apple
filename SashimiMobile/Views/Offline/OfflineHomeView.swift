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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.lg) {
                // Offline banner
                offlineBanner

                if downloads.isEmpty {
                    emptyState
                } else {
                    // Group by type
                    let movies = downloads.filter { $0.itemType == .movie }
                    let episodes = downloads.filter { $0.itemType == .episode }

                    if !movies.isEmpty {
                        downloadSection(title: "Movies", items: movies)
                    }

                    if !episodes.isEmpty {
                        // Group episodes by series
                        let grouped = Dictionary(grouping: episodes) { $0.seriesName ?? "Unknown" }
                        let sortedSeries = grouped.keys.sorted()

                        ForEach(sortedSeries, id: \.self) { seriesName in
                            if let seriesEpisodes = grouped[seriesName] {
                                downloadSection(
                                    title: seriesName,
                                    items: seriesEpisodes.sorted {
                                        ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) <
                                            ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
                                    }
                                )
                            }
                        }
                    }
                }

                Spacer().frame(height: 40)
            }
            .padding(.top, MobileSpacing.md)
        }
        .background(MobileColors.background)
        .navigationTitle("Downloads")
        .fullScreenPlayer(item: $playingItem)
    }

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

    private func downloadSection(title: String, items: [DownloadedItem]) -> some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text(title)
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.horizontal, MobileSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileSpacing.sm) {
                    ForEach(items, id: \.itemId) { item in
                        offlineCard(item)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }

    private func offlineCard(_ item: DownloadedItem) -> some View {
        // Build a minimal BaseItemDto for playback
        let playableItem = BaseItemDto(
            id: item.itemId,
            name: item.name,
            type: item.itemType,
            seriesName: item.seriesName,
            seriesId: item.seriesId,
            seasonId: item.seasonId,
            parentId: nil,
            indexNumber: item.episodeNumber,
            parentIndexNumber: item.seasonNumber,
            overview: item.overview,
            runTimeTicks: item.runTimeTicks,
            userData: nil,
            imageTags: nil,
            backdropImageTags: nil,
            parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil,
            mediaType: nil,
            productionYear: item.productionYear,
            communityRating: nil,
            officialRating: nil,
            genres: nil,
            taglines: nil,
            people: nil,
            criticRating: nil,
            premiereDate: nil,
            chapters: nil,
            path: nil,
            remoteTrailers: nil
        )

        return Button {
            playingItem = playableItem
        } label: {
            VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
                // Poster
                posterImage(for: item)

                // Title
                Text(item.displayTitle)
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(2)

                // Episode name for series
                if item.seriesName != nil {
                    Text(item.name)
                        .font(MobileTypography.captionSmall)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                }

                // Runtime
                if let ticks = item.runTimeTicks {
                    let minutes = ticks / 10_000_000 / 60
                    Text("\(minutes) min")
                        .font(MobileTypography.captionSmall)
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }
            .frame(width: MobileSizing.posterWidth)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func posterImage(for item: DownloadedItem) -> some View {
        let posterPath = DownloadFileManager.itemDirectory(for: item.itemId)
            .appendingPathComponent("poster.jpg")
        if FileManager.default.fileExists(atPath: posterPath.path) {
            AsyncImage(url: posterPath) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                posterPlaceholder
            }
            .frame(width: MobileSizing.posterWidth, height: MobileSizing.posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        RoundedRectangle(cornerRadius: MobileCornerRadius.small)
            .fill(MobileColors.cardBackground)
            .frame(width: MobileSizing.posterWidth, height: MobileSizing.posterHeight)
            .overlay {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(MobileColors.textTertiary)
            }
    }

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
