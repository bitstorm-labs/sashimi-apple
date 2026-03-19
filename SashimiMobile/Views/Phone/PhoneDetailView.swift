import SwiftUI
import NukeUI

// swiftlint:disable file_length type_body_length
// PhoneDetailView handles movies, series, and episodes in one stacked layout - splitting would fragment related display logic

struct PhoneDetailView: View {
    let item: BaseItemDto
    var libraryName: String?

    // MARK: - State (mirrored from MobileDetailView)

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
    @State private var overviewExpanded = false
    @ObservedObject private var downloadManager = DownloadManager.shared

    // MARK: - Computed Properties

    private var isSeries: Bool { item.type == .series }
    private var isEpisode: Bool { item.type == .episode }
    private var isMovie: Bool { item.type == .movie }

    private var isYouTubeStyle: Bool {
        if let name = libraryName, name.lowercased().contains("youtube") {
            return true
        }
        return item.path?.lowercased().contains("youtube") ?? false
    }

    private var isYouTubeSeriesStyle: Bool {
        isSeries && isYouTubeStyle
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

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backdropSection

                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    titleSection
                    metadataRow
                    actionButtons
                    overviewSection

                    if isSeries {
                        seasonsSection
                    }

                    if let people = item.people, people.contains(where: { $0.type == "Actor" }) {
                        castSection(people)
                    }

                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, MobileSpacing.md)
                .padding(.top, MobileSpacing.sm)
            }
        }
        .background(MobileColors.background)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenPlayer(item: $playingItem)
        .sheet(item: $showingEpisodeDetail) { episode in
            PhoneEpisodeSheet(episode: episode, libraryName: libraryName)
        }
        .task {
            if let freshItem = try? await JellyfinClient.shared.getItem(itemId: item.id) {
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
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await refreshPlaybackState()
                }
            }
        }
    }

    // MARK: - Backdrop Section

    private var backdropSection: some View {
        ZStack(alignment: .bottom) {
            LazyImage(url: backdropImageURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(MobileColors.cardBackground)
                }
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(
                colors: [.clear, MobileColors.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
        }
    }

    // MARK: - Title Section

    @ViewBuilder
    private var titleSection: some View {
        if isEpisode {
            // Show series name above episode title
            if let seriesName = item.seriesName {
                Text(seriesName)
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
            }

            if !isYouTubeChannelEpisode, let season = item.parentIndexNumber, let episode = item.indexNumber {
                Text("S\(season):E\(episode)")
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.accent)
            }
        }

        Text(item.name)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(MobileColors.textPrimary)
    }

    // MARK: - Metadata Row

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: MobileSpacing.sm) {
            if let year = item.productionYear {
                Text(String(year))
            }

            if isSeries {
                let seasonCount = seasons.count
                if seasonCount > 0 {
                    Text("\u{2022}")
                    Text(seasonCount == 1 ? "1 Season" : "\(seasonCount) Seasons")
                }
            }

            if let runtime = item.runTimeTicks {
                Text("\u{2022}")
                Text(formatRuntime(runtime))
            }

            if let rating = item.officialRating {
                Text(rating)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MobileColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(MobileTypography.caption)
        .foregroundStyle(MobileColors.textSecondary)

        // Ratings row
        ratingsRow

        // Media info badges (non-series)
        if !isSeries {
            mediaInfoBadges
        }

        // Genres
        if let genres = item.genres, !genres.isEmpty {
            Text(genres.prefix(3).joined(separator: " \u{2022} "))
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textSecondary)
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
                        Text("\u{1F345}")
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

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        if isSeries {
            seriesActionButtons
        } else if isEpisode {
            episodeActionButtons
        } else {
            movieActionButtons
        }
    }

    private var seriesActionButtons: some View {
        HStack(spacing: MobileSpacing.sm) {
            if let nextEp = nextEpisodeToPlay {
                let epHasProgress = (nextEp.userData?.playbackPositionTicks ?? 0) > 0

                Button {
                    playingItem = nextEp
                } label: {
                    Label(epHasProgress ? "Resume" : "Play", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
            }

            watchedButton

            if !episodes.isEmpty {
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
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20))
                }
                .buttonStyle(.bordered)
                .confirmationDialog("Select Quality", isPresented: $showingDownloadQuality) {
                    ForEach(DownloadQuality.allCases) { quality in
                        Button("\(quality.displayName) \u{2014} \(quality.subtitle)") {
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
                if let count = Int(nextNInput), count > 0 {
                    downloadScope = .nextN(count)
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
        HStack(spacing: MobileSpacing.sm) {
            Button {
                playingItem = item
            } label: {
                Label(hasProgress ? "Resume" : "Play", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)

            watchedButton

            DownloadButton(item: item, quality: nil)

            if isEpisode, item.seriesId != nil {
                NavigationLink {
                    if let seriesItem = navigateToSeriesItem {
                        PhoneDetailView(item: seriesItem, libraryName: libraryName)
                    } else {
                        ProgressView()
                    }
                } label: {
                    Image(systemName: "tv")
                        .font(.system(size: 16))
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
    }

    private var movieActionButtons: some View {
        HStack(spacing: MobileSpacing.sm) {
            Button {
                playingItem = item
            } label: {
                Label(hasProgress ? "Resume" : "Play", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)

            watchedButton

            DownloadButton(item: item, quality: nil)

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
    }

    // MARK: - Overview Section

    @ViewBuilder
    private var overviewSection: some View {
        if let overview = item.overview, !overview.isEmpty {
            Text(overview)
                .font(MobileTypography.body)
                .foregroundStyle(MobileColors.textSecondary)
                .lineLimit(overviewExpanded ? nil : 3)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: MobileAnimation.normal)) {
                        overviewExpanded.toggle()
                    }
                }
        }
    }

    // MARK: - Seasons Section

    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.md) {
            if !seasons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MobileSpacing.sm) {
                        ForEach(seasons) { season in
                            Button {
                                selectedSeason = season
                                Task {
                                    await loadEpisodesForSeason(seriesId: item.id, season: season)
                                }
                            } label: {
                                Text(season.name)
                                    .font(.system(size: 14, weight: selectedSeason?.id == season.id ? .bold : .medium))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(selectedSeason?.id == season.id ? MobileColors.accent : MobileColors.cardBackground)
                                    .foregroundStyle(selectedSeason?.id == season.id ? .black : .white)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            if isLoadingEpisodes {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
            } else if !episodes.isEmpty {
                VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                    Text("Episodes")
                        .font(MobileTypography.headline)
                        .foregroundStyle(MobileColors.textPrimary)

                    episodeList
                }
            }
        }
    }

    // MARK: - Episode List (Vertical)

    private var episodeList: some View {
        LazyVStack(spacing: MobileSpacing.sm) {
            ForEach(episodes) { episode in
                Button {
                    showingEpisodeDetail = episode
                } label: {
                    HStack(spacing: MobileSpacing.sm) {
                        LazyImage(url: episodeThumbnailURL(episode)) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Rectangle().fill(MobileColors.cardBackground)
                            }
                        }
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))

                        VStack(alignment: .leading, spacing: 4) {
                            if !isYouTubeStyle, let epNum = episode.indexNumber {
                                Text("E\(epNum)")
                                    .font(MobileTypography.captionSmall)
                                    .foregroundStyle(MobileColors.accent)
                            }
                            Text(episode.name)
                                .font(MobileTypography.titleSmall)
                                .foregroundStyle(MobileColors.textPrimary)
                                .lineLimit(2)
                            if let runtime = episode.runTimeTicks {
                                Text(formatRuntime(runtime))
                                    .font(MobileTypography.captionSmall)
                                    .foregroundStyle(MobileColors.textTertiary)
                            }
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)
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

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileSpacing.md) {
                    ForEach(cast) { person in
                        MobileCastCard(person: person)
                    }
                }
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
            // Silently fail
        }
    }

    private func loadEpisodeContent() async {
        guard let seriesId = item.seriesId else { return }
        do {
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
        do {
            episodes = try await JellyfinClient.shared.getEpisodes(seriesId: seriesId, seasonId: season.id)
        } catch {
            // Silently fail
        }
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
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }

        if isEpisode {
            return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=1280")
        }

        if isYouTubeSeriesStyle {
            return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=800")
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

    private func episodeThumbnailURL(_ episode: BaseItemDto) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(episode.id)/Images/Primary?maxWidth=400")
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
}

// MARK: - Adaptive Detail View (routes iPhone vs iPad)

struct AdaptiveDetailView: View {
    let item: BaseItemDto
    var libraryName: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            PhoneDetailView(item: item, libraryName: libraryName)
        } else {
            MobileDetailView(item: item, libraryName: libraryName)
        }
    }
}
