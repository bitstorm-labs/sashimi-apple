import SwiftUI
import AVKit
import os

private let trailerLogger = Logger(subsystem: "com.mondominator.sashimi", category: "Trailer")

// swiftlint:disable type_body_length file_length
// MediaDetailView is a complex view handling movies, series, seasons, and episodes
// with multiple states and sub-views - splitting would reduce cohesion

struct MediaDetailView: View {
    let initialItem: BaseItemDto
    var forceYouTubeStyle: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var item: BaseItemDto
    @State private var showingPlayer = false
    @State private var startFromBeginning = false

    @State private var isWatched: Bool = false
    @State private var hasProgress: Bool = false

    init(item: BaseItemDto, forceYouTubeStyle: Bool = false) {
        self.initialItem = item
        self.forceYouTubeStyle = forceYouTubeStyle
        self._item = State(initialValue: item)
    }
    @State private var seasons: [BaseItemDto] = []
    @State private var episodes: [BaseItemDto] = []
    @State private var moreFromSeason: [BaseItemDto] = []
    @State private var selectedSeason: BaseItemDto?
    @State private var selectedEpisode: BaseItemDto?
    @State private var mediaInfo: MediaSourceInfo?
    @State private var seriesOfficialRating: String?
    @State private var seriesGenres: [String]?
    @State private var seriesCommunityRating: Double?
    @State private var seriesCriticRating: Int?
    @State private var nextEpisodeToPlay: BaseItemDto?
    @State private var isLoadingEpisodes = false
    @State private var showingSeriesDetail: BaseItemDto?
    @State private var showingEpisodeDetail: BaseItemDto?
    @State private var showingFileInfo = false
    @State private var showingTrailers = false
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
        // Episodes with landscape primary image (aspect ratio > 1) are YouTube-style
        if isEpisode {
            if let aspectRatio = item.primaryImageAspectRatio, aspectRatio > 1.0 {
                return true
            }
            // Fallback: no parent backdrops or youtube in path
            if !seriesHasBackdrop || (item.path?.lowercased().contains("youtube") ?? false) {
                return true
            }
        }
        return false
    }

    // YouTube series (channels) should show circular art like in the library list
    private var isYouTubeSeriesStyle: Bool {
        isSeries && forceYouTubeStyle
    }

    // Episode from YouTube library - show circular channel art instead of series logo
    private var isYouTubeChannelEpisode: Bool {
        isEpisode && (forceYouTubeStyle || (item.path?.lowercased().contains("youtube") ?? false))
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

    // For backdrop: episodes use their own thumbnail, others use backdrop
    private var backdropId: String {
        return item.id
    }

    // Episodes use Primary (thumbnail), others use Backdrop
    // YouTube channels from Pinchflat have Banner images instead of Backdrop
    private var backdropImageType: String {
        if isEpisode || isVideo {
            return "Primary"
        }
        if isYouTubeSeriesStyle {
            return "Banner"
        }
        return "Backdrop"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: isEpisode ? 0 : 20)
                mainContentSection
            }
        }
        .background {
            GeometryReader { geometry in
                ZStack {
                    // Dark background base
                    SashimiTheme.background
                        .ignoresSafeArea()

                    // Background image - top right (Plex-style)
                    VStack(spacing: 0) {
                        Spacer().frame(height: 80)
                        HStack {
                            Spacer()
                            AsyncItemImage(
                                itemId: backdropId,
                                imageType: backdropImageType,
                                maxWidth: 3840,
                                contentMode: .fit,
                                fallbackImageTypes: isYouTubeSeriesStyle ? ["Backdrop", "Thumb", "Primary"] : ["Thumb", "Backdrop", "Primary"]
                            )
                            .id(refreshID)
                            .frame(width: geometry.size.width * (isYouTubeSeriesStyle ? 0.65 : (isSeries ? 0.55 : 0.45)), alignment: .topTrailing)
                            // Soft edge gradients fading into background
                            .mask(
                                // Use a combined gradient mask for smooth edges on all sides
                                LinearGradient(
                                    colors: [.clear, .white, .white, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .mask(
                                    LinearGradient(
                                        colors: [.clear, .white, .white, .white],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .mask(
                                    LinearGradient(
                                        colors: [.white, .white, .white, .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            )
                            .padding(.trailing, 140)
                        }
                        Spacer()
                    }
                    .ignoresSafeArea()

                    // Subtle gradient for text readability (minimal to keep backdrop vibrant)
                    LinearGradient(
                        colors: [
                            SashimiTheme.background.opacity(0.0),
                            SashimiTheme.background.opacity(0.05),
                            SashimiTheme.background.opacity(0.3),
                            SashimiTheme.background
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            PlayerView(item: selectedEpisode ?? item, startFromBeginning: startFromBeginning)
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
        .fullScreenCover(isPresented: $showingTrailers) {
            if let trailer = item.remoteTrailers?.first, let url = trailer.url {
                TrailerPlayerView(urlString: url, name: trailer.name ?? "Trailer")
            }
        }
        .task {
            await loadContent()
        }
        .onAppear {
            isWatched = item.userData?.played ?? false
            hasProgress = item.progressPercent > 0
        }
        .onChange(of: showingPlayer) { _, isShowing in
            if !isShowing {
                // Reset startFromBeginning and refresh item data when returning from player
                startFromBeginning = false
                Task { await refreshItemState() }
            }
        }
    }

    private func deleteItem() async {
        do {
            try await JellyfinClient.shared.deleteItem(itemId: item.id)
            ToastManager.shared.show("Item deleted", type: .success)
            // Small delay to let the toast appear before dismissing
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                dismiss()
            }
        } catch {
            ToastManager.shared.show("Failed to delete: \(error.localizedDescription)")
        }
    }

    private func refreshItemState() async {
        do {
            let refreshedItem = try await JellyfinClient.shared.getItem(itemId: item.id)

            isWatched = refreshedItem.userData?.played ?? false
            hasProgress = refreshedItem.progressPercent > 0 && !(refreshedItem.userData?.played ?? false)
        } catch {
            // Silently ignore - non-critical refresh
        }
    }

    private func refreshMetadata() async {
        isRefreshing = true
        do {
            // Refresh metadata on server
            try await JellyfinClient.shared.refreshMetadata(itemId: item.id)
            ToastManager.shared.show("Metadata refresh started", type: .info)

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
            if isEpisode {
                // Episode layout: logo above title, no poster
                episodeHeaderSection
                    .padding(.horizontal, 60)
                    .focusSection()
            } else if isSeries {
                // Series layout: logo above info, no poster
                seriesHeaderSection
                    .padding(.horizontal, 60)
                    .focusSection()
            } else {
                // Movie layout: poster + info side by side
                HStack(alignment: .top, spacing: 40) {
                    posterSection
                    infoSection
                }
                .padding(.horizontal, 60)
                .focusSection()
            }

            if let overview = item.overview {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .lineLimit(4)
                    .padding(.horizontal, 60)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
            }

            if isSeries {
                seasonsSection
                    .focusSection()
            } else if isEpisode {
                nextUpSection
                    .focusSection()
            }

            if let people = item.people, people.contains(where: { $0.type == "Actor" }) {
                castSection(people)
            }

            Spacer().frame(height: 80)
        }
    }

    // MARK: - Episode Header (with series logo or YouTube channel art)
    private var episodeHeaderSection: some View {
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
                                    fallbackImageTypes: ["Thumb"]
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
                        fallbackImageTypes: []
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
    private var seriesHeaderSection: some View {
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
                    fallbackImageTypes: []
                )
                .frame(maxHeight: 220, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }

            infoSection
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

    @ViewBuilder
    private var posterSection: some View {
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
                        contentMode: .fit
                    )
                    .clipShape(Circle())
                )
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
        } else {
            SmartPosterImage(
                itemIds: posterFallbackIds,
                maxWidth: isYouTubeStyle ? 640 : 400,
                imageTypes: isYouTubeStyle ? ["Primary", "Thumb", "Backdrop"] : ["Primary", "Thumb"]
            )
            .frame(width: isYouTubeStyle ? 320 : 200, height: isYouTubeStyle ? 180 : 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
        }
    }

    // MARK: - Info Section
    private var infoSection: some View {
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
                                fallbackImageTypes: ["Thumb"]
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
                                .resizable()
                                .aspectRatio(contentMode: .fit)
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

            HStack(spacing: 16) {
                if !isSeries {
                    ratingsRow
                }

                if let info = mediaInfo {
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

            Spacer()

            actionButtonsRow
        }
        .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
    }

    private func mediaInfoBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SashimiTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func audioInfoBadge(codec: String, channels: Int) -> some View {
        if let logoName = audioCodecLogoName(codec) {
            HStack(spacing: 8) {
                Image(logoName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 24)
                Text(formatChannels(channels))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SashimiTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
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
            // Premiere date only - S#:E# is now in title
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

        if isSeries {
            // For series: show year and season count
            if let year = item.productionYear {
                parts.append(String(year))
            }
            let seasonCount = seasons.count
            if seasonCount > 0 {
                parts.append(seasonCount == 1 ? "1 Season" : "\(seasonCount) Seasons")
            }
        } else if let runtime = item.runTimeTicks {
            // Only show runtime for non-series content
            parts.append(formatRuntime(runtime))
        }

        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private var ratingsRow: some View {
        // Use series ratings as fallback for episodes
        let communityRating = item.communityRating ?? seriesCommunityRating
        let criticRating = item.criticRating ?? seriesCriticRating
        let hasCommunityRating = (communityRating ?? 0) > 0
        let hasCriticRating = criticRating != nil

        if hasCommunityRating || hasCriticRating {
            HStack(spacing: 20) {
                if let rating = communityRating, rating > 0 {
                    HStack(spacing: 8) {
                        Image("TMDBLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 24)
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 18, weight: .bold))
                    }
                }

                if let critic = criticRating {
                    HStack(spacing: 6) {
                        Text("🍅")
                            .font(.system(size: 18))
                        Text("\(critic)%")
                            .font(.system(size: 18, weight: .bold))
                    }
                }
            }
            .foregroundStyle(SashimiTheme.textPrimary)
        }
    }

    // MARK: - Action Buttons
    private var actionButtonsRow: some View {
        HStack(spacing: 30) {
            // Series: show play button for next episode
            if isSeries, let nextEp = nextEpisodeToPlay {
                let epHasProgress = (nextEp.userData?.playbackPositionTicks ?? 0) > 0
                let seasonNum = nextEp.parentIndexNumber ?? 1
                let epNum = nextEp.indexNumber ?? 1
                ActionButton(
                    title: epHasProgress ? "Resume S\(seasonNum):E\(epNum)" : "Play S\(seasonNum):E\(epNum)",
                    icon: "play.fill",
                    isPrimary: true
                ) {
                    selectedEpisode = nextEp
                    startFromBeginning = false
                    showingPlayer = true
                }
            }

            // Non-series: show regular play buttons
            if !isSeries {
                ActionButton(
                    title: hasProgress ? "Resume" : "Play",
                    icon: "play.fill",
                    isPrimary: true
                ) {
                    startFromBeginning = false
                    showingPlayer = true
                }

                if hasProgress {
                    ActionButton(
                        title: "Start Over",
                        icon: "arrow.counterclockwise",
                        isPrimary: false
                    ) {
                        startFromBeginning = true
                        showingPlayer = true
                    }
                }
            }

            // Trailer button for movies with trailers
            if !isSeries && !isEpisode, let trailers = item.remoteTrailers, !trailers.isEmpty {
                ActionButton(
                    title: "Trailer",
                    icon: "film",
                    isPrimary: false
                ) {
                    showingTrailers = true
                }
            }

            ActionButton(
                title: "Watched",
                icon: isWatched ? "checkmark.circle.fill" : "checkmark.circle",
                isActive: isWatched
            ) {
                Task { await toggleWatched() }
            }

            // Episode: show Series button
            if isEpisode, let seriesId = item.seriesId {
                ActionButton(
                    title: "Series",
                    icon: "tv",
                    isPrimary: false
                ) {
                    navigateToSeries(seriesId: seriesId)
                }
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
                        .stroke(isMoreButtonFocused ? SashimiTheme.accent : .clear, lineWidth: 3)
                )
                .shadow(color: isMoreButtonFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
                .scaleEffect(isMoreButtonFocused ? 1.05 : 1.0)
                .animation(.spring(response: 0.3), value: isMoreButtonFocused)
            }
            .focused($isMoreButtonFocused)
            .menuStyle(.borderlessButton)

            Spacer()
        }
    }

    private func toggleWatched() async {
        let newState = !isWatched
        let previousProgress = hasProgress
        isWatched = newState
        if newState {
            // When marking as watched, clear progress (it's complete)
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
            hasProgress = previousProgress
            ToastManager.shared.show("Failed to update watched status")
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

            // Audio track languages
            if !info.audioLanguages.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundStyle(SashimiTheme.textTertiary)
                    Text("Audio: " + info.audioLanguages.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(SashimiTheme.textSecondary)
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
        let cast = Array(people.filter { $0.type == "Actor" }.prefix(20))

        return VStack(alignment: .leading, spacing: 16) {
            Text("Cast")
                .font(.headline)
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(cast) { person in
                        CastCard(person: person)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .focusSection()
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
                    .frame(height: 280)
            } else if !episodes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Episodes")
                        .font(.headline)
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .padding(.horizontal, 60)

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 30) {
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
    private var nextUpSection: some View {
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
                        HStack(spacing: 30) {
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
        await loadMediaInfo()
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

    private func findNextEpisodeToPlay() async {
        do {
            let nextUpItems = try await JellyfinClient.shared.getNextUp(limit: 50)
            // Find next up for this series
            if let next = nextUpItems.first(where: { $0.seriesId == item.id }) {
                nextEpisodeToPlay = next
                return
            }
            // If no next up, find first unwatched episode
            for season in seasons {
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

    /// Calculates and formats the finish time if playback started now
    private var finishTimeString: String? {
        guard let totalTicks = item.runTimeTicks, totalTicks > 0 else { return nil }

        // Calculate remaining time (account for any progress)
        let watchedTicks = item.userData?.playbackPositionTicks ?? 0
        let remainingTicks = totalTicks - watchedTicks
        guard remainingTicks > 0 else { return nil }

        let remainingSeconds = TimeInterval(remainingTicks) / 10_000_000
        let finishDate = Date().addingTimeInterval(remainingSeconds)

        let formatter = DateFormatter()
        formatter.timeStyle = .short  // e.g., "10:45 PM"
        formatter.dateStyle = .none

        return "Ends at \(formatter.string(from: finishDate))"
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
                    .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 3)
            )
            .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isPrimary ? .startsMediaSession : [])
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
                .font(.system(size: 24))
                .fontWeight(isSelected ? .bold : .medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    isSelected || isFocused ? Color(red: 0.28, green: 0.35, blue: 0.45) : SashimiTheme.cardBackground
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isFocused ? Color.white.opacity(0.5) : .clear, lineWidth: 3)
                )
                .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 10)
                .scaleEffect(isFocused ? 1.05 : 1.0)
                .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("\(season.name)\(isSelected ? ", selected" : "")")
        .accessibilityHint("Double-tap to show episodes")
    }
}

struct CastCard: View {
    let person: PersonInfo
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            // No action - cast cards are display only
        } label: {
            VStack(spacing: 8) {
                if person.primaryImageTag != nil {
                    AsyncImage(
                        url: JellyfinClient.shared.personImageURL(personId: person.id, maxWidth: 200),
                        content: { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        },
                        placeholder: {
                            Circle().fill(SashimiTheme.cardBackground)
                        }
                    )
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 3)
                    )
                } else {
                    Circle()
                        .fill(SashimiTheme.cardBackground)
                        .frame(width: 100, height: 100)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(SashimiTheme.textTertiary)
                        }
                        .overlay(
                            Circle()
                                .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 3)
                        )
                }

                MarqueeText(
                    text: person.name,
                    isScrolling: isFocused,
                    height: 32,
                    pingPong: true
                )
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)

                if let role = person.role, !role.isEmpty {
                    MarqueeText(
                        text: role,
                        isScrolling: isFocused,
                        height: 28,
                        startDelay: 2.0,
                        pingPong: true
                    )
                    .font(.caption2)
                    .foregroundStyle(SashimiTheme.textTertiary)
                }
            }
            .frame(width: 140)
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(person.role.map { "\(person.name) as \($0)" } ?? person.name)
    }
}

struct EpisodeCard: View {
    let episode: BaseItemDto
    var isCurrentEpisode: Bool = false
    var showEpisodeThumbnail: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var pulseAnimation: Bool = false

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
                        VStack {
                            Spacer()
                            SashimiProgressBar(progress: episode.progressPercent, height: 4, showBackground: false)
                        }
                    }

                    if episode.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, Color(red: 0.29, green: 0.73, blue: 0.47))
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isCurrentEpisode && !isFocused ? .white : (isFocused ? SashimiTheme.accent : .clear),
                            lineWidth: isCurrentEpisode && !isFocused ? 4 : 3
                        )
                        .opacity(isCurrentEpisode && !isFocused ? (pulseAnimation ? 1.0 : 0.4) : 1.0)
                )
                .shadow(color: isFocused ? SashimiTheme.focusGlow : (isCurrentEpisode ? Color.white.opacity(pulseAnimation ? 0.6 : 0.2) : .clear), radius: 12)
                .onAppear {
                    if isCurrentEpisode {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            pulseAnimation = true
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(
                        text: episode.name,
                        isScrolling: isFocused,
                        height: 28
                    )
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)

                    HStack(spacing: 6) {
                        // Only show S#:E# for non-YouTube content
                        if !(episode.path?.lowercased().contains("youtube") ?? false) {
                            Text("S\(String(episode.parentIndexNumber ?? 1)):E\(String(episode.indexNumber ?? 0))")
                                .font(.system(size: 20))
                                .foregroundStyle(SashimiTheme.textTertiary)
                        }

                        if let runtime = episode.runTimeTicks {
                            Text("• \(runtime / 10_000_000 / 60) min")
                                .font(.system(size: 20))
                                .foregroundStyle(SashimiTheme.textTertiary)
                        }
                    }
                }
                .frame(width: showEpisodeThumbnail ? 240 : 150, alignment: .leading)
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(episodeAccessibilityLabel)
        .accessibilityHint("Double-tap to play")
    }

    private var episodeAccessibilityLabel: String {
        var parts: [String] = []
        parts.append("Episode \(episode.indexNumber ?? 0)")
        parts.append(episode.name)

        if episode.userData?.played == true {
            parts.append("watched")
        } else if episode.progressPercent > 0 {
            parts.append("\(Int(episode.progressPercent * 100)) percent watched")
        }

        if isCurrentEpisode {
            parts.append("now playing")
        }

        return parts.joined(separator: ", ")
    }
}

struct TrailerListView: View {
    let trailers: [MediaUrl]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Trailers")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(.top, 50)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(trailers.enumerated()), id: \.offset) { index, trailer in
                            TrailerRow(
                                name: trailer.name ?? "Trailer \(index + 1)",
                                url: trailer.url
                            )
                        }
                    }
                    .padding(.horizontal, 100)
                }

                Button("Close") {
                    dismiss()
                }
                .padding(.bottom, 50)
            }
        }
    }
}

struct TrailerRow: View {
    let name: String
    let url: String?
    @FocusState private var isFocused: Bool
    @State private var showingPlayer = false

    var body: some View {
        Button {
            showingPlayer = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isFocused ? .white : .gray)

                Text(name)
                    .font(.body)
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(isFocused ? SashimiTheme.accent : SashimiTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .fullScreenCover(isPresented: $showingPlayer) {
            if let urlString = url {
                TrailerPlayerView(urlString: urlString, name: name)
            }
        }
    }
}

struct TrailerPlayerView: View {
    let urlString: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showYouTubePrompt = false

    private var youtubeVideoId: String? {
        if urlString.contains("youtube.com/watch") {
            return URLComponents(string: urlString)?.queryItems?.first(where: { $0.name == "v" })?.value
        } else if urlString.contains("youtu.be/") {
            return urlString.components(separatedBy: "youtu.be/").last?.components(separatedBy: "?").first
        }
        return nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showYouTubePrompt, let videoId = youtubeVideoId {
                // YouTube video - prompt to open in YouTube app
                VStack(spacing: 30) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.red)

                    Text("YouTube Trailer")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Open this trailer in the YouTube app?")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 40) {
                        Button("Open YouTube") {
                            openInYouTubeApp(videoId: videoId)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    .padding(.top, 20)
                }
                .padding(60)
            } else if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading trailer...")
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundStyle(.yellow)
                    Text(error)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("Close") { dismiss() }
                        .padding(.top, 20)
                }
                .padding()
            } else if player != nil {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .overlay(alignment: .topLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .padding(40)
                    }
            }
        }
        .onAppear {
            if youtubeVideoId != nil {
                // YouTube video - show prompt to open in YouTube app
                showYouTubePrompt = true
            } else {
                loadDirectTrailer()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadDirectTrailer() {
        trailerLogger.info("Loading direct trailer: \(urlString)")
        if let url = URL(string: urlString) {
            isLoading = false
            player = AVPlayer(url: url)
            player?.play()
        } else {
            trailerLogger.error("Invalid trailer URL: \(urlString)")
            isLoading = false
            errorMessage = "Invalid trailer URL"
        }
    }

    private func openInYouTubeApp(videoId: String) {
        // Try YouTube app URL scheme for tvOS
        let youtubeAppURL = URL(string: "youtube://watch/\(videoId)")
        let youtubeWebURL = URL(string: "https://www.youtube.com/watch?v=\(videoId)")

        if let appURL = youtubeAppURL {
            UIApplication.shared.open(appURL) { success in
                if !success {
                    trailerLogger.info("YouTube app not available, trying web URL")
                    if let webURL = youtubeWebURL {
                        UIApplication.shared.open(webURL) { webSuccess in
                            if !webSuccess {
                                trailerLogger.error("Could not open YouTube")
                            }
                        }
                    }
                }
                dismiss()
            }
        }
    }
}
