import Foundation
import AVKit
import AVFoundation
import Combine

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
    @Published var showingUpNext = false
    @Published var resumePositionTicks: Int64 = 0

    // Track when playback actually started (for quick-exit protection)
    private var playbackStartDate: Date?

    // Media source info for subtitle/audio selection
    private var currentMediaSource: MediaSourceInfo?
    private var currentSubtitleStreamIndex: Int?

    // Skip intro/credits
    @Published var segments: [MediaSegmentDto] = []
    @Published var currentSegment: MediaSegmentDto?
    @Published var showingSkipButton = false

    private var timeObserver: Any?
    private var segmentObserver: Any?
    private var progressReportTask: Task<Void, Never>?
    private var statusObserver: NSKeyValueObservation?
    private var errorObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private let client = JellyfinClient.shared
    private let playbackSettings = PlaybackSettings.shared

    func loadMedia(item: BaseItemDto, startFromBeginning: Bool = false) async {
        isLoading = true
        error = nil
        errorMessage = nil

        do {
            // Fetch fresh item data to get latest playback position
            let freshItem = try await client.getItem(itemId: item.id)
            currentItem = freshItem

            let playbackInfo = try await client.getPlaybackInfo(itemId: freshItem.id)

            guard let mediaSource = playbackInfo.mediaSources?.first else {
                throw PlayerError.noMediaSource
            }

            // Store media source for subtitle/audio track info
            currentMediaSource = mediaSource

            let url: URL?
            if let transcodingPath = mediaSource.transcodingUrl, !transcodingPath.isEmpty {
                url = await client.buildURL(path: transcodingPath)
            } else if let directPath = mediaSource.directStreamUrl, !directPath.isEmpty {
                url = await client.buildURL(path: directPath)
            } else {
                url = await client.getPlaybackURL(itemId: item.id, mediaSourceId: mediaSource.id, container: mediaSource.container)
            }

            guard let url else {
                throw PlayerError.noStreamURL
            }

            attemptedURL = url.absoluteString

            // Configure audio session for playback
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)

            let asset = AVURLAsset(url: url)
            let playerItem = AVPlayerItem(asset: asset)

            // Set up chapter markers immediately (before playback starts)
            if let chapters = freshItem.chapters, !chapters.isEmpty,
               let runTimeTicks = freshItem.runTimeTicks {
                let duration = Double(runTimeTicks) / 10_000_000.0
                setupChapterMarkers(on: playerItem, chapters: chapters, duration: duration)
            }

            errorObserver = playerItem.observe(\.status) { [weak self] item, _ in
                Task { @MainActor in
                    if item.status == .failed {
                        self?.errorMessage = item.error?.localizedDescription ?? "Unknown playback error"
                        self?.error = item.error
                    }
                }
            }

            player = AVPlayer(playerItem: playerItem)
            player?.volume = 1.0
            player?.isMuted = false

            statusObserver = player?.observe(\.status) { [weak self] player, _ in
                Task { @MainActor in
                    if player.status == .failed {
                        self?.errorMessage = player.error?.localizedDescription ?? "Player failed"
                        self?.error = player.error
                    }
                }
            }

            // Observe play/pause to report progress immediately
            rateObserver = player?.observe(\.timeControlStatus) { [weak self] _, _ in
                Task { @MainActor in
                    await self?.reportProgress()
                }
            }

            // Observe playback end
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.handlePlaybackEnded()
                }
            }

            isLoading = false

            // Fetch media segments for skip intro/credits (non-blocking)
            await fetchSegments(itemId: freshItem.id)

            // Check if there's saved progress to resume from
            let thresholdTicks = Int64(playbackSettings.resumeThresholdSeconds) * 10_000_000
            if startFromBeginning {
                // User explicitly chose to start over - play from beginning
                resumePositionTicks = 0
                try? await client.reportPlaybackStart(itemId: freshItem.id, positionTicks: 0)
                startProgressReporting()
                setupSegmentTracking()
                playbackStartDate = Date()
                player?.play()
            } else if let startTicks = freshItem.userData?.playbackPositionTicks, startTicks > thresholdTicks {
                // Auto-resume from saved position (no dialog)
                resumePositionTicks = startTicks
                let startTime = CMTime(value: startTicks / 10000, timescale: 1000)
                await player?.seek(to: startTime)
                try? await client.reportPlaybackStart(itemId: freshItem.id, positionTicks: startTicks)
                startProgressReporting()
                setupSegmentTracking()
                playbackStartDate = Date()
                player?.play()
            } else {
                // No saved progress - start playing immediately
                resumePositionTicks = 0
                try? await client.reportPlaybackStart(itemId: freshItem.id, positionTicks: 0)
                startProgressReporting()
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
        guard let item = currentItem,
              let player,
              let currentTime = player.currentItem?.currentTime() else { return }

        let positionTicks = Int64(currentTime.seconds * 10_000_000)
        let isPaused = player.timeControlStatus == .paused

        try? await client.reportPlaybackProgress(itemId: item.id, positionTicks: positionTicks, isPaused: isPaused)
    }

    private func handlePlaybackEnded() async {
        progressReportTask?.cancel()

        if let item = currentItem {
            // Mark as watched by reporting position at the end
            if let duration = player?.currentItem?.duration.seconds, duration.isFinite {
                let endTicks = Int64(duration * 10_000_000)
                try? await client.reportPlaybackStopped(itemId: item.id, positionTicks: endTicks)
            }
            // Mark item as played
            try? await client.markPlayed(itemId: item.id)

            // Check for next episode/video if this is an episode or video
            if playbackSettings.autoPlayNextEpisode, let next = await fetchNextItem(for: item) {
                nextEpisode = next
                showingUpNext = true
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
            return await fetchNextByIndex(parentId: seasonId, currentIndex: currentIndex, type: .episode, exactMatch: false)
        }

        // Handle videos (explicit Video type)
        if item.type == .video {
            let parentId = item.seasonId ?? item.seriesId ?? item.parentId
            guard let parentId, let currentIndex = item.indexNumber else { return nil }
            return await fetchNextByIndex(parentId: parentId, currentIndex: currentIndex, type: .video, exactMatch: false)
        }

        return nil
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
        showingUpNext = false
        nextEpisode = nil
        playbackEnded = false
        await loadMedia(item: next)
    }

    func cancelUpNext() {
        showingUpNext = false
        nextEpisode = nil
        playbackEnded = true
    }

    func stop() async {
        progressReportTask?.cancel()
        cleanupSegmentTracking()
        subtitleManager.clear()

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

            // Cap position at 90% to prevent Jellyfin from auto-marking as watched
            // when user manually exits near the end. Only handlePlaybackEnded should mark as watched.
            if let totalTicks = item.runTimeTicks, totalTicks > 0 {
                let maxTicks = Int64(Double(totalTicks) * 0.90)
                positionTicks = min(positionTicks, maxTicks)
            }

            try? await client.reportPlaybackStopped(itemId: item.id, positionTicks: positionTicks)
        }

        player?.pause()
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
        selectedSubtitleTrackId = "off"
    }

    func selectSubtitleTrack(_ track: SubtitleTrackOption) {
        // Update selection state
        selectedSubtitleTrackId = track.isOffOption ? "off" : track.id

        guard let item = currentItem, let player = player else { return }

        if track.isOffOption {
            // Turn off subtitles
            subtitleManager.clear()
        } else {
            // Load and display subtitles via our custom overlay
            Task {
                await subtitleManager.loadSubtitles(itemId: item.id, subtitleIndex: track.index)
                subtitleManager.startTracking(player: player)
            }
        }
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
        let targetTime = CMTime(seconds: segment.endSeconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: targetTime)
        showingSkipButton = false
        currentSegment = nil
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
    }

    deinit {
        progressReportTask?.cancel()
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
