import Foundation
import AVFoundation

extension PlayerViewModel {
    // MARK: - Skip Intro/Credits

    func fetchSegments(itemId: String, expectedGeneration: PlaybackGeneration? = nil) async {
        do {
            let fetchedSegments = try await client.getMediaSegments(itemId: itemId)
            guard expectedGeneration.map(isCurrentPlaybackGeneration) ?? true else { return }
            segments = fetchedSegments
        } catch {
            guard expectedGeneration.map(isCurrentPlaybackGeneration) ?? true else { return }
            // Segments not available - silently ignore (server may not have intro-skipper plugin)
            segments = []
        }
    }

    func setupSegmentTracking() {
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
        // A channel runs on the clock: skipping an intro, by hand or
        // automatically, would put the viewer ahead of the schedule and the
        // next programme would start late. Live TV has no skip button.
        guard !isWatchingStation else { return }
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
            guard let itemID = currentItem?.id else { return }
            let attempt = playbackAttempt
            Task { await handlePlaybackEnded(itemID: itemID, attempt: attempt) }
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

    func cleanupSegmentTracking() {
        if let segmentObserver, let player {
            player.removeTimeObserver(segmentObserver)
        }
        segmentObserver = nil
        segments = []
        currentSegment = nil
        showingSkipButton = false
    }
}
