import SwiftUI

// swiftlint:disable type_body_length file_length
// MediaDetailView is a complex view handling movies, series, seasons, and episodes
// with multiple states and sub-views - splitting would reduce cohesion

private enum SashimiTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let cardBackground = Color(white: 0.12)
    static let accent = Color(red: 0.36, green: 0.68, blue: 0.90)
    static let accentSecondary = Color(red: 0.95, green: 0.65, blue: 0.25)
    static let highlight = Color(red: 0.36, green: 0.68, blue: 0.90) // Blue accent for highlights
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.75)
    static let textTertiary = Color(white: 0.55)
    static let progressBackground = Color(white: 0.25)
}

struct MediaDetailView: View {
    let item: BaseItemDto
    var forceYouTubeStyle: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var showingPlayer = false
    @State private var isFavorite: Bool = false
    @State private var isWatched: Bool = false
    @State private var seasons: [BaseItemDto] = []
    @State private var episodes: [BaseItemDto] = []
    @State private var moreFromSeason: [BaseItemDto] = []
    @State private var selectedSeason: BaseItemDto?
    @State private var selectedEpisode: BaseItemDto?
    @State private var mediaInfo: MediaSourceInfo?
    @State private var isLoadingEpisodes = false
    @State private var showingSeriesDetail: BaseItemDto?
    @State private var showingEpisodeDetail: BaseItemDto?
    @State private var showingFileInfo = false
    @State private var showingDeleteConfirm = false
    @State private var isRefreshing = false
    @State private var refreshID = UUID()
    @FocusState private var isMoreButtonFocused: Bool

    private var isSeries: Bool { item.type == .series }
    private var isEpisode: Bool { item.type == .episode }
    private var isVideo: Bool { item.type == .video }

    // YouTube-style content uses landscape thumbnails instead of portrait posters
    private var isYouTubeStyle: Bool {
        // Explicitly set from calling context
        if forceYouTubeStyle { return true }
        // Videos are always YouTube-style
        if isVideo { return true }
        // Episodes without parent backdrops are YouTube-style (from Pinchflat)
        if isEpisode && !seriesHasBackdrop { return true }
        return false
    }

    // Check if series has backdrop images available
    private var seriesHasBackdrop: Bool {
        // For episodes, check parent series backdrop tags
        if isEpisode {
            if let tags = item.parentBackdropImageTags, !tags.isEmpty {
                return true
            }
            return false
        }
        // For series/movies, check own backdrop tags
        if let tags = item.backdropImageTags, !tags.isEmpty {
            return true
        }
        return false
    }

    // For backdrop: use series backdrop if available, otherwise episode's thumbnail
    private var backdropId: String {
        if isEpisode && seriesHasBackdrop {
            return item.seriesId ?? item.id
        }
        return item.id
    }

    // Use Backdrop if series has it, otherwise Primary (thumbnail)
    private var backdropImageType: String {
        if isEpisode && seriesHasBackdrop {
            return "Backdrop"
        }
        if isEpisode || isVideo {
            return "Primary"
        }
        return "Backdrop"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 100)
                mainContentSection
            }
        }
        .background {
            ZStack {
                // Full-screen background image
                AsyncItemImage(
                    itemId: backdropId,
                    imageType: backdropImageType,
                    maxWidth: 1920,
                    contentMode: .fill,
                    fallbackImageTypes: ["Thumb", "Backdrop", "Primary"]
                )
                .id(refreshID)
                .ignoresSafeArea()

                // Gradient overlays for readability
                LinearGradient(
                    colors: [
                        SashimiTheme.background.opacity(0.4),
                        SashimiTheme.background.opacity(0.75),
                        SashimiTheme.background.opacity(0.95),
                        SashimiTheme.background
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                // Side vignette
                HStack {
                    LinearGradient(
                        colors: [SashimiTheme.background.opacity(0.85), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 500)
                    Spacer()
                }
                .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            PlayerView(item: selectedEpisode ?? item)
        }
        .fullScreenCover(item: $showingSeriesDetail) { series in
            MediaDetailView(item: series, forceYouTubeStyle: forceYouTubeStyle)
        }
        .fullScreenCover(item: $showingEpisodeDetail) { episode in
            MediaDetailView(item: episode, forceYouTubeStyle: forceYouTubeStyle)
        }
        .alert("File Info", isPresented: $showingFileInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(mediaInfo?.path ?? "Path not available")
        }
        .confirmationDialog("Delete Item", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteItem() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete this item? This cannot be undone.")
        }
        .task {
            await loadContent()
        }
        .onAppear {
            isFavorite = item.userData?.isFavorite ?? false
            isWatched = item.userData?.played ?? false
        }
    }

    private func deleteItem() async {
        do {
            try await JellyfinClient.shared.deleteItem(itemId: item.id)
            ToastManager.shared.show("Item deleted")
            // Small delay to let the toast appear before dismissing
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                dismiss()
            }
        } catch {
            ToastManager.shared.show("Failed to delete: \(error.localizedDescription)")
        }
    }

    private func refreshMetadata() async {
        isRefreshing = true
        do {
            // Refresh metadata on server
            try await JellyfinClient.shared.refreshMetadata(itemId: item.id)
            ToastManager.shared.show("Metadata refresh started")

            // Wait a moment for server to process
            try await Task.sleep(for: .seconds(2))

            // Reload content to pick up new metadata/images
            await loadContent()

            // Force image views to reload by changing the refresh ID
            refreshID = UUID()
        } catch {
            ToastManager.shared.show("Failed to refresh metadata")
        }
        isRefreshing = false
    }

    // MARK: - Main Content
    private var mainContentSection: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .top, spacing: 40) {
                posterSection
                infoSection
            }
            .padding(.horizontal, 60)
            .focusSection()

            if let overview = item.overview {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .lineLimit(4)
                    .padding(.horizontal, 60)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
            }

            if let people = item.people, !people.isEmpty {
                castSection(people)
            }

            if isSeries || isEpisode {
                seasonsSection
                    .focusSection()
            }

            Spacer().frame(height: 80)
        }
    }

    // MARK: - Poster

    private var posterId: String {
        if isEpisode {
            // Regular TV shows have parent backdrop images - use season poster
            if seriesHasBackdrop, let seasonId = item.seasonId {
                return seasonId
            }
            // YouTube/home videos - use episode's own thumbnail
            return item.id
        }
        // Video type (YouTube) - always use own thumbnail
        if isVideo {
            return item.id
        }
        return item.id
    }

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

    private var posterSection: some View {
        SmartPosterImage(
            itemIds: posterFallbackIds,
            maxWidth: isYouTubeStyle ? 640 : 400,
            imageTypes: isYouTubeStyle ? ["Primary", "Thumb", "Backdrop"] : ["Primary", "Thumb"]
        )
        .frame(width: isYouTubeStyle ? 320 : 200, height: isYouTubeStyle ? 180 : 300)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
    }

    // MARK: - Info Section
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.name)
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(SashimiTheme.textPrimary)

            Text(metadataLabel)
                .font(.subheadline)
                .foregroundStyle(SashimiTheme.textSecondary)

            HStack(spacing: 16) {
                ratingsRow

                if let rating = item.officialRating {
                    Text(rating)
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(SashimiTheme.textSecondary, lineWidth: 1.5)
                        )
                }
            }

            if let genres = item.genres, !genres.isEmpty {
                Text(genres.prefix(4).joined(separator: " • "))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(SashimiTheme.textSecondary)
            }

            if let info = mediaInfo {
                HStack(spacing: 12) {
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

            Spacer()

            actionButtonsRow
        }
        .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
    }

    private func mediaInfoBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SashimiTheme.cardBackground)
            )
    }

    @ViewBuilder
    private func audioInfoBadge(codec: String, channels: Int) -> some View {
        if let logoName = audioCodecLogoName(codec) {
            HStack(spacing: 8) {
                Image(logoName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 22)
                Text(formatChannels(channels))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SashimiTheme.cardBackground)
            )
        } else {
            mediaInfoBadge("\(formatCodec(codec)) \(formatChannels(channels))")
        }
    }

    private func audioCodecLogoName(_ codec: String) -> String? {
        let upper = codec.uppercased()
        switch upper {
        case "AC3": return "DolbyDigital"
        case "EAC3": return "DolbyDigitalPlus"
        case "TRUEHD": return "DolbyTrueHD"
        case "DTS", "DCA": return "DTS"
        default: return nil
        }
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

    private var metadataLabel: String {
        var parts: [String] = []

        if isEpisode {
            let season = item.parentIndexNumber ?? 1
            let episode = item.indexNumber ?? 1
            parts.append("S\(season):E\(episode)")

            if let premiereDateStr = item.premiereDate {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = isoFormatter.date(from: premiereDateStr) ?? ISO8601DateFormatter().date(from: premiereDateStr) {
                    let displayFormatter = DateFormatter()
                    displayFormatter.dateFormat = "MMMM d, yyyy"
                    parts.append(displayFormatter.string(from: date))
                }
            }
        }

        if let runtime = item.runTimeTicks {
            parts.append(formatRuntime(runtime))
        }

        return parts.joined(separator: " • ")
    }

    private var ratingsRow: some View {
        HStack(spacing: 20) {
            if let rating = item.communityRating, rating > 0 {
                HStack(spacing: 8) {
                    Image("TMDBLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 24)
                    Text(String(format: "%.1f", rating))
                        .fontWeight(.semibold)
                }
            }

            if let criticRating = item.criticRating {
                HStack(spacing: 6) {
                    Text("🍅")
                        .font(.system(size: 20))
                    Text("\(criticRating)%")
                        .fontWeight(.semibold)
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(SashimiTheme.textPrimary)
    }

    // MARK: - Action Buttons
    private var actionButtonsRow: some View {
        HStack(spacing: 16) {
            ActionButton(
                title: item.progressPercent > 0 ? "Resume" : "Play",
                icon: "play.fill",
                isPrimary: true
            ) {
                showingPlayer = true
            }

            ActionButton(
                title: "Watched",
                icon: isWatched ? "checkmark.circle.fill" : "checkmark.circle",
                isActive: isWatched
            ) {
                Task { await toggleWatched() }
            }

            ActionButton(
                title: isFavorite ? "Favorited" : "Favorite",
                icon: isFavorite ? "heart.fill" : "heart",
                isActive: isFavorite
            ) {
                Task { await toggleFavorite() }
            }

            Menu {
                Button {
                    showingFileInfo = true
                } label: {
                    Label("File Info", systemImage: "info.circle")
                }

                Button {
                    Task { await refreshMetadata() }
                } label: {
                    Label(isRefreshing ? "Refreshing..." : "Refresh Metadata", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)

                if isEpisode, let seriesId = item.seriesId {
                    Button {
                        navigateToSeries(seriesId: seriesId)
                    } label: {
                        Label("Go to Series", systemImage: "tv")
                    }
                }

                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "ellipsis.circle")
                    Text("More")
                }
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(SashimiTheme.cardBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(isMoreButtonFocused ? 0.6 : 0), lineWidth: 2)
                )
                .scaleEffect(isMoreButtonFocused ? 1.10 : 1.0)
                .animation(.spring(response: 0.3), value: isMoreButtonFocused)
            }
            .focused($isMoreButtonFocused)
            .menuStyle(.borderlessButton)

            Spacer()
        }
    }

    private func toggleWatched() async {
        let newState = !isWatched
        isWatched = newState
        do {
            if newState {
                try await JellyfinClient.shared.markPlayed(itemId: item.id)
            } else {
                try await JellyfinClient.shared.markUnplayed(itemId: item.id)
            }
        } catch {
            isWatched = !newState
            ToastManager.shared.show("Failed to update watched status")
        }
    }

    private func toggleFavorite() async {
        let newState = !isFavorite
        isFavorite = newState
        do {
            if newState {
                try await JellyfinClient.shared.markFavorite(itemId: item.id)
            } else {
                try await JellyfinClient.shared.removeFavorite(itemId: item.id)
            }
        } catch {
            isFavorite = !newState
            ToastManager.shared.show("Failed to update favorite")
        }
    }

    private func navigateToSeries(seriesId: String) {
        Task {
            do {
                let series = try await JellyfinClient.shared.getItem(itemId: seriesId)
                showingSeriesDetail = series
            } catch {
                ToastManager.shared.show("Failed to load series")
            }
        }
    }

    // MARK: - Media Info
    private func mediaInfoSection(_ info: MediaSourceInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                if let container = info.container {
                    mediaInfoPill(icon: "doc", text: container.uppercased())
                }

                if let videoCodec = info.videoCodec {
                    mediaInfoPill(icon: "film", text: videoCodec.uppercased())
                }

                if let resolution = info.videoResolution {
                    mediaInfoPill(icon: "rectangle.on.rectangle", text: resolution)
                }

                if let audioCodec = info.audioCodec {
                    mediaInfoPill(icon: "speaker.wave.2", text: audioCodec.uppercased())
                }

                if let channels = info.audioChannels {
                    mediaInfoPill(icon: "speaker.wave.3", text: "\(channels) CH")
                }
            }
        }
    }

    private func mediaInfoPill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(SashimiTheme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(SashimiTheme.cardBackground)
        .clipShape(Capsule())
    }

    // MARK: - Cast
    private func castSection(_ people: [PersonInfo]) -> some View {
        let cast = Array(people.filter { $0.type == "Actor" }.prefix(12))

        return VStack(alignment: .leading, spacing: 16) {
            Text("Cast")
                .font(.headline)
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(cast) { person in
                        CastCard(person: person)
                    }
                }
                .padding(.horizontal, 60)
            }
        }
    }

    // MARK: - Seasons Section
    private var seasonsSection: some View {
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
                    .frame(height: 200)
            } else if !episodes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Episodes")
                        .font(.headline)
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .padding(.horizontal, 60)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(episodes) { episode in
                                EpisodeCard(episode: episode, isCurrentEpisode: episode.id == item.id, showEpisodeThumbnail: true) {
                                    showingEpisodeDetail = episode
                                }
                                .id("\(episode.id)-\(refreshID)")
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.vertical, 20)
                    }
                }
                .focusSection()
            }
        }
    }

    private func loadEpisodesForSeason(seriesId: String, season: BaseItemDto) async {
        isLoadingEpisodes = true
        do {
            episodes = try await JellyfinClient.shared.getEpisodes(seriesId: seriesId, seasonId: season.id)
        } catch {
            ToastManager.shared.show("Failed to load episodes")
        }
        isLoadingEpisodes = false
    }

    // MARK: - Data Loading
    private func loadContent() async {
        if isSeries {
            await loadSeriesContent()
        } else if isEpisode {
            await loadEpisodeContent()
        }
        await loadMediaInfo()
    }

    private func loadSeriesContent() async {
        do {
            seasons = try await JellyfinClient.shared.getSeasons(seriesId: item.id)
            if let firstSeason = seasons.first {
                selectedSeason = firstSeason
                await loadEpisodesForSeason(seriesId: item.id, season: firstSeason)
            }
        } catch {
            ToastManager.shared.show("Failed to load series content")
        }
    }

    private func loadEpisodeContent() async {
        guard let seriesId = item.seriesId else { return }
        do {
            seasons = try await JellyfinClient.shared.getSeasons(seriesId: seriesId)

            if let seasonId = item.seasonId {
                selectedSeason = seasons.first { $0.id == seasonId }
                let allEpisodes = try await JellyfinClient.shared.getEpisodes(seriesId: seriesId, seasonId: seasonId)
                episodes = allEpisodes
                moreFromSeason = allEpisodes.filter { $0.id != item.id }
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
            let playbackInfo = try await JellyfinClient.shared.getPlaybackInfo(itemId: item.id)
            mediaInfo = playbackInfo.mediaSources?.first
        } catch {
            // Silently ignore media info loading failures - not critical for playback
        }
    }

    private func formatRuntime(_ ticks: Int64) -> String {
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }
}

// MARK: - Supporting Views

struct ActionButton: View {
    let title: String
    let icon: String
    var isPrimary: Bool = false
    var isActive: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline)
            .fontWeight(.semibold)
            .padding(.horizontal, isPrimary ? 24 : 16)
            .padding(.vertical, 10)
            .foregroundStyle(isPrimary ? .black : (isActive ? SashimiTheme.accent : .white))
            .background(
                isPrimary ? AnyShapeStyle(Color.white) : AnyShapeStyle(SashimiTheme.cardBackground)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isFocused ? 0.6 : 0), lineWidth: 2)
            )
            .scaleEffect(isFocused ? 1.10 : 1.0)
            .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

struct SeasonTab: View {
    let season: BaseItemDto
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(season.name)
                .font(.system(size: 20))
                .fontWeight(isSelected ? .bold : .medium)
                .foregroundStyle(isSelected || isFocused ? SashimiTheme.highlight : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    isSelected || isFocused ? SashimiTheme.highlight.opacity(0.2) : SashimiTheme.cardBackground
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(SashimiTheme.highlight.opacity(isFocused ? 0.8 : 0), lineWidth: 2)
                )
                .scaleEffect(isFocused ? 1.10 : 1.0)
                .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

struct CastCard: View {
    let person: PersonInfo

    var body: some View {
        VStack(spacing: 8) {
            if person.primaryImageTag != nil {
                AsyncImage(url: JellyfinClient.shared.personImageURL(personId: person.id)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle().fill(SashimiTheme.cardBackground)
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(SashimiTheme.cardBackground)
                    .frame(width: 80, height: 80)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
            }

            Text(person.name)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .lineLimit(1)

            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(.caption2)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: 90)
    }
}

struct EpisodeCard: View {
    let episode: BaseItemDto
    var isCurrentEpisode: Bool = false
    var showEpisodeThumbnail: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    // All possible image sources in order: episode, season, series
    private var fallbackImageIds: [String] {
        var ids = [episode.id]
        if let seasonId = episode.seasonId {
            ids.append(seasonId)
        }
        if let seriesId = episode.seriesId {
            ids.append(seriesId)
        }
        return ids
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    if showEpisodeThumbnail {
                        // Try episode thumbnail first, fall back to season/series poster
                        SmartPosterImage(itemIds: fallbackImageIds, maxWidth: 400)
                            .frame(width: 240, height: 135)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        SmartPosterImage(itemIds: fallbackImageIds, maxWidth: 400)
                            .frame(width: 150, height: 225)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if episode.progressPercent > 0 {
                        GeometryReader { geo in
                            VStack {
                                Spacer()
                                Rectangle()
                                    .fill(SashimiTheme.highlight)
                                    .frame(width: geo.size.width * episode.progressPercent, height: 3)
                            }
                        }
                    }

                    if episode.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .background(Circle().fill(.black.opacity(0.5)))
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }

                    if isCurrentEpisode {
                        Text("NOW PLAYING")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(SashimiTheme.highlight)
                            .clipShape(Capsule())
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? SashimiTheme.highlight : .clear, lineWidth: 2)
                )

                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(
                        text: episode.name,
                        isScrolling: isFocused,
                        height: 28
                    )
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)

                    HStack(spacing: 6) {
                        Text(verbatim: "S\(episode.parentIndexNumber ?? 1):E\(episode.indexNumber ?? 0)")
                            .font(.system(size: 20))
                            .foregroundStyle(SashimiTheme.textTertiary)

                        if let runtime = episode.runTimeTicks {
                            Text("• \(runtime / 10_000_000 / 60) min")
                                .font(.system(size: 20))
                                .foregroundStyle(SashimiTheme.textTertiary)
                        }
                    }
                }
                .frame(width: showEpisodeThumbnail ? 240 : 150, alignment: .leading)
            }
            .scaleEffect(isFocused ? 1.10 : 1.0)
            .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}
