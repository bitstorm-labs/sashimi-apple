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

    /// Stops playback: everything local happens before this returns, the
    /// network work is left running in the returned task (#591).
    ///
    /// The player used to stay up until the stopped report and the transcode
    /// DELETE had both come back, so a slow or dead server held the viewer on
    /// the player for 30 seconds to two minutes. Nothing the viewer sees
    /// depends on those requests: the position is captured and the report
    /// persisted here, synchronously, and the delivery layer retries a report
    /// that fails. Callers dismiss straight away and await the task only for
    /// work that must follow the report (a Home refresh, delete-after-watching).
    @discardableResult
    func beginStop(reason: PlayerDiagnostics.TeardownReason = .unspecified) -> Task<Void, Never> {
        // Invalidate a transition waiting on report delivery synchronously,
        // before the asynchronous teardown can yield to that transition.
        playbackAttempt += 1
        playbackAttemptItemID = nil
        sameItemPlaybackAttempts.removeAll()
        pendingPlaybackEnd = nil
        // Leaving the player settles the Up Next card: no countdown may start
        // an episode after the viewer has gone.
        clearEpisodeUpNext()
        preparePendingStoppedReportIfNeeded()
        if let teardownTask {
            return teardownTask
        }

        let work = tearDownLocally(reason: reason)
        // Captured by value: the view model is a @StateObject of a view that
        // is on its way out, and the report must not depend on it surviving.
        let reporter = playbackReporter
        let client = client
        let tag = sessionTag
        let task = Task { @MainActor in
            if let report = work.report {
                await reporter.stopped(
                    itemID: report.itemID,
                    positionTicks: report.positionTicks,
                    playSessionID: work.playSessionID
                )
            }
            // Posted once the server has the position (or the attempt has
            // failed and the report is queued), so Home refreshes against it.
            NotificationCenter.default.post(name: .playbackDidEnd, object: nil)

            // The stopped report already ends the session's transcode: the
            // server's ReportPlaybackStopped calls KillTranscodingJobs for its
            // PlaySessionId (verified live: ffmpeg exits on the report alone).
            // The DELETE is only needed when no such report went out: channel
            // playback, a session that never started, or a failed delivery.
            guard let playSessionID = work.transcodeSessionID,
                  !reporter.lastStoppedReportEndedSession else { return }
            Task {
                await Self.stopActiveEncoding(playSessionID: playSessionID, reason: reason, client: client, tag: tag)
            }
        }
        teardownTask = task
        return task
    }

    func stop(reason: PlayerDiagnostics.TeardownReason = .unspecified) async {
        let task = beginStop(reason: reason)
        await task.value
        teardownTask = nil
    }

    /// What is left to tell the server once the player is gone.
    private struct PendingStopWork {
        var report: (itemID: String, positionTicks: Int64)?
        var playSessionID: String?
        /// Set when the session had a server-side transcode to end.
        var transcodeSessionID: String?
    }

    /// Releases the player and every observer on it, and returns what still
    /// has to be reported. Synchronous: nothing here waits on the network.
    private func tearDownLocally(reason: PlayerDiagnostics.TeardownReason) -> PendingStopWork {
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
        clearPlaybackNotice()
        cleanupSegmentTracking()
        subtitleManager.clear()
        // The session is over — the persisted playbackSettings carry the
        // subtitle preference into the next one.
        sessionSubtitlePreference = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        var work = PendingStopWork(playSessionID: playSessionId)
        if let item = currentItem, !isOfflinePlayback, let positionTicks = stoppedReportPositionTicks() {
            work.report = (item.id, positionTicks)
        }
        if !isOfflinePlayback, currentMediaSource?.transcodingUrl != nil {
            work.transcodeSessionID = playSessionId
        }
        playSessionId = nil

        player?.pause()
        invalidatePlayerObservers()
        player = nil
        isPlayerReady = false
        pendingResumeTicks = 0
        activeTrackRequest = nil
        setCurrentItem(nil)
        transitionState = .empty
        playbackStartDate = nil
        return work
    }

    private static func stopActiveEncoding(
        playSessionID: String,
        reason: PlayerDiagnostics.TeardownReason,
        client: JellyfinClient,
        tag: String
    ) async {
        let context = [PlayerDiagnostics.field("vm", tag), PlayerDiagnostics.field("reason", reason.rawValue)]
        PlayerDiagnostics.event(.encodingStop, context + [PlayerDiagnostics.field("playSession", playSessionID)])
        do {
            try await client.stopActiveEncoding(playSessionId: playSessionID)
        } catch {
            logger.error("stopActiveEncoding failed: \(error.localizedDescription, privacy: .public)")
            PlayerDiagnostics.failure(.encodingStop, context + PlayerDiagnostics.fields(for: error))
        }
    }
}
