import SwiftUI

/// One season of a show (#760): poster, the show's name, "Season N · X
/// episodes · Y of X watched", Play for the next unwatched episode, the
/// season-wide watched mark, Series, and the season's episodes.
struct SeasonDetailView: View {
    let serverID: String?
    var forceYouTubeStyle = false

    @StateObject private var model: SeasonDetailViewModel
    @State private var playingItem: BaseItemDto?
    @State private var startFromBeginning = false
    @State private var showingEpisode: BaseItemDto?
    @State private var showingSeries: BaseItemDto?
    @State private var seasonWatchRequest: SeasonWatchRequest?
    @Namespace private var focusScope
    @Environment(\.resetFocus) private var resetFocus

    init(season: BaseItemDto, serverID: String?, forceYouTubeStyle: Bool = false) {
        self.serverID = serverID
        self.forceYouTubeStyle = forceYouTubeStyle
        _model = StateObject(wrappedValue: SeasonDetailViewModel(season: season))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                    .padding(.horizontal, 60)
                    .focusSection()
                episodesSection
                    .focusSection()
            }
            .padding(.vertical, 60)
        }
        .focusScope(focusScope)
        .background(SashimiTheme.background.ignoresSafeArea())
        .fullScreenCover(item: $playingItem) { episode in
            PlayerView(item: episode, serverID: serverID, startFromBeginning: startFromBeginning)
        }
        .fullScreenCover(item: $showingEpisode) { episode in
            MediaDetailView(item: episode, forceYouTubeStyle: forceYouTubeStyle, serverID: serverID)
        }
        .fullScreenCover(item: $showingSeries) { series in
            MediaDetailView(item: series, forceYouTubeStyle: forceYouTubeStyle, serverID: serverID)
        }
        .seasonWatchConfirmation($seasonWatchRequest) { request in
            Task {
                if await model.applySeasonWatch(request.action) {
                    ToastManager.shared.show(request.action.successMessage, type: .success)
                } else {
                    ToastManager.shared.show(SeasonWatchAction.failureMessage)
                }
            }
        }
        .task { await model.load() }
        // Play only exists once the episodes are in, and a scope's preferred
        // focus is honoured only on first focus or a reset: hand it over then.
        .onChange(of: model.hasLoaded) { _, loaded in
            if loaded { resetFocus(in: focusScope) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidEnd)) { _ in
            Task { await model.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sashimiPlayedStateDidChange)) { note in
            guard let change = PlayedStateChange.from(note) else { return }
            Task { await model.apply(change) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 40) {
            SmartPosterImage(
                itemIds: [model.season.id, model.seriesId].compactMap { $0 },
                maxWidth: ImageSizing.pixelWidth(points: 260),
                serverID: serverID,
                tagSource: model.season
            )
            .frame(width: 260, height: 390)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 16) {
                Text(forceYouTubeStyle ? model.title.cleanedYouTubeTitle : model.title)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(2)

                Text(model.subtitle)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(SashimiTheme.textSecondary)

                infoRow

                actionRow
                    .padding(.top, 20)
            }
        }
    }

    private var infoRow: some View {
        HStack(spacing: 16) {
            if let year = model.season.productionYear {
                Text(String(year))
                    .font(.subheadline)
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
            if let rating = model.officialRating {
                Text(rating)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(SashimiTheme.textSecondary, lineWidth: 1.5)
                    )
            }
            if let status = model.status {
                SeriesStatusBadge(status: status, fontSize: 18)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 30) {
            if let target = model.playTarget {
                ActionButton(title: target.title, icon: "play.fill", isPrimary: true) {
                    startFromBeginning = target.startsOver
                    DetailAmbience.stopForPlayback()
                    playingItem = target.episode
                }
                .prefersDefaultFocus(in: focusScope)
            }

            if model.hasLoaded,
               SeasonWatchAction.canApply(to: model.season, isConnected: NetworkMonitor.shared.isConnected) {
                let action = model.watchAction
                ActionButton(
                    title: action.title,
                    icon: action == .markWatched ? "checkmark.circle" : "checkmark.circle.fill",
                    isActive: action == .markUnwatched
                ) {
                    seasonWatchRequest = SeasonWatchRequest(season: model.season, action: action)
                }
            }

            if let series = model.series {
                ActionButton(title: "Series", icon: "tv", isPrimary: false) {
                    showingSeries = series
                }
            }

            Spacer()
        }
    }

    // MARK: - Episodes

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Episodes")
                .font(.headline)
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 60)

            if model.isLoading && !model.hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            } else if model.episodes.isEmpty {
                EmptyStateView(
                    icon: "tv",
                    title: model.loadFailed ? "Couldn't Load Episodes" : "No Episodes",
                    message: model.loadFailed ? "Check the connection and try again" : "This season has no episodes"
                )
                .frame(maxWidth: .infinity)
                .frame(height: 220)
            } else {
                episodeStrip
            }
        }
    }

    private var episodeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy, as on the series page: a long season otherwise fires
                // every card's image request at once.
                LazyHStack(spacing: 30) {
                    ForEach(model.episodes) { episode in
                        EpisodeCard(
                            episode: episode,
                            isCurrentEpisode: episode.id == model.playTarget?.episode.id,
                            showEpisodeThumbnail: true
                        ) {
                            showingEpisode = episode
                        }
                        .id(episode.id)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .onAppear { scrollToPlayTarget(proxy) }
        }
    }

    private func scrollToPlayTarget(_ proxy: ScrollViewProxy) {
        guard let id = model.playTarget?.episode.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation { proxy.scrollTo(id, anchor: .leading) }
        }
    }
}
