import SwiftUI
import SwiftData
import NukeUI

// swiftlint:disable file_length type_body_length
// MobileDetailView handles movies, series, and episodes in one view - splitting would fragment related display logic

struct MobileDetailView: View {
    let item: BaseItemDto
    var libraryName: String?
    @State private var playingItem: BaseItemDto?
    @State private var seasons: [BaseItemDto] = []
    @State private var episodes: [BaseItemDto] = []
    @State private var selectedSeason: BaseItemDto?
    @State private var nextEpisodeToPlay: BaseItemDto?
    @State private var isLoadingEpisodes = false
    @State private var isWatched: Bool = false
    @State private var hasProgress: Bool = false
    @State private var seriesCommunityRating: Double?
    @State private var seriesCriticRating: Int?
    @State private var showingEpisodeDetail: BaseItemDto?
    @State private var mediaInfo: MediaSourceInfo?
    @State private var navigateToSeriesItem: BaseItemDto?
    @State private var downloadScope: DownloadScope?
    @State private var showingDownloadQuality = false
    @State private var showingNextNAlert = false
    @State private var showingNoUnwatchedAlert = false
    @State private var nextNInput = ""
    // Fail-closed: hide Original in the season/bulk menu unless the representative
    // first episode is confirmed device-compatible.
    @State private var seasonOriginalAllowed = false
    @ObservedObject private var downloadManager = DownloadManager.shared

    private var isSeries: Bool { item.type == .series }
    private var isEpisode: Bool { item.type == .episode }
    private var isMovie: Bool { item.type == .movie }

    // YouTube detection via libraryName or path
    private var isYouTubeStyle: Bool {
        if let name = libraryName, name.lowercased().contains("youtube") {
            return true
        }
        return item.path?.lowercased().contains("youtube") ?? false
    }

    private var isYouTubeSeriesStyle: Bool {
        isSeries && isYouTubeStyle
    }

    private var seriesMetadataParts: [String] {
        var parts: [String] = []
        if let year = item.productionYear {
            parts.append(String(year))
        }
        if !seasons.isEmpty {
            parts.append(seasons.count == 1 ? "1 Season" : "\(seasons.count) Seasons")
        }
        if let rating = item.officialRating {
            parts.append(rating)
        }
        return parts
    }

    private var isYouTubeChannelEpisode: Bool {
        isEpisode && isYouTubeStyle
    }

    private enum DownloadScope {
        case all
        case unwatched
        case nextN(Int)
    }

    private var episodesForDownload: [BaseItemDto] {
        guard let scope = downloadScope else { return [] }
        switch scope {
        case .all:
            return episodes
        case .unwatched:
            return episodes.filter { !($0.userData?.played ?? false) }
        case .nextN(let count):
            return Array(episodes.filter { !($0.userData?.played ?? false) }.prefix(count))
        }
    }

    // Drops .original from the season/bulk menu unless the representative episode
    // is confirmed device-compatible (mirrors DownloadButton.availableQualities).
    private var availableSeasonQualities: [DownloadQuality] {
        DownloadQuality.allCases.filter { $0 != .original || seasonOriginalAllowed }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.lg) {
                // Main content section with logo, title, info
                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    if isSeries {
                        seriesHeaderSection
                    } else if isEpisode {
                        episodeHeaderSection
                    } else {
                        movieHeaderSection
                    }

                    // Overview
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(MobileTypography.body)
                            .foregroundStyle(MobileColors.textSecondary)
                            .lineLimit(4)
                            .frame(maxWidth: UIScreen.main.bounds.width * 0.5, alignment: .leading)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
                .padding(.top, MobileSpacing.sm)

                // Seasons & Episodes for series
                if isSeries {
                    seasonsSection
                }

                // More Episodes for episode detail
                if isEpisode {
                    moreEpisodesSection
                }

                // Cast section
                if let people = item.people, people.contains(where: { $0.type == "Actor" }) {
                    castSection(people)
                }

                Spacer().frame(height: 40)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .background {
            // Background with backdrop image on the right
            GeometryReader { geometry in
                ZStack {
                    // Dark background base
                    MobileColors.background

                    // Backdrop image - top right (Plex-style)
                    HStack {
                        Spacer()
                        if let backdropURL = backdropImageURL {
                            LazyImage(url: backdropURL) { state in
                                if let image = state.image {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: geometry.size.width * (isYouTubeSeriesStyle ? 0.65 : (isSeries ? 0.55 : 0.5)))
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

                    // Subtle gradient for text readability
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
        .fullScreenPlayer(item: $playingItem)
        .sheet(item: $showingEpisodeDetail) { episode in
            NavigationStack {
                MobileDetailView(item: episode, libraryName: libraryName)
            }
        }
        .task {
            if NetworkMonitor.shared.isConnected,
               let freshItem = try? await JellyfinClient.shared.getItem(itemId: item.id) {
                isWatched = freshItem.userData?.played ?? false
                hasProgress = freshItem.progressPercent > 0
            } else {
                isWatched = item.userData?.played ?? false
                hasProgress = item.progressPercent > 0
            }
            await loadContent()
        }
        .onChange(of: playingItem) { _, newValue in
            if newValue == nil {
                // Player was dismissed — wait for stop() to report progress, then refresh
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await refreshPlaybackState()
                }
            }
        }
        .onChange(of: episodes.first?.id) { _, _ in
            seasonOriginalAllowed = false
            Task { await refreshSeasonOriginalAllowed() }
        }
    }

    /// Determines whether the season/bulk menu should offer Original, using the
    /// first (representative) episode as a proxy — series are uniformly encoded.
    /// Fails closed: any missing episode / source / error leaves it false.
    private func refreshSeasonOriginalAllowed() async {
        guard NetworkMonitor.shared.isConnected, let first = episodes.first else {
            seasonOriginalAllowed = false
            return
        }
        do {
            let info = try await JellyfinClient.shared.getPlaybackInfo(itemId: first.id)
            seasonOriginalAllowed = info.mediaSources?.first
                .map { DeviceMediaCompatibility.canDirectPlayOnDevice($0) } ?? false
        } catch {
            seasonOriginalAllowed = false
        }
    }

    // MARK: - Series Header

    private var seriesHeaderSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            // Series logo / YouTube channel art
            if isYouTubeSeriesStyle {
                // Circular channel art + cleaned title (matches tvOS)
                HStack(spacing: 12) {
                    if let channelArtURL = channelArtURL(for: item.id) {
                        LazyImage(url: channelArtURL) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Circle().fill(MobileColors.cardBackground)
                            }
                        }
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
                    }
                    Text((item.name ?? "Unknown").cleanedYouTubeTitle)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(MobileColors.textPrimary)
                }
            } else if let logoURL = logoImageURL(for: item.id) {
                LazyImage(url: logoURL) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(maxHeight: 100)
                .frame(maxWidth: 300, alignment: .leading)
            } else {
                // Fallback to title if no logo
                Text(item.name ?? "Unknown")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(MobileColors.textPrimary)
            }

            // Metadata + ratings row
            HStack(spacing: MobileSpacing.sm) {
                let metaParts = seriesMetadataParts
                if !metaParts.isEmpty {
                    Text(metaParts.joined(separator: " • "))
                }

                ratingsRow
            }
            .font(MobileTypography.caption)
            .foregroundStyle(MobileColors.textSecondary)

            // Genres
            if let genres = item.genres, !genres.isEmpty {
                Text(genres.prefix(3).joined(separator: " • "))
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
            }

            // Action buttons
            seriesActionButtons
        }
    }

    // MARK: - Episode Header

    private var episodeHeaderSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            // Series logo / YouTube channel art
            if isYouTubeChannelEpisode, let seriesId = item.seriesId {
                // Circular channel art (matches tvOS)
                HStack(spacing: 12) {
                    if let channelArtURL = channelArtURL(for: seriesId) {
                        LazyImage(url: channelArtURL) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Circle().fill(MobileColors.cardBackground)
                            }
                        }
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                    }
                    Text((item.seriesName ?? "").cleanedYouTubeTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(MobileColors.textSecondary)
                }
            } else if let seriesId = item.seriesId, let logoURL = logoImageURL(for: seriesId) {
                LazyImage(url: logoURL) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(maxHeight: 70)
                .frame(maxWidth: 250, alignment: .leading)
            } else if let seriesName = item.seriesName {
                Text(seriesName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MobileColors.textSecondary)
            }

            // Episode title (no S#:E# for YouTube)
            HStack(spacing: 8) {
                if !isYouTubeChannelEpisode, let season = item.parentIndexNumber, let episode = item.indexNumber {
                    Text("S\(season):E\(episode)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(MobileColors.textPrimary)
                    Text("•")
                        .foregroundStyle(MobileColors.textTertiary)
                }
                Text(item.name ?? "Unknown")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(2)
            }

            // Metadata row
            HStack(spacing: MobileSpacing.sm) {
                if let premiereDateStr = item.premiereDate {
                    Text(formatPremiereDate(premiereDateStr))
                }

                if let runtime = item.runTimeTicks {
                    Text("•")
                    Text(formatRuntime(runtime))
                }
            }
            .font(MobileTypography.caption)
            .foregroundStyle(MobileColors.textSecondary)

            // Ratings + media info
            HStack(spacing: MobileSpacing.sm) {
                ratingsRow
                mediaInfoBadges
            }

            // Action buttons
            episodeActionButtons
        }
    }

    // MARK: - Movie Header

    private var movieHeaderSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            // Movie logo or title
            if let logoURL = logoImageURL(for: item.id) {
                LazyImage(url: logoURL) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(maxHeight: 100)
                .frame(maxWidth: 300, alignment: .leading)
            } else {
                Text(item.name ?? "Unknown")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(MobileColors.textPrimary)
            }

            HStack(spacing: MobileSpacing.sm) {
                if let year = item.productionYear {
                    Text(String(year))
                }

                if let runtime = item.runTimeTicks {
                    Text("•")
                    Text(formatRuntime(runtime))
                }

                if let rating = item.officialRating {
                    Text("•")
                    Text(rating)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MobileColors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .font(MobileTypography.caption)
            .foregroundStyle(MobileColors.textSecondary)

            HStack(spacing: MobileSpacing.sm) {
                ratingsRow
                mediaInfoBadges
            }

            if let genres = item.genres, !genres.isEmpty {
                Text(genres.prefix(3).joined(separator: " • "))
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
            }

            movieActionButtons
        }
    }

    // MARK: - Ratings Row

    @ViewBuilder
    private var ratingsRow: some View {
        let communityRating = item.communityRating ?? seriesCommunityRating
        let criticRating = item.criticRating ?? seriesCriticRating

        if communityRating != nil || criticRating != nil {
            HStack(spacing: MobileSpacing.md) {
                if let rating = communityRating, rating > 0 {
                    HStack(spacing: 4) {
                        Image("TMDBLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 16)
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 14, weight: .bold))
                    }
                }

                if let critic = criticRating {
                    HStack(spacing: 4) {
                        Text("🍅")
                            .font(.system(size: 14))
                        Text("\(critic)%")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
            }
            .foregroundStyle(MobileColors.textPrimary)
        }
    }

    // MARK: - Media Info Badges

    @ViewBuilder
    private var mediaInfoBadges: some View {
        if let info = mediaInfo {
            HStack(spacing: 6) {
                if let resolution = info.videoResolution {
                    mediaInfoBadge(resolution)
                }
                if let videoCodec = info.videoCodec {
                    mediaInfoBadge(formatCodec(videoCodec))
                }
                if let audioCodec = info.audioCodec, let channels = info.audioChannels {
                    mediaInfoBadge("\(formatCodec(audioCodec)) \(formatChannels(channels))")
                }
            }
        }
    }

    private func mediaInfoBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(MobileColors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
    }

    private func formatCodec(_ codec: String) -> String {
        let upper = codec.uppercased()
        switch upper {
        case "HEVC", "H265": return "HEVC"
        case "H264", "AVC": return "H.264"
        case "AV1": return "AV1"
        case "AAC": return "AAC"
        case "AC3": return "DD"
        case "EAC3": return "DD+"
        case "TRUEHD": return "TrueHD"
        case "DTS": return "DTS"
        case "FLAC": return "FLAC"
        default: return upper
        }
    }

    private func formatChannels(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    // MARK: - Action Buttons

    private var seriesActionButtons: some View {
        HStack(spacing: MobileSpacing.md) {
            if let nextEp = nextEpisodeToPlay {
                let epHasProgress = (nextEp.userData?.playbackPositionTicks ?? 0) > 0
                let seasonNum = nextEp.parentIndexNumber ?? 1
                let epNum = nextEp.indexNumber ?? 1

                Button {
                    playingItem = nextEp
                } label: {
                    Label(
                        epHasProgress ? "Resume S\(seasonNum):E\(epNum)" : "Play S\(seasonNum):E\(epNum)",
                        systemImage: "play.fill"
                    )
                    .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
            }

            watchedButton

            // Download menu with scope options
            if !episodes.isEmpty && NetworkMonitor.shared.isConnected {
                Menu {
                    Button("All Episodes") {
                        downloadScope = .all
                        showingDownloadQuality = true
                    }
                    Button("Unwatched Only") {
                        let unwatched = episodes.filter { !($0.userData?.played ?? false) }
                        if unwatched.isEmpty {
                            showingNoUnwatchedAlert = true
                        } else {
                            downloadScope = .unwatched
                            showingDownloadQuality = true
                        }
                    }
                    Button("Custom...") {
                        let unwatched = episodes.filter { !($0.userData?.played ?? false) }
                        if unwatched.isEmpty {
                            showingNoUnwatchedAlert = true
                        } else {
                            nextNInput = ""
                            showingNextNAlert = true
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .confirmationDialog("Select Quality", isPresented: $showingDownloadQuality) {
                    ForEach(availableSeasonQualities) { quality in
                        Button("\(quality.displayName) — \(quality.subtitle)") {
                            DownloadManager.shared.downloadSeason(
                                episodes: episodesForDownload, quality: quality
                            )
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        downloadScope = nil
                    }
                }
            }

            Spacer()
        }
        .alert("Download Unwatched Episodes", isPresented: $showingNextNAlert) {
            TextField("Number of episodes", text: $nextNInput)
                .keyboardType(.numberPad)
            Button("OK") {
                if let n = Int(nextNInput), n > 0 {
                    downloadScope = .nextN(n)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showingDownloadQuality = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("How many unwatched episodes would you like to download?")
        }
        .alert("No Unwatched Episodes", isPresented: $showingNoUnwatchedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("All episodes in this season are already watched.")
        }
    }

    private var episodeActionButtons: some View {
        HStack(spacing: MobileSpacing.md) {
            Button {
                playingItem = item
            } label: {
                Label(hasProgress ? "Resume" : "Play", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)

            watchedButton

            if NetworkMonitor.shared.isConnected {
                DownloadButton(item: item, quality: nil)
            }

            if NetworkMonitor.shared.isConnected, isEpisode, item.seriesId != nil {
                NavigationLink {
                    if let seriesItem = navigateToSeriesItem {
                        MobileDetailView(item: seriesItem, libraryName: libraryName)
                    } else {
                        ProgressView()
                    }
                } label: {
                    Label("Series", systemImage: "tv")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            Spacer()
        }
    }

    private var movieActionButtons: some View {
        HStack(spacing: MobileSpacing.md) {
            Button {
                playingItem = item
            } label: {
                Label(hasProgress ? "Resume" : "Play", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)

            watchedButton

            if NetworkMonitor.shared.isConnected {
                DownloadButton(item: item, quality: nil)
            }

            Spacer()
        }
    }

    private var watchedButton: some View {
        Button {
            Task { await toggleWatched() }
        } label: {
            Image(systemName: isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(isWatched ? MobileColors.accent : MobileColors.textSecondary)
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }

    // MARK: - Seasons Section

    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.md) {
            if !seasons.isEmpty {
                // Season tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MobileSpacing.sm) {
                        ForEach(seasons) { season in
                            Button {
                                selectedSeason = season
                                Task {
                                    await loadEpisodesForSeason(seriesId: item.id, season: season)
                                }
                            } label: {
                                Text(season.name ?? "Season")
                                    .font(.system(size: 14, weight: selectedSeason?.id == season.id ? .bold : .medium))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(selectedSeason?.id == season.id ? MobileColors.accent : MobileColors.cardBackground)
                                    .foregroundStyle(selectedSeason?.id == season.id ? .black : .white)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, MobileSpacing.md)
                }
            }

            // Episodes
            if isLoadingEpisodes {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
            } else if !episodes.isEmpty {
                VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                    Text("Episodes")
                        .font(MobileTypography.headline)
                        .foregroundStyle(MobileColors.textPrimary)
                        .padding(.horizontal, MobileSpacing.md)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: MobileSpacing.md) {
                            ForEach(episodes) { episode in
                                MobileEpisodeCard(
                                    episode: episode,
                                    isCurrentEpisode: episode.id == nextEpisodeToPlay?.id,
                                    isYouTube: isYouTubeStyle
                                ) {
                                    showingEpisodeDetail = episode
                                }
                            }
                        }
                        .padding(.horizontal, MobileSpacing.md)
                    }
                }
            }
        }
    }

    // MARK: - More Episodes Section

    private var moreEpisodesSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            if !episodes.isEmpty {
                Text("More Episodes")
                    .font(MobileTypography.headline)
                    .foregroundStyle(MobileColors.textPrimary)
                    .padding(.horizontal, MobileSpacing.md)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MobileSpacing.md) {
                        ForEach(episodes) { episode in
                            MobileEpisodeCard(
                                episode: episode,
                                isCurrentEpisode: episode.id == item.id
                            ) {
                                showingEpisodeDetail = episode
                            }
                        }
                    }
                    .padding(.horizontal, MobileSpacing.md)
                }
            }
        }
    }

    // MARK: - Cast Section

    private func castSection(_ people: [PersonInfo]) -> some View {
        let cast = Array(people.filter { $0.type == "Actor" }.prefix(15))

        return VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("Cast")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.horizontal, MobileSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileSpacing.md) {
                    ForEach(cast) { person in
                        MobileCastCard(person: person)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }

    // MARK: - Data Loading

    private func loadContent() async {
        if isSeries {
            await loadSeriesContent()
        } else if isEpisode {
            await loadEpisodeContent()
        }

        guard NetworkMonitor.shared.isConnected else { return }

        if !isSeries {
            await loadMediaInfo()
        }

        if isEpisode, let seriesId = item.seriesId {
            navigateToSeriesItem = try? await JellyfinClient.shared.getItem(itemId: seriesId)
        }
    }

    private func loadMediaInfo() async {
        do {
            let playbackInfo = try await JellyfinClient.shared.getPlaybackInfo(itemId: item.id)
            mediaInfo = playbackInfo.mediaSources?.first
        } catch {
            // Not critical
        }
    }

    private func loadSeriesContent() async {
        guard NetworkMonitor.shared.isConnected else {
            await loadOfflineSeriesContent()
            return
        }
        do {
            seasons = try await JellyfinClient.shared.getSeasons(seriesId: item.id)
            await findNextEpisodeToPlay()

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
            await loadOfflineSeriesContent()
        }
    }

    private func loadOfflineSeriesContent() async {
        let downloaded = offlineEpisodes(for: item.id)
        guard !downloaded.isEmpty else { return }

        // Build synthetic season items from downloaded episodes
        let seasonNumbers = Array(Set(downloaded.compactMap { $0.seasonNumber })).sorted()
        seasons = seasonNumbers.map { num in
            BaseItemDto(
                id: "offline-season-\(num)",
                name: "Season \(num)",
                type: .season,
                seriesName: nil, seriesId: item.id, seasonId: nil, parentId: nil,
                indexNumber: num, parentIndexNumber: nil, overview: nil, runTimeTicks: nil,
                userData: nil, imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
                primaryImageAspectRatio: nil, mediaType: nil, productionYear: nil,
                communityRating: nil, officialRating: nil, genres: nil, taglines: nil,
                people: nil, criticRating: nil, premiereDate: nil, chapters: nil,
                path: nil, remoteTrailers: nil
            )
        }

        if let firstSeason = seasons.first {
            selectedSeason = firstSeason
            episodes = downloaded
                .filter { $0.seasonNumber == firstSeason.indexNumber }
                .map { $0.asBaseItemDto }
        }
    }

    private func offlineEpisodes(for seriesId: String) -> [DownloadedItem] {
        guard let container = DownloadManager.shared.modelContainer else { return [] }
        let context = ModelContext(container)
        let predicate = #Predicate<DownloadedItem> { $0.statusRaw == "completed" }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
        guard let items = try? context.fetch(descriptor) else { return [] }
        return items
            .filter { $0.seriesId == seriesId || $0.seriesName == item.name }
            .sorted {
                ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) <
                    ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
            }
    }

    private func loadEpisodeContent() async {
        guard let seriesId = item.seriesId else { return }
        do {
            // Get series ratings as fallback
            let series = try? await JellyfinClient.shared.getItem(itemId: seriesId)
            seriesCommunityRating = series?.communityRating
            seriesCriticRating = series?.criticRating

            if let seasonId = item.seasonId {
                episodes = try await JellyfinClient.shared.getEpisodes(seriesId: seriesId, seasonId: seasonId)
            }
        } catch {
            // Silently fail
        }
    }

    private func loadEpisodesForSeason(seriesId: String, season: BaseItemDto) async {
        isLoadingEpisodes = true
        if NetworkMonitor.shared.isConnected {
            do {
                episodes = try await JellyfinClient.shared.getEpisodes(seriesId: seriesId, seasonId: season.id)
                isLoadingEpisodes = false
                return
            } catch {
                // Fall through to offline
            }
        }
        let downloaded = offlineEpisodes(for: seriesId)
        episodes = downloaded
            .filter { $0.seasonNumber == season.indexNumber }
            .map { $0.asBaseItemDto }
        isLoadingEpisodes = false
    }

    private func findNextEpisodeToPlay() async {
        do {
            let nextUpItems = try await JellyfinClient.shared.getNextUp(limit: 50)
            if let next = nextUpItems.first(where: { $0.seriesId == item.id }) {
                nextEpisodeToPlay = next
                return
            }
            for season in seasons {
                let eps = try await JellyfinClient.shared.getEpisodes(seriesId: item.id, seasonId: season.id)
                if let firstUnwatched = eps.first(where: { !($0.userData?.played ?? false) }) {
                    nextEpisodeToPlay = firstUnwatched
                    return
                }
            }
        } catch {
            // Silently fail
        }
    }

    private func refreshPlaybackState() async {
        guard let freshItem = try? await JellyfinClient.shared.getItem(itemId: item.id) else { return }
        isWatched = freshItem.userData?.played ?? false
        hasProgress = freshItem.progressPercent > 0
        // For series, also refresh next-up episode
        if isSeries {
            await findNextEpisodeToPlay()
        }
    }

    private func toggleWatched() async {
        let newState = !isWatched
        isWatched = newState
        if newState {
            hasProgress = false
        }
        do {
            if newState {
                try await JellyfinClient.shared.markPlayed(itemId: item.id)
            } else {
                try await JellyfinClient.shared.markUnplayed(itemId: item.id)
            }
        } catch {
            isWatched = !newState
        }
    }

    // MARK: - URLs

    private var backdropImageURL: URL? {
        // Offline: use local files
        if !NetworkMonitor.shared.isConnected {
            // For series, check first downloaded episode's backdrop
            if isSeries {
                let downloaded = offlineEpisodes(for: item.id)
                if let firstEp = downloaded.first {
                    return OfflineImageHelper.backdropURL(for: firstEp.itemId)
                        ?? OfflineImageHelper.thumbnailURL(for: firstEp.itemId)
                }
            }
            return OfflineImageHelper.backdropURL(for: item.id)
                ?? OfflineImageHelper.thumbnailURL(for: item.id)
        }

        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }

        if isEpisode {
            return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=1280")
        }

        if isYouTubeSeriesStyle {
            return URL(string: "\(serverURL)/Items/\(item.id)/Images/Banner?maxWidth=1920")
        }

        let imageId: String
        if item.backdropImageTags?.isEmpty == false {
            imageId = item.id
        } else if item.parentBackdropImageTags?.isEmpty == false, let seriesId = item.seriesId {
            imageId = seriesId
        } else {
            return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=1280")
        }

        return URL(string: "\(serverURL)/Items/\(imageId)/Images/Backdrop?maxWidth=1280")
    }

    private func logoImageURL(for itemId: String) -> URL? {
        guard NetworkMonitor.shared.isConnected else { return nil }
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(itemId)/Images/Logo?maxWidth=500")
    }

    private func channelArtURL(for itemId: String) -> URL? {
        guard NetworkMonitor.shared.isConnected else { return nil }
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(itemId)/Images/Primary?maxWidth=240")
    }

    // MARK: - Formatting

    private func formatRuntime(_ ticks: Int64) -> String {
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }

    private func formatPremiereDate(_ dateStr: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "MMMM d, yyyy"
            return displayFormatter.string(from: date)
        }
        return ""
    }
}

// MARK: - Episode Card

struct MobileEpisodeCard: View {
    let episode: BaseItemDto
    var isCurrentEpisode: Bool = false
    var isYouTube: Bool = false
    let action: () -> Void

    private var imageURL: URL? {
        if !NetworkMonitor.shared.isConnected {
            return OfflineImageHelper.thumbnailURL(for: episode.id)
        }
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(episode.id)/Images/Primary?maxWidth=400")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                ZStack(alignment: .bottomLeading) {
                    // Thumbnail
                    if let url = imageURL {
                        LazyImage(url: url) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Rectangle()
                                    .fill(MobileColors.cardBackground)
                            }
                        }
                    } else {
                        Rectangle()
                            .fill(MobileColors.cardBackground)
                    }

                    // Progress bar
                    if episode.progressPercent > 0 {
                        VStack {
                            Spacer()
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(MobileColors.progressBackground)
                                    Rectangle()
                                        .fill(MobileColors.accent)
                                        // progressPercent is a 0-1 fraction, not 0-100
                                        .frame(width: geo.size.width * CGFloat(episode.progressPercent))
                                }
                            }
                            .frame(height: 3)
                        }
                    }

                    // Watched checkmark
                    if episode.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, Color(red: 0.29, green: 0.73, blue: 0.47))
                            .font(.system(size: 18))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(6)
                    }
                }
                .frame(width: 180, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: MobileCornerRadius.small)
                        .stroke(isCurrentEpisode ? MobileColors.accent : .clear, lineWidth: 2)
                )

                // Episode info
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.name ?? "Episode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MobileColors.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if !isYouTube, let ep = episode.indexNumber {
                            Text("E\(ep)")
                        }
                        if let runtime = episode.runTimeTicks {
                            let prefix = isYouTube ? "" : "• "
                            Text("\(prefix)\(runtime / 10_000_000 / 60) min")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(MobileColors.textTertiary)
                }
                .frame(width: 180, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cast Card

struct MobileCastCard: View {
    let person: PersonInfo

    private var imageURL: URL? {
        guard person.primaryImageTag != nil else { return nil }
        return JellyfinClient.shared.personImageURL(personId: person.id, maxWidth: 150)
    }

    var body: some View {
        VStack(spacing: MobileSpacing.xs) {
            if let url = imageURL {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        placeholderCircle
                    }
                }
                .frame(width: 70, height: 70)
                .clipShape(Circle())
            } else {
                placeholderCircle
            }

            Text(person.name ?? "Unknown")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MobileColors.textPrimary)
                .lineLimit(1)

            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(.system(size: 10))
                    .foregroundStyle(MobileColors.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: 80)
    }

    private var placeholderCircle: some View {
        Circle()
            .fill(MobileColors.cardBackground)
            .frame(width: 70, height: 70)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(MobileColors.textTertiary)
            }
    }
}
