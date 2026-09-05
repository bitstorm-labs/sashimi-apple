import Foundation
import AVKit
import AVFoundation
import Combine
import MediaPlayer
import os

// swiftlint:disable file_length type_body_length function_body_length
// PlayerViewModel manages complex video playback state - splitting would fragment playback logic

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

enum QualityOption: String, CaseIterable, Identifiable {
    case auto = "auto"
    case quality1080p = "1080"
    case quality720p = "720"
    case quality480p = "480"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .quality1080p: return "1080p"
        case .quality720p: return "720p"
        case .quality480p: return "480p"
        }
    }

    var maxBitrate: Int? {
        switch self {
        case .auto: return nil  // No limit
        case .quality1080p: return 20_000_000  // 20 Mbps
        case .quality720p: return 8_000_000   // 8 Mbps
        case .quality480p: return 4_000_000   // 4 Mbps
        }
    }

    /// Pixel width cap for the tier.
    ///
    /// The bitrate cap alone does not change resolution: a 1080p source already
    /// under the cap is simply passed through, so picking "720p" on a 7 Mbps
    /// 1080p file produced a 1080p stream and the OSD correctly kept saying
    /// 1080p. The width is what actually makes the tier mean what it says.
    var maxWidth: Int? {
        switch self {
        case .auto: return nil
        case .quality1080p: return 1920
        case .quality720p: return 1280
        case .quality480p: return 854
        }
    }
}

// Playback reporting is best-effort by design -- a failed report must never
// interrupt playback -- but swallowing it silently meant watch state could
// stop syncing with no trace at all.
private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "PlayerViewModel")

@MainActor
final class PlayerViewModel: ObservableObject {
    let serverID: String?
    private let playbackReporter: PlaybackSessionReporter

    init(
        serverID: String? = nil,
        client: JellyfinClient? = nil,
        reportDelivery: PlaybackReportDelivery? = nil
    ) {
        self.serverID = serverID
        let resolvedServerID = serverID ?? SessionManager.shared.activeServerId
        let resolvedClient = client
            ?? resolvedServerID.flatMap { SessionManager.shared.makeClient(for: $0) }
            // A known server must never fall back to the mutable shared client:
            // that client may currently point at a different saved server.
            // An unconfigured client fails visibly and lets the durable report
            // queue retry once the selected server can be restored.
            ?? (resolvedServerID == nil ? JellyfinClient.shared : JellyfinClient())
        self.playbackReporter = PlaybackSessionReporter(
            serverID: resolvedServerID,
            client: resolvedClient,
            delivery: reportDelivery
        )
        self.client = resolvedClient
    }

    @Published var player: AVPlayer?
    @Published private(set) var isPlayerReady = false
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

    /// Bumped whenever the player is rebuilt against a different asset, so
    /// views can refresh track menus that would otherwise describe the old one.
    @Published private(set) var tracksVersion = 0
    @Published var nextEpisode: BaseItemDto?
    /// Re-entrancy guard for end-of-playback handling (see handlePlaybackEnded).
    private var isHandlingEnd = false
    /// Resume position still waiting to be applied once the item is ready to
    /// play. A pre-ready seek is silently dropped for HLS/transcode streams
    /// (no seekable range yet), so we re-seek from the status observer.
    private var pendingResumeTicks: Int64 = 0
    @Published var resumePositionTicks: Int64 = 0
    @Published var selectedQuality: QualityOption = .auto
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
    private var playbackStartDate: Date?
    private var isOfflinePlayback = false

    // MARK: Recovery (official-client error fallback)

    /// How many recovery rebuilds this item has burned. Two attempts max —
    /// first forces a transcode (fresh session at the current position, video
    /// copy still allowed), the second additionally disallows video stream
    /// copy (a genuine re-encode, the last resort). Mirrors jellyfin-web's
    /// onPlaybackError escalation. Reset per item in loadMedia.
    private var recoveryAttempts = 0
    /// Re-entrancy guard: a failed item can fire status + error-log + stall
    /// notifications for the same underlying failure in one runloop.
    private var isRecovering = false
    /// Pending stall watchdog — armed on a stall notification, cancelled when
    /// playback recovers on its own or the player is torn down.
    private var stallWatchdogTask: Task<Void, Never>?

    /// Whether the error/stall fallback can still fire for this item.
    private var canAttemptRecovery: Bool {
        !isRecovering && !isOfflinePlayback && recoveryAttempts < 2 && currentItem != nil
    }

    /// Subtitles that came down with a download. Injected by the iOS player,
    /// because the download store lives in the app target and this view model
    /// is shared. Empty for online playback.
    private var offlineSubtitles: [OfflineSubtitle] = []

    // Media source info for subtitle/audio selection
    private var currentMediaSource: MediaSourceInfo?
    private var currentSubtitleStreamIndex: Int?

    /// The subtitle track the session wants, described by content rather
    /// than stream index (indexes are not stable across media sources).
    /// Once set, subtitles stay on across quality changes and episode
    /// transitions until explicitly turned off (disableSubtitles/stop).
    private struct SubtitlePreference {
        let language: String?
        let displayTitle: String?
        let isExternal: Bool
    }
    private var sessionSubtitlePreference: SubtitlePreference?

    /// The audio track the viewer picked in the player this session.
    ///
    /// Matched by language and display name rather than raw index, for the same
    /// reason subtitles are: a rebuilt player (quality change) or the next
    /// episode is a different asset whose option ordering need not match.
    /// Without this, a manual pick was silently reverted to the default track
    /// on every quality change and every episode -- while the menu kept the
    /// checkmark on the track that was no longer playing.
    private struct AudioPreference {
        let language: String?
        let displayName: String
    }
    private var sessionAudioPreference: AudioPreference?

    // Server-side play session: sent with playback reports so the server can
    // correlate them, and used to stop the session's transcode when playback
    // is torn down or rebuilt.
    private var playSessionId: String?

    /// Play method reported to the server — keeps the dashboard honest now
    /// that explicit quality picks force transcodes.
    private var currentPlayMethod: String {
        currentMediaSource?.transcodingUrl != nil ? "Transcode" : "DirectStream"
    }

    // Skip intro/credits
    @Published var segments: [MediaSegmentDto] = []
    @Published var currentSegment: MediaSegmentDto?
    @Published var showingSkipButton = false

    private var segmentObserver: Any?
    private var progressReportTask: Task<Void, Never>?
    private var subtitleLoadTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var statusObserver: NSKeyValueObservation?
    private var errorObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    /// AVPlayerItem error/access log observers — see observeItemLogs.
    private var itemErrorLogObserver: NSObjectProtocol?
    private var itemAccessLogObserver: NSObjectProtocol?
    /// Time-jump / stall / failed-to-end observers, kept together because they
    /// share a lifetime with the current player item.
    private var stallObservers: [NSObjectProtocol] = []
    /// Last stall count already reported, so a climbing counter is logged once
    /// per new stall instead of on every access-log entry.
    private var lastReportedStallCount = 0
    private let client: JellyfinClient
    private let playbackSettings = PlaybackSettings.shared

    // MARK: - Diagnostics

    /// Identifies THIS view model instance in the log.
    ///
    /// The production restart loop (transcode starts, client abandons it ~1s
    /// later, a different transcode starts) has two very different causes that
    /// are indistinguishable server-side: one view model loading twice, or two
    /// view models each loading once (SwiftUI recreating the player view).
    /// Tagging every line with the instance is what tells them apart.
    nonisolated private let sessionTag = String(UUID().uuidString.prefix(8))

    /// Incremented by every path that builds a player (loadMedia,
    /// changeQuality). Two `load.begin` lines with the same `vm` and different
    /// `attempt` values mean this instance was asked to load twice.
    private var playbackAttempt = 0

    /// Fields stamped on every diagnostic line from this instance.
    private var diagContext: [String] {
        [
            PlayerDiagnostics.field("vm", sessionTag),
            PlayerDiagnostics.field("attempt", playbackAttempt)
        ]
    }

    private func diag(_ stage: PlayerDiagnostics.Stage, _ fields: [String] = []) {
        PlayerDiagnostics.event(stage, diagContext + fields)
    }

    private func diagFailure(_ stage: PlayerDiagnostics.Stage, _ fields: [String] = []) {
        PlayerDiagnostics.failure(stage, diagContext + fields)
    }

    private func diagDetail(_ stage: PlayerDiagnostics.Stage, _ fields: [String] = []) {
        PlayerDiagnostics.detail(stage, diagContext + fields)
    }

    /// Refreshes the stream-info chip from the server's own session view.
    /// Called when the player overlay becomes visible; cheap single GET.
    func refreshStreamInfo() async {
        guard !isOfflinePlayback else {
            streamInfo = StreamInfo(method: .directPlay, detail: nil, reason: nil)
            return
        }
        guard let session = try? await client.getOwnSession(),
              session.nowPlayingItemId?.id != nil else { return }

        let method = session.playState?.playMethod
        let info = session.transcodingInfo

        if method == "Transcode", info == nil {
            // Transcode session whose ffmpeg already finished (or hasn't
            // registered yet): Jellyfin drops TranscodingInfo but PlayMethod
            // stays "Transcode". Keep the last known chip if we have one —
            // never fall through to "Direct Play" for a transcode session.
            if streamInfo == nil {
                streamInfo = StreamInfo(method: .transcode, detail: nil, reason: nil)
            }
        } else if method == "Transcode", let info {
            if info.isVideoDirect == true {
                // Container remux / audio conversion — video untouched, so the
                // source video bitrate IS the delivered speed. Show it.
                streamInfo = StreamInfo(method: .directStream, detail: sourceBitrateDetail, reason: nil)
            } else {
                var parts: [String] = []
                if let width = info.width, let height = info.height {
                    parts.append(Self.resolutionLabel(width: width, height: height))
                }
                if let codec = info.videoCodec { parts.append(codec.uppercased()) }
                if let bitrate = info.bitrate, bitrate > 0 {
                    parts.append("\(Int(round(Double(bitrate) / 1_000_000))) Mbps")
                } else if let source = sourceBitrateDetail {
                    // TranscodingInfo omitted the target bitrate — show source
                    parts.append(source)
                }
                let reason = info.transcodeReasons?.first.map(Self.humanTranscodeReason)
                streamInfo = StreamInfo(
                    method: .transcode,
                    detail: parts.isEmpty ? nil : parts.joined(separator: " "),
                    reason: reason
                )
            }
        } else if method == "DirectStream" {
            streamInfo = StreamInfo(method: .directStream, detail: sourceBitrateDetail, reason: nil)
        } else if method != nil {
            streamInfo = StreamInfo(method: .directPlay, detail: sourceBitrateDetail, reason: nil)
        }
    }

    /// Source file's overall bitrate ("4 Mbps") for direct play/stream chips —
    /// transcode sessions report the target bitrate via TranscodingInfo instead.
    private var sourceBitrateDetail: String? {
        // Prefer the container bitrate; fall back to the video stream's own
        // bitrate when the MediaSource omits it (some remuxed/direct files),
        // so the OSD speed chip is never blank.
        let bps = (currentMediaSource?.bitrate).flatMap { $0 > 0 ? $0 : nil }
            ?? currentMediaSource?.mediaStreams?.first(where: { $0.type == "Video" })?.bitRate
        guard let bps, bps > 0 else { return nil }
        return "\(Int(round(Double(bps) / 1_000_000))) Mbps"
    }

    private static func resolutionLabel(width: Int, height: Int) -> String {
        if width >= 3200 || height >= 2160 { return "4K" }
        if width >= 1800 || height >= 1080 { return "1080p" }
        if width >= 1200 || height >= 720 { return "720p" }
        return "\(height)p"
    }

    private static func humanTranscodeReason(_ reason: String) -> String {
        switch reason {
        case "ContainerNotSupported": return "container"
        case "ContainerBitrateExceedsLimit": return "bitrate limit"
        case "VideoCodecNotSupported": return "video codec"
        case "AudioCodecNotSupported": return "audio codec"
        case "SubtitleCodecNotSupported": return "subtitles"
        case "VideoResolutionNotSupported": return "resolution"
        case "AudioChannelsNotSupported": return "audio channels"
        case "UnknownVideoStreamInfo", "UnknownAudioStreamInfo": return "stream info"
        default: return reason
        }
    }

    /// Ends the server-side transcode belonging to the CURRENT play session, if
    /// there is one, and records why.
    ///
    /// This is the client action Jellyfin logs as "Stopping ffmpeg process with
    /// q command" (it is a DELETE /Videos/ActiveEncodings). From the server's
    /// side it is indistinguishable from the client simply walking away, which
    /// is why every call site has to name its reason here.
    private func stopActiveEncodingIfNeeded(reason: PlayerDiagnostics.TeardownReason) async {
        guard !isOfflinePlayback,
              let playSessionId,
              currentMediaSource?.transcodingUrl != nil else { return }

        diag(.encodingStop, [
            PlayerDiagnostics.field("reason", reason.rawValue),
            PlayerDiagnostics.field("playSession", playSessionId)
        ])
        do {
            try await client.stopActiveEncoding(playSessionId: playSessionId)
        } catch {
            logger.error("stopActiveEncoding failed: \(error.localizedDescription, privacy: .public)")
            diagFailure(.encodingStop, [
                PlayerDiagnostics.field("reason", reason.rawValue)
            ] + PlayerDiagnostics.fields(for: error))
        }
    }

    func loadMedia(
        item: BaseItemDto,
        startFromBeginning: Bool = false,
        localFileURL: URL? = nil,
        offlineSubtitles: [OfflineSubtitle] = []
    ) async {
        playbackAttempt += 1
        isPlayerReady = false
        playbackReporter.reset()
        // Fresh item, fresh recovery budget; a watchdog armed for the old
        // player must not fire into the new one.
        recoveryAttempts = 0
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        diag(.loadBegin, [
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("type", item.type?.rawValue),
            PlayerDiagnostics.field("startFromBeginning", startFromBeginning),
            PlayerDiagnostics.field("offline", localFileURL != nil),
            PlayerDiagnostics.field("hadPlayer", player != nil),
            PlayerDiagnostics.field("previousItem", currentItem?.id)
        ])
        self.offlineSubtitles = offlineSubtitles
        // Tear down everything tied to the previous player first — auto-play
        // next episode reuses this ViewModel, and observers left on the old
        // player crash when it deallocates (same teardown as changeQuality).
        // The session subtitle intent is deliberately preserved so subtitles
        // stay on across episodes; only the overlay/tracking is cleared.
        // Silence and release the outgoing player BEFORE anything awaits.
        //
        // This teardown removed the observers but never paused the player and
        // never let go of it, so the previous episode kept playing its audio
        // underneath the new one. The gap is not brief: everything below this
        // point awaits the network — stopActiveEncoding, then the playback-info
        // fetch — and the new AVPlayer is not created until well after that. On
        // tvOS the AVPlayerViewController also goes on holding the old instance
        // until the new one is assigned, so it really does keep decoding.
        //
        // changeQuality and the stop path both do this; only this one did not,
        // which is how auto-play-next and skip-credits ended up with two
        // players running.
        if player != nil {
            diag(.teardown, [
                PlayerDiagnostics.field("reason", PlayerDiagnostics.TeardownReason.newItem.rawValue),
                PlayerDiagnostics.field("outgoingItem", currentItem?.id),
                PlayerDiagnostics.field("incomingItem", item.id)
            ])
        }
        player?.pause()
        progressReportTask?.cancel()
        subtitleLoadTask?.cancel()
        cleanupSegmentTracking()
        subtitleManager.clear()
        selectedSubtitleTrackId = "off"
        invalidatePlayerObservers()
        isHandlingEnd = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player = nil

        // Kill the previous episode's transcode session, same as
        // changeQuality — auto-play-next otherwise leaves the old encode
        // running until the server times it out.
        await stopActiveEncodingIfNeeded(reason: .newItem)

        isLoading = true
        error = nil
        errorMessage = nil

        do {
            let freshItem: BaseItemDto

            if let localFileURL {
                // Offline playback from local file
                freshItem = item
                currentItem = item

                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .moviePlayback)
                try audioSession.setActive(true)

                diag(.streamSelected, [
                    PlayerDiagnostics.field("kind", PlayerDiagnostics.StreamKind.localFile.rawValue),
                    PlayerDiagnostics.field("ext", localFileURL.pathExtension)
                ])
                let asset = AVURLAsset(url: localFileURL)
                diag(.assetCreated, [PlayerDiagnostics.field("kind", PlayerDiagnostics.StreamKind.localFile.rawValue)])
                let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable", "duration"])
                // Same observer wiring as the online path. loadMedia has already
                // torn down the previous endObserver, so building the player
                // directly here left downloads with no end-of-item notification
                // and no way to surface a decode failure.
                makePlayerAndObservers(for: playerItem)
            } else {
                // Online playback - fetch fresh data from server.
                // Resolve container types (Series/Season) to the episode that
                // should actually play BEFORE any PlaybackInfo request — a
                // series id posted to PlaybackInfo is a guaranteed server 500
                // (InvalidCastException to IHasMediaSources, seen in
                // production). Entry points like the Continue Watching Play
                // button and Top Shelf deep links hand over whatever item the
                // row carried, so the guarantee lives here, not in each caller.
                freshItem = try await resolvePlayableItem(client.getItem(itemId: item.id))
                currentItem = freshItem

                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .moviePlayback)
                try audioSession.setActive(true)

                try await setupPlayer(for: freshItem)
                await applyPreferredTracks()
            }

            // Set up remote control commands for Bluetooth headsets/remotes
            // On tvOS, AVPlayerViewController handles MPRemoteCommandCenter automatically
            #if os(iOS)
            setupRemoteCommands()
            #endif
            updateNowPlayingInfo(item: freshItem)

            isLoading = false

            isOfflinePlayback = localFileURL != nil
            let isOffline = isOfflinePlayback

            diag(.loadReady, [
                PlayerDiagnostics.field("item", freshItem.id),
                PlayerDiagnostics.field("playSession", playSessionId),
                PlayerDiagnostics.field("offline", isOffline)
            ])

            // Fetch media segments for skip intro/credits (skip when offline)
            if !isOffline {
                await fetchSegments(itemId: freshItem.id)
            }

            // Check if there's saved progress to resume from
            let thresholdTicks = Int64(playbackSettings.resumeThresholdSeconds) * 10_000_000
            if startFromBeginning {
                // User explicitly chose to start over - play from beginning
                resumePositionTicks = 0
                pendingResumeTicks = 0
                if !isOffline {
                    await reportPlaybackStart(item: freshItem, positionTicks: 0)
                    startProgressReporting()
                }
                setupSegmentTracking()
                playbackStartDate = Date()
                logAndPlay(positionTicks: resumePositionTicks)
            } else if let startTicks = freshItem.userData?.playbackPositionTicks, startTicks > thresholdTicks {
                // Auto-resume from saved position (no dialog)
                resumePositionTicks = startTicks
                pendingResumeTicks = startTicks
                // NO seek here. The resume position is applied exactly once,
                // from the status observer, when the item reports .readyToPlay.
                //
                // What used to be here was `await player?.seek(to: startTime)`,
                // and it was wrong twice over:
                //
                //  1. It AWAITED a seek completion inside startup. AVFoundation
                //     only promises to call that completion when the seek
                //     finishes or is superseded, and on a stream that is not
                //     ready yet that can be seconds — or never, if the item is
                //     replaced first. Everything below it (reportPlaybackStart,
                //     progress reporting, segment tracking, and play() itself)
                //     was blocked behind it. That is a resume-only stall, and
                //     resume-only is exactly the failure boundary reported.
                //
                //  2. It armed pendingResumeTicks as well, so the SAME resume
                //     position was seeked to twice: once here, and again from
                //     applyPendingResumeSeekIfNeeded — which compares against
                //     player.currentTime(), still 0 while the first seek is in
                //     flight, so the 3-second guard never suppressed it. On a
                //     Jellyfin HLS session every seek makes the server kill the
                //     running ffmpeg and restart it at the new offset, so two
                //     seeks a second apart produce precisely the captured
                //     start -> "Stopping ffmpeg with q command" -> start ->
                //     stop pattern.
                diag(.seek, [
                    PlayerDiagnostics.field("phase", "resume-armed"),
                    PlayerDiagnostics.field("targetSeconds", Double(startTicks) / 10_000_000),
                    PlayerDiagnostics.field("startTimeTicksSentToServer", false)
                ])
                if !isOffline {
                    await reportPlaybackStart(item: freshItem, positionTicks: startTicks)
                    startProgressReporting()
                }
                setupSegmentTracking()
                playbackStartDate = Date()
                logAndPlay(positionTicks: resumePositionTicks)
            } else {
                // No saved progress - start playing immediately
                resumePositionTicks = 0
                pendingResumeTicks = 0
                if !isOffline {
                    await reportPlaybackStart(item: freshItem, positionTicks: 0)
                    startProgressReporting()
                }
                setupSegmentTracking()
                playbackStartDate = Date()
                logAndPlay(positionTicks: resumePositionTicks)
            }
        } catch {
            diagFailure(.loadFailed, [PlayerDiagnostics.field("item", item.id)] + PlayerDiagnostics.fields(for: error))
            self.error = error
            self.errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Starts playback and records the position it starts from, so a stream
    /// that begins at 0:00 when it should have resumed is visible in the log
    /// rather than only in the server's `-ss` argument.
    private func logAndPlay(positionTicks: Int64) {
        diag(.play, [
            PlayerDiagnostics.field("resumeTargetSeconds", Double(positionTicks) / 10_000_000),
            PlayerDiagnostics.field("currentSeconds", player?.currentTime().seconds),
            PlayerDiagnostics.field("hasPlayer", player != nil),
            PlayerDiagnostics.field("timeControl", player.map { PlayerDiagnostics.name(timeControlStatus: $0.timeControlStatus) })
        ])
        player?.play()
        // Startup watchdog: a start that never begins playing posts NO
        // AVPlayerItemPlaybackStalled (that notification is for streams that
        // were playing and ran dry), so the stall-armed watchdog can't see
        // it. Observed live: a resume seek whose segment request hung
        // server-side (grid divergence) sat "waiting" forever with zero
        // notifications. Give a cold transcode start a generous window, then
        // treat a still-stuck start as recoverable.
        armStallWatchdog(grace: 15)
    }

    /// Replaces the position the item will resume to once it is ready.
    ///
    /// The iOS player uses this when a locally-saved offline position is newer
    /// than the server's. It must go through here rather than seeking the
    /// player directly: the resume seek is applied on `.readyToPlay`, so a
    /// direct seek issued before that is simply undone a moment later.
    func overrideResumePosition(ticks: Int64) {
        guard ticks > 0 else { return }
        resumePositionTicks = ticks
        pendingResumeTicks = ticks
        diag(.seek, [
            PlayerDiagnostics.field("phase", "resume-override"),
            PlayerDiagnostics.field("targetSeconds", Double(ticks) / 10_000_000)
        ])
    }

    private func startProgressReporting() {
        progressReportTask?.cancel()
        progressReportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                // Outside reportProgress on purpose: that early-returns for
                // offline playback, but the lock screen still needs updating
                // when watching a download.
                refreshNowPlayingProgress()
                await reportProgress()
            }
        }
    }

    private func reportPlaybackStart(item: BaseItemDto, positionTicks: Int64) async {
        await playbackReporter.start(
            itemID: item.id,
            positionTicks: positionTicks,
            playSessionID: playSessionId,
            playMethod: currentPlayMethod
        )
    }

    private func reportProgress() async {
        guard !isOfflinePlayback,
              let item = currentItem,
              let player,
              let currentTime = player.currentItem?.currentTime() else { return }

        let positionTicks = Int64(currentTime.seconds * 10_000_000)
        let isPaused = player.timeControlStatus == .paused
        await playbackReporter.progress(
            itemID: item.id,
            positionTicks: positionTicks,
            isPaused: isPaused,
            playSessionID: playSessionId
        )
    }

    /// Flushes the current in-memory position when the scene is about to be
    /// backgrounded. The reporter persists the event before attempting the
    /// request, so suspension or a transient network failure cannot discard it.
    func reportCurrentProgress() async {
        await reportProgress()
    }

    private func handlePlaybackEnded() async {
        // Guard against firing twice (e.g. a skip-to-end and the natural end
        // notification for the same item). Reset when the next item loads.
        if isHandlingEnd {
            diag(.playbackEnded, [PlayerDiagnostics.field("suppressed", true)])
            return
        }
        isHandlingEnd = true
        diag(.playbackEnded, [
            PlayerDiagnostics.field("item", currentItem?.id),
            PlayerDiagnostics.field("positionSeconds", player?.currentItem?.currentTime().seconds),
            PlayerDiagnostics.field("autoPlayNext", playbackSettings.autoPlayNextEpisode)
        ])

        progressReportTask?.cancel()

        if let item = currentItem, !isOfflinePlayback {
            // Stopped + mark-played form one durable completion event. The
            // delivery layer persists the phase between the two requests so a
            // retry never loses completion or repeats a successful first phase.
            let duration = player?.currentItem?.duration.seconds ?? 0
            let currentSeconds = player?.currentItem?.currentTime().seconds ?? 0
            let endSeconds = duration.isFinite && duration > 0 ? duration : currentSeconds
            await playbackReporter.completed(
                itemID: item.id,
                positionTicks: Int64(max(0.0, endSeconds) * 10_000_000),
                playSessionID: playSessionId
            )

            // Check for next episode/video if this is an episode or video
            if playbackSettings.autoPlayNextEpisode, let next = await fetchNextItem(for: item) {
                nextEpisode = next
                await playNextEpisode()
                return
            }
        }

        playbackEnded = true
    }

    private func fetchNextItem(for item: BaseItemDto) async -> BaseItemDto? {
        // Handle episodes (TV shows and YouTube content)
        if item.type == .episode, let seasonId = item.seasonId, let currentIndex = item.indexNumber {
            // First try exact match (index + 1) for regular TV shows
            if let next = await fetchNextByIndex(parentId: seasonId, currentIndex: currentIndex, type: .episode, exactMatch: true) {
                return next
            }
            // Fall back to next higher index for YouTube (date-based indexes like 20241108)
            if let next = await fetchNextByIndex(parentId: seasonId, currentIndex: currentIndex, type: .episode, exactMatch: false) {
                return next
            }
            // Season finale: roll over to the first episode of the next season.
            return await fetchFirstEpisodeOfNextSeason(for: item)
        }

        // Handle videos (explicit Video type)
        if item.type == .video {
            let parentId = item.seasonId ?? item.seriesId ?? item.parentId
            guard let parentId, let currentIndex = item.indexNumber else { return nil }
            return await fetchNextByIndex(parentId: parentId, currentIndex: currentIndex, type: .video, exactMatch: false)
        }

        return nil
    }

    /// After a season finale, find the first episode of the next season so
    /// auto-play rolls over across seasons (matches other Jellyfin clients).
    private func fetchFirstEpisodeOfNextSeason(for item: BaseItemDto) async -> BaseItemDto? {
        guard let seriesId = item.seriesId,
              let currentSeason = item.parentIndexNumber else { return nil }
        do {
            let seasons = try await client.getItems(
                parentId: seriesId,
                includeTypes: [.season],
                sortBy: "IndexNumber",
                limit: 100
            )
            guard let nextSeason = seasons.items.first(where: { ($0.indexNumber ?? 0) == currentSeason + 1 }) else {
                return nil
            }
            let episodes = try await client.getItems(
                parentId: nextSeason.id,
                includeTypes: [.episode],
                sortBy: "IndexNumber",
                limit: 100
            )
            // First real episode (index >= 1 skips "specials"/index 0)
            return episodes.items.first { ($0.indexNumber ?? 0) >= 1 } ?? episodes.items.first
        } catch {
            return nil
        }
    }

    private func fetchNextByIndex(parentId: String, currentIndex: Int, type: ItemType, exactMatch: Bool = true) async -> BaseItemDto? {
        do {
            let response = try await client.getItems(
                parentId: parentId,
                includeTypes: [type],
                sortBy: "IndexNumber",
                limit: 100
            )
            if exactMatch {
                // For TV episodes: look for exact next index (1, 2, 3...)
                return response.items.first { ($0.indexNumber ?? 0) == currentIndex + 1 }
            } else {
                // For YouTube: find first item with higher index (sorted ascending)
                return response.items.first { ($0.indexNumber ?? 0) > currentIndex }
            }
        } catch {
            return nil
        }
    }

    func playNextEpisode() async {
        guard let next = nextEpisode else { return }
        diag(.nextEpisode, [PlayerDiagnostics.field("item", next.id)])
        nextEpisode = nil
        playbackEnded = false
        await loadMedia(item: next)
    }

    func changeQuality(_ quality: QualityOption) async {
        guard let item = currentItem else { return }

        // Save current position
        let currentPosition = player?.currentItem?.currentTime()
        let positionTicks = currentPosition.map { Int64($0.seconds * 10_000_000) } ?? 0

        playbackAttempt += 1
        diag(.qualityChange, [
            PlayerDiagnostics.field("from", selectedQuality.rawValue),
            PlayerDiagnostics.field("to", quality.rawValue),
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("positionSeconds", currentPosition?.seconds)
        ])

        // Update quality setting
        selectedQuality = quality

        // Stop current playback
        diag(.teardown, [
            PlayerDiagnostics.field("reason", PlayerDiagnostics.TeardownReason.qualityChange.rawValue),
            PlayerDiagnostics.field("item", item.id)
        ])
        player?.pause()
        progressReportTask?.cancel()
        subtitleLoadTask?.cancel()
        cleanupSegmentTracking()
        subtitleManager.clear()
        // Reset the menu selection alongside the overlay — the re-apply
        // below sets it back when it finds a match in the new source, and
        // without this a failed match would leave the menu showing a track
        // that isn't rendering.
        selectedSubtitleTrackId = "off"

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        invalidatePlayerObservers()
        player = nil
        isLoading = true

        // Kill the old transcode session before requesting a new one, so the
        // server isn't left encoding a stream nobody is watching.
        await stopActiveEncodingIfNeeded(reason: .qualityChange)

        do {
            // An explicit non-Auto pick forces a transcode so the selection
            // visibly takes effect: the tiers are caps, and a direct-played
            // source under the cap would otherwise make the pick a no-op.
            try await setupPlayer(for: item, maxBitrate: quality.maxBitrate, maxWidth: quality.maxWidth, forceTranscode: quality != .auto)
            isLoading = false
            updateNowPlayingInfo(item: item)

            // Seek to saved position. A bare pre-ready seek is silently dropped
            // on HLS/transcode streams -- and forceTranscode above means any
            // non-Auto pick is ALWAYS that case -- so arm pendingResumeTicks
            // too and let the status observer re-apply it once the item is
            // ready. Without this the stream restarts at 0:00 and the 5s
            // progress report then overwrites the server's resume point with 0.
            if positionTicks > 0 {
                // Armed only — same reasoning as the resume path in loadMedia:
                // awaiting a pre-ready seek blocked startup, and issuing it here
                // as well as from the status observer meant two seeks (two
                // server-side transcode restarts) for one position change.
                pendingResumeTicks = positionTicks
                diag(.seek, [
                    PlayerDiagnostics.field("phase", "quality-change-armed"),
                    PlayerDiagnostics.field("targetSeconds", Double(positionTicks) / 10_000_000)
                ])
            }

            // Re-apply the session's subtitle selection on the rebuilt
            // player — the overlay was cleared along with the old player.
            // Match by content, not raw index: the new media source's stream
            // indexes may differ from the old one's. When there was no manual
            // pick this session, fall back to the Settings preference (which
            // is what selected the subtitles that were just cleared).
            if !applySessionSubtitlePreference() {
                applyPreferredSubtitles()
            }
            // Audio needs the same treatment: the rebuilt player starts on the
            // asset's default track, so without this a manual pick silently
            // reverted while the menu still showed it selected.
            if await !applySessionAudioPreference() {
                await applyPreferredAudioLanguage()
            }

            // Resume playback and tracking. Segments belong to the ITEM, but
            // cleanupSegmentTracking() cleared them with the player, and
            // fetchSegments is otherwise only called from loadMedia -- so
            // without this the observer runs against an empty array and skip
            // intro/credits stays dead for the rest of the episode.
            await fetchSegments(itemId: item.id)
            startProgressReporting()
            setupSegmentTracking()
            logAndPlay(positionTicks: positionTicks)
        } catch {
            diagFailure(.loadFailed, [
                PlayerDiagnostics.field("phase", "quality-change"),
                PlayerDiagnostics.field("item", item.id)
            ] + PlayerDiagnostics.fields(for: error))
            self.error = error
            self.errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Official-client error fallback (jellyfin-web's `onPlaybackError`):
    /// when the stream fails or stalls unrecoverably, rebuild playback at the
    /// current position forcing a transcode — a fresh session whose segments
    /// are produced from where the viewer actually is. The first attempt
    /// keeps video stream-copy allowed (a fresh remux session clears the
    /// jellyfin#16070 seek-freeze, whose broken state is per-session); the
    /// second disallows it (genuine re-encode — the last resort, and the
    /// escalation jellyfin-web uses). Two attempts per item, then the error
    /// surfaces normally.
    private func attemptPlaybackRecovery(reason: String) async {
        guard !isRecovering,
              !isOfflinePlayback,
              recoveryAttempts < 2,
              let item = currentItem else { return }
        isRecovering = true
        defer { isRecovering = false }
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil

        // Prefer the live position — but a playback that never actually got
        // going (stuck near zero while a resume point exists) recovers to the
        // RESUME point, not to the couple of seconds the wedged player
        // reports. Observed live: a hung resume seek left currentTime ≈ 2 s
        // while the viewer's real position was 30 minutes in.
        let liveSeconds = player?.currentTime().seconds ?? 0
        let liveTicks = (liveSeconds.isFinite && liveSeconds > 0) ? Int64(liveSeconds * 10_000_000) : 0
        let positionTicks = liveTicks > 100_000_000  // > 10 s: playback was really underway
            ? liveTicks
            : max(liveTicks, resumePositionTicks)

        playbackAttempt += 1
        diag(.loadBegin, [
            PlayerDiagnostics.field("phase", "recovery"),
            PlayerDiagnostics.field("recoveryAttempt", attempt),
            PlayerDiagnostics.field("trigger", reason),
            PlayerDiagnostics.field("allowVideoStreamCopy", attempt < 2),
            PlayerDiagnostics.field("positionSeconds", Double(positionTicks) / 10_000_000)
        ])

        // Clear the surfaced failure — the rebuild is the response to it.
        error = nil
        errorMessage = nil

        // Teardown mirrors changeQuality.
        diag(.teardown, [
            PlayerDiagnostics.field("reason", PlayerDiagnostics.TeardownReason.recovery.rawValue),
            PlayerDiagnostics.field("item", item.id)
        ])
        player?.pause()
        progressReportTask?.cancel()
        subtitleLoadTask?.cancel()
        cleanupSegmentTracking()
        subtitleManager.clear()
        selectedSubtitleTrackId = "off"
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        invalidatePlayerObservers()
        player = nil
        isLoading = true
        await stopActiveEncodingIfNeeded(reason: .recovery)

        do {
            try await setupPlayer(
                for: item,
                maxBitrate: selectedQuality.maxBitrate,
                maxWidth: selectedQuality.maxWidth,
                forceTranscode: true,
                allowVideoStreamCopy: attempt < 2
            )
            isLoading = false
            updateNowPlayingInfo(item: item)
            if positionTicks > 0 {
                pendingResumeTicks = positionTicks
            }
            if !applySessionSubtitlePreference() {
                applyPreferredSubtitles()
            }
            if await !applySessionAudioPreference() {
                await applyPreferredAudioLanguage()
            }
            await fetchSegments(itemId: item.id)
            startProgressReporting()
            setupSegmentTracking()
            logAndPlay(positionTicks: positionTicks)
        } catch {
            diagFailure(.loadFailed, [
                PlayerDiagnostics.field("phase", "recovery"),
                PlayerDiagnostics.field("recoveryAttempt", attempt),
                PlayerDiagnostics.field("item", item.id)
            ] + PlayerDiagnostics.fields(for: error))
            self.error = error
            self.errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Arms (or re-arms) the stall watchdog: if the player still isn't making
    /// progress `grace` seconds from now, treat it as the unrecoverable
    /// freeze and run recovery. Ordinary buffering resumes on its own well
    /// inside the grace window and cancels nothing — the watchdog just finds
    /// the position advanced (or playback running) and stands down.
    ///
    /// Recovery is launched in a DETACHED task: recovery's own teardown
    /// cancels `stallWatchdogTask`, and when the watchdog task itself invoked
    /// recovery that cancellation propagated into the in-flight rebuild's
    /// network awaits and aborted it mid-recovery.
    private func armStallWatchdog(grace: Double = 8) {
        stallWatchdogTask?.cancel()
        let stalledAt = player?.currentTime().seconds ?? 0
        stallWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled, let self else { return }
            guard let player = self.player,
                  player.timeControlStatus != .playing else { return }
            let now = player.currentTime().seconds
            guard now.isFinite, abs(now - stalledAt) < 0.5 else { return }
            self.stallWatchdogTask = nil
            Task { await self.attemptPlaybackRecovery(reason: "stall-watchdog") }
        }
    }

    /// Applies the saved resume position once the item can actually seek.
    ///
    /// This is now the ONLY place a resume position is applied. It runs from
    /// the `.readyToPlay` transition, which is the first moment the item has a
    /// seekable range at all — a seek issued before that is either dropped
    /// (HLS/transcode) or deferred, and in both cases it duplicated this one.
    /// `pendingResumeTicks` is cleared before seeking so a repeated
    /// `.readyToPlay` cannot issue a second seek.
    private func applyPendingResumeSeekIfNeeded() {
        guard pendingResumeTicks > 0, let player else { return }
        let target = CMTime(value: pendingResumeTicks / 10000, timescale: 1000)
        pendingResumeTicks = 0
        let drift = abs(player.currentTime().seconds - target.seconds)
        diag(.seek, [
            PlayerDiagnostics.field("phase", "post-ready-resume"),
            PlayerDiagnostics.field("targetSeconds", target.seconds),
            PlayerDiagnostics.field("driftSeconds", drift),
            PlayerDiagnostics.field("applied", drift > 3)
        ])
        if drift > 3 {
            player.seek(to: target)
            // The resume seek is the observed hang case: the segment request
            // for the target can wedge server-side (grid divergence) with no
            // notification ever posted. Watchdog it like a fresh start.
            armStallWatchdog(grace: 15)
        }
    }

    /// Maps a container item (Series/Season) to the episode that should play:
    /// server next-up first, then first unwatched episode, then first episode
    /// (fully-watched series). Playable items pass through untouched. Throws
    /// rather than letting a non-playable id reach PlaybackInfo, so the
    /// failure is a visible "couldn't find an episode" instead of a silent
    /// server 500 mid-startup.
    func resolvePlayableItem(_ item: BaseItemDto) async throws -> BaseItemDto {
        guard let type = item.type, !type.isPlayableMediaType else {
            diag(.loadResolved, [
                PlayerDiagnostics.field("resolved", false),
                PlayerDiagnostics.field("item", item.id),
                PlayerDiagnostics.field("type", item.type?.rawValue)
            ])
            return item
        }

        if type == .series, let next = try? await client.getNextUp(seriesId: item.id, limit: 1).first {
            logResolution(from: item, to: next, via: "next-up")
            return next
        }

        if type == .series || type == .season {
            // For a series this searches all episodes (getItems is recursive);
            // for a season, just that season's.
            if let unwatched = try? await client.getItems(
                parentId: item.id,
                includeTypes: [.episode],
                sortBy: "ParentIndexNumber,IndexNumber",
                limit: 1,
                isPlayed: false
            ).items.first {
                logResolution(from: item, to: unwatched, via: "first-unwatched")
                return unwatched
            }
            if let first = try? await client.getItems(
                parentId: item.id,
                includeTypes: [.episode],
                sortBy: "ParentIndexNumber,IndexNumber",
                limit: 1
            ).items.first {
                logResolution(from: item, to: first, via: "first-episode")
                return first
            }
        }

        logger.error("Could not resolve \(type.rawValue, privacy: .public) \(item.id, privacy: .public) to a playable episode")
        diagFailure(.loadResolved, [
            PlayerDiagnostics.field("resolved", false),
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("type", type.rawValue),
            PlayerDiagnostics.field("outcome", "no-playable-episode")
        ])
        throw PlayerError.noPlayableEpisode(item.name)
    }

    private func logResolution(from container: BaseItemDto, to episode: BaseItemDto, via: String) {
        diag(.loadResolved, [
            PlayerDiagnostics.field("resolved", true),
            PlayerDiagnostics.field("fromType", container.type?.rawValue),
            PlayerDiagnostics.field("fromItem", container.id),
            PlayerDiagnostics.field("toItem", episode.id),
            PlayerDiagnostics.field("toType", episode.type?.rawValue),
            PlayerDiagnostics.field("via", via)
        ])
    }

    /// Shared player setup: resolves stream URL, creates AVPlayer with observers.
    /// `allowVideoStreamCopy` is only ever false on the second recovery
    /// attempt (see attemptPlaybackRecovery) — the normal path always permits
    /// the server to copy the video stream untouched.
    private func setupPlayer(for item: BaseItemDto, maxBitrate: Int? = nil, maxWidth: Int? = nil, forceTranscode: Bool = false, allowVideoStreamCopy: Bool = true) async throws {
        // Bitrate precedence: explicit override (quality menu change) →
        // session quality selection → global Settings cap. QualityOption.auto
        // has a nil bitrate, so "Auto" defers to Settings, where 0 = no cap.
        let effectiveBitrate = PlaybackSelection.effectiveMaxBitrate(
            sessionOverride: maxBitrate ?? selectedQuality.maxBitrate,
            settingsMaxBitrate: playbackSettings.maxBitrate
        )

        // The cap in force, and whether it came from a real measurement or a
        // default (the #341/#342 Auto-cap work). An unexplained transcode is
        // almost always this value, and it was previously only visible in the
        // JellyfinClient log, disconnected from the play attempt it belonged to.
        let bandwidth = await client.bandwidthStatus
        diag(.playbackInfoRequest, [
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("itemType", item.type?.rawValue),
            PlayerDiagnostics.field("requestedBitrate", effectiveBitrate),
            PlayerDiagnostics.field("effectiveCap", effectiveBitrate ?? bandwidth.cap),
            PlayerDiagnostics.field("capSource", effectiveBitrate != nil ? "explicit" : (bandwidth.isMeasured ? "measured" : "default")),
            PlayerDiagnostics.field("measuredBitrate", bandwidth.measuredBitrate),
            PlayerDiagnostics.field("localServer", bandwidth.isLocalServer),
            PlayerDiagnostics.field("maxWidth", maxWidth),
            PlayerDiagnostics.field("forceTranscode", forceTranscode),
            PlayerDiagnostics.field("forceDirectPlay", playbackSettings.forceDirectPlay),
            // Video stream-copy is normally allowed (see getPlaybackInfo): the
            // Apple TV decodes the source codec natively, so the server remuxes
            // + copies rather than re-encodes. False only on the second
            // recovery attempt — the stream-copy HLS seek-freeze
            // (jellyfin#16070, #4188) is handled by the error/stall recovery
            // fallback (attemptPlaybackRecovery), the official-client pattern.
            PlayerDiagnostics.field("allowVideoStreamCopy", allowVideoStreamCopy)
        ])

        // Phase 1 of the VLC work: the profile can be VLC-shaped for
        // observation, but the player below is still AVPlayer either way.
        let engine: PlaybackEngineKind = playbackSettings.debugVLCDeviceProfile ? .vlc : .avFoundation

        var playbackInfo = try await client.getPlaybackInfo(
            itemId: item.id,
            itemType: item.type,
            engine: engine,
            maxBitrate: effectiveBitrate,
            maxWidth: maxWidth,
            forceDirectPlay: playbackSettings.forceDirectPlay,
            forceTranscode: forceTranscode,
            allowVideoStreamCopy: allowVideoStreamCopy
        )

        // Source-aware retry (Auto path only). The source bitrate is only known
        // from the response, so it takes a second pass: if the link cannot carry
        // this source the server returns a transcode, and left alone that is a
        // heavy, stutter/OOM-prone full-4K re-encode riding the link ceiling
        // (a ~72 Mbps Wi-Fi link vs a 68.8 Mbps 4K remux). Re-request a light
        // 1080p the link comfortably holds. A copyable source never reaches here
        // (no transcodingUrl, or cap >= source), so a wired/fast client keeps
        // native 4K; explicit quality picks and forceTranscode are untouched.
        if effectiveBitrate == nil, maxWidth == nil, !forceTranscode,
           let source = playbackInfo.mediaSources?.first,
           source.transcodingUrl?.isEmpty == false,
           let override = PlaybackSelection.constrainedAutoOverride(cap: bandwidth.cap, sourceBitrate: source.bitrate, isWired: bandwidth.isWired) {
            diag(.playbackInfoRequest, [
                PlayerDiagnostics.field("phase", "constrained-retry"),
                PlayerDiagnostics.field("sourceBitrate", source.bitrate),
                PlayerDiagnostics.field("cap", bandwidth.cap),
                PlayerDiagnostics.field("isWired", bandwidth.isWired),
                PlayerDiagnostics.field("retryWidth", override.maxWidth),
                PlayerDiagnostics.field("retryBitrate", override.maxBitrate)
            ])
            playbackInfo = try await client.getPlaybackInfo(
                itemId: item.id,
                itemType: item.type,
                engine: engine,
                maxBitrate: override.maxBitrate,
                maxWidth: override.maxWidth,
                forceDirectPlay: playbackSettings.forceDirectPlay,
                forceTranscode: forceTranscode,
                allowVideoStreamCopy: allowVideoStreamCopy
            )
        }

        guard let mediaSource = playbackInfo.mediaSources?.first else {
            diagFailure(.playbackInfoResponse, [
                PlayerDiagnostics.field("item", item.id),
                PlayerDiagnostics.field("outcome", "no-media-source"),
                PlayerDiagnostics.field("sourceCount", playbackInfo.mediaSources?.count ?? 0)
            ])
            throw PlayerError.noMediaSource
        }

        diag(.playbackInfoResponse, [
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("mediaSource", mediaSource.id),
            PlayerDiagnostics.field("playSession", playbackInfo.playSessionId),
            PlayerDiagnostics.field("container", mediaSource.container),
            PlayerDiagnostics.field("supportsDirectPlay", mediaSource.supportsDirectPlay),
            PlayerDiagnostics.field("supportsDirectStream", mediaSource.supportsDirectStream),
            PlayerDiagnostics.field("supportsTranscoding", mediaSource.supportsTranscoding),
            PlayerDiagnostics.field("hasTranscodingUrl", mediaSource.transcodingUrl?.isEmpty == false),
            PlayerDiagnostics.field("hasDirectStreamUrl", mediaSource.directStreamUrl?.isEmpty == false),
            PlayerDiagnostics.field("videoCodec", mediaSource.videoCodec),
            PlayerDiagnostics.field("audioCodec", mediaSource.audioCodec),
            PlayerDiagnostics.field("sourceBitrate", mediaSource.bitrate),
            PlayerDiagnostics.field("resolution", mediaSource.videoResolution),
            PlayerDiagnostics.field("transcodeReasons", mediaSource.transcodeReasons?.joined(separator: ",") ?? "none")
        ])

        playSessionId = playbackInfo.playSessionId
        currentMediaSource = mediaSource
        videoResolution = mediaSource.videoResolution
        streamInfo = nil   // stale for the new session; refreshed when the overlay opens

        let resolvedURL: URL?
        let streamKind: PlayerDiagnostics.StreamKind
        if let transcodingPath = mediaSource.transcodingUrl, !transcodingPath.isEmpty {
            streamKind = .transcodeHLS
            resolvedURL = await client.buildURL(path: transcodingPath)
        } else if let directPath = mediaSource.directStreamUrl, !directPath.isEmpty {
            streamKind = .directStream
            resolvedURL = await client.buildURL(path: directPath)
        } else if mediaSource.supportsDirectPlay != false {
            streamKind = .directPlayStatic
            resolvedURL = await client.getPlaybackURL(itemId: item.id, mediaSourceId: mediaSource.id, container: mediaSource.container)
        } else {
            // The server offered no transcode/remux URL AND says the source
            // can't direct play (e.g. Force Direct Play against a container
            // this device can't decode). The old behavior built a static
            // stream URL anyway — a stream that bypasses the device profile,
            // which is what forces fMP4 for HEVC — and handed AVPlayer a file
            // it can't render: audio over a black screen instead of an error.
            // Fail loudly instead.
            logger.error("Media source \(mediaSource.id, privacy: .public) is not playable: no stream URLs and SupportsDirectPlay=false")
            diagFailure(.streamSelected, [
                PlayerDiagnostics.field("mediaSource", mediaSource.id),
                PlayerDiagnostics.field("outcome", "source-not-playable")
            ])
            throw PlayerError.sourceNotPlayable
        }

        guard let resolvedURL else {
            diagFailure(.streamSelected, [
                PlayerDiagnostics.field("kind", streamKind.rawValue),
                PlayerDiagnostics.field("outcome", "no-stream-url")
            ])
            throw PlayerError.noStreamURL
        }

        // Which URL AVPlayer is actually being pointed at. `describe(url:)`
        // keeps the path and drops the query — the query is where api_key lives.
        // `avplayerPlayableContainer` is a pure observation (nothing branches on
        // it): AVPlayer has no Matroska demuxer, so a direct-stream URL ending
        // in .mkv is a stream it cannot render, and that should be visible here
        // rather than inferred from a black screen.
        let container = resolvedURL.pathExtension.lowercased()
        diag(.streamSelected, [
            PlayerDiagnostics.field("kind", streamKind.rawValue),
            PlayerDiagnostics.field("mediaSource", mediaSource.id),
            PlayerDiagnostics.field("playSession", playSessionId),
            PlayerDiagnostics.field(
                "avplayerPlayableContainer",
                container.isEmpty || container == "m3u8" || DeviceMediaCompatibility.directPlayContainers.contains(container)
            ),
            PlayerDiagnostics.describe(url: resolvedURL)
        ])

        // NOTE: the full URL deliberately goes no further than AVURLAsset. It
        // used to be retained in a published `attemptedURL` property that
        // nothing ever read — a credential (`api_key`) parked in view-model
        // state, one `Text(...)` away from being on screen.
        let asset = AVURLAsset(url: resolvedURL)
        diag(.assetCreated, [
            PlayerDiagnostics.field("kind", streamKind.rawValue),
            PlayerDiagnostics.field("chapters", item.chapters?.count ?? 0)
        ])
        let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable", "duration"])

        if let chapters = item.chapters, !chapters.isEmpty,
           let runTimeTicks = item.runTimeTicks {
            let duration = Double(runTimeTicks) / 10_000_000.0
            setupChapterMarkers(on: playerItem, chapters: chapters, duration: duration)
        }

        makePlayerAndObservers(for: playerItem)
    }

    /// Builds the AVPlayer and wires every observer it needs.
    ///
    /// Factored out because offline playback builds its own AVPlayer and used
    /// to skip all of this: downloaded episodes never fired
    /// AVPlayerItemDidPlayToEndTime (so they never dismissed and auto-play-next
    /// was dead for downloads), and a corrupt download sat on a black screen
    /// with no error because nothing observed .failed.
    private func makePlayerAndObservers(for playerItem: AVPlayerItem) {
        isPlayerReady = false
        tracksVersion &+= 1
        errorObserver = playerItem.observe(\.status) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self else { return }
                // EVERY transition, not just the interesting ones: an item that
                // never leaves .unknown is a different failure from one that
                // reaches .failed, and the two are indistinguishable to a viewer
                // (both are a black screen).
                self.diag(.itemStatus, [
                    PlayerDiagnostics.field("status", PlayerDiagnostics.name(itemStatus: observed.status))
                ] + (observed.status == .failed ? PlayerDiagnostics.fields(for: observed.error) : []))

                if observed.status == .failed {
                    self.isPlayerReady = false
                    self.diagFailure(.itemStatus, [
                        PlayerDiagnostics.field("status", "failed")
                    ] + PlayerDiagnostics.fields(for: observed.error))
                    // Recovery first (official-client pattern): rebuild at the
                    // current position forcing a transcode. The error only
                    // surfaces once recovery is exhausted.
                    if self.canAttemptRecovery {
                        await self.attemptPlaybackRecovery(reason: "item-failed")
                    } else {
                        self.errorMessage = observed.error?.localizedDescription ?? "Unknown playback error"
                        self.error = observed.error
                    }
                } else if observed.status == .readyToPlay {
                    self.isPlayerReady = true
                    self.logTrackAvailability(for: observed)
                    self.applyPendingResumeSeekIfNeeded()
                }
            }
        }

        observeItemLogs(for: playerItem)

        player = AVPlayer(playerItem: playerItem)
        player?.appliesMediaSelectionCriteriaAutomatically = false
        player?.volume = 1.0
        player?.isMuted = false
        diag(.playerCreated, [
            PlayerDiagnostics.field("tracksVersion", tracksVersion)
        ])

        statusObserver = player?.observe(\.status) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self else { return }
                self.diag(.playerStatus, [
                    PlayerDiagnostics.field("status", PlayerDiagnostics.name(playerStatus: observed.status))
                ])
                if observed.status == .failed {
                    self.diagFailure(.playerStatus, [
                        PlayerDiagnostics.field("status", "failed")
                    ] + PlayerDiagnostics.fields(for: observed.error))
                    self.errorMessage = observed.error?.localizedDescription ?? "Player failed"
                    self.error = observed.error
                }
            }
        }

        rateObserver = player?.observe(\.timeControlStatus) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self else { return }
                // "waiting" for a long stretch after play() IS the stall the
                // viewer describes as a freeze; the reason says whether it is
                // buffering or waiting on a minimum stall-free duration.
                self.diag(.timeControl, [
                    PlayerDiagnostics.field("status", PlayerDiagnostics.name(timeControlStatus: observed.timeControlStatus)),
                    PlayerDiagnostics.field("reason", observed.reasonForWaitingToPlay?.rawValue),
                    PlayerDiagnostics.field("positionSeconds", observed.currentTime().seconds)
                ])
                self.refreshNowPlayingProgress()
                await self.reportProgress()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handlePlaybackEnded()
            }
        }
    }

    /// Subscribes to the AVPlayerItem notifications that explain stalls,
    /// audio-only playback and seek failures.
    ///
    /// None of this reaches `AVPlayerItem.status`: an item can stall forever,
    /// drop every video frame, or fail an individual segment fetch while its
    /// status stays `.readyToPlay`. Until now the app observed only `status`,
    /// which is why a failed play could only be described as "it just sat
    /// there" and had to be reconstructed from the server's ffmpeg log.
    private func observeItemLogs(for playerItem: AVPlayerItem) {
        removeItemLogObservers()
        let center = NotificationCenter.default

        itemErrorLogObserver = center.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem,
                  let event = item.errorLog()?.events.last else { return }
            Task { @MainActor in
                self?.diagFailure(.errorLog, PlayerDiagnostics.summarize(errorEvent: event))
            }
        }

        itemAccessLogObserver = center.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem,
                  let event = item.accessLog()?.events.last else { return }
            Task { @MainActor in
                guard let self else { return }
                // Access-log entries arrive on every rendition switch and
                // periodically during playback, so the raw sample is .debug.
                self.diagDetail(.accessLog, PlayerDiagnostics.summarize(accessEvent: event))
                // A stall is the exception: promote it, because "numberOfStalls
                // climbing" is the difference between "the link can't carry
                // this" and "the stream itself is broken".
                if event.numberOfStalls > self.lastReportedStallCount {
                    self.lastReportedStallCount = event.numberOfStalls
                    self.diag(.accessLog, [
                        PlayerDiagnostics.field("stallDetected", true)
                    ] + PlayerDiagnostics.summarize(accessEvent: event))
                }
            }
        }

        // Seeks made through the tvOS transport bar never pass through this
        // view model — AVPlayerViewController drives AVPlayer directly. This
        // notification is the only way to see them, and seeking is the
        // reproducer for the 4K stream-copy failure.
        stallObservers.append(center.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                self?.logSeekLanding(on: item, cause: "time-jumped")
            }
        })

        stallObservers.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                self?.logSeekLanding(on: item, cause: "playback-stalled")
                // A stall that never recovers is the seek-freeze; give normal
                // buffering a grace window, then rebuild at position.
                self?.armStallWatchdog()
            }
        })

        stallObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self else { return }
                self.diagFailure(.itemStatus, [
                    PlayerDiagnostics.field("event", "failed-to-play-to-end")
                ] + PlayerDiagnostics.fields(for: error))
                if self.canAttemptRecovery {
                    await self.attemptPlaybackRecovery(reason: "failed-to-play-to-end")
                }
            }
        })
    }

    private func removeItemLogObservers() {
        let center = NotificationCenter.default
        if let itemErrorLogObserver {
            center.removeObserver(itemErrorLogObserver)
            self.itemErrorLogObserver = nil
        }
        if let itemAccessLogObserver {
            center.removeObserver(itemAccessLogObserver)
            self.itemAccessLogObserver = nil
        }
        for observer in stallObservers {
            center.removeObserver(observer)
        }
        stallObservers.removeAll()
        lastReportedStallCount = 0
    }

    /// Where a seek (or stall) actually landed, relative to what the stream can
    /// serve.
    ///
    /// `seekable` is the range Jellyfin's playlist claims; `loaded` is what
    /// AVPlayer actually holds. A position inside `seekable` but outside
    /// `loaded`, with playback not advancing, is a seek into a segment the
    /// server has not produced — the question the server log cannot answer.
    private func logSeekLanding(on item: AVPlayerItem, cause: String) {
        let position = item.currentTime().seconds
        let seekable = item.seekableTimeRanges.first?.timeRangeValue
        let loaded = item.loadedTimeRanges.first?.timeRangeValue
        diag(.seek, [
            PlayerDiagnostics.field("cause", cause),
            PlayerDiagnostics.field("positionSeconds", position),
            PlayerDiagnostics.field("seekableStart", seekable?.start.seconds),
            PlayerDiagnostics.field("seekableEnd", seekable.map { ($0.start + $0.duration).seconds }),
            PlayerDiagnostics.field("loadedStart", loaded?.start.seconds),
            PlayerDiagnostics.field("loadedEnd", loaded.map { ($0.start + $0.duration).seconds }),
            PlayerDiagnostics.field("likelyToKeepUp", item.isPlaybackLikelyToKeepUp),
            PlayerDiagnostics.field("bufferEmpty", item.isPlaybackBufferEmpty)
        ] + PlayerDiagnostics.trackSummary(for: item).fields)
    }

    /// How many video and audio tracks AVPlayer ended up with, and how many it
    /// enabled. Zero enabled video tracks alongside enabled audio IS the
    /// "audio plays, picture is frozen" report, stated rather than inferred.
    private func logTrackAvailability(for item: AVPlayerItem) {
        diag(.tracks, PlayerDiagnostics.trackSummary(for: item).fields + [
            PlayerDiagnostics.field("durationSeconds", item.duration.seconds)
        ])
    }

    /// Invalidates the KVO observations tied to the current player/item.
    /// Must run before the player is dropped or replaced so no observation
    /// outlives the object it watches.
    private func invalidatePlayerObservers() {
        statusObserver?.invalidate()
        statusObserver = nil
        errorObserver?.invalidate()
        errorObserver = nil
        rateObserver?.invalidate()
        rateObserver = nil
        removeItemLogObservers()
        // A watchdog armed for this player must not fire into whatever
        // replaces it. (Recovery re-arms its own if the new stream stalls.)
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
    }

    func stop(reason: PlayerDiagnostics.TeardownReason = .unspecified) async {
        preparePendingStoppedReportIfNeeded()
        if let teardownTask {
            await teardownTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStop(reason: reason)
        }
        teardownTask = task
        await task.value
        teardownTask = nil
    }

    private func performStop(reason: PlayerDiagnostics.TeardownReason) async {
        diag(.teardown, [
            PlayerDiagnostics.field("reason", reason.rawValue),
            PlayerDiagnostics.field("item", currentItem?.id),
            PlayerDiagnostics.field("playSession", playSessionId),
            PlayerDiagnostics.field("positionSeconds", player?.currentItem?.currentTime().seconds),
            PlayerDiagnostics.field("hadPlayer", player != nil)
        ])
        progressReportTask?.cancel()
        subtitleLoadTask?.cancel()
        cleanupSegmentTracking()
        subtitleManager.clear()
        // The session is over — the persisted playbackSettings carry the
        // subtitle preference into the next one.
        sessionSubtitlePreference = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        if let item = currentItem,
           let player,
           let currentTime = player.currentItem?.currentTime() {
            // Check if playback was too short (< 10 seconds)
            // If so, preserve the original resume position to prevent progress reset
            let elapsedSeconds = playbackStartDate.map { Date().timeIntervalSince($0) } ?? 0
            var positionTicks: Int64
            if elapsedSeconds < 10 && resumePositionTicks > 0 {
                // Quick exit - preserve original progress
                positionTicks = resumePositionTicks
            } else {
                // Normal exit - report current position
                positionTicks = Int64(currentTime.seconds * 10_000_000)
            }

            if !isOfflinePlayback {
                await playbackReporter.stopped(
                    itemID: item.id,
                    positionTicks: positionTicks,
                    playSessionID: playSessionId
                )
            }
        }

        // Kill the session's server-side transcode, if one was active.
        await stopActiveEncodingIfNeeded(reason: reason)
        playSessionId = nil

        player?.pause()
        invalidatePlayerObservers()
        player = nil
        isPlayerReady = false
        currentItem = nil
        playbackStartDate = nil

        // Notify that playback ended so Home can refresh
        NotificationCenter.default.post(name: .playbackDidEnd, object: nil)
    }

    /// Called synchronously from disappearance/background callbacks before
    /// SwiftUI schedules the awaited teardown task. The report is persisted by
    /// PlaybackSessionReporter before any network await, so process suspension
    /// cannot lose the final position merely because the view is gone.
    func preparePendingStoppedReportIfNeeded() {
        guard let item = currentItem,
              let player,
              let currentTime = player.currentItem?.currentTime(),
              !isOfflinePlayback else { return }

        let elapsedSeconds = playbackStartDate.map { Date().timeIntervalSince($0) } ?? 0
        let positionTicks: Int64
        if elapsedSeconds < 10, resumePositionTicks > 0 {
            positionTicks = resumePositionTicks
        } else {
            positionTicks = Int64(currentTime.seconds * 10_000_000)
        }
        playbackReporter.prepareStopped(
            itemID: item.id,
            positionTicks: positionTicks,
            playSessionID: playSessionId
        )
    }

    func loadAudioTracks() {
        guard let playerItem = player?.currentItem else { return }

        guard let audioGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            audioTracks = []
            return
        }

        let options = audioGroup.options
        var tracks: [AudioTrackOption] = []
        for (index, option) in options.enumerated() {
            let locale = option.locale
            let displayName = option.displayName
            let langCode = locale?.language.languageCode?.identifier

            tracks.append(AudioTrackOption(
                id: "\(index)",
                displayName: displayName,
                languageCode: langCode,
                index: index
            ))
        }

        audioTracks = tracks

        if let currentSelection = playerItem.currentMediaSelection.selectedMediaOption(in: audioGroup),
           let currentIndex = options.firstIndex(of: currentSelection) {
            selectedAudioTrackId = "\(currentIndex)"
        }
    }

    func selectAudioTrack(_ track: AudioTrackOption) {
        guard let playerItem = player?.currentItem,
              let audioGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
              track.index < audioGroup.options.count else { return }

        let option = audioGroup.options[track.index]
        playerItem.select(option, in: audioGroup)
        selectedAudioTrackId = track.id
        sessionAudioPreference = AudioPreference(
            language: track.languageCode,
            displayName: track.displayName
        )
    }

    /// Re-applies the session's audio pick to a rebuilt player or a new episode.
    /// Returns false when there is no pick or nothing matches, so the caller can
    /// fall back to the Settings preference.
    @discardableResult
    private func applySessionAudioPreference() async -> Bool {
        guard let preference = sessionAudioPreference,
              let playerItem = player?.currentItem,
              let audioGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible)
        else { return false }

        // Prefer an exact display-name match, then fall back to language: the
        // same tiering the subtitle path uses, so "Japanese [5.1]" still
        // resolves to "Japanese" on a source that labels it differently.
        let byName = audioGroup.options.firstIndex { $0.displayName == preference.displayName }
        let byLanguage = preference.language.flatMap { language in
            audioGroup.options.firstIndex { $0.locale?.language.languageCode?.identifier == language }
        }
        guard let index = byName ?? byLanguage else { return false }

        playerItem.select(audioGroup.options[index], in: audioGroup)
        selectedAudioTrackId = "\(index)"
        return true
    }

    // MARK: - Settings-based track preferences

    /// Applies the Settings-preferred audio/subtitle languages when playback
    /// starts. Selections made later in the player UI naturally override
    /// these because they happen afterwards.
    private func applyPreferredTracks() async {
        // A pick made in the player this session beats the Settings default,
        // mirroring how subtitles behave just below.
        if await !applySessionAudioPreference() {
            await applyPreferredAudioLanguage()
        }
        // The session's subtitle intent (a selection made in the player,
        // e.g. during the previous episode) wins over the Settings-based
        // preference — subtitles stay on until manually turned off.
        if !applySessionSubtitlePreference() {
            applyPreferredSubtitles()
        }
    }

    /// Re-applies the session's subtitle intent against the current media
    /// source. Returns false when there is no intent or no matching stream,
    /// so callers can fall back to the Settings-based preference.
    @discardableResult
    private func applySessionSubtitlePreference() -> Bool {
        guard let preference = sessionSubtitlePreference,
              let stream = PlaybackSelection.matchingSubtitleStream(
                in: currentMediaSource?.subtitleStreams ?? [],
                language: preference.language,
                displayTitle: preference.displayTitle,
                isExternal: preference.isExternal
              ) else { return false }

        selectSubtitleTrack(Self.subtitleTrackOption(for: stream), isUserSelection: false)
        return true
    }

    private func applyPreferredAudioLanguage() async {
        let preferred = playbackSettings.preferredAudioLanguage
        guard !preferred.isEmpty, let playerItem = player?.currentItem else { return }

        // appliesMediaSelectionCriteriaAutomatically is false, so the default
        // track plays unless we pick one explicitly.
        guard let audioGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible) else { return }

        let codes = audioGroup.options.map { $0.locale?.language.languageCode?.identifier }
        if let index = PlaybackSelection.preferredAudioOptionIndex(languageCodes: codes, preferredLanguage: preferred) {
            playerItem.select(audioGroup.options[index], in: audioGroup)
            selectedAudioTrackId = "\(index)"
        }
    }

    private func applyPreferredSubtitles() {
        guard let mediaSource = currentMediaSource,
              let stream = PlaybackSelection.preferredSubtitleStream(
                from: mediaSource.subtitleStreams,
                preferredLanguage: playbackSettings.preferredSubtitleLanguage,
                subtitlesEnabled: playbackSettings.subtitlesEnabled
              ) else { return }

        selectSubtitleTrack(Self.subtitleTrackOption(for: stream), isUserSelection: false)
    }

    /// Builds a menu option for a Jellyfin subtitle stream using the same
    /// id/display scheme as loadSubtitleTracks(), so selections made through
    /// any path stay consistent with the subtitle menu.
    private static func subtitleTrackOption(for stream: MediaStream) -> SubtitleTrackOption {
        SubtitleTrackOption(
            id: "\(stream.index ?? 0)",
            displayName: stream.displayTitle ?? stream.language ?? "Unknown",
            languageCode: stream.language,
            index: stream.index ?? 0,
            isOffOption: false,
            isExternal: stream.isExternal ?? false
        )
    }

    func loadSubtitleTracks() {
        var tracks: [SubtitleTrackOption] = []

        // Add "Off" option first
        tracks.append(SubtitleTrackOption(
            id: "off",
            displayName: "Off",
            languageCode: nil,
            index: -1,
            isOffOption: true
        ))

        // Offline playback has no media source, so the downloaded files are the
        // only thing that can populate this menu.
        if isOfflinePlayback {
            for subtitle in offlineSubtitles {
                tracks.append(SubtitleTrackOption(
                    id: "\(subtitle.index)",
                    displayName: subtitle.displayTitle,
                    languageCode: subtitle.language,
                    index: subtitle.index,
                    isOffOption: false,
                    isExternal: true
                ))
            }
        } else if let mediaSource = currentMediaSource {
            let subtitleStreams = mediaSource.subtitleStreams
            for stream in subtitleStreams {
                let displayName = stream.displayTitle ?? stream.language ?? "Unknown"
                tracks.append(SubtitleTrackOption(
                    id: "\(stream.index ?? 0)",
                    displayName: displayName,
                    languageCode: stream.language,
                    index: stream.index ?? 0,
                    isOffOption: false,
                    isExternal: stream.isExternal ?? false
                ))
            }
        }

        subtitleTracks = tracks
        // Keep a still-valid selection (e.g. the Settings-based pre-selection
        // applied when playback started) — this runs from the player UI's
        // onAppear and used to unconditionally reset the menu to "Off" even
        // while subtitles were showing.
        if !tracks.contains(where: { $0.id == selectedSubtitleTrackId }) {
            selectedSubtitleTrackId = "off"
        }
    }

    /// Selects a subtitle track. `isUserSelection` distinguishes a manual
    /// pick in the player UI (persisted as the user's preference) from the
    /// automatic re-application paths (Settings preference, quality change,
    /// next episode), which must not overwrite the stored preference.
    func selectSubtitleTrack(_ track: SubtitleTrackOption, isUserSelection: Bool = true) {
        // A newer selection supersedes any in-flight subtitle load — racing
        // loads used to call startTracking against a stale player.
        subtitleLoadTask?.cancel()

        if track.isOffOption {
            if isUserSelection {
                // Manual "Off" — same persistence semantics as the views
                // that call disableSubtitles() directly.
                disableSubtitles()
            } else {
                selectedSubtitleTrackId = "off"
                subtitleManager.clear()
            }
            return
        }

        selectedSubtitleTrackId = track.id

        if isUserSelection {
            // Remember the session's subtitle intent by content so it
            // survives quality changes and episode transitions (stream
            // indexes don't). Only manual picks may write this — automatic
            // re-applies can resolve via a weaker fallback tier (e.g.
            // embedded "English" for an external "English (SDH)" pick), and
            // storing that match would permanently degrade the intent.
            sessionSubtitlePreference = SubtitlePreference(
                language: track.languageCode,
                displayTitle: track.displayName,
                isExternal: track.isExternal
            )
            // "On stays on until I turn it off" — persist the manual choice
            // across app launches too.
            playbackSettings.subtitlesEnabled = true
            if let language = track.languageCode, !language.isEmpty {
                playbackSettings.preferredSubtitleLanguage = language
            }
        }

        guard let item = currentItem, let player = player else { return }

        // Load and display subtitles via our custom overlay. Capture the
        // player at creation: by the time the load finishes the player
        // may have been rebuilt (quality change / next episode), and
        // tracking a stale player would leave a live observer on it.
        let capturedPlayer = player
        subtitleLoadTask = Task {
            if isOfflinePlayback,
               let downloaded = offlineSubtitles.first(where: { $0.index == track.index }) {
                await subtitleManager.loadSubtitles(fileURL: downloaded.fileURL)
            } else {
                await subtitleManager.loadSubtitles(
                    itemId: item.id,
                    subtitleIndex: track.index,
                    serverID: serverID
                )
            }
            guard !Task.isCancelled, self.player === capturedPlayer else { return }
            subtitleManager.startTracking(player: capturedPlayer)
        }
    }

    /// Turns subtitles off through the same path as selecting the "Off" track
    /// option: sets the "off" sentinel AND clears the subtitle overlay. Views
    /// must use this instead of mutating `selectedSubtitleTrackId` directly,
    /// which would leave the current subtitles on screen.
    ///
    /// This is the ONLY place (besides stop()) that drops the session
    /// subtitle intent, and it persists the "off" choice — subtitles stay
    /// off across episodes and app launches until re-enabled.
    func disableSubtitles() {
        subtitleLoadTask?.cancel()
        selectedSubtitleTrackId = "off"
        subtitleManager.clear()
        sessionSubtitlePreference = nil
        playbackSettings.subtitlesEnabled = false
    }

    func loadAllTracks() {
        loadAudioTracks()
        loadSubtitleTracks()
    }

    // MARK: - Skip Intro/Credits

    private func fetchSegments(itemId: String) async {
        do {
            segments = try await client.getMediaSegments(itemId: itemId)
        } catch {
            // Segments not available - silently ignore (server may not have intro-skipper plugin)
            segments = []
        }
    }

    private func setupSegmentTracking() {
        guard let player else { return }

        // Check position every 0.5 seconds for segment detection
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        segmentObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.checkCurrentSegment(at: time.seconds)
            }
        }
    }

    private func checkCurrentSegment(at currentSeconds: Double) {
        // Find if we're currently in any skippable segment
        let skippableTypes: [MediaSegmentType] = [.intro, .outro, .recap, .preview]
        let activeSegment = segments.first { segment in
            skippableTypes.contains(segment.type) &&
            currentSeconds >= segment.startSeconds &&
            currentSeconds < segment.endSeconds
        }

        if let segment = activeSegment {
            if currentSegment?.id != segment.id {
                currentSegment = segment

                // Check if we should auto-skip this segment type
                let shouldAutoSkip: Bool
                switch segment.type {
                case .intro, .recap:
                    shouldAutoSkip = playbackSettings.autoSkipIntro
                case .outro, .preview:
                    shouldAutoSkip = playbackSettings.autoSkipCredits
                default:
                    shouldAutoSkip = false
                }

                if shouldAutoSkip {
                    skipCurrentSegment()
                } else {
                    showingSkipButton = true
                }
            }
        } else {
            if currentSegment != nil {
                currentSegment = nil
                showingSkipButton = false
            }
        }
    }

    func skipCurrentSegment() {
        guard let segment = currentSegment, let player else { return }
        showingSkipButton = false
        currentSegment = nil

        // If this skip lands at (or within ~2s of) the end — typical for a
        // credits/outro segment — run the end-of-playback flow directly.
        // Seeking to the exact end does NOT post AVPlayerItemDidPlayToEndTime,
        // so auto-play-next would otherwise never fire (issue #241).
        let duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0, segment.endSeconds >= duration - 2.0 {
            Task { await handlePlaybackEnded() }
            return
        }

        let targetTime = CMTime(seconds: segment.endSeconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        diag(.seek, [
            PlayerDiagnostics.field("phase", "skip-segment"),
            PlayerDiagnostics.field("segmentType", segment.type.rawValue),
            PlayerDiagnostics.field("targetSeconds", segment.endSeconds)
        ])
        player.seek(to: targetTime)
    }

    private func cleanupSegmentTracking() {
        if let segmentObserver, let player {
            player.removeTimeObserver(segmentObserver)
        }
        segmentObserver = nil
        segments = []
        currentSegment = nil
        showingSkipButton = false
    }

    // MARK: - Chapter Navigation

    private func setupChapterMarkers(on playerItem: AVPlayerItem, chapters: [ChapterInfo], duration: Double) {
        #if os(tvOS)
        guard !chapters.isEmpty else { return }

        var timedGroups: [AVTimedMetadataGroup] = []

        for (index, chapter) in chapters.enumerated() {
            // Create title metadata
            let titleItem = AVMutableMetadataItem()
            titleItem.key = AVMetadataKey.commonKeyTitle as NSString
            titleItem.keySpace = .common
            titleItem.value = (chapter.name ?? "Chapter \(index + 1)") as NSString

            // Calculate time range (from this chapter to next, or to end)
            let startTime = CMTime(seconds: chapter.startSeconds, preferredTimescale: 600)
            let endTime: CMTime
            if index + 1 < chapters.count {
                endTime = CMTime(seconds: chapters[index + 1].startSeconds, preferredTimescale: 600)
            } else {
                endTime = CMTime(seconds: duration, preferredTimescale: 600)
            }
            let timeRange = CMTimeRange(start: startTime, end: endTime)

            let group = AVTimedMetadataGroup(items: [titleItem], timeRange: timeRange)
            timedGroups.append(group)
        }

        // nil title = chapter markers (vs event markers)
        let markerGroup = AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: timedGroups)
        playerItem.navigationMarkerGroups = [markerGroup]
        #else
        // Chapter markers are tvOS-only; iOS uses AVPlayerViewController's built-in chapter UI
        _ = (playerItem, chapters, duration)
        #endif
    }

    // MARK: - Remote Control Commands (Bluetooth headsets)

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove handlers registered by a previous loadMedia call first —
        // auto-play-next reuses this ViewModel across episodes, and addTarget
        // stacks a new handler each time (removal otherwise only happens in
        // deinit). Mirrors the list in cleanupRemoteCommands().
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            return .success
        }

        // Toggle play/pause (what most Bluetooth headsets use)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else { return .commandFailed }
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
            return .success
        }

        // Skip forward/backward
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else { return .commandFailed }
            let currentTime = player.currentTime().seconds
            let newTime = currentTime + 15
            player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else { return .commandFailed }
            let currentTime = player.currentTime().seconds
            let newTime = max(0, currentTime - 15)
            player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
            return .success
        }
    }

    private func updateNowPlayingInfo(item: BaseItemDto) {
        var nowPlayingInfo = [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyTitle] = item.name ?? "Unknown"

        if let seriesName = item.seriesName {
            nowPlayingInfo[MPMediaItemPropertyArtist] = seriesName
        }

        if let runTimeTicks = item.runTimeTicks {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(runTimeTicks) / 10_000_000.0
        }

        // Elapsed must come from the PLAYER, not the server's saved position.
        // Using userData meant "Start from Beginning" showed the lock screen
        // scrubber at the old resume point and counting up from there.
        if let current = player?.currentTime().seconds, current.isFinite {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = current
        } else if let playbackPositionTicks = item.userData?.playbackPositionTicks {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(playbackPositionTicks) / 10_000_000.0
        }

        // Hard-coding 1.0 made the lock-screen clock keep advancing while
        // paused, because the system extrapolates elapsed time from the rate.
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = Double(player?.rate ?? 0)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    /// Refreshes the Now Playing elapsed time and rate for the current item.
    ///
    /// updateNowPlayingInfo was only called from loadMedia and changeQuality, so
    /// after the first paint the lock screen never heard about seeks, pauses or
    /// ordinary progress.
    private func refreshNowPlayingProgress() {
        guard let item = currentItem else { return }
        updateNowPlayingInfo(item: item)
    }

    nonisolated private func cleanupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    deinit {
        PlayerDiagnostics.event(.deinitialized, [
            PlayerDiagnostics.field("vm", sessionTag),
            PlayerDiagnostics.field("reason", PlayerDiagnostics.TeardownReason.deallocated.rawValue)
        ])
        progressReportTask?.cancel()
        subtitleLoadTask?.cancel()
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
