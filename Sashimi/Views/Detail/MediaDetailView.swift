import SwiftUI
import NukeUI

struct MediaDetailView: View {
    var forceYouTubeStyle: Bool = false
    let serverID: String?
    @Environment(\.dismiss) var dismiss
    @State var item: BaseItemDto
    @State var showingPlayer = false
    @State var startFromBeginning = false

    @State var isWatched: Bool = false
    @State var hasProgress: Bool = false

    init(item: BaseItemDto, forceYouTubeStyle: Bool = false, serverID: String? = nil) {
        self.forceYouTubeStyle = forceYouTubeStyle
        self.serverID = serverID
        self._item = State(initialValue: item)
    }
    @State var seasons: [BaseItemDto] = []
    @State var episodes: [BaseItemDto] = []
    @State var selectedSeason: BaseItemDto?
    @State var selectedEpisode: BaseItemDto?
    @State var mediaInfo: MediaSourceInfo?
    @State var seriesOfficialRating: String?
    @State var seriesGenres: [String]?
    @State var seriesCommunityRating: Double?
    /// The show's airing status, for an episode's status pill.
    @State var seriesStatus: String?
    @State var seriesCriticRating: Int?
    @State var nextEpisodeToPlay: BaseItemDto?
    @State var isLoadingEpisodes = false
    @State var showingSeriesDetail: BaseItemDto?
    @State var showingEpisodeDetail: BaseItemDto?
    @State var showingPersonDetail: PersonInfo?
    @State var pendingServerMedia: ServerMediaResult?
    @State var selectedServerMedia: ServerMediaResult?
    @State var showingFileInfo = false
    @State var showingDeleteConfirm = false
    @State var seasonWatchRequest: SeasonWatchRequest?
    @State var showingFullOverview = false
    @State var isFavorite: Bool = false
    @State var isRefreshing = false
    @State var refreshID = UUID()
    @FocusState var isMoreButtonFocused: Bool
    /// Add to Channel, for the active server's administrators.
    @State var channelTarget: ChannelTarget?
    @ObservedObject var session = SessionManager.shared

    var isSeries: Bool { item.type == .series }
    var isEpisode: Bool { item.type == .episode }
    private var isVideo: Bool { item.type == .video }
    var isMovie: Bool { item.type == .movie }

    // YouTube-style content uses landscape thumbnails instead of portrait posters
    var isYouTubeStyle: Bool {
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
    var isYouTubeSeriesStyle: Bool {
        isSeries && forceYouTubeStyle
    }

    // Episode from YouTube library - show circular channel art instead of series logo
    var isYouTubeChannelEpisode: Bool {
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

    /// Fraction of the layout width the backdrop fills in the top-right corner.
    /// Single source of truth: the frame and the image request both derive from
    /// it, so resizing the layout can't silently leave the request undersized.
    ///
    /// About half the screen, flush to the top and right edges like the home
    /// hero. Its left third fades out, so the part under the info column is a
    /// blend into the background rather than picture behind the title.
    private var backdropWidthFraction: CGFloat {
        isYouTubeSeriesStyle ? 0.6 : 0.55
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

                    // Background image: flush top-right, fading into the page on
                    // its left and bottom, the same way the home hero does.
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Spacer()
                            AsyncItemImage(
                                itemId: backdropId,
                                imageType: backdropImageType,
                                // Request at native pixel density: tvOS lays out
                                // in 1920pt but Apple TV 4K renders @2x, so a
                                // point-width frame needs twice that many pixels
                                // or the backdrop is upscaled and reads soft.
                                maxWidth: Int(geometry.size.width * backdropWidthFraction * 2),
                                contentMode: .fit,
                                fallbackImageTypes: isYouTubeSeriesStyle ? ["Backdrop", "Thumb", "Primary"] : ["Thumb", "Backdrop", "Primary"],
                                serverID: serverID
                            )
                            .id(refreshID)
                            .heroTrailer(for: item, serverID: serverID)
                            .frame(width: geometry.size.width * backdropWidthFraction, alignment: .topTrailing)
                            // Only the left and bottom edges fade; the top and
                            // right run off the screen like the home hero's.
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: .white, location: 0.35)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .mask(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .white, location: 0.6),
                                            .init(color: .clear, location: 1.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            )
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
        .themeSong(for: item)
        .fullScreenCover(isPresented: $showingPlayer) {
            PlayerView(
                item: selectedEpisode ?? item,
                serverID: serverID,
                startFromBeginning: startFromBeginning
            )
        }
        .fullScreenCover(item: $showingSeriesDetail) { series in
            MediaDetailView(item: series, forceYouTubeStyle: forceYouTubeStyle, serverID: serverID)
        }
        .fullScreenCover(item: $showingEpisodeDetail) { episode in
            MediaDetailView(item: episode, forceYouTubeStyle: forceYouTubeStyle, serverID: serverID)
        }
        .fullScreenCover(item: $showingPersonDetail, onDismiss: presentPendingServerMedia) { person in
            PersonDetailView(
                person: person,
                excludingItemID: item.id,
                excludingTitleKey: ServerMediaResultGrouping.titleKey(for: item),
                originatingServerID: serverID ?? SessionManager.shared.activeServerId,
                onSelectSource: queueServerMedia
            )
        }
        .fullScreenCover(item: $selectedServerMedia) { source in
            NavigationStack {
                ServerScopedMediaDetailView(source: source)
            }
        }
        .fullScreenCover(item: $channelTarget) { target in
            AddToChannelView(target: target)
        }
        .sheet(isPresented: $showingFullOverview) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(item.name)
                        .font(Typography.headlineSmall)
                        .foregroundStyle(SashimiTheme.textPrimary)
                    Text(item.overview ?? "")
                        .font(Typography.body)
                        .foregroundStyle(SashimiTheme.textSecondary)
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 1100, alignment: .leading)
            }
            .background(SashimiTheme.background)
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
        .seasonWatchConfirmation($seasonWatchRequest) { request in
            Task { await applySeasonWatch(request) }
        }
        .task {
            await loadContent()
        }
        .onAppear {
            isWatched = item.userData?.played ?? false
            hasProgress = item.progressPercent > 0
            isFavorite = item.userData?.isFavorite ?? false
        }
        .onChange(of: showingPlayer) { _, isShowing in
            if !isShowing {
                // Reset startFromBeginning and refresh item data when returning from player
                startFromBeginning = false
                // selectedEpisode is what the player actually played (a trailer,
                // a shuffled episode, or next-up). Leaving it set meant the NEXT
                // press of Play replayed that instead of the item: play a movie's
                // trailer, come back, press Play, and you got the trailer again
                // with no way out short of leaving the detail view.
                selectedEpisode = nil
                Task { await refreshItemState() }
            }
        }
        // The player now closes before its stopped report has reached the
        // server (#591), so the refresh above can read the position from
        // before this viewing. This one runs once the report is in.
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidEnd)) { _ in
            Task { await refreshItemState() }
        }
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

            // Action buttons in their own full-width row under the cover art
            // (Plex layout), rather than squeezed at the bottom of the info
            // column beside the poster. Down from the poster/info lands here.
            actionButtonsRow
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

            if isSeries {
                seasonsSection
                    .focusSection()
            } else if isEpisode {
                nextUpSection
                    .focusSection()
            }

            if let people = item.people, !people.isEmpty {
                castSection(people)
            }

            Spacer().frame(height: 80)
        }
    }
}
