import SwiftUI
import NukeUI

/// A show's page while offline: the online detail layout (the iPad's
/// `MobileDetailView`, the iPhone's `PhoneDetailView`) over the downloaded
/// episodes only. Kept separate from those views, which are built around
/// server calls, but drawn with the same pieces so it reads as the same page.
struct OfflineShowView: View {
    let showKey: String
    @StateObject private var library = OfflineLibrary()
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var selectedSeason: Int?
    @State private var playingItem: BaseItemDto?
    @State private var startOverItem: BaseItemDto?

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        Group {
            if let show = library.show(forKey: showKey) {
                if isPad {
                    padLayout(show)
                } else {
                    phoneLayout(show)
                }
            } else if library.entries.isEmpty {
                Color.clear
            } else {
                ContentUnavailableView(
                    "No Downloaded Episodes",
                    systemImage: "arrow.down.circle",
                    description: Text("This show's downloads were removed.")
                )
            }
        }
        .background(MobileColors.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .fullScreenPlayer(item: $playingItem, serverID: library.show(forKey: showKey)?.serverID)
        .fullScreenPlayer(
            item: $startOverItem,
            serverID: library.show(forKey: showKey)?.serverID,
            startFromBeginning: true
        )
        .onAppear { library.reload() }
        .onChange(of: downloadManager.stateVersion) { _, _ in
            library.reload()
        }
    }

    // MARK: - iPad (MobileDetailView's layout)

    private func padLayout(_ show: OfflineShow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.xxl) {
                VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                    titleView(show, size: 28, maxHeight: 100)
                    metadataText(show)
                    actionButtons(show)
                        .padding(.top, MobileSpacing.xs)
                }
                .padding(.horizontal, MobileSpacing.md)
                .padding(.top, MobileSpacing.sm)

                VStack(alignment: .leading, spacing: MobileSpacing.lg) {
                    seasonTabs(show)
                        .padding(.horizontal, MobileSpacing.md)
                    VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                        episodesHeading
                            .padding(.horizontal, MobileSpacing.md)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: MobileSpacing.md) {
                                ForEach(episodes(of: show)) { episode in
                                    MobileEpisodeCard(
                                        episode: episode.item,
                                        isCurrentEpisode: episode.itemId == show.playTarget?.itemId,
                                        serverID: episode.serverID,
                                        artwork: OfflineArtwork.thumbnail(for: episode)
                                    ) {
                                        play(episode.item)
                                    }
                                    .pendingSyncBadge(episode.needsSync, size: 10)
                                }
                            }
                            .padding(.horizontal, MobileSpacing.md)
                        }
                    }
                }

                Spacer().frame(height: 40)
            }
        }
        .background { OfflineShowPadBackdrop(image: backdrop(for: show)) }
    }

    // MARK: - iPhone (PhoneDetailView's layout)

    private func phoneLayout(_ show: OfflineShow) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                phoneBackdrop(show)
                    .clipped()

                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    titleView(show, size: 22, maxHeight: 70)
                    metadataText(show)
                    ScrollView(.horizontal, showsIndicators: false) {
                        actionButtons(show)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    seasonTabs(show)
                    VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                        episodesHeading
                        LazyVStack(spacing: MobileSpacing.sm) {
                            ForEach(episodes(of: show)) { episode in
                                OfflinePhoneEpisodeRow(
                                    episode: episode,
                                    isCurrent: episode.itemId == show.playTarget?.itemId
                                ) {
                                    play(episode.item)
                                }
                            }
                        }
                    }
                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, MobileSpacing.md)
                .padding(.top, MobileSpacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
    }

    /// PhoneDetailView's 220pt backdrop band, image overlaid on a fixed frame
    /// so its size never drives the column width.
    private func phoneBackdrop(_ show: OfflineShow) -> some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .overlay {
                    if let backdrop = backdrop(for: show) {
                        backdrop.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(MobileColors.cardBackground)
                    }
                }
                .clipped()

            LinearGradient(colors: [.clear, MobileColors.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 80)
        }
    }

    // MARK: - Shared pieces

    /// The series logo when the image cache still has it from browsing
    /// online (never fetched: this page is offline), else the title.
    @ViewBuilder
    private func titleView(_ show: OfflineShow, size: CGFloat, maxHeight: CGFloat) -> some View {
        let title = Text(show.name)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(MobileColors.textPrimary)
            .lineLimit(3)
        if let request = cachedLogoRequest(for: show) {
            Color.clear
                .frame(maxWidth: isPad ? 300 : .infinity, alignment: .leading)
                .frame(height: maxHeight)
                .overlay(alignment: .leading) {
                    LazyImage(request: request) { state in
                        if let image = state.image {
                            image.resizable().scaledToFit()
                        } else {
                            title
                        }
                    }
                }
        } else {
            title
        }
    }

    private func cachedLogoRequest(for show: OfflineShow) -> ImageRequest? {
        guard let seriesId = show.seriesId else { return nil }
        let serverURL = show.serverID.flatMap { id in
            SessionManager.shared.servers.first { $0.id == id }?.url
        }
        guard let url = JellyfinClient.shared.syncImageURL(
            itemId: seriesId,
            imageType: "Logo",
            maxWidth: 500,
            serverURL: serverURL
        ) else { return nil }
        // Same URL as the online page, so the request hits its cache entry.
        var request = SashimiImagePipeline.request(url: url)
        request.options.insert(.returnCacheDataDontLoad)
        return request
    }

    private func metadataText(_ show: OfflineShow) -> some View {
        var parts: [String] = []
        if let year = show.year {
            parts.append(String(year))
        }
        let seasons = show.seasons.count
        if seasons > 0 {
            parts.append(seasons == 1 ? "1 Season" : "\(seasons) Seasons")
        }
        parts.append(show.episodes.count == 1 ? "1 Episode Downloaded" : "\(show.episodes.count) Episodes Downloaded")
        return Text(parts.joined(separator: " • "))
            .font(MobileTypography.caption)
            .foregroundStyle(MobileColors.textSecondary)
            .lineLimit(1)
    }

    /// The online series buttons that work offline: Resume / Play the next
    /// downloaded episode, start it over, and shuffle the downloads.
    private func actionButtons(_ show: OfflineShow) -> some View {
        HStack(spacing: MobileSpacing.md) {
            if let target = show.playTarget {
                let resumes = target.isInProgress
                let label: String = {
                    if let season = target.seasonNumber, let number = target.episodeNumber {
                        return "\(resumes ? "Resume" : "Play") S\(season):E\(number)"
                    }
                    return resumes ? "Resume" : "Play"
                }()
                Button {
                    play(target.item)
                } label: {
                    Label(label, systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize()
                }
                .buttonStyle(.borderedProminent)

                if resumes {
                    Button {
                        ThemeSongPlayer.shared.stopForPlayback()
                        startOverItem = target.item
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 20))
                            .foregroundStyle(MobileColors.textSecondary)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityLabel("Start Over")
                }
            }

            if show.episodes.count > 1 {
                Button {
                    if let random = show.episodes.randomElement() {
                        play(random.item)
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
    }

    /// Season capsules, only for seasons that have downloads.
    @ViewBuilder
    private func seasonTabs(_ show: OfflineShow) -> some View {
        let seasons = show.seasons
        if seasons.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MobileSpacing.sm) {
                    ForEach(seasons, id: \.self) { season in
                        let isSelected = season == currentSeason(of: show)
                        Button {
                            selectedSeason = season
                        } label: {
                            Text(season == 0 ? "Specials" : "Season \(season)")
                                .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(isSelected ? MobileColors.accent : MobileColors.cardBackground)
                                .foregroundStyle(isSelected ? .black : .white)
                                .clipShape(Capsule())
                        }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var episodesHeading: some View {
        Text("Episodes")
            .font(MobileTypography.headline)
            .foregroundStyle(MobileColors.textPrimary)
    }

    /// The tab on screen: the viewer's pick, else the season of the episode
    /// the Play button would start.
    private func currentSeason(of show: OfflineShow) -> Int? {
        if let selectedSeason, show.seasons.contains(selectedSeason) {
            return selectedSeason
        }
        return show.playTarget?.seasonNumber ?? show.seasons.first
    }

    private func episodes(of show: OfflineShow) -> [OfflineEntry] {
        guard show.seasons.count > 1, let season = currentSeason(of: show) else { return show.episodes }
        return show.episodes.filter { $0.seasonNumber == season }
    }

    /// The play target's art, else any downloaded episode's.
    private func backdrop(for show: OfflineShow) -> Image? {
        if let target = show.playTarget, let image = OfflineArtwork.landscape(for: target) {
            return image
        }
        return show.episodes.lazy.compactMap(OfflineArtwork.landscape(for:)).first
    }

    private func play(_ item: BaseItemDto) {
        ThemeSongPlayer.shared.stopForPlayback()
        playingItem = item
    }
}

// MARK: - Pieces

/// MobileDetailView's backdrop: the art at the top right, faded into the
/// page on its left and lower edges.
private struct OfflineShowPadBackdrop: View {
    let image: Image?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                MobileColors.background

                HStack {
                    Spacer()
                    if let image {
                        image
                            .resizable().scaledToFit()
                            .frame(width: geometry.size.width * 0.55)
                            .mask(
                                LinearGradient(
                                    colors: [.clear, .white, .white, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .mask(
                                    LinearGradient(
                                        colors: [.white, .white, .white, .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            )
                            .padding(.trailing, 20)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                LinearGradient(
                    colors: [Color.black.opacity(0.5), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)
                .frame(maxHeight: .infinity, alignment: .top)

                LinearGradient(
                    colors: [
                        MobileColors.background.opacity(0.0),
                        MobileColors.background.opacity(0.1),
                        MobileColors.background.opacity(0.5),
                        MobileColors.background
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }
}

/// PhoneDetailView's vertical episode row: still, E#, title, runtime.
private struct OfflinePhoneEpisodeRow: View {
    let episode: OfflineEntry
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MobileSpacing.sm) {
                thumbnail
                    .frame(width: 120, height: 68)
                    .offlineIndicator(itemId: episode.itemId, serverID: episode.serverID, size: 14)
                    .pendingSyncBadge(episode.needsSync, size: 9)
                    .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))
                    .currentEpisodeHighlight(isCurrent)

                VStack(alignment: .leading, spacing: 4) {
                    if let number = episode.episodeNumber {
                        Text("E\(number)")
                            .font(MobileTypography.captionSmall)
                            .foregroundStyle(MobileColors.accent)
                    }
                    Text(episode.name)
                        .font(MobileTypography.titleSmall)
                        .foregroundStyle(MobileColors.textPrimary)
                        .lineLimit(2)
                    if let runtime = runtimeText {
                        Text(runtime)
                            .font(MobileTypography.captionSmall)
                            .foregroundStyle(MobileColors.textTertiary)
                    }
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = OfflineArtwork.thumbnail(for: episode) {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(MobileColors.cardBackground)
                }
            }
            .frame(width: 120, height: 68)

            if episode.isPlayed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, Color(red: 0.29, green: 0.73, blue: 0.47))
                    .padding(3)
            }

            if episode.item.progressPercent > 0 {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        Rectangle()
                            .fill(MobileColors.accent)
                            .frame(width: geo.size.width * episode.item.progressPercent, height: 3)
                    }
                    .frame(height: 3)
                }
            }
        }
    }

    private var runtimeText: String? {
        guard let ticks = episode.runTimeTicks, ticks > 0 else { return nil }
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }
}
