import SwiftUI

/// One season of a show (#760) on iPhone, iPad and Mac: poster, the show's
/// name, "Season N · X episodes · Y of X watched", Play for the next
/// unwatched episode, the season-wide watched mark, Download Season, Series,
/// and the season's episodes in the series page's card style, under the
/// series' backdrop and hero trailer (#764).
struct MobileSeasonView: View {
    var libraryName: String?
    var serverID: String?
    let layout: AdaptiveDetailLayout

    @StateObject private var model: SeasonDetailViewModel
    @State private var playingItem: BaseItemDto?
    @State private var startOverItem: BaseItemDto?
    @State private var showingEpisode: BaseItemDto?
    @State private var seasonWatchRequest: SeasonWatchRequest?
    @State private var errorMessage: String?

    init(season: BaseItemDto, libraryName: String? = nil, serverID: String? = nil, layout: AdaptiveDetailLayout) {
        self.libraryName = libraryName
        self.serverID = serverID
        self.layout = layout
        _model = StateObject(wrappedValue: SeasonDetailViewModel(season: season))
    }

    private var isYouTube: Bool {
        libraryName?.lowercased().contains("youtube") == true
            || model.season.path?.lowercased().contains("youtube") == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // iPhone: the series' backdrop and trailer across the top, as
                // on the series page.
                if layout == .phone {
                    PhoneHeroBanner(serverID: serverID, trailerItem: model.season) { width in
                        heroURL(maxWidth: ImageSizing.backdropPixelWidth(points: width >= 1 ? width : 440))
                            .map { SashimiImagePipeline.request(url: $0, serverID: serverID) }
                    }
                    .clipped()
                }
                VStack(alignment: .leading, spacing: MobileSpacing.xl) {
                    header
                    episodesSection
                }
                .padding(MobileSpacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
        // iPad and Mac: the series' backdrop and trailer top-right, fading
        // into the page, as on the series page (#764).
        .background {
            if layout == .pad {
                PadDetailHeroBackground(serverID: serverID, trailerItem: model.season) { maxWidth in
                    heroURL(maxWidth: maxWidth)
                }
            } else {
                MobileColors.background
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .themeSong(for: model.season)
        .fullScreenPlayer(item: $playingItem, serverID: serverID)
        .fullScreenPlayer(item: $startOverItem, serverID: serverID, startFromBeginning: true)
        .sheet(item: $showingEpisode) { episode in
            NavigationStack {
                AdaptiveDetailView(item: episode, libraryName: libraryName, serverID: serverID)
            }
        }
        .seasonWatchConfirmation($seasonWatchRequest) { request in
            Task {
                if !(await model.applySeasonWatch(request.action)) {
                    errorMessage = SeasonWatchAction.failureMessage
                }
            }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await model.load() }
        // Posted once the player's stopped report is in: the next episode
        // (and its checkmark) has moved on.
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
            Task { await model.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sashimiPlayedStateDidChange)) { note in
            guard let change = PlayedStateChange.from(note) else { return }
            Task { await model.apply(change) }
        }
    }

    /// The series' backdrop (a YouTube channel's banner): seasons have none.
    private func heroURL(maxWidth: Int) -> URL? {
        let hero = DetailHero.mobileImage(for: model.season, isYouTubeSeries: isYouTube)
        let serverURL = serverID.flatMap { id in SessionManager.shared.servers.first { $0.id == id }?.url }
            ?? (serverID == nil ? SessionManager.shared.serverURL : nil)
        guard let serverURL else { return nil }
        return JellyfinClient.shared.syncImageURL(
            itemId: hero.itemId,
            imageType: hero.type,
            maxWidth: hero.type == "Banner" ? 1920 : maxWidth,
            tag: model.season.imageTag(for: hero.type, itemId: hero.itemId),
            serverURL: serverURL
        )
    }

    // MARK: - Header

    private var posterSize: CGSize {
        layout == .pad ? CGSize(width: 180, height: 270) : CGSize(width: 110, height: 165)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.md) {
            HStack(alignment: .top, spacing: MobileSpacing.md) {
                SmartPosterImage(
                    itemIds: [model.season.id, model.seriesId].compactMap { $0 },
                    maxWidth: ImageSizing.pixelWidth(points: posterSize.width),
                    serverID: serverID,
                    tagSource: model.season
                )
                .frame(width: posterSize.width, height: posterSize.height)
                .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))

                VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                    Text(isYouTube ? model.title.cleanedYouTubeTitle : model.title)
                        .font(.system(size: layout == .pad ? 28 : 22, weight: .bold))
                        .foregroundStyle(MobileColors.textPrimary)
                        .lineLimit(3)
                    Text(model.subtitle)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                    infoRow
                    // iPad and Mac have the width for the buttons beside the poster.
                    if layout == .pad {
                        actionRow
                            .padding(.top, MobileSpacing.xs)
                    }
                }
            }
            if layout == .phone {
                actionRow
            }
        }
    }

    private var infoRow: some View {
        WrappingHStack(spacing: MobileSpacing.sm) {
            if let year = model.season.productionYear {
                Text(String(year))
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
            }
            if let rating = model.officialRating {
                Text(rating)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MobileColors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4), lineWidth: 1))
            }
            if let status = model.status {
                SeriesStatusBadge(status: status)
            }
        }
    }

    /// Wraps onto a second line when it doesn't fit (a phone) rather than
    /// hiding Download Season and Series off the edge.
    private var actionRow: some View {
        WrappingHStack(spacing: MobileSpacing.sm) {
            if let target = model.playTarget {
                Button {
                    DetailAmbience.stopForPlayback()
                    if target.startsOver {
                        startOverItem = target.episode
                    } else {
                        playingItem = target.episode
                    }
                } label: {
                    Label(target.title, systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize()
                }
                .buttonStyle(.borderedProminent)
            }

            if model.hasLoaded,
               SeasonWatchAction.canApply(to: model.season, isConnected: NetworkMonitor.shared.isConnected) {
                let action = model.watchAction
                Button {
                    seasonWatchRequest = SeasonWatchRequest(season: model.season, action: action)
                } label: {
                    Label(action.title, systemImage: action == .markWatched ? "checkmark.circle" : "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            if NetworkMonitor.shared.isOnline, !model.episodes.isEmpty {
                BulkDownloadMenu(
                    seasonEpisodes: model.episodes,
                    seasonName: model.season.name,
                    serverID: serverID,
                    title: "Download Season"
                )
            }

            // A link rather than a navigationDestination: this page is itself
            // pushed, and a destination declared on a pushed page never fired.
            if let series = model.series {
                NavigationLink {
                    AdaptiveDetailView(item: series, libraryName: libraryName, serverID: serverID)
                } label: {
                    Label("Series", systemImage: "tv")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
    }

    // MARK: - Episodes

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("Episodes")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)

            if model.isLoading && !model.hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
            } else if model.episodes.isEmpty {
                Text(model.loadFailed ? "Couldn't load this season's episodes." : "This season has no episodes.")
                    .font(MobileTypography.body)
                    .foregroundStyle(MobileColors.textSecondary)
            } else if layout == .pad {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: MobileSpacing.md, alignment: .top)],
                    alignment: .leading,
                    spacing: MobileSpacing.lg
                ) {
                    ForEach(model.episodes) { episode in
                        MobileEpisodeCard(
                            episode: episode,
                            isCurrentEpisode: episode.id == model.playTarget?.episode.id,
                            isYouTube: isYouTube,
                            serverID: serverID
                        ) {
                            showingEpisode = episode
                        }
                        .contextMenu {
                            // The episode download menu (#744); acts on the active server.
                            if serverID == nil { ItemContextMenu(item: episode) }
                        }
                    }
                }
            } else {
                LazyVStack(spacing: MobileSpacing.sm) {
                    ForEach(model.episodes) { episode in
                        PhoneEpisodeRow(
                            episode: episode,
                            isCurrentEpisode: episode.id == model.playTarget?.episode.id,
                            isYouTube: isYouTube,
                            serverID: serverID
                        ) {
                            showingEpisode = episode
                        }
                    }
                }
            }
        }
    }
}
