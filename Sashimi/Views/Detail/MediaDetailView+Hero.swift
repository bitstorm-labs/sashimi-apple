import SwiftUI

extension MediaDetailView {
    // MARK: - Episode Header (with series logo or YouTube channel art)
    var episodeHeaderSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isYouTubeChannelEpisode {
                // YouTube: circular channel art
                if let seriesId = item.seriesId {
                    HStack(spacing: 30) {
                        Circle()
                            .fill(SashimiTheme.cardBackground)
                            .frame(width: 120, height: 120)
                            .overlay(
                                AsyncItemImage(
                                    itemId: seriesId,
                                    imageType: "Primary",
                                    maxWidth: 240,
                                    contentMode: .fill,
                                    fallbackImageTypes: ["Thumb"],
                                    serverID: serverID
                                )
                                .clipShape(Circle())
                            )

                        if let seriesName = item.seriesName {
                            Text(seriesName.cleanedYouTubeTitle)
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(SashimiTheme.textSecondary)
                        }
                    }
                }
            } else {
                // Regular TV: series logo
                if let seriesId = item.seriesId {
                    AsyncItemImage(
                        itemId: seriesId,
                        imageType: "Logo",
                        maxWidth: 1400,
                        contentMode: .fit,
                        fallbackImageTypes: [],
                        serverID: serverID
                    )
                    .frame(maxHeight: 220, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                } else if let seriesName = item.seriesName {
                    // Fallback: show series name as text if no logo
                    Text(seriesName)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(SashimiTheme.textSecondary)
                }
            }

            infoSection
        }
    }

    // MARK: - Series Header (with logo above info)
    var seriesHeaderSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isYouTubeSeriesStyle {
                // YouTube channel: logo is shown inline with title in infoSection
                EmptyView()
            } else {
                // Regular series: logo
                AsyncItemImage(
                    itemId: item.id,
                    imageType: "Logo",
                    maxWidth: 1400,
                    contentMode: .fit,
                    fallbackImageTypes: [],
                    serverID: serverID
                )
                .frame(maxHeight: 220, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }

            infoSection
        }
    }

    // MARK: - Poster

    // All possible poster IDs to try in order
    private var posterFallbackIds: [String] {
        var ids: [String] = []
        if isEpisode {
            if isYouTubeStyle {
                // YouTube-style: episode thumbnail first, then series
                ids.append(item.id)
                if let seriesId = item.seriesId {
                    ids.append(seriesId)
                }
            } else {
                // Regular TV: season poster first, then episode, then series
                if let seasonId = item.seasonId {
                    ids.append(seasonId)
                }
                ids.append(item.id)
                if let seriesId = item.seriesId {
                    ids.append(seriesId)
                }
            }
        } else {
            ids.append(item.id)
        }
        return ids
    }

    @ViewBuilder
    var posterSection: some View {
        if isYouTubeSeriesStyle {
            // Circular art for YouTube channels
            Circle()
                .fill(SashimiTheme.cardBackground)
                .frame(width: 200, height: 280)
                .overlay(
                    SmartPosterImage(
                        itemIds: posterFallbackIds,
                        maxWidth: 400,
                        imageTypes: ["Primary", "Thumb"],
                        contentMode: .fit,
                        serverID: serverID
                    )
                    .clipShape(Circle())
                )
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
        } else {
            SmartPosterImage(
                itemIds: posterFallbackIds,
                maxWidth: isYouTubeStyle ? 640 : 400,
                imageTypes: isYouTubeStyle ? ["Primary", "Thumb", "Backdrop"] : ["Primary", "Thumb"],
                serverID: serverID
            )
            .frame(width: isYouTubeStyle ? 320 : 200, height: isYouTubeStyle ? 180 : 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
        }
    }

    // MARK: - Info Section
    var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isEpisode {
                // Episode title with S#:E# prefix (skip for YouTube)
                HStack(spacing: 12) {
                    if !isYouTubeChannelEpisode, let season = item.parentIndexNumber, let episode = item.indexNumber {
                        Text("S\(String(season)):E\(String(episode))")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(SashimiTheme.textPrimary)
                        Text("•")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
                    Text(item.name)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                }
            } else if isYouTubeSeriesStyle {
                // YouTube series: circular logo before title
                HStack(spacing: 20) {
                    Circle()
                        .fill(SashimiTheme.cardBackground)
                        .frame(width: 60, height: 60)
                        .overlay(
                            AsyncItemImage(
                                itemId: item.id,
                                imageType: "Primary",
                                maxWidth: 120,
                                contentMode: .fill,
                                fallbackImageTypes: ["Thumb"],
                                serverID: serverID
                            )
                            .clipShape(Circle())
                        )
                    Text(item.name.cleanedYouTubeTitle)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                }
            } else {
                Text(item.name)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)
            }

            HStack(spacing: 12) {
                Text(metadataLabel)
                    .font(.subheadline)
                    .foregroundStyle(SashimiTheme.textSecondary)

                if isSeries {
                    // Show community rating (TMDB) for series
                    if let rating = item.communityRating, rating > 0 {
                        Text("•")
                            .foregroundStyle(SashimiTheme.textTertiary)
                        HStack(spacing: 8) {
                            Image("TMDBLogo")
                                .resizable().scaledToFit()
                                .frame(height: 24)
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 18, weight: .bold))
                        }
                        .foregroundStyle(SashimiTheme.textPrimary)
                    }
                    // Show critic rating (Rotten Tomatoes) for series
                    if let criticRating = item.criticRating {
                        Text("•")
                            .foregroundStyle(SashimiTheme.textTertiary)
                        HStack(spacing: 6) {
                            Text("🍅")
                                .font(.system(size: 18))
                            Text("\(criticRating)%")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .foregroundStyle(SashimiTheme.textPrimary)
                    }
                } else if let finishTime = finishTimeString {
                    Text("•")
                        .foregroundStyle(SashimiTheme.textTertiary)
                    Text(finishTime)
                        .font(.subheadline)
                        .foregroundStyle(SashimiTheme.accent)
                }
            }

            if isMovie {
                // Movies: ratings on one row, quality badges on their own row
                // beneath, so a well-tagged release doesn't run off in one long
                // line. The badge row is conditional on its own so nothing shows
                // an empty row's worth of spacing before playback info lands.
                HStack(spacing: 16) {
                    ratingsRow
                }
                if mediaInfo != nil {
                    HStack(spacing: 16) {
                        qualityBadges
                    }
                }
            } else {
                // Series and episodes keep the single combined line.
                HStack(spacing: 16) {
                    if !isSeries {
                        ratingsRow
                    }
                    qualityBadges
                }
            }

            if !isEpisode {
                HStack(spacing: 16) {
                    // Advisory rating (fall back to series rating for episodes)
                    if let rating = item.officialRating ?? seriesOfficialRating {
                        Text(rating)
                            .font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(SashimiTheme.textSecondary, lineWidth: 1.5)
                            )
                    }

                    if let genres = item.genres, !genres.isEmpty {
                        Text(genres.prefix(4).joined(separator: " • "))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(SashimiTheme.textSecondary)
                    } else if let genres = seriesGenres, !genres.isEmpty {
                        Text(genres.prefix(4).joined(separator: " • "))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(SashimiTheme.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
