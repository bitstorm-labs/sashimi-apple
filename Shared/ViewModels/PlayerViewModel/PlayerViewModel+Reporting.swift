import Foundation
import AVFoundation

extension PlayerViewModel {
    func startProgressReporting() {
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

    func reportPlaybackStart(item: BaseItemDto, positionTicks: Int64) async {
        await playbackReporter.start(
            itemID: item.id,
            positionTicks: positionTicks,
            playSessionID: playSessionId,
            playMethod: currentPlayMethod
        )
    }

    func reportProgress() async {
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

    func reportCurrentPlaybackStoppedForTransition() async {
        guard let item = currentItem, !isOfflinePlayback else { return }

        let elapsedSeconds = playbackStartDate.map { Date().timeIntervalSince($0) } ?? 0
        let positionTicks: Int64
        if elapsedSeconds < 10 && resumePositionTicks > 0 {
            positionTicks = resumePositionTicks
        } else {
            let currentSeconds = player?.currentItem?.currentTime().seconds ?? 0
            positionTicks = Int64(currentSeconds * 10_000_000)
        }
        await playbackReporter.stopped(
            itemID: item.id,
            positionTicks: positionTicks,
            playSessionID: playSessionId
        )
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
}
