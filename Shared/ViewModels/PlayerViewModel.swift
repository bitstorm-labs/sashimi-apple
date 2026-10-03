import Foundation
import AVKit
import AVFoundation
import Combine
import MediaPlayer
import os

extension Notification.Name {
    static let playbackDidEnd = Notification.Name("playbackDidEnd")
}

struct AudioTrackOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let languageCode: String?
    let index: Int
}

struct SubtitleTrackOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let languageCode: String?
    let index: Int
    let isOffOption: Bool
    let isExternal: Bool

    init(id: String, displayName: String, languageCode: String?, index: Int, isOffOption: Bool, isExternal: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
        self.index = index
        self.isOffOption = isOffOption
        self.isExternal = isExternal
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    typealias RecoverySetup = @MainActor (BaseItemDto, Int?, Int?, Bool) async throws -> Void

    let serverID: String?
    let playbackReporter: any PlayerPlaybackReporting

    /// Set when this player was opened by tuning to a channel rather than by
    /// picking an item. Its presence is what makes playback ephemeral.
    ///
    /// Mutable because it advances with the channel: when a programme ends, the
    /// next one carries its own offset, boundary and successor.
    var channelContext: ChannelPlaybackContext? {
        didSet { updateKeepsScreenAwake() }
    }

    /// A channel is live TV: the screen stays on for as long as one is being
    /// watched, INCLUDING the Up Next breaks between programmes. AVKit only
    /// holds off the screensaver while video plays, so a long break let it
    /// start, and the next programme then played its audio under it. Off when
    /// the channel is paused, so a forgotten pause still lets the TV rest.
    @Published private(set) var keepsScreenAwake = false

    private func updateKeepsScreenAwake() {
        let awake = channelContext != nil && stationPausedAt == nil
        if keepsScreenAwake != awake { keepsScreenAwake = awake }
    }
    let recoverySetup: RecoverySetup?

    init(
        serverID: String? = nil,
        client: JellyfinClient? = nil,
        reportDelivery: PlaybackReportDelivery? = nil,
        navigationClient: (any PlayerEpisodeNavigationClient)? = nil,
        reporter: (any PlayerPlaybackReporting)? = nil,
        transitionLoader: (any PlayerTransitionLoader)? = nil,
        recoverySetup: RecoverySetup? = nil,
        channelContext: ChannelPlaybackContext? = nil
    ) {
        self.serverID = serverID
        self.channelContext = channelContext
        keepsScreenAwake = channelContext != nil
        let resolvedServerID = serverID ?? SessionManager.shared.activeServerId
        let resolvedClient = client
            ?? resolvedServerID.flatMap { SessionManager.shared.makeClient(for: $0) }
            // A known server must never fall back to the mutable shared client:
            // that client may currently point at a different saved server.
            // An unconfigured client fails visibly and lets the durable report
            // queue retry once the selected server can be restored.
            ?? (resolvedServerID == nil ? JellyfinClient.shared : JellyfinClient())
        // Channel viewing writes no watch state. Substituting the reporter is
        // deliberate rather than guarding each call: suppression that lives in
        // the type cannot be forgotten at a call site added later.
        self.playbackReporter = reporter
            ?? (channelContext != nil
                ? ChannelPlaybackReporter()
                : PlaybackSessionReporter(
                    serverID: resolvedServerID,
                    client: resolvedClient,
                    delivery: reportDelivery
                ))
        self.client = resolvedClient
        self.navigationClient = navigationClient ?? resolvedClient
        self.transitionLoader = transitionLoader
        self.recoverySetup = recoverySetup
    }

    @Published var player: AVPlayer?
    @Published var isPlayerReady = false
    @Published var isLoading = true
    @Published var error: Error?
    @Published var currentItem: BaseItemDto?
    @Published var errorMessage: String?
    @Published var audioTracks: [AudioTrackOption] = []
    @Published var selectedAudioTrackId: String?
    @Published var subtitleTracks: [SubtitleTrackOption] = []
    @Published var selectedSubtitleTrackId: String?
    @Published var subtitleManager = SubtitleManager()
    @Published var playbackEnded = false

    /// Canonical current/previous/next state shared by both player surfaces.
    /// The compatibility accessors below keep existing callers source
    /// compatible while views observe this single published state.
    @Published var transitionState = PlayerTransitionState.empty

    var nextEpisode: BaseItemDto? { transitionState.nextEpisode }
    var previousEpisode: BaseItemDto? { transitionState.previousEpisode }

    /// A lookup error is intentionally generic at the UI boundary. The
    /// detailed, scrubbed error is emitted through PlayerDiagnostics instead.
    var episodeLookupFailed: Bool {
        transitionState.lookupStatus == .failed
    }

    /// Bumped whenever the player is rebuilt against a different asset, so
    /// views can refresh track menus that would otherwise describe the old one.
    @Published var tracksVersion = 0
    /// Re-entrancy guard for end-of-playback handling (see handlePlaybackEnded).
    var isHandlingEnd = false
    struct PendingPlaybackEnd {
        let itemID: String
        let attempt: Int
    }
    struct PlaybackGeneration {
        let itemID: String
        let attempt: Int
    }
    var pendingPlaybackEnd: PendingPlaybackEnd?
    var isChangingQuality = false
    var playbackAttemptItemID: String?
    var sameItemPlaybackAttempts = Set<Int>()
    /// Resume position still waiting to be applied once the item is ready to
    /// play. A pre-ready seek is silently dropped for HLS/transcode streams
    /// (no seekable range yet), so we re-seek from the status observer.
    var pendingResumeTicks: Int64 = 0
    @Published var resumePositionTicks: Int64 = 0
    @Published var selectedQuality: QualityOption = .auto
    /// The bitrate cap the current stream was requested with (the tier's, a
    /// Settings cap, or Auto's measured/default cap). Drives the quality label
    /// and is where Auto's step-down starts from.
    @Published var activeBitrateCap: Int?
    /// A brief player message: "Switching to 480p · 4 Mbps…" while a quality
    /// change rebuilds, "Lowering quality for your connection" after a
    /// bandwidth step-down. Shown by both player surfaces.
    @Published var playbackNotice: String?
    var playbackNoticeTask: Task<Void, Never>?
    @Published var videoResolution: String?
    @Published var streamInfo: StreamInfo?

    /// How playback is actually being delivered, per the server's session —
    /// shown as a chip in the player's top info bar when controls are visible.
    struct StreamInfo: Equatable {
        enum Method: Equatable {
            case directPlay
            case directStream   // container remux / audio conversion; video copied
            case transcode
        }

        let method: Method
        /// Transcode target, e.g. "1080p H264 8 Mbps" (nil unless transcoding)
        let detail: String?
        /// Human-readable primary transcode reason, e.g. "bitrate limit"
        let reason: String?

        var label: String {
            // Viewer-facing wording: "Direct Play" vs "Direct Stream" is server
            // plumbing — both deliver the identical video bits, so both read
            // "Original". Only a transcode changes the picture: "Converted".
            switch method {
            case .directPlay: return "Original"
            case .directStream: return "Original"
            case .transcode: return "Converted"
            }
        }
    }

    // Track when playback actually started (for quick-exit protection)
    var playbackStartDate: Date?
    var isOfflinePlayback = false

    // MARK: Recovery (official-client error fallback)

    /// How many same-quality recovery rebuilds this item has burned. Two max —
    /// first forces a transcode (fresh session at the current position, video
    /// copy still allowed), the second additionally disallows video stream
    /// copy (a genuine re-encode, the last resort). Mirrors jellyfin-web's
    /// onPlaybackError escalation. Reset per item in loadMedia.
    var recoveryAttempts = 0
    /// Bandwidth step-downs taken this item (see PlaybackRecoveryPlan). They
    /// don't spend the rebuild budget: each one lowers the bitrate, so they
    /// end at the 720 kbps floor. Reset per item in loadMedia.
    var qualityStepDowns = 0
    /// Re-entrancy guard: a failed item can fire status + error-log + stall
    /// notifications for the same underlying failure in one runloop.
    var isRecovering = false
    /// Pending stall watchdog — armed on a stall notification, cancelled when
    /// playback recovers on its own or the player is torn down.
    var stallWatchdogTask: Task<Void, Never>?
    var navigationTask: Task<Void, Never>?

    /// Whether the error/stall fallback can still fire for this item.
    var canAttemptRecovery: Bool {
        !transitionState.isTransitioning && !isRecovering && !isOfflinePlayback && currentItem != nil
            && recoveryDecision(isStall: false) != .giveUp
    }

    /// Subtitles that came down with a download. Injected by the iOS player,
    /// because the download store lives in the app target and this view model
    /// is shared. Empty for online playback.
    var offlineSubtitles: [OfflineSubtitle] = []
    /// Episode navigation for local-file playback: previous / next among the
    /// downloads, so a downloaded episode rolls into the next downloaded one.
    /// Injected by the iOS player (the download store lives in the app
    /// target); nil keeps local playback without episode navigation.
    var offlineEpisodeSource: (any OfflineEpisodeSource)?

    // Media source info for subtitle/audio selection
    var currentMediaSource: MediaSourceInfo?
    private var currentSubtitleStreamIndex: Int?

    /// The subtitle track the session wants, described by content rather
    /// than stream index (indexes are not stable across media sources).
    /// Once set, subtitles stay on across quality changes and episode
    /// transitions until explicitly turned off (disableSubtitles/stop).
    struct SubtitlePreference {
        let language: String?
        let displayTitle: String?
        let isExternal: Bool
    }
    var sessionSubtitlePreference: SubtitlePreference?

    /// The audio track the viewer picked in the player this session.
    ///
    /// Matched by language and display name rather than raw index, for the same
    /// reason subtitles are: a rebuilt player (quality change) or the next
    /// episode is a different asset whose option ordering need not match.
    /// Without this, a manual pick was silently reverted to the default track
    /// on every quality change and every episode -- while the menu kept the
    /// checkmark on the track that was no longer playing.
    struct AudioPreference {
        let language: String?
        let displayName: String
    }
    var sessionAudioPreference: AudioPreference?

    // Server-side play session: sent with playback reports so the server can
    // correlate them, and used to stop the session's transcode when playback
    // is torn down or rebuilt.
    var playSessionId: String?

    /// Play method reported to the server — keeps the dashboard honest now
    /// that explicit quality picks force transcodes.
    var currentPlayMethod: String {
        currentMediaSource?.transcodingUrl != nil ? "Transcode" : "DirectStream"
    }

    // Skip intro/credits
    @Published var segments: [MediaSegmentDto] = []
    @Published var currentSegment: MediaSegmentDto?
    @Published var showingSkipButton = false

    var segmentObserver: Any?
    var progressReportTask: Task<Void, Never>?
    var subtitleLoadTask: Task<Void, Never>?
    var teardownTask: Task<Void, Never>?
    var statusObserver: NSKeyValueObservation?
    var errorObserver: NSKeyValueObservation?
    var rateObserver: NSKeyValueObservation?
    var endObserver: NSObjectProtocol?
    /// AVPlayerItem error/access log observers — see observeItemLogs.
    var itemErrorLogObserver: NSObjectProtocol?
    var itemAccessLogObserver: NSObjectProtocol?
    /// Time-jump / stall / failed-to-end observers, kept together because they
    /// share a lifetime with the current player item.
    var stallObservers: [NSObjectProtocol] = []
    /// Last stall count already reported, so a climbing counter is logged once
    /// per new stall instead of on every access-log entry.
    var lastReportedStallCount = 0
    /// Serves the current item's rewritten master playlist (tvOS HDR
    /// stream-copy only, #449). `AVAssetResourceLoader` holds its delegate
    /// weakly, so it lives here for as long as the asset it feeds.
    var hlsPlaylistLoader: HLSPlaylistResourceLoader?
    let client: JellyfinClient
    let navigationClient: any PlayerEpisodeNavigationClient
    let transitionLoader: (any PlayerTransitionLoader)?
    let playbackSettings = PlaybackSettings.shared

    func setCurrentItem(_ item: BaseItemDto?) {
        currentItem = item
        transitionState.currentItem = item
    }

    func resetTransitionState(for item: BaseItemDto?) {
        transitionState = PlayerTransitionState(
            currentItem: item,
            previousEpisode: nil,
            nextEpisode: nil,
            lookupStatus: item?.type == .episode ? .loading : .notApplicable,
            endCard: nil,
            isTransitioning: transitionState.isTransitioning
        )
    }

    // MARK: - Diagnostics

    /// Identifies THIS view model instance in the log.
    ///
    /// The production restart loop (transcode starts, client abandons it ~1s
    /// later, a different transcode starts) has two very different causes that
    /// are indistinguishable server-side: one view model loading twice, or two
    /// view models each loading once (SwiftUI recreating the player view).
    /// Tagging every line with the instance is what tells them apart.
    nonisolated let sessionTag = String(UUID().uuidString.prefix(8))

    /// Incremented by every path that builds a player (loadMedia,
    /// changeQuality). Two `load.begin` lines with the same `vm` and different
    /// `attempt` values mean this instance was asked to load twice.
    var playbackAttempt = 0

    // MARK: - Stations

    @Published var stationBanner: StationBanner?
    @Published var upNext: UpNext?
    @Published var stationMark: StationMark?
    var stationPausedAt: Date? {
        didSet { updateKeepsScreenAwake() }
    }
    var secondsBehindLive: TimeInterval = 0
    var stations: [VirtualChannel] = []

    deinit {
        PlayerDiagnostics.event(.deinitialized, [
            PlayerDiagnostics.field("vm", sessionTag),
            PlayerDiagnostics.field("reason", PlayerDiagnostics.TeardownReason.deallocated.rawValue)
        ])
        progressReportTask?.cancel()
        subtitleLoadTask?.cancel()
        navigationTask?.cancel()
        cleanupRemoteCommands()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        // The diagnostics observers are block-based, so they outlive this
        // object unless they are removed explicitly — same contract as
        // endObserver above.
        if let itemErrorLogObserver {
            NotificationCenter.default.removeObserver(itemErrorLogObserver)
        }
        if let itemAccessLogObserver {
            NotificationCenter.default.removeObserver(itemAccessLogObserver)
        }
        for observer in stallObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

enum PlayerError: LocalizedError {
    case noMediaSource
    case noStreamURL
    case noPlayableEpisode(String)
    case sourceNotPlayable

    var errorDescription: String? {
        switch self {
        case .noMediaSource:
            return "No playable media source found"
        case .noStreamURL:
            return "Could not generate stream URL"
        case .noPlayableEpisode(let name):
            return "Couldn't find an episode of \"\(name)\" to play"
        case .sourceNotPlayable:
            return "This video can't be played on this device with the current playback settings"
        }
    }
}
