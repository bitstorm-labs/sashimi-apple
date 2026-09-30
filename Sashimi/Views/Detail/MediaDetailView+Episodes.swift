import SwiftUI

extension MediaDetailView {
    // MARK: - Seasons Section
    var seasonsSection: some View {
        let seriesId = isSeries ? item.id : item.seriesId

        return VStack(alignment: .leading, spacing: 24) {
            if !seasons.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Seasons")
                        .font(.headline)
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .padding(.horizontal, 60)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(seasons) { season in
                                SeasonTab(
                                    season: season,
                                    isSelected: selectedSeason?.id == season.id
                                ) {
                                    selectedSeason = season
                                    if let seriesId = seriesId {
                                        Task { await loadEpisodesForSeason(seriesId: seriesId, season: season) }
                                    }
                                }
                                // Long-press a season tab: the same idiom
                                // MediaRow uses for item-level watched.
                                .seasonWatchMenu(
                                    for: season,
                                    action: seasonWatchAction(for: season),
                                    request: $seasonWatchRequest
                                )
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.vertical, 12)
                    }
                }
                .focusSection()
            }

            if isLoadingEpisodes {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
            } else if !episodes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Episodes")
                        .font(.headline)
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .padding(.horizontal, 60)

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            // Lazy: a non-lazy HStack instantiates every child
                            // immediately, so a 24-episode season fired 24
                            // concurrent image requests on appear, ~20 of them
                            // off-screen — saturating the queue ahead of the
                            // images actually on screen.
                            LazyHStack(spacing: 30) {
                                ForEach(episodes) { episode in
                                    EpisodeCard(episode: episode, isCurrentEpisode: episode.id == nextEpisodeToPlay?.id, showEpisodeThumbnail: true) {
                                        showingEpisodeDetail = episode
                                    }
                                    .id("\(episode.id)-\(refreshID)")
                                }
                            }
                            .padding(.horizontal, 60)
                            .padding(.vertical, 20)
                        }
                        .onAppear {
                            if let nextEpId = nextEpisodeToPlay?.id {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation {
                                        proxy.scrollTo("\(nextEpId)-\(refreshID)", anchor: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
                .focusSection()
            } else if selectedSeason != nil {
                // Empty state when season has no episodes
                EmptyStateView(
                    icon: "tv",
                    title: "No Episodes",
                    message: "This season has no episodes"
                )
                .frame(maxWidth: .infinity)
                .frame(height: 280)
            }
        }
    }

    // MARK: - Next Up Section (for episode detail view)
    var nextUpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More Episodes")
                .font(.headline)
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 60)

            if isLoadingEpisodes {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
            } else if !episodes.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // Lazy for the same reason as the season strip above.
                        LazyHStack(spacing: 30) {
                            ForEach(episodes) { episode in
                                EpisodeCard(
                                    episode: episode,
                                    isCurrentEpisode: episode.id == item.id,
                                    showEpisodeThumbnail: true
                                ) {
                                    showingEpisodeDetail = episode
                                }
                                .id(episode.id)
                            }
                        }
                        .padding(.leading, 60)
                        .padding(.trailing, 60)
                        .padding(.vertical, 20)
                    }
                    .onAppear {
                        scrollToCurrentEpisode(proxy: proxy)
                    }
                    .onChange(of: episodes) { _, _ in
                        scrollToCurrentEpisode(proxy: proxy)
                    }
                }
            }
        }
    }

    private func scrollToCurrentEpisode(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(item.id, anchor: .leading)
            }
        }
    }

    // MARK: - Season watched state

    private func seasonWatchAction(for season: BaseItemDto) -> SeasonWatchAction {
        // `episodes` only describes the selected season, and only once loaded.
        let loaded = season.id == selectedSeason?.id && !isLoadingEpisodes ? episodes : nil
        return SeasonWatchAction.resolve(season: season, loadedEpisodes: loaded)
    }

    func applySeasonWatch(_ request: SeasonWatchRequest) async {
        do {
            try await request.action.apply(seasonId: request.season.id)
        } catch {
            ToastManager.shared.show(SeasonWatchAction.failureMessage)
            return
        }
        ToastManager.shared.show(request.action.successMessage, type: .success)
        await reloadAfterSeasonWatchChange()
    }

    /// Refresh everything a season-wide played change touches, keeping the
    /// user on the season they were looking at (loadSeriesContent would jump
    /// to whichever season now holds Next Up).
    private func reloadAfterSeasonWatchChange() async {
        guard isSeries else { return }
        if let refreshed = try? await JellyfinClient.shared.getItem(itemId: item.id) {
            item = refreshed
            isWatched = refreshed.userData?.played ?? false
            hasProgress = refreshed.progressPercent > 0 && !isWatched
        }
        if let reloaded = try? await JellyfinClient.shared.getSeasons(seriesId: item.id) {
            seasons = reloaded
            selectedSeason = reloaded.first { $0.id == selectedSeason?.id } ?? selectedSeason
        }
        // findNextEpisodeToPlay only ever assigns, so a fully watched series
        // would otherwise keep pointing Play at the old Next Up.
        nextEpisodeToPlay = nil
        await findNextEpisodeToPlay()
        if let season = selectedSeason {
            await loadEpisodesForSeason(seriesId: item.id, season: season)
        }
        refreshID = UUID()
    }

    func loadEpisodesForSeason(seriesId: String, season: BaseItemDto) async {
        isLoadingEpisodes = true
        do {
            let loaded = try await JellyfinClient.shared.getEpisodes(seriesId: seriesId, seasonId: season.id)
            // Two quick tab presses race: if S1 resolves after S2 was selected,
            // assigning here would show S1's episodes under a highlighted S2
            // tab, and playing "S2E1" would start S1E1. Drop the stale result,
            // and leave the spinner up for the request still in flight.
            guard selectedSeason?.id == season.id else { return }
            episodes = loaded
        } catch {
            guard selectedSeason?.id == season.id else { return }
            ToastManager.shared.show("Failed to load episodes")
        }
        guard selectedSeason?.id == season.id else { return }
        isLoadingEpisodes = false
    }
}
