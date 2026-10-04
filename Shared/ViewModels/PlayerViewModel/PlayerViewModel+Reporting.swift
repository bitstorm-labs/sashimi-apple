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
              let positionTicks = livePositionTicks() else { return }

        let isPaused = player.timeControlStatus == .paused
        await playbackReporter.progress(
            itemID: item.id,
            positionTicks: positionTicks,
            isPaused: isPaused,
            playSessionID: playSessionId
        )
    }

    func reportCurrentPlaybackStoppedForTransition() async {
        guard let item = currentItem, !isOfflinePlayback else { return }

        let positionTicks = reportablePositionTicks() ?? 0
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
              !isOfflinePlayback,
              let positionTicks = stoppedReportPositionTicks() else { return }

        playbackReporter.prepareStopped(
            itemID: item.id,
            positionTicks: positionTicks,
            playSessionID: playSessionId
        )
    }
}

// MARK: - Position (#593)

/// Where the viewer is, for anything that records it.
///
/// `AVPlayerItem.currentTime()` is not that until the item is ready and its
/// resume seek has landed: a rebuilt item (quality change, audio change,
/// recovery) reads zero while it loads, and reporting that zero wiped the
/// server's resume point. `pendingResumeTicks` holds the real position for
/// exactly that window.
enum PlaybackPosition {
    /// The position to save or report. Nil when nothing is known (no clock
    /// and no pending resume), so the caller reports nothing rather than zero.
    ///
    /// - Parameter secondsSinceStart: pass nil to skip the quick-exit rule
    ///   (an exit within 10 s of starting keeps the original resume point).
    static func ticks(
        currentSeconds: Double?,
        pendingResumeTicks: Int64,
        resumePositionTicks: Int64 = 0,
        secondsSinceStart: TimeInterval? = nil
    ) -> Int64? {
        if pendingResumeTicks > 0 { return pendingResumeTicks }
        if let secondsSinceStart, secondsSinceStart < 10, resumePositionTicks > 0 {
            return resumePositionTicks
        }
        // A non-numeric CMTime reads NaN, and Int64(NaN) traps.
        guard let currentSeconds, currentSeconds.isFinite, currentSeconds >= 0 else { return nil }
        return Int64(currentSeconds * 10_000_000)
    }
}

extension PlayerViewModel {
    /// The viewer's position right now: the pending resume point while a
    /// rebuilt item loads, the item's clock otherwise.
    func livePositionTicks() -> Int64? {
        PlaybackPosition.ticks(
            currentSeconds: player?.currentItem?.currentTime().seconds,
            pendingResumeTicks: pendingResumeTicks
        )
    }

    /// `livePositionTicks`, except that leaving within 10 s of starting keeps
    /// the original resume point.
    func reportablePositionTicks() -> Int64? {
        PlaybackPosition.ticks(
            currentSeconds: player?.currentItem?.currentTime().seconds,
            pendingResumeTicks: pendingResumeTicks,
            resumePositionTicks: resumePositionTicks,
            secondsSinceStart: playbackStartDate.map { Date().timeIntervalSince($0) } ?? 0
        )
    }

    /// The position a stopped report carries on teardown. With no player a
    /// report is only sent when a rebuild left a pending position behind:
    /// that is the one case where the position is known without a clock.
    func stoppedReportPositionTicks() -> Int64? {
        guard player != nil || pendingResumeTicks > 0 else { return nil }
        return reportablePositionTicks()
    }
}
