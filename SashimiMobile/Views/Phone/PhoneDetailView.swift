import SwiftUI
import SwiftData
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
    @State private var startOverItem: BaseItemDto?
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
    // Fail-closed: hide Original in the season/bulk menu unless the representative
    // first episode is confirmed device-compatible.
    @State private var seasonOriginalAllowed = false
    @ObservedObject private var downloadManager = DownloadManager.shared

    // MARK: - Computed Properties

    private var isSeries: Bool { item.type == .series }
    private var isEpisode: Bool { item.type == .episode }
    /// The series whose seasons/episodes this page lists (self for a series,
    /// the parent for an episode) — drives the shared episode machinery.
    private var contentSeriesId: String { isSeries ? item.id : (item.seriesId ?? item.id) }
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

    // Drops .original from the season/bulk menu unless the representative episode
    // is confirmed device-compatible (mirrors DownloadButton.availableQualities).
    private var availableSeasonQualities: [DownloadQuality] {
        DownloadQuality.allCases.filter { $0 != .original || seasonOriginalAllowed }
    }

    // MARK: - Body

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                backdropSection
                    .clipped()

                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    titleSection
                    metadataRow
                    actionButtons
                    overviewSection

                    if isSeries || isEpisode {
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
            .frame(maxWidth: .infinity)
        }
        .clipped()
        .background(MobileColors.background)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenPlayer(item: $playingItem)
        .fullScreenPlayer(item: $startOverItem, startFromBeginning: true)
        .sheet(item: $showingEpisodeDetail) { episode in
            // Full detail view — one consistent episode UI (matches iPad)
            NavigationStack {
                PhoneDetailView(item: episode, libraryName: libraryName)
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

    // MARK: - Backdrop Section

    @ViewBuilder
    private var backdropSection: some View {
        if isYouTubeSeriesStyle {
            VStack(spacing: 0) {
                // Banner
                ZStack(alignment: .bottom) {
                    LazyImage(url: backdropImageURL) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(MobileColors.cardBackground)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 120)
                    .clipped()

                    LinearGradient(
                        colors: [.clear, MobileColors.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 60)
                }

                // Channel avatar overlapping banner
                LazyImage(url: channelAvatarURL) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Circle().fill(MobileColors.cardBackground)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                .offset(y: -36)
                .padding(.bottom, -24)
            }
        } else {
            ZStack(alignment: .bottom) {
                LazyImage(url: backdropImageURL) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
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
    }

    private var channelAvatarURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=240")
    }

    // MARK: - Title Section

    @ViewBuilder
    private var titleSection: some View {
        if isEpisode {
            if !isYouTubeChannelEpisode, let seriesId = item.seriesId, let logoURL = logoImageURL(for: seriesId) {
                LazyImage(url: logoURL) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 56)
                    } else if state.error != nil, let seriesName = item.seriesName {
                        Text(seriesName)
                            .font(MobileTypography.caption)
                            .foregroundStyle(MobileColors.textSecondary)
                    }
                }
            } else if let seriesName = item.seriesName {
                Text(isYouTubeStyle ? seriesName.cleanedYouTubeTitle : seriesName)
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
            }

            if !isYouTubeChannelEpisode, let season = item.parentIndexNumber, let episode = item.indexNumber {
                Text("S\(season):E\(episode)")
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.accent)
            }
        }

        if isSeries, !isYouTubeSeriesStyle, let logoURL = logoImageURL(for: item.id) {
            LazyImage(url: logoURL) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else if state.error != nil {
                    seriesTitleText
                }
            }
            .frame(maxHeight: 70)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            seriesTitleText
        }
    }

    private var seriesTitleText: some View {
        Text(isYouTubeSeriesStyle ? item.name.cleanedYouTubeTitle : item.name)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(MobileColors.textPrimary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: isYouTubeSeriesStyle ? .center : .leading)
            .clipped()
    }

    private var trailerURL: URL? {
        guard let raw = item.remoteTrailers?.first?.url else { return nil }
        return URL(string: raw)
    }

    private func logoImageURL(for itemId: String) -> URL? {
        JellyfinClient.shared.imageURL(itemId: itemId, imageType: "Logo", maxWidth: 500)
    }

    /// Premiere date "November 8, 2024" (tvOS parity)
    private var premiereDateLongText: String? {
        guard let raw = item.premiereDate else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM d, yyyy"
        return fmt.string(from: date)
    }

    /// Episode air date "Nov 8, 2024" (short form for list rows)
    private func shortAirDateText(_ episode: BaseItemDto) -> String? {
        guard let raw = episode.premiereDate else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy"
        return fmt.string(from: date)
    }

    /// "Ends at 9:41 PM"
    private var endsAtText: String? {
        guard let ticks = item.runTimeTicks, ticks > 0 else { return nil }
        let end = Date().addingTimeInterval(Double(ticks) / 10_000_000)
        let fmt = DateFormatter(); fmt.timeStyle = .short
        return "Ends at \(fmt.string(from: end))"
    }

    // MARK: - Metadata Row

    @ViewBuilder
    private var metadataRow: some View {
        // Metadata line: date • runtime, then a blue "Ends at" (tvOS accent)
        HStack(spacing: 6) {
            let parts = metadataParts
            if !parts.isEmpty {
                Text(parts.joined(separator: " \u{2022} "))
                    .foregroundStyle(MobileColors.textSecondary)
            }
            if let ends = endsAtText {
                if !parts.isEmpty {
                    Text("\u{2022}").foregroundStyle(MobileColors.textSecondary)
                }
                Text(ends).foregroundStyle(MobileColors.accent)
            }
        }
        .font(MobileTypography.caption)
        .lineLimit(1)

        // Ratings + media (quality) chips on a single line
        HStack(spacing: MobileSpacing.sm) {
            ratingsRow
            if !isSeries {
                mediaInfoBadges
            }
        }

        // Cert chip + genres — movies only (tvOS-style stroked cert chip)
        if isMovie {
            HStack(spacing: MobileSpacing.sm) {
                if let rating = item.officialRating {
                    Text(rating)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MobileColors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4), lineWidth: 1))
                }
                if let genres = item.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " \u{2022} "))
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        if let dateText = premiereDateLongText {
            parts.append(dateText)
        } else if let year = item.productionYear {
            parts.append(String(year))
        }
        if let runtime = item.runTimeTicks {
            parts.append(formatRuntime(runtime))
        }
        return parts
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
                    audioInfoBadge(codec: audioCodec, channels: channels)
                }
            }
        }
    }

    /// Audio badge with the real Dolby/DTS wordmark where available (tvOS parity)
    @ViewBuilder
    private func audioInfoBadge(codec: String, channels: Int) -> some View {
        if let logoName = audioCodecLogoName(codec) {
            HStack(spacing: 4) {
                Image(logoName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 10)
                Text(formatChannels(channels))
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(MobileColors.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.3), lineWidth: 1))
        } else {
            mediaInfoBadge("\(formatCodec(codec)) \(formatChannels(channels))")
        }
    }

    private func audioCodecLogoName(_ codec: String) -> String? {
        switch codec.uppercased() {
        case "AC3": return "DolbyDigital"
        case "EAC3": return "DolbyDigitalPlus"
        case "TRUEHD": return "DolbyTrueHD"
        case "DTS", "DCA": return "DTS"
        default: return nil
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
                let epLabel: String = {
                    if let sNum = nextEp.parentIndexNumber, let eNum = nextEp.indexNumber {
                        return "\(epHasProgress ? "Resume" : "Play") S\(sNum):E\(eNum)"
                    }
                    return epHasProgress ? "Resume" : "Play"
                }()

                Button {
                    playingItem = nextEp
                } label: {
                    Label(epLabel, systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)

                if epHasProgress {
                    Button {
                        startOverItem = nextEp
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }

            if let trailerURL, NetworkMonitor.shared.isConnected {
                Button {
                    UIApplication.shared.open(trailerURL)
                } label: {
                    Image(systemName: "film")
                        .font(.system(size: 16))
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            watchedButton

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
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20))
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .confirmationDialog("Select Quality", isPresented: $showingDownloadQuality) {
                    ForEach(availableSeasonQualities) { quality in
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

            if hasProgress {
                Button {
                    startOverItem = item
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16))
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            watchedButton

            if NetworkMonitor.shared.isConnected {
                DownloadButton(item: item, quality: nil)
            }

            if NetworkMonitor.shared.isConnected, isEpisode, item.seriesId != nil {
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
                .tint(.white)
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

            if hasProgress {
                Button {
                    startOverItem = item
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16))
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            if let trailerURL, NetworkMonitor.shared.isConnected {
                Button {
                    UIApplication.shared.open(trailerURL)
                } label: {
                    Image(systemName: "film")
                        .font(.system(size: 16))
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

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

    // MARK: - Overview Section

    private func stripURLs(_ text: String) -> String {
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: "https?://\\S+", options: [])
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var overviewSection: some View {
        let cleanOverview = stripURLs(item.overview ?? "")
        if !cleanOverview.isEmpty {
            VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                Text(cleanOverview)
                    .font(MobileTypography.body)
                    .foregroundStyle(MobileColors.textSecondary)
                    .lineLimit(overviewExpanded ? 50 : 2)

                Button {
                    withAnimation(.easeInOut(duration: MobileAnimation.normal)) {
                        overviewExpanded.toggle()
                    }
                } label: {
                    Text(overviewExpanded ? "Show Less" : "Show More")
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.accent)
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
                                    await loadEpisodesForSeason(seriesId: contentSeriesId, season: season)
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

    /// The episode this page treats as "current": the open episode itself,
    /// or the series page's next-up.
    private var currentEpisodeId: String? {
        isEpisode ? item.id : nextEpisodeToPlay?.id
    }

    private var episodeList: some View {
        LazyVStack(spacing: MobileSpacing.sm) {
            ForEach(episodes) { episode in
                Button {
                    showingEpisodeDetail = episode
                } label: {
                    HStack(spacing: MobileSpacing.sm) {
                        ZStack(alignment: .topTrailing) {
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

                            // Watched checkmark (tvOS parity)
                            if episode.userData?.played == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white, Color(red: 0.29, green: 0.73, blue: 0.47))
                                    .padding(3)
                            }

                            // Progress bar (tvOS parity)
                            if episode.progressPercent > 0 {
                                VStack {
                                    Spacer()
                                    GeometryReader { geo in
                                        Rectangle()
                                            .fill(MobileColors.accent)
                                            .frame(width: geo.size.width * episode.progressPercent, height: 3)
                                    }
                                    .frame(height: 3)
                                }
                            }
                        }
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileCornerRadius.small)
                                .stroke(episode.id == currentEpisodeId ? Color.white : .clear, lineWidth: 2)
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            if !isYouTubeStyle, let epNum = episode.indexNumber {
                                HStack(spacing: 4) {
                                    Text("E\(epNum)")
                                        .foregroundStyle(MobileColors.accent)
                                    if let aired = shortAirDateText(episode) {
                                        Text("• \(aired)")
                                            .foregroundStyle(MobileColors.textTertiary)
                                    }
                                }
                                .font(MobileTypography.captionSmall)
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

        let seasonNumbers = Array(Set(downloaded.compactMap { $0.seasonNumber })).sorted()
        seasons = seasonNumbers.map { num in
            BaseItemDto(
                id: "offline-season-\(num)", name: "Season \(num)", type: .season,
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
            let series = try? await JellyfinClient.shared.getItem(itemId: seriesId)
            seriesCommunityRating = series?.communityRating
            seriesCriticRating = series?.criticRating

            seasons = (try? await JellyfinClient.shared.getSeasons(seriesId: seriesId)) ?? []
            if let seasonId = item.seasonId {
                selectedSeason = seasons.first { $0.id == seasonId }
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
        if !NetworkMonitor.shared.isConnected {
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

    private func episodeThumbnailURL(_ episode: BaseItemDto) -> URL? {
        if !NetworkMonitor.shared.isConnected {
            return OfflineImageHelper.thumbnailURL(for: episode.id)
        }
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
        case "AC3": return "Dolby Digital"
        case "EAC3": return "Dolby Digital+"
        case "TRUEHD": return "Dolby TrueHD"
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
