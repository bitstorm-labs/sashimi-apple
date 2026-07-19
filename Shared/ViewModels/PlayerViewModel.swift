import Foundation
import AVKit
import AVFoundation
import Combine
import MediaPlayer

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
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isLoading = true
    @Published var error: Error?
    @Published var currentItem: BaseItemDto?
    @Published var errorMessage: String?
    @Published var attemptedURL: String?
    @Published var audioTracks: [AudioTrackOption] = []
    @Published var selectedAudioTrackId: String?
    @Published var subtitleTracks: [SubtitleTrackOption] = []
    @Published var selectedSubtitleTrackId: String?
    @Published var subtitleManager = SubtitleManager()
    @Published var playbackEnded = false
    @Published var nextEpisode: BaseItemDto?
    /// Re-entrancy guard for end-of-playback handling (see handlePlaybackEnded).
    private var isHandlingEnd = false
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
            switch method {
            case .directPlay: return "Direct Play"
            case .directStream: return "Direct Stream"
            case .transcode: return "Transcode"
            }
        }
    }

    // Track when playback actually started (for quick-exit protection)
    private var playbackStartDate: Date?
    private var isOfflinePlayback = false

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
    private var statusObserver: NSKeyValueObservation?
    private var errorObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private let client = JellyfinClient.shared
    private let playbackSettings = PlaybackSettings.shared

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
                // Container remux / audio conversion — video untouched
                streamInfo = StreamInfo(method: .directStream, detail: nil, reason: nil)
            } else {
                var parts: [String] = []
                if let width = info.width, let height = info.height {
                    parts.append(Self.resolutionLabel(width: width, height: height))
                }
                if let codec = info.videoCodec { parts.append(codec.uppercased()) }
                if let bitrate = info.bitrate, bitrate > 0 {
                    parts.append("\(Int(round(Double(bitrate) / 1_000_000))) Mbps")
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

    func loadMedia(item: BaseItemDto, startFromBeginning: Bool = false, localFileURL: URL? = nil) async {
        // Tear down everything tied to the previous player first — auto-play
        // next episode reuses this ViewModel, and observers left on the old
        // player crash when it deallocates (same teardown as changeQuality).
        // The session subtitle intent is deliberately preserved so subtitles
        // stay on across episodes; only the overlay/tracking is cleared.
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

        // Kill the previous episode's transcode session, same as
        // changeQuality — auto-play-next otherwise leaves the old encode
        // running until the server times it out.
        if let playSessionId, currentMediaSource?.transcodingUrl != nil {
            try? await client.stopActiveEncoding(playSessionId: playSessionId)
        }

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

                let asset = AVURLAsset(url: localFileURL)
                let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable", "duration"])
                player = AVPlayer(playerItem: playerItem)
            } else {
                // Online playback - fetch fresh data from server
                freshItem = try await client.getItem(itemId: item.id)
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

            // Fetch media segments for skip intro/credits (skip when offline)
            if !isOffline {
                await fetchSegments(itemId: freshItem.id)
            }

            // Check if there's saved progress to resume from
            let thresholdTicks = Int64(playbackSettings.resumeThresholdSeconds) * 10_000_000
            if startFromBeginning {
                // User explicitly chose to start over - play from beginning
                resumePositionTicks = 0
                if !isOffline {
                    try? await client.reportPlaybackStart(itemId: freshItem.id, positionTicks: 0, playSessionId: playSessionId, playMethod: currentPlayMethod)
                    startProgressReporting()
                }
                setupSegmentTracking()
                playbackStartDate = Date()
                player?.play()
            } else if let startTicks = freshItem.userData?.playbackPositionTicks, startTicks > thresholdTicks {
                // Auto-resume from saved position (no dialog)
                resumePositionTicks = startTicks
                let startTime = CMTime(value: startTicks / 10000, timescale: 1000)
                await player?.seek(to: startTime)
                if !isOffline {
                    try? await client.reportPlaybackStart(itemId: freshItem.id, positionTicks: startTicks, playSessionId: playSessionId, playMethod: currentPlayMethod)
                    startProgressReporting()
                }
                setupSegmentTracking()
                playbackStartDate = Date()
                player?.play()
            } else {
                // No saved progress - start playing immediately
                resumePositionTicks = 0
                if !isOffline {
                    try? await client.reportPlaybackStart(itemId: freshItem.id, positionTicks: 0, playSessionId: playSessionId, playMethod: currentPlayMethod)
                    startProgressReporting()
                }
                setupSegmentTracking()
                playbackStartDate = Date()
                player?.play()
            }
        } catch {
            self.error = error
            self.errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func startProgressReporting() {
        progressReportTask?.cancel()
        progressReportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await reportProgress()
            }
        }
    }

    private func reportProgress() async {
        guard !isOfflinePlayback,
              let item = currentItem,
              let player,
              let currentTime = player.currentItem?.currentTime() else { return }

        let positionTicks = Int64(currentTime.seconds * 10_000_000)
        let isPaused = player.timeControlStatus == .paused

        try? await client.reportPlaybackProgress(itemId: item.id, positionTicks: positionTicks, isPaused: isPaused, playSessionId: playSessionId)
    }

    private func handlePlaybackEnded() async {
        // Guard against firing twice (e.g. a skip-to-end and the natural end
        // notification for the same item). Reset when the next item loads.
        if isHandlingEnd { return }
        isHandlingEnd = true

        progressReportTask?.cancel()

        if let item = currentItem, !isOfflinePlayback {
            // Mark as watched by reporting position at the end
            if let duration = player?.currentItem?.duration.seconds, duration.isFinite {
                let endTicks = Int64(duration * 10_000_000)
                try? await client.reportPlaybackStopped(itemId: item.id, positionTicks: endTicks, playSessionId: playSessionId)
            }
            // Mark item as played
            try? await client.markPlayed(itemId: item.id)

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
        nextEpisode = nil
        playbackEnded = false
        await loadMedia(item: next)
    }

    func changeQuality(_ quality: QualityOption) async {
        guard let item = currentItem else { return }

        // Save current position
        let currentPosition = player?.currentItem?.currentTime()
        let positionTicks = currentPosition.map { Int64($0.seconds * 10_000_000) } ?? 0

        // Update quality setting
        selectedQuality = quality

        // Stop current playback
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
        if let playSessionId, currentMediaSource?.transcodingUrl != nil {
            try? await client.stopActiveEncoding(playSessionId: playSessionId)
        }

        do {
            // An explicit non-Auto pick forces a transcode so the selection
            // visibly takes effect: the tiers are caps, and a direct-played
            // source under the cap would otherwise make the pick a no-op.
            try await setupPlayer(for: item, maxBitrate: quality.maxBitrate, forceTranscode: quality != .auto)
            isLoading = false
            updateNowPlayingInfo(item: item)

            // Seek to saved position
            if positionTicks > 0 {
                let seekTime = CMTime(value: positionTicks / 10000, timescale: 1000)
                await player?.seek(to: seekTime)
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

            // Resume playback and tracking
            startProgressReporting()
            setupSegmentTracking()
            player?.play()
        } catch {
            self.error = error
            self.errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Shared player setup: resolves stream URL, creates AVPlayer with observers.
    private func setupPlayer(for item: BaseItemDto, maxBitrate: Int? = nil, forceTranscode: Bool = false) async throws {
        // Bitrate precedence: explicit override (quality menu change) →
        // session quality selection → global Settings cap. QualityOption.auto
        // has a nil bitrate, so "Auto" defers to Settings, where 0 = no cap.
        let effectiveBitrate = PlaybackSelection.effectiveMaxBitrate(
            sessionOverride: maxBitrate ?? selectedQuality.maxBitrate,
            settingsMaxBitrate: playbackSettings.maxBitrate
        )
        let playbackInfo = try await client.getPlaybackInfo(
            itemId: item.id,
            maxBitrate: effectiveBitrate,
            forceDirectPlay: playbackSettings.forceDirectPlay,
            forceTranscode: forceTranscode
        )

        guard let mediaSource = playbackInfo.mediaSources?.first else {
            throw PlayerError.noMediaSource
        }

        playSessionId = playbackInfo.playSessionId
        currentMediaSource = mediaSource
        videoResolution = mediaSource.videoResolution
        streamInfo = nil   // stale for the new session; refreshed when the overlay opens

        let resolvedURL: URL?
        if let transcodingPath = mediaSource.transcodingUrl, !transcodingPath.isEmpty {
            resolvedURL = await client.buildURL(path: transcodingPath)
        } else if let directPath = mediaSource.directStreamUrl, !directPath.isEmpty {
            resolvedURL = await client.buildURL(path: directPath)
        } else {
            resolvedURL = await client.getPlaybackURL(itemId: item.id, mediaSourceId: mediaSource.id, container: mediaSource.container)
        }

        guard let resolvedURL else {
            throw PlayerError.noStreamURL
        }

        attemptedURL = resolvedURL.absoluteString

        let asset = AVURLAsset(url: resolvedURL)
        let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable", "duration"])

        if let chapters = item.chapters, !chapters.isEmpty,
           let runTimeTicks = item.runTimeTicks {
            let duration = Double(runTimeTicks) / 10_000_000.0
            setupChapterMarkers(on: playerItem, chapters: chapters, duration: duration)
        }

        errorObserver = playerItem.observe(\.status) { [weak self] observed, _ in
            Task { @MainActor in
                if observed.status == .failed {
                    self?.errorMessage = observed.error?.localizedDescription ?? "Unknown playback error"
                    self?.error = observed.error
                }
            }
        }

        player = AVPlayer(playerItem: playerItem)
        player?.appliesMediaSelectionCriteriaAutomatically = false
        player?.volume = 1.0
        player?.isMuted = false

        statusObserver = player?.observe(\.status) { [weak self] observed, _ in
            Task { @MainActor in
                if observed.status == .failed {
                    self?.errorMessage = observed.error?.localizedDescription ?? "Player failed"
                    self?.error = observed.error
                }
            }
        }

        rateObserver = player?.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in
                await self?.reportProgress()
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
    }

    func stop() async {
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
                try? await client.reportPlaybackStopped(itemId: item.id, positionTicks: positionTicks, playSessionId: playSessionId)
            }
        }

        // Kill the session's server-side transcode, if one was active.
        if !isOfflinePlayback, let playSessionId, currentMediaSource?.transcodingUrl != nil {
            try? await client.stopActiveEncoding(playSessionId: playSessionId)
        }
        playSessionId = nil

        player?.pause()
        invalidatePlayerObservers()
        player = nil
        currentItem = nil
        playbackStartDate = nil

        // Notify that playback ended so Home can refresh
        NotificationCenter.default.post(name: .playbackDidEnd, object: nil)
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
    }

    // MARK: - Settings-based track preferences

    /// Applies the Settings-preferred audio/subtitle languages when playback
    /// starts. Selections made later in the player UI naturally override
    /// these because they happen afterwards.
    private func applyPreferredTracks() async {
        await applyPreferredAudioLanguage()
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

        // Load subtitle tracks from Jellyfin's media source (not AVPlayer)
        if let mediaSource = currentMediaSource {
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
            await subtitleManager.loadSubtitles(itemId: item.id, subtitleIndex: track.index)
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

        if let playbackPositionTicks = item.userData?.playbackPositionTicks {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(playbackPositionTicks) / 10_000_000.0
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
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
        progressReportTask?.cancel()
        subtitleLoadTask?.cancel()
        cleanupRemoteCommands()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }
}

enum PlayerError: LocalizedError {
    case noMediaSource
    case noStreamURL

    var errorDescription: String? {
        switch self {
        case .noMediaSource:
            return "No playable media source found"
        case .noStreamURL:
            return "Could not generate stream URL"
        }
    }
}
