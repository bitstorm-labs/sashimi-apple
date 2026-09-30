import Foundation
import AVFoundation

extension PlayerViewModel {
    /// Official-client error fallback (jellyfin-web's `onPlaybackError`):
    /// when the stream fails or stalls unrecoverably, rebuild playback at the
    /// current position forcing a transcode — a fresh session whose segments
    /// are produced from where the viewer actually is. The first attempt
    /// keeps video stream-copy allowed (a fresh remux session clears the
    /// jellyfin#16070 seek-freeze, whose broken state is per-session); the
    /// second disallows it (genuine re-encode — the last resort, and the
    /// escalation jellyfin-web uses). Two attempts per item, then the error
    /// surfaces normally.
    func attemptPlaybackRecovery(reason: String, itemID: String, attempt: Int) async { // swiftlint:disable:this function_body_length
        let sourceGeneration = PlaybackGeneration(itemID: itemID, attempt: attempt)
        guard isCurrentPlaybackGeneration(sourceGeneration),
              !transitionState.isTransitioning,
              !isRecovering,
              !isOfflinePlayback,
              recoveryAttempts < 2,
              let item = currentItem,
              item.id == itemID else { return }

        transitionState.isTransitioning = true
        isRecovering = true
        defer {
            isRecovering = false
            finishTransition()
        }
        recoveryAttempts += 1
        let recoveryNumber = recoveryAttempts
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

        advancePlaybackAttemptForSameItem(itemID: item.id)
        let recoveryGeneration = PlaybackGeneration(itemID: item.id, attempt: playbackAttempt)
        diag(.loadBegin, [
            PlayerDiagnostics.field("phase", "recovery"),
            PlayerDiagnostics.field("recoveryAttempt", recoveryNumber),
            PlayerDiagnostics.field("trigger", reason),
            PlayerDiagnostics.field("allowVideoStreamCopy", recoveryNumber < 2),
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
        guard isCurrentPlaybackGeneration(recoveryGeneration), !Task.isCancelled else { return }

        do {
            if let recoverySetup {
                try await recoverySetup(item, selectedQuality.maxBitrate, selectedQuality.maxWidth, recoveryNumber < 2)
            } else {
                try await setupPlayer(
                    for: item,
                    maxBitrate: selectedQuality.maxBitrate,
                    maxWidth: selectedQuality.maxWidth,
                    forceTranscode: true,
                    allowVideoStreamCopy: recoveryNumber < 2,
                    expectedPlaybackGeneration: recoveryGeneration
                )
            }
            guard isCurrentPlaybackGeneration(recoveryGeneration), !Task.isCancelled else { return }
            isLoading = false
            updateNowPlayingInfo(item: item)
            if positionTicks > 0 {
                pendingResumeTicks = positionTicks
            }
            if !applySessionSubtitlePreference() {
                applyPreferredSubtitles()
            }
            if await !applySessionAudioPreference(expectedGeneration: recoveryGeneration) {
                guard isCurrentPlaybackGeneration(recoveryGeneration), !Task.isCancelled else { return }
                await applyPreferredAudioLanguage(expectedGeneration: recoveryGeneration)
                guard isCurrentPlaybackGeneration(recoveryGeneration), !Task.isCancelled else { return }
            }
            await fetchSegments(itemId: item.id, expectedGeneration: recoveryGeneration)
            guard isCurrentPlaybackGeneration(recoveryGeneration), !Task.isCancelled else { return }
            startProgressReporting()
            setupSegmentTracking()
            logAndPlay(positionTicks: positionTicks)
        } catch {
            guard isCurrentPlaybackGeneration(recoveryGeneration), !Task.isCancelled else { return }
            diagFailure(.loadFailed, [
                PlayerDiagnostics.field("phase", "recovery"),
                PlayerDiagnostics.field("recoveryAttempt", recoveryNumber),
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
    func armStallWatchdog(for generation: PlaybackGeneration, grace: Double = 8) {
        guard isCurrentPlaybackGeneration(generation), let watchedPlayer = player else { return }
        stallWatchdogTask?.cancel()
        let stalledAt = watchedPlayer.currentTime().seconds
        stallWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled, let self else { return }
            guard self.isCurrentPlaybackGeneration(generation),
                  let player = self.player,
                  player === watchedPlayer,
                  player.timeControlStatus != .playing else { return }
            let now = player.currentTime().seconds
            guard now.isFinite, abs(now - stalledAt) < 0.5 else { return }
            self.stallWatchdogTask = nil
            Task { await self.attemptPlaybackRecovery(reason: "stall-watchdog", itemID: generation.itemID, attempt: generation.attempt) }
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
    func applyPendingResumeSeekIfNeeded(generation: PlaybackGeneration) {
        guard isCurrentPlaybackGeneration(generation), pendingResumeTicks > 0, let player else { return }
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
            armStallWatchdog(for: generation, grace: 15)
        }
    }
}
