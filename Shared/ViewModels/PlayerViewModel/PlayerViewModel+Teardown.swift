import Foundation
import AVFoundation
import os

// Playback reporting is best-effort by design -- a failed report must never
// interrupt playback -- but swallowing it silently meant watch state could
// stop syncing with no trace at all.
private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "PlayerViewModel")

extension PlayerViewModel {
    /// Ends the server-side transcode belonging to the CURRENT play session, if
    /// there is one, and records why.
    ///
    /// This is the client action Jellyfin logs as "Stopping ffmpeg process with
    /// q command" (it is a DELETE /Videos/ActiveEncodings). From the server's
    /// side it is indistinguishable from the client simply walking away, which
    /// is why every call site has to name its reason here.
    func stopActiveEncodingIfNeeded(reason: PlayerDiagnostics.TeardownReason) async {
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

    @discardableResult
    func beginStop(reason: PlayerDiagnostics.TeardownReason = .unspecified) -> Task<Void, Never> {
        // Invalidate a transition waiting on report delivery synchronously,
        // before the asynchronous teardown can yield to that transition.
        playbackAttempt += 1
        playbackAttemptItemID = nil
        sameItemPlaybackAttempts.removeAll()
        pendingPlaybackEnd = nil
        preparePendingStoppedReportIfNeeded()
        if let teardownTask {
            return teardownTask
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStop(reason: reason)
        }
        teardownTask = task
        return task
    }

    func stop(reason: PlayerDiagnostics.TeardownReason = .unspecified) async {
        let task = beginStop(reason: reason)
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
        navigationTask?.cancel()
        navigationTask = nil
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
        setCurrentItem(nil)
        transitionState = .empty
        playbackStartDate = nil

        // Notify that playback ended so Home can refresh
        NotificationCenter.default.post(name: .playbackDidEnd, object: nil)
    }
}
