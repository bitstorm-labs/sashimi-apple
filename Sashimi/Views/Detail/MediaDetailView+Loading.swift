import SwiftUI

extension MediaDetailView {
    // MARK: - Data Loading
    func loadContent() async {
        // Refresh item data to ensure consistency regardless of navigation source
        do {
            let refreshedItem = try await JellyfinClient.shared.getItem(itemId: item.id)
            item = refreshedItem

            isWatched = refreshedItem.userData?.played ?? false
            hasProgress = refreshedItem.progressPercent > 0 && !(refreshedItem.userData?.played ?? false)
        } catch {
            // Use initial item data if refresh fails
        }

        if isSeries {
            await loadSeriesContent()
        } else if isEpisode {
            await loadEpisodeContent()
        }
        // Series pages have no media sources of their own — PlaybackInfo for a
        // series id is a guaranteed server 500 (InvalidCastException to
        // IHasMediaSources). This call also lands at the END of the load chain
        // above, so it raced the real episode PlaybackInfo whenever the user
        // pressed Play quickly. The iOS detail views already have this gate.
        if !isSeries {
            await loadMediaInfo()
        }
    }

    private func loadSeriesContent() async {
        do {
            seasons = try await JellyfinClient.shared.getSeasons(seriesId: item.id)
            // Find next episode to play first (from NextUp API)
            await findNextEpisodeToPlay()

            // Select the season containing the next episode, or first season as fallback
            if let nextEp = nextEpisodeToPlay, let seasonId = nextEp.seasonId {
                selectedSeason = seasons.first { $0.id == seasonId }
                if let season = selectedSeason {
                    await loadEpisodesForSeason(seriesId: item.id, season: season)
                }
            } else if let firstSeason = seasons.first {
                selectedSeason = firstSeason
                await loadEpisodesForSeason(seriesId: item.id, season: firstSeason)
            }
        } catch {
            ToastManager.shared.show("Failed to load series content")
        }
    }

    func findNextEpisodeToPlay() async {
        do {
            let nextUpItems = try await JellyfinClient.shared.getNextUp(limit: 50)
            // Find next up for this series
            if let next = nextUpItems.first(where: { $0.seriesId == item.id }) {
                nextEpisodeToPlay = next
                return
            }
            // If no next up, find first unwatched episode
            for season in seasons.specialsLast {
                let eps = try await JellyfinClient.shared.getEpisodes(seriesId: item.id, seasonId: season.id)
                if let firstUnwatched = eps.first(where: { !($0.userData?.played ?? false) }) {
                    nextEpisodeToPlay = firstUnwatched
                    return
                }
            }
        } catch {
            // Silently fail - button just won't show
        }
    }

    private func loadEpisodeContent() async {
        guard let seriesId = item.seriesId else { return }
        do {
            // Fetch series to get its official rating and genres as fallback
            let series = try? await JellyfinClient.shared.getItem(itemId: seriesId)
            if item.officialRating == nil {
                seriesOfficialRating = series?.officialRating
            }
            if item.genres == nil || item.genres?.isEmpty == true {
                seriesGenres = series?.genres
            }
            // Get series ratings for episode fallback
            seriesCommunityRating = series?.communityRating
            seriesCriticRating = series?.criticRating

            seasons = try await JellyfinClient.shared.getSeasons(seriesId: seriesId)

            if let seasonId = item.seasonId {
                selectedSeason = seasons.first { $0.id == seasonId }
                let allEpisodes = try await JellyfinClient.shared.getEpisodes(seriesId: seriesId, seasonId: seasonId)
                episodes = allEpisodes
            } else if let firstSeason = seasons.first {
                selectedSeason = firstSeason
                await loadEpisodesForEpisodeView(seriesId: seriesId, seasonId: firstSeason.id)
            }
        } catch {
            ToastManager.shared.show("Failed to load episode content")
        }
    }

    private func loadEpisodesForEpisodeView(seriesId: String, seasonId: String) async {
        isLoadingEpisodes = true
        do {
            episodes = try await JellyfinClient.shared.getEpisodes(seriesId: seriesId, seasonId: seasonId)
        } catch {
            ToastManager.shared.show("Failed to load episodes")
        }
        isLoadingEpisodes = false
    }

    private func loadMediaInfo() async {
        do {
            let playbackInfo = try await JellyfinClient.shared.getPlaybackInfo(itemId: item.id, itemType: item.type, engine: .avFoundation)
            mediaInfo = playbackInfo.mediaSources?.first
        } catch {
            // Silently ignore media info loading failures - not critical for playback
        }
    }
}
