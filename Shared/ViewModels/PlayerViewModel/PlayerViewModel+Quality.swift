import Foundation
import AVFoundation

extension PlayerViewModel {
    func changeQuality(_ quality: QualityOption) async { // swiftlint:disable:this function_body_length
        guard !transitionState.isTransitioning, let item = currentItem else { return }
        // Quality changes rebuild the same mutable player as episode
        // transitions. Claim the shared lock before the first await so two
        // rapid menu selections cannot tear down and recreate the player out
        // of order.
        transitionState.isTransitioning = true
        isChangingQuality = true
        defer {
            isChangingQuality = false
            finishTransition()
        }

        // Save current position
        let currentPosition = player?.currentItem?.currentTime()
        let positionTicks = currentPosition.map { Int64($0.seconds * 10_000_000) } ?? 0

        advancePlaybackAttemptForSameItem(itemID: item.id)
        diag(.qualityChange, [
            PlayerDiagnostics.field("from", selectedQuality.rawValue),
            PlayerDiagnostics.field("to", quality.rawValue),
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("positionSeconds", currentPosition?.seconds)
        ])

        // Update quality setting
        selectedQuality = quality
        let attempt = playbackAttempt

        // Stop current playback
        diag(.teardown, [
            PlayerDiagnostics.field("reason", PlayerDiagnostics.TeardownReason.qualityChange.rawValue),
            PlayerDiagnostics.field("item", item.id)
        ])
        player?.pause()
        progressReportTask?.cancel()
        subtitleLoadTask?.cancel()
        // Episode ordering belongs to the item, not the stream. Leave its
        // in-flight lookup alive when replacing the player for this same item.
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
        guard playbackAttempt == attempt, !Task.isCancelled else { return }

        do {
            // An explicit non-Auto pick forces a transcode so the selection
            // visibly takes effect: the tiers are caps, and a direct-played
            // source under the cap would otherwise make the pick a no-op.
            try await setupPlayer(for: item, maxBitrate: quality.maxBitrate, maxWidth: quality.maxWidth, forceTranscode: quality != .auto)
            guard playbackAttempt == attempt, !Task.isCancelled else { return }
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
}
