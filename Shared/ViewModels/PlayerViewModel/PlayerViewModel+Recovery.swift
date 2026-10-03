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
    ///
    /// When the link is the problem (the access log shows segments arriving
    /// slower than the stream needs, or a fresh session stalled again) the
    /// rebuild instead steps DOWN a quality tier, as far as the 720 kbps
    /// floor — see PlaybackRecoveryPlan.
    func attemptPlaybackRecovery(reason: String, itemID: String, attempt: Int) async { // swiftlint:disable:this function_body_length cyclomatic_complexity
        let sourceGeneration = PlaybackGeneration(itemID: itemID, attempt: attempt)
        guard isCurrentPlaybackGeneration(sourceGeneration),
              !transitionState.isTransitioning,
              !isRecovering,
              !isOfflinePlayback,
              let item = currentItem,
              item.id == itemID else { return }
        // Read before teardown: the access log goes with the player.
        let throughput = currentThroughput()
        let streamBitrate = currentStreamBitrate(throughput: throughput)
        let decision = PlaybackRecoveryPlan.decide(
            isStall: reason == Self.stallRecoveryReason,
            rebuildAttempts: recoveryAttempts,
            currentBitrate: streamBitrate,
            throughput: throughput
        )

        let recoveryQuality: QualityOption
        let allowVideoStreamCopy: Bool
        switch decision {
        case .giveUp:
            return
        case .rebuild(let allowCopy):
            recoveryAttempts += 1
            recoveryQuality = selectedQuality
            allowVideoStreamCopy = allowCopy
        case .stepDown(let lower):
            qualityStepDowns += 1
            recoveryQuality = lower
            // A real encode at the lower bitrate: a copy of a source that is
            // already under the new cap would be the same stream that stalled.
            allowVideoStreamCopy = false
        }

        transitionState.isTransitioning = true
        isRecovering = true
        defer {
            isRecovering = false
            finishTransition()
        }
        let recoveryNumber = recoveryAttempts + qualityStepDowns
        if case .stepDown(let lower) = decision {
            selectedQuality = lower
            showPlaybackNotice("Lowering quality for your connection", duration: nil)
        }
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
            PlayerDiagnostics.field("allowVideoStreamCopy", allowVideoStreamCopy),
            PlayerDiagnostics.field("decision", Self.diagnosticName(decision)),
            PlayerDiagnostics.field("streamBitrate", streamBitrate),
            PlayerDiagnostics.field("observedBitrate", throughput.map { Int($0.observedBitrate) }),
            PlayerDiagnostics.field("indicatedBitrate", throughput.map { Int($0.indicatedBitrate) }),
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
                try await recoverySetup(item, recoveryQuality.maxBitrate, recoveryQuality.maxWidth, allowVideoStreamCopy)
            } else {
                try await setupPlayer(
                    for: item,
                    maxBitrate: recoveryQuality.maxBitrate,
                    maxWidth: recoveryQuality.maxWidth,
                    forceTranscode: true,
                    allowVideoStreamCopy: allowVideoStreamCopy,
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
            if case .stepDown = decision {
                showPlaybackNotice("Lowering quality for your connection · \(recoveryQuality.menuTitle)")
            }
            scheduleStreamInfoRefresh(for: recoveryGeneration)
        } catch {
            guard isCurrentPlaybackGeneration(recoveryGeneration), !Task.isCancelled else { return }
            clearPlaybackNotice()
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

    static let stallRecoveryReason = "stall-watchdog"

    /// What recovery would do now for a non-stall failure (item/decoder
    /// error). `canAttemptRecovery` uses it so an error is surfaced exactly
    /// when recovery has nothing left to try.
    func recoveryDecision(isStall: Bool) -> PlaybackRecoveryPlan.Decision {
        let throughput = currentThroughput()
        return PlaybackRecoveryPlan.decide(
            isStall: isStall,
            rebuildAttempts: recoveryAttempts,
            currentBitrate: currentStreamBitrate(throughput: throughput),
            throughput: throughput
        )
    }

    /// AVPlayer's latest access-log reading for the current item, if any.
    func currentThroughput() -> PlaybackRecoveryPlan.Throughput? {
        guard let event = player?.currentItem?.accessLog()?.events.last else { return nil }
        return PlaybackRecoveryPlan.Throughput(
            observedBitrate: event.observedBitrate,
            indicatedBitrate: event.indicatedBitrate
        )
    }

    /// The bitrate being streamed: the tier's cap (or Auto's requested cap),
    /// lowered to the variant's own bitrate when the access log knows it — a
    /// direct-played 9.5 Mbps file under a 100 Mbps Auto cap steps down from
    /// 9.5, not from 100.
    func currentStreamBitrate(throughput: PlaybackRecoveryPlan.Throughput?) -> Int? {
        let indicated = throughput.map { Int($0.indicatedBitrate) }.flatMap { $0 > 0 ? $0 : nil }
        return [selectedQuality.maxBitrate ?? activeBitrateCap, indicated].compactMap { $0 }.min()
    }

    private static func diagnosticName(_ decision: PlaybackRecoveryPlan.Decision) -> String {
        switch decision {
        case .rebuild(let allowCopy): return allowCopy ? "rebuild-copy" : "rebuild-encode"
        case .stepDown(let lower): return "step-down-\(lower.rawValue)"
        case .giveUp: return "give-up"
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
            Task { await self.attemptPlaybackRecovery(reason: Self.stallRecoveryReason, itemID: generation.itemID, attempt: generation.attempt) }
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
