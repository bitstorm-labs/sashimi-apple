import SwiftUI
import SwiftData
import UIKit
import NukeUI

// swiftlint:disable file_length type_body_length
// PhoneDetailView handles movies, series, and episodes in one stacked layout - splitting would fragment related display logic

struct PhoneDetailView: View {
    // @State (tvOS parity): list/search endpoints omit heavy fields like
    // People, so the .task refresh swaps in the full item — with a plain
    // `let`, cast (and other detail-only fields) silently never showed for
    // items opened from search.
    @State var item: BaseItemDto
    var libraryName: String?
    // Keep the existing call sites server-agnostic when no scoped source is selected.
    // swiftlint:disable:next implicit_optional_initialization
    var serverID: String? = nil
    // Optional season selected by a Siri deep-link. The route opens the
    // parent series, then loads this season instead of defaulting to Next Up.
    // swiftlint:disable:next implicit_optional_initialization
    var initialSeasonID: String? = nil

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
    /// The show's airing status, for a season's or episode's status pill.
    @State private var seriesStatus: String?
    @State private var seriesCriticRating: Int?
    @State private var showingEpisodeDetail: BaseItemDto?
    @State private var showingPersonDetail: PersonInfo?
    @State private var pendingServerMedia: ServerMediaResult?
    @State private var selectedServerMedia: ServerMediaResult?
    @State private var mediaInfo: MediaSourceInfo?
    @State private var navigateToSeriesItem: BaseItemDto?
    @State private var showSeriesDetail = false
    @State private var overviewExpanded = false
    // Admin menu (tvOS parity): File Info / Refresh Metadata / Delete
    @State private var showingFileInfo = false
    @State private var showingDeleteConfirm = false
    @State private var isRefreshing = false
    @State private var adminError: String?
    @State private var seasonWatchRequest: SeasonWatchRequest?
    /// The season page (#760): Go to Season, or a season tab tapped again.
    @State private var seasonPage: BaseItemDto?
    @State private var channelTarget: ChannelTarget?
    @State private var showingAddToList = false
    @ObservedObject private var session = SessionManager.shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloadManager = DownloadManager.shared

    // MARK: - Computed Properties

    private var isSeries: Bool { item.type == .series }
    private var isEpisode: Bool { item.type == .episode }
    /// The series whose seasons/episodes this page lists (self for a series,
    /// the parent for an episode) — drives the shared episode machinery.
    private var contentSeriesId: String {
        if isSeries {
            return item.id
        }
        return item.seriesId ?? item.parentId ?? item.id
    }
    private var isMovie: Bool { item.type == .movie }

    private var currentTitleKey: String {
        ServerMediaResultGrouping.titleKey(for: item)
    }

    private var originatingPersonServerID: String? {
        serverID ?? SessionManager.shared.activeServerId
    }

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

                    if let people = item.people, !people.isEmpty {
                        castSection(people)
                    }

                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, MobileSpacing.md)
                .padding(.top, MobileSpacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
        .background(MobileColors.background)
        .navigationBarTitleDisplayMode(.inline)
        .themeSong(for: item)
        .fullScreenPlayer(item: $playingItem, serverID: serverID)
        .fullScreenPlayer(item: $startOverItem, serverID: serverID, startFromBeginning: true)
        .navigationDestination(isPresented: $showSeriesDetail) {
            if let seriesItem = navigateToSeriesItem {
                PhoneDetailView(item: seriesItem, libraryName: libraryName, serverID: serverID)
            }
        }
        .navigationDestination(item: $seasonPage) { season in
            MobileSeasonView(season: season, libraryName: libraryName, serverID: serverID, layout: .phone)
        }
        .playerSheet(item: $showingEpisodeDetail) { episode in
            // Full detail view — one consistent episode UI (matches iPad)
            NavigationStack {
                PhoneDetailView(item: episode, libraryName: libraryName, serverID: serverID)
            }
        }
        .playerSheet(item: $showingPersonDetail, onDismiss: presentPendingServerMedia) { person in
            personDetailView(for: person)
        }
        .fullScreenCover(item: $selectedServerMedia) { source in
            NavigationStack {
                ServerScopedMediaDetailView(source: source)
            }
        }
        .sheet(isPresented: $showingAddToList) {
            MobileAddToListSheet(item: item)
                .dismissesOnOutsideTap()
        }
        .sheet(item: $channelTarget) { target in
            MobileAddToChannelSheet(target: target)
                .dismissesOnOutsideTap()
        }
        .task {
            if NetworkMonitor.shared.isOnline,
               let freshItem = try? await JellyfinClient.shared.getItem(itemId: item.id) {
                item = freshItem
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
        // Posted once the stopped report has been delivered: the player
        // closes before that (#591), and on a slow server the one-second
        // guess above reads the position from before this viewing.
        .onReceive(NotificationCenter.default.publisher(for: .sashimiPlayedStateDidChange)) { note in
            guard let change = PlayedStateChange.from(note) else { return }
            Task { await applyPlayedStateChange(change) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
            Task { await refreshPlaybackState() }
        }
        .alert("File Info", isPresented: $showingFileInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            let filePath = mediaInfo?.path ?? item.path ?? "Path not available"
            Text(filePath)
        }
        .confirmationDialog("Delete Item", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteItem() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete this item? This cannot be undone.")
        }
        .seasonWatchConfirmation($seasonWatchRequest) { request in
            Task { await applySeasonWatch(request) }
        }
        .alert("Error", isPresented: .constant(adminError != nil)) {
            Button("OK") { adminError = nil }
        } message: {
            let errorMessage = adminError ?? ""
            Text(errorMessage)
        }
    }

    @ViewBuilder
    private func personDetailView(for person: PersonInfo) -> some View {
        NavigationStack {
            PersonDetailView(
                person: person,
                excludingItemID: item.id,
                excludingTitleKey: currentTitleKey,
                originatingServerID: originatingPersonServerID,
                onSelectSource: queueServerMedia
            )
        }
    }

    private func queueServerMedia(_ source: ServerMediaResult) {
        pendingServerMedia = source
        showingPersonDetail = nil
    }

    private func presentPendingServerMedia() {
        guard let source = pendingServerMedia else { return }
        pendingServerMedia = nil
        selectedServerMedia = source
    }

    // MARK: - Admin Menu (tvOS parity)

    /// File Info / Refresh Metadata / Delete — online only.
    @ViewBuilder
    private var adminMenuItems: some View {
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
    }

    /// Single overflow menu per action row: Go to Series / Season and Add to
    /// Channel first (#760), then the admin items.
    private var overflowMenu: some View {
        Menu {
            ForEach(menuEntries, id: \.title) { entry in
                Button {
                    open(entry)
                } label: {
                    Label(entry.title, systemImage: entry.systemImage)
                }
            }
            Divider()
            adminMenuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16))
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel("More")
    }

    private var menuEntries: [DetailMenuEntry] {
        DetailMenuEntry.entries(for: item, canManageChannels: session.canManageChannels(serverID: serverID))
    }

    private func open(_ entry: DetailMenuEntry) {
        switch entry {
        case .goToSeries(let seriesId):
            // The page fetches its series as it loads; fetch it now if
            // More was opened before that finished.
            Task {
                if navigateToSeriesItem == nil {
                    navigateToSeriesItem = try? await JellyfinClient.shared.getItem(itemId: seriesId)
                }
                if navigateToSeriesItem != nil { showSeriesDetail = true }
            }
        case .goToSeason(let seasonId, _):
            if let season = selectedSeason, season.id == seasonId {
                seasonPage = season
            } else {
                Task { seasonPage = try? await JellyfinClient.shared.getItem(itemId: seasonId) }
            }
        case .addToChannel(let target):
            channelTarget = target
        }
    }

    private func openSeasonPage(_ season: BaseItemDto) {
        guard SeasonPageText.canOpen(season, isConnected: NetworkMonitor.shared.isConnected) else { return }
        seasonPage = season
    }

    private func refreshMetadata() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await JellyfinClient.shared.refreshMetadata(itemId: item.id)
            // Give the server a beat, then pull the refreshed item.
            try? await Task.sleep(for: .seconds(2))
            if let fresh = try? await JellyfinClient.shared.getItem(itemId: item.id) {
                item = fresh
            }
        } catch {
            adminError = "Failed to refresh metadata: \(error.localizedDescription)"
        }
    }

    private func deleteItem() async {
        do {
            try await JellyfinClient.shared.deleteItem(itemId: item.id)
            dismiss()
        } catch {
            adminError = "Failed to delete: \(error.localizedDescription)"
        }
    }

    // MARK: - Backdrop Section

    @ViewBuilder
    private var backdropSection: some View {
        if isYouTubeSeriesStyle {
            VStack(spacing: 0) {
                // Banner
                ZStack(alignment: .bottom) {
                    LazyImage(request: imageRequest(for: backdropImageURL(widthPoints: 0))) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
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
                LazyImage(request: imageRequest(for: channelAvatarURL)) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
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
            PhoneHeroBanner(serverID: serverID, trailerItem: item, isBlurred: !hasRealBackdrop) { width in
                imageRequest(for: backdropImageURL(widthPoints: width))
            }
        }
    }

    private var channelAvatarURL: URL? {
        serverImageURL(item.id, "Primary", maxWidth: ImageSizing.pixelWidth(points: 72))
    }

    /// Channel avatar for a YouTube EPISODE's header — the series' Primary.
    private func seriesAvatarURL(for seriesId: String) -> URL? {
        serverImageURL(seriesId, "Primary", maxWidth: ImageSizing.pixelWidth(points: 28))
    }

    /// Whether a genuine landscape backdrop exists. When false, `backdropImageURL`
    /// serves the portrait poster as a fallback, which must be blurred so it
    /// doesn't render as a sliced strip. Mirrors the URL's own tag checks.
    private var hasRealBackdrop: Bool {
        // Episodes always resolve to their OWN Primary in backdropImageURL — a
        // 16:9 still (YouTube thumbnail / TV frame grab), never a portrait
        // poster — so the blur fallback must not apply. Without this, YouTube
        // videos (no backdrop/parentBackdrop tags) rendered their thumbnail as
        // a blurred smear in the hero.
        if isEpisode, item.imageTags?["Primary"] != nil { return true }
        if item.backdropImageTags?.isEmpty == false { return true }
        if item.seriesId != nil, item.parentBackdropImageTags?.isEmpty == false { return true }
        return false
    }

    // MARK: - Title Section

    @ViewBuilder
    private var titleSection: some View {
        if isEpisode {
            if !isYouTubeChannelEpisode, let seriesId = item.seriesId, let logoURL = logoImageURL(for: seriesId) {
                LazyImage(request: imageRequest(for: logoURL)) { state in
                    if let image = state.image {
                        image.resizable().scaledToFit().frame(maxHeight: 56)
                    } else if state.error != nil, let seriesName = item.seriesName {
                        Text(seriesName)
                            .font(MobileTypography.caption)
                            .foregroundStyle(MobileColors.textSecondary)
                    }
                }
            } else if isYouTubeChannelEpisode, let seriesId = item.seriesId, let seriesName = item.seriesName {
                // YouTube channels have no Logo image — show the circular
                // channel avatar (series Primary) + name instead, matching the
                // tvOS/Roku episode headers.
                HStack(spacing: 8) {
                    LazyImage(request: imageRequest(for: seriesAvatarURL(for: seriesId))) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            Circle().fill(MobileColors.cardBackground)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    Text(seriesName.cleanedYouTubeTitle)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                }
            } else if let seriesName = item.seriesName {
                Text(isYouTubeStyle ? seriesName.cleanedYouTubeTitle : seriesName)
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
            }
        }

        if isEpisode {
            episodeTitleText
        } else if isSeries, !isYouTubeSeriesStyle, let logoURL = logoImageURL(for: item.id) {
            // Bounded container + overlay: LazyImage under a height-only cap
            // reports its IDEAL size (the raw logo pixels) when the ScrollView
            // proposes unbounded height — a wide logo PNG then dictates the
            // whole detail column's width, shoving every section past the
            // screen edges (the "expanding, edges cut off" bug; same physics
            // as the missing-backdrop movie fix). The overlay keeps the
            // image's size out of layout entirely.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 70)
                .overlay(alignment: .leading) {
                    LazyImage(request: imageRequest(for: logoURL)) { state in
                        if let image = state.image {
                            image.resizable().scaledToFit()
                        } else if state.error != nil {
                            seriesTitleText
                        }
                    }
                }
                .clipped()
        } else {
            seriesTitleText
        }
    }

    /// tvOS parity: "S1:E2 • Episode Name" inline at title size.
    private var episodeTitleText: some View {
        HStack(spacing: 8) {
            if !isYouTubeChannelEpisode, let season = item.parentIndexNumber, let episode = item.indexNumber {
                Text("S\(season):E\(episode)")
                    .foregroundStyle(MobileColors.textPrimary)
                Text("•")
                    .foregroundStyle(MobileColors.textTertiary)
            }
            Text(item.name)
                .foregroundStyle(MobileColors.textPrimary)
                .lineLimit(3)
        }
        .font(.system(size: 22, weight: .bold))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var seriesTitleText: some View {
        Text(isYouTubeSeriesStyle ? item.name.cleanedYouTubeTitle : item.name)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(MobileColors.textPrimary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: isYouTubeSeriesStyle ? .center : .leading)
            .clipped()
    }

    private func logoImageURL(for itemId: String) -> URL? {
        // Deliberately untagged: OfflineShowView looks this exact URL up
        // cache-only (`returnCacheDataDontLoad`) with no tag to hand.
        JellyfinClient.shared.syncImageURL(
            itemId: itemId,
            imageType: "Logo",
            maxWidth: ImageSizing.mobileLogoWidth,
            serverURL: detailServerURL
        )
    }

    /// A server image URL carrying the image's tag (looked up on `owner`,
    /// the page's item by default), so a changed server image is a new
    /// cache key rather than the stale cached picture.
    private func serverImageURL(
        _ itemId: String,
        _ imageType: String,
        maxWidth: Int,
        owner: BaseItemDto? = nil
    ) -> URL? {
        guard let serverURL = detailServerURL else { return nil }
        return JellyfinClient.shared.syncImageURL(
            itemId: itemId,
            imageType: imageType,
            maxWidth: maxWidth,
            tag: (owner ?? item).imageTag(for: imageType, itemId: itemId),
            serverURL: serverURL
        )
    }

    private var detailServerURL: URL? {
        if let serverID {
            return SessionManager.shared.servers.first(where: { $0.id == serverID })?.url
        }
        return SessionManager.shared.serverURL
    }

    private func imageRequest(for url: URL?) -> ImageRequest? {
        guard let url else { return nil }
        return SashimiImagePipeline.request(url: url, serverID: serverID)
    }

    /// Premiere date "November 8, 2024" (tvOS parity)
    private var premiereDateLongText: String? {
        DateFormatting.formatLongDate(item.premiereDate)
    }

    /// "Ends at 9:41 PM" from now + what is left to watch (tvOS parity)
    private var endsAtText: String? {
        guard let ticks = item.runTimeTicks, ticks > 0 else { return nil }
        let remaining = ticks - (item.userData?.playbackPositionTicks ?? 0)
        guard remaining > 0 else { return nil }
        return "Ends at \(ClockTime.time(Date().addingTimeInterval(Double(remaining) / 10_000_000)))"
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

        // Ratings + media (quality) chips + status: one line when they fit,
        // wrapping on narrow phones (375pt) instead of clipping the badge.
        WrappingHStack(spacing: MobileSpacing.sm) {
            ratingsRow
            if !isSeries {
                mediaInfoBadges
            }
            if let status = SeriesStatus(item: item, seriesStatus: seriesStatus) {
                SeriesStatusBadge(status: status)
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
        // Movies lead with the release year (right before the runtime);
        // episodes/others keep their full air date.
        if isMovie, let year = item.productionYear {
            parts.append(String(year))
        } else if let dateText = premiereDateLongText {
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
                            .resizable().scaledToFit()
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
                    .resizable().scaledToFit()
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

    /// Play the item's local trailer inline (Trailarr). The button only appears
    /// when a local trailer exists (LocalTrailerCount > 0), matching Roku.
    private func playLocalTrailer() async {
        // Matches tvOS: stopped before the network round-trip, not after —
        // otherwise the theme keeps playing through the whole
        // getLocalTrailers() fetch and never stops at all if it fails.
        DetailAmbience.stopForPlayback()
        if let trailer = try? await JellyfinClient.shared.getLocalTrailers(itemId: item.id).first {
            playingItem = trailer
        }
    }

    /// Shuffle: play a random episode of this series.
    private func shuffleEpisode() async {
        if let ep = try? await JellyfinClient.shared.getRandomItem(parentId: contentSeriesId, itemTypes: [.episode]) {
            DetailAmbience.stopForPlayback()
            playingItem = ep
        }
    }

    // MARK: - Action Buttons

    /// Play, Start Over, Shuffle, Trailer, Watched, Download, More (#760).
    ///
    /// The row's ideal width can exceed the content width on smaller phones.
    /// An HStack that can't compress CHOOSES its ideal width, which silently
    /// widens the whole detail column — every section then overhangs the
    /// screen and .clipped() trims both edges. Hosting the row in a
    /// horizontal ScrollView caps it at the proposed width: it scrolls when
    /// tight and looks identical when it fits.
    private var actionButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileSpacing.sm) {
                ForEach(mainRowActions, id: \.self) { action in
                    actionButton(action)
                }
                Spacer()
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    /// What Play plays: a series' next episode, otherwise the item.
    private var playItem: BaseItemDto? {
        isSeries ? nextEpisodeToPlay : item
    }

    private var playHasProgress: Bool {
        isSeries ? (nextEpisodeToPlay?.userData?.playbackPositionTicks ?? 0) > 0 : hasProgress
    }

    private var mainRowActions: [DetailRowAction] {
        DetailRowAction.mainRow(
            for: item.type,
            hasProgress: playHasProgress,
            hasTrailer: (item.localTrailerCount ?? 0) > 0,
            supportsDownloads: NetworkMonitor.shared.isOnline,
            // Lists live on the active server only.
            supportsLists: NetworkMonitor.shared.isOnline && (serverID == nil || serverID == SessionManager.shared.activeServerId)
        ).filter { $0 != .more || NetworkMonitor.shared.isOnline }
    }

    @ViewBuilder
    private func actionButton(_ action: DetailRowAction) -> some View {
        switch action {
        case .play:
            if let playItem {
                Button {
                    DetailAmbience.stopForPlayback()
                    playingItem = playItem
                } label: {
                    Label(playLabel(for: playItem), systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .layoutPriority(1)
            }
        case .startOver:
            iconButton("arrow.counterclockwise", label: "Start Over") {
                DetailAmbience.stopForPlayback()
                startOverItem = playItem
            }
        case .shuffle:
            iconButton("shuffle", label: "Shuffle") { Task { await shuffleEpisode() } }
        case .trailer:
            iconButton("film", label: "Play Trailer") { Task { await playLocalTrailer() } }
        case .watched:
            Button {
                Task { await toggleWatched() }
            } label: {
                Image(systemName: isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isWatched ? MobileColors.accent : MobileColors.textSecondary)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .accessibilityLabel(isWatched ? "Watched" : "Mark Watched")
        case .download:
            downloadButton
        case .addToList:
            iconButton("text.badge.plus", label: "Add to List") { showingAddToList = true }
        case .more:
            overflowMenu
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if isSeries {
            BulkDownloadMenu(
                seasonEpisodes: episodes,
                seasonName: selectedSeason?.name,
                seriesId: item.id,
                serverID: serverID,
                compact: true
            )
        } else {
            DownloadButton(item: item, serverID: serverID, quality: nil, offersBulkOptions: isEpisode)
        }
    }

    private func playLabel(for playItem: BaseItemDto) -> String {
        let verb = playHasProgress ? "Resume" : "Play"
        if isSeries, let sNum = playItem.parentIndexNumber, let eNum = playItem.indexNumber {
            return "\(verb) S\(sNum):E\(eNum)"
        }
        return verb
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel(label)
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
                        .foregroundStyle(MobileColors.link)
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
                                // Tapping the season already shown opens its page (#760).
                                if selectedSeason?.id == season.id {
                                    openSeasonPage(season)
                                    return
                                }
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
                            .seasonTabMenu(
                                for: season,
                                action: seasonWatchAction(for: season),
                                request: $seasonWatchRequest
                            ) {
                                openSeasonPage(season)
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
                PhoneEpisodeRow(
                    episode: episode,
                    isCurrentEpisode: episode.id == currentEpisodeId,
                    isYouTube: isYouTubeStyle,
                    serverID: serverID
                ) {
                    showingEpisodeDetail = episode
                }
            }
        }
    }

    // MARK: - Cast Section

    private func castSection(_ people: [PersonInfo]) -> some View {
        let cast = PersonInfo.sortedForDisplay(people, limit: 20)

        return VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("Cast & Crew")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileSpacing.md) {
                    ForEach(cast) { person in
                        MobileCastCard(person: person, serverID: serverID) {
                            showingPersonDetail = person
                        }
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

        guard NetworkMonitor.shared.isOnline else { return }

        if !isSeries {
            await loadMediaInfo()
        }

        if isEpisode, let seriesId = item.seriesId {
            navigateToSeriesItem = try? await JellyfinClient.shared.getItem(itemId: seriesId)
        }
    }

    private func loadMediaInfo() async {
        do {
            let playbackInfo = try await JellyfinClient.shared.getPlaybackInfo(itemId: item.id, itemType: item.type, engine: .avFoundation)
            mediaInfo = playbackInfo.mediaSources?.first
        } catch {
            // Not critical
        }
    }

    private func loadSeriesContent() async {
        guard NetworkMonitor.shared.isOnline else {
            await loadOfflineSeriesContent()
            return
        }
        do {
            seasons = try await JellyfinClient.shared.getSeasons(seriesId: item.id)
            let requestedSeason = initialSeasonID.flatMap { seasonID in
                seasons.first { $0.id == seasonID }
            }
            await findNextEpisodeToPlay(preferredSeasonID: requestedSeason?.id)

            if let requestedSeason {
                selectedSeason = requestedSeason
                await loadEpisodesForSeason(seriesId: item.id, season: requestedSeason)
            } else if let nextEp = nextEpisodeToPlay, let seasonId = nextEp.seasonId {
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
                primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
                communityRating: nil, officialRating: nil, genres: nil, taglines: nil,
                people: nil, criticRating: nil, premiereDate: nil, chapters: nil,
                path: nil, remoteTrailers: nil, localTrailerCount: nil, mediaStreams: nil
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
            seriesStatus = series?.status

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
        if NetworkMonitor.shared.isOnline {
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

    private func findNextEpisodeToPlay(preferredSeasonID: String? = nil) async {
        nextEpisodeToPlay = nil
        do {
            let nextUpItems = try await JellyfinClient.shared.getNextUp(limit: 50)
            if let next = nextUpItems.first(where: {
                $0.seriesId == contentSeriesId
                    && (preferredSeasonID == nil || $0.seasonId == preferredSeasonID)
            }) {
                nextEpisodeToPlay = next
                return
            }
            let seasonsToCheck = preferredSeasonID
                .flatMap { seasonID in seasons.filter { $0.id == seasonID } }
                ?? seasons
            for season in seasonsToCheck.specialsLast {
                let eps = try await JellyfinClient.shared.getEpisodes(
                    seriesId: contentSeriesId,
                    seasonId: season.id
                )
                if let firstUnwatched = eps.first(where: { !($0.userData?.played ?? false) }) {
                    nextEpisodeToPlay = firstUnwatched
                    return
                }
            }
        } catch {
            // Silently fail
        }
    }

    // MARK: - Season watched state

    private func seasonWatchAction(for season: BaseItemDto) -> SeasonWatchAction {
        // `episodes` only describes the selected season, and only once loaded.
        let loaded = season.id == selectedSeason?.id && !isLoadingEpisodes ? episodes : nil
        return SeasonWatchAction.resolve(season: season, loadedEpisodes: loaded)
    }

    private func applySeasonWatch(_ request: SeasonWatchRequest) async {
        do {
            try await request.action.apply(seasonId: request.season.id)
        } catch {
            adminError = SeasonWatchAction.failureMessage
            return
        }
        await reloadAfterSeasonWatchChange()
    }

    /// Refresh what a season-wide played change touches (watched badges, the
    /// season list, Next Up / Play), staying on the season on screen.
    private func reloadAfterSeasonWatchChange() async {
        if let freshItem = try? await JellyfinClient.shared.getItem(itemId: item.id) {
            isWatched = freshItem.userData?.played ?? false
            hasProgress = freshItem.progressPercent > 0 && !isWatched
        }
        if let reloaded = try? await JellyfinClient.shared.getSeasons(seriesId: contentSeriesId) {
            seasons = reloaded
            selectedSeason = reloaded.first { $0.id == selectedSeason?.id } ?? selectedSeason
        }
        if let season = selectedSeason {
            await loadEpisodesForSeason(seriesId: contentSeriesId, season: season)
        }
        if isSeries {
            await findNextEpisodeToPlay()
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

    /// A watched mark made anywhere (the episode page over this one, a context
    /// menu, a season or series mark) shows on this page's episodes (#750).
    private func applyPlayedStateChange(_ change: PlayedStateChange) async {
        if change.itemId == item.id {
            isWatched = change.played
            if change.played { hasProgress = false }
        }
        let seasonId = selectedSeason?.id
        guard NetworkMonitor.shared.isOnline,
              let fresh = await change.refreshedEpisodes(
                showing: episodes,
                containerIds: [item.id, item.seriesId, item.seasonId],
                seriesId: contentSeriesId,
                seasonId: seasonId
              ),
              selectedSeason?.id == seasonId else { return }
        episodes = fresh
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

    /// `widthPoints` is the picture's drawn width; before layout (0) it
    /// assumes a portrait iPhone's full width.
    private func backdropImageURL(widthPoints: CGFloat) -> URL? {
        if !NetworkMonitor.shared.isOnline {
            if isSeries {
                let downloaded = offlineEpisodes(for: item.id)
                if let firstEp = downloaded.first {
                    return OfflineImageHelper.backdropURL(for: firstEp.itemId, serverID: firstEp.serverID)
                        ?? OfflineImageHelper.thumbnailURL(for: firstEp.itemId, serverID: firstEp.serverID)
                }
            }
            return OfflineImageHelper.backdropURL(for: item.id, serverID: serverID)
                ?? OfflineImageHelper.thumbnailURL(for: item.id, serverID: serverID)
        }

        let heroWidth = ImageSizing.backdropPixelWidth(points: widthPoints >= 1 ? widthPoints : 440)
        let hero = DetailHero.mobileImage(for: item, isYouTubeSeries: isYouTubeSeriesStyle)
        return serverImageURL(hero.itemId, hero.type, maxWidth: hero.type == "Banner" ? 1920 : heroWidth)
    }

    // MARK: - Formatting

    private func formatRuntime(_ ticks: Int64) -> String {
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
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

enum AdaptiveDetailLayout: Equatable {
    case phone
    case pad

    static func forDevice(idiom: UIUserInterfaceIdiom) -> Self {
        MobileLayoutIdiom.usesPadLayout(idiom) ? .pad : .phone
    }
}

/// How tapping an episode card opens that episode (#781). On the Mac and
/// iPad it pushes the episode's own page (back returns to the show); a small
/// sheet there read as a dialog, and Play in it played inside the dialog.
/// iPhone keeps its near-full-height episode sheet.
enum EpisodeOpenStyle: Equatable {
    case push
    case sheet

    static func forDevice(idiom: UIUserInterfaceIdiom) -> Self {
        AdaptiveDetailLayout.forDevice(idiom: idiom) == .pad ? .push : .sheet
    }

    @MainActor static var current: Self {
        forDevice(idiom: UIDevice.current.userInterfaceIdiom)
    }
}

struct AdaptiveDetailView: View {
    let item: BaseItemDto
    var libraryName: String?
    // Keep the existing adaptive entry point compatible with unscoped detail views.
    // swiftlint:disable:next implicit_optional_initialization
    var serverID: String? = nil
    // swiftlint:disable:next implicit_optional_initialization
    var initialSeasonID: String? = nil
    private let deviceIdiom: UIUserInterfaceIdiom?

    init(
        item: BaseItemDto,
        libraryName: String? = nil,
        serverID: String? = nil,
        initialSeasonID: String? = nil,
        deviceIdiom: UIUserInterfaceIdiom? = nil
    ) {
        self.item = item
        self.libraryName = libraryName
        self.serverID = serverID
        self.initialSeasonID = initialSeasonID
        self.deviceIdiom = deviceIdiom
    }

    // A phone's horizontal size class changes when it rotates, but its device
    // idiom does not. Keep the detail view type stable so a presented player's
    // fullScreenCover state survives portrait/landscape changes.
    private var layout: AdaptiveDetailLayout {
        AdaptiveDetailLayout.forDevice(idiom: deviceIdiom ?? UIDevice.current.userInterfaceIdiom)
    }

    private var detailContent: AdaptiveDetailContent {
        // A season has its own page (#760) on every device.
        if item.type == .season {
            return .season(MobileSeasonView(season: item, libraryName: libraryName, serverID: serverID, layout: layout))
        }
        switch layout {
        case .phone:
            return .phone(
                PhoneDetailView(
                    item: item,
                    libraryName: libraryName,
                    serverID: serverID,
                    initialSeasonID: initialSeasonID
                )
            )
        case .pad:
            return .pad(
                MobileDetailView(
                    item: item,
                    libraryName: libraryName,
                    serverID: serverID,
                    initialSeasonID: initialSeasonID
                )
            )
        }
    }

    var body: some View {
        detailContent
    }
}

enum AdaptiveDetailContent: View {
    case phone(PhoneDetailView)
    case pad(MobileDetailView)
    case season(MobileSeasonView)

    var layout: AdaptiveDetailLayout {
        switch self {
        case .phone:
            return .phone
        case .pad:
            return .pad
        case .season(let view):
            return view.layout
        }
    }

    @ViewBuilder
    var body: some View {
        switch self {
        case .phone(let view):
            view
        case .pad(let view):
            view
        case .season(let view):
            view
        }
    }
}
