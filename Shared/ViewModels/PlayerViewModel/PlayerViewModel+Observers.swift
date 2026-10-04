import Foundation
import AVFoundation

extension PlayerViewModel {
    /// Builds the AVPlayer and wires every observer it needs.
    ///
    /// Factored out because offline playback builds its own AVPlayer and used
    /// to skip all of this: downloaded episodes never fired
    /// AVPlayerItemDidPlayToEndTime (so they never dismissed and auto-play-next
    /// was dead for downloads), and a corrupt download sat on a black screen
    /// with no error because nothing observed .failed.
    func makePlayerAndObservers(for playerItem: AVPlayerItem) { // swiftlint:disable:this function_body_length
        let generation = currentItem.map { PlaybackGeneration(itemID: $0.id, attempt: playbackAttempt) }
        isPlayerReady = false
        tracksVersion &+= 1
        errorObserver = playerItem.observe(\.status) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self else { return }
                // EVERY transition, not just the interesting ones: an item that
                // never leaves .unknown is a different failure from one that
                // reaches .failed, and the two are indistinguishable to a viewer
                // (both are a black screen).
                self.diag(.itemStatus, [
                    PlayerDiagnostics.field("status", PlayerDiagnostics.name(itemStatus: observed.status))
                ] + (observed.status == .failed ? PlayerDiagnostics.fields(for: observed.error) : []))

                if observed.status == .failed {
                    guard let generation, self.isCurrentPlaybackGeneration(generation) else { return }
                    self.isPlayerReady = false
                    self.diagFailure(.itemStatus, [
                        PlayerDiagnostics.field("status", "failed")
                    ] + PlayerDiagnostics.fields(for: observed.error))
                    // Recovery first (official-client pattern): rebuild at the
                    // current position forcing a transcode. The error only
                    // surfaces once recovery is exhausted.
                    if self.canAttemptRecovery {
                        await self.attemptPlaybackRecovery(
                            reason: "item-failed",
                            itemID: generation.itemID,
                            attempt: generation.attempt
                        )
                    } else {
                        self.errorMessage = observed.error?.localizedDescription ?? "Unknown playback error"
                        self.error = observed.error
                    }
                } else if observed.status == .readyToPlay {
                    guard let generation, self.isCurrentPlaybackGeneration(generation) else { return }
                    self.isPlayerReady = true
                    self.logTrackAvailability(for: observed)
                    self.applyPendingResumeSeekIfNeeded(generation: generation)
                }
            }
        }

        observeItemLogs(for: playerItem, generation: generation)

        player = AVPlayer(playerItem: playerItem)
        player?.appliesMediaSelectionCriteriaAutomatically = false
#if targetEnvironment(simulator)
        // Simulator playback must never leak audio to the host. Apply this
        // before any ready-to-play callback can reach logAndPlay().
        player?.volume = 0
        player?.isMuted = true
#else
        player?.volume = 1.0
        player?.isMuted = false
#endif
        diag(.playerCreated, [
            PlayerDiagnostics.field("tracksVersion", tracksVersion)
        ])

        statusObserver = player?.observe(\.status) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, let generation, self.isCurrentPlaybackGeneration(generation) else { return }
                self.diag(.playerStatus, [
                    PlayerDiagnostics.field("status", PlayerDiagnostics.name(playerStatus: observed.status))
                ])
                if observed.status == .failed {
                    self.diagFailure(.playerStatus, [
                        PlayerDiagnostics.field("status", "failed")
                    ] + PlayerDiagnostics.fields(for: observed.error))
                    self.errorMessage = observed.error?.localizedDescription ?? "Player failed"
                    self.error = observed.error
                }
            }
        }

        rateObserver = player?.observe(\.timeControlStatus) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, let generation, self.isCurrentPlaybackGeneration(generation) else { return }
                // "waiting" for a long stretch after play() IS the stall the
                // viewer describes as a freeze; the reason says whether it is
                // buffering or waiting on a minimum stall-free duration.
                self.diag(.timeControl, [
                    PlayerDiagnostics.field("status", PlayerDiagnostics.name(timeControlStatus: observed.timeControlStatus)),
                    PlayerDiagnostics.field("reason", observed.reasonForWaitingToPlay?.rawValue),
                    PlayerDiagnostics.field("positionSeconds", observed.currentTime().seconds)
                ])
                self.playbackPauseStateChanged(
                    isPaused: observed.timeControlStatus == .paused,
                    generation: generation
                )
                self.refreshNowPlayingProgress()
                await self.reportProgress()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let generation else { return }
            Task { @MainActor in
                await self?.handlePlaybackEnded(itemID: generation.itemID, attempt: generation.attempt)
            }
        }
    }

    /// Subscribes to the AVPlayerItem notifications that explain stalls,
    /// audio-only playback and seek failures.
    ///
    /// None of this reaches `AVPlayerItem.status`: an item can stall forever,
    /// drop every video frame, or fail an individual segment fetch while its
    /// status stays `.readyToPlay`. Until now the app observed only `status`,
    /// which is why a failed play could only be described as "it just sat
    /// there" and had to be reconstructed from the server's ffmpeg log.
    private func observeItemLogs(for playerItem: AVPlayerItem, generation: PlaybackGeneration?) { // swiftlint:disable:this function_body_length
        removeItemLogObservers()
        let center = NotificationCenter.default

        itemErrorLogObserver = center.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem,
                  let event = item.errorLog()?.events.last else { return }
            Task { @MainActor in
                self?.diagFailure(.errorLog, PlayerDiagnostics.summarize(errorEvent: event))
            }
        }

        itemAccessLogObserver = center.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem,
                  let event = item.accessLog()?.events.last else { return }
            Task { @MainActor in
                guard let self else { return }
                // Access-log entries arrive on every rendition switch and
                // periodically during playback, so the raw sample is .debug.
                self.diagDetail(.accessLog, PlayerDiagnostics.summarize(accessEvent: event))
                // A stall is the exception: promote it, because "numberOfStalls
                // climbing" is the difference between "the link can't carry
                // this" and "the stream itself is broken".
                if event.numberOfStalls > self.lastReportedStallCount {
                    self.lastReportedStallCount = event.numberOfStalls
                    self.diag(.accessLog, [
                        PlayerDiagnostics.field("stallDetected", true)
                    ] + PlayerDiagnostics.summarize(accessEvent: event))
                }
            }
        }

        // Seeks made through the tvOS transport bar never pass through this
        // view model — AVPlayerViewController drives AVPlayer directly. This
        // notification is the only way to see them, and seeking is the
        // reproducer for the 4K stream-copy failure.
        stallObservers.append(center.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let generation, self?.isCurrentPlaybackGeneration(generation) == true else { return }
                self?.logSeekLanding(on: item, cause: "time-jumped")
            }
        })

        stallObservers.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let generation, self?.isCurrentPlaybackGeneration(generation) == true else { return }
                self?.logSeekLanding(on: item, cause: "playback-stalled")
                // A stall that never recovers is the seek-freeze; give normal
                // buffering a grace window, then rebuild at position.
                self?.armStallWatchdog(for: generation)
            }
        })

        stallObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, let generation, self.isCurrentPlaybackGeneration(generation) else { return }
                self.diagFailure(.itemStatus, [
                    PlayerDiagnostics.field("event", "failed-to-play-to-end")
                ] + PlayerDiagnostics.fields(for: error))
                if self.canAttemptRecovery {
                    await self.attemptPlaybackRecovery(
                        reason: "failed-to-play-to-end",
                        itemID: generation.itemID,
                        attempt: generation.attempt
                    )
                }
            }
        })
    }

    private func removeItemLogObservers() {
        let center = NotificationCenter.default
        if let itemErrorLogObserver {
            center.removeObserver(itemErrorLogObserver)
            self.itemErrorLogObserver = nil
        }
        if let itemAccessLogObserver {
            center.removeObserver(itemAccessLogObserver)
            self.itemAccessLogObserver = nil
        }
        for observer in stallObservers {
            center.removeObserver(observer)
        }
        stallObservers.removeAll()
        lastReportedStallCount = 0
    }

    /// Where a seek (or stall) actually landed, relative to what the stream can
    /// serve.
    ///
    /// `seekable` is the range Jellyfin's playlist claims; `loaded` is what
    /// AVPlayer actually holds. A position inside `seekable` but outside
    /// `loaded`, with playback not advancing, is a seek into a segment the
    /// server has not produced — the question the server log cannot answer.
    private func logSeekLanding(on item: AVPlayerItem, cause: String) {
        let position = item.currentTime().seconds
        let seekable = item.seekableTimeRanges.first?.timeRangeValue
        let loaded = item.loadedTimeRanges.first?.timeRangeValue
        diag(.seek, [
            PlayerDiagnostics.field("cause", cause),
            PlayerDiagnostics.field("positionSeconds", position),
            PlayerDiagnostics.field("seekableStart", seekable?.start.seconds),
            PlayerDiagnostics.field("seekableEnd", seekable.map { ($0.start + $0.duration).seconds }),
            PlayerDiagnostics.field("loadedStart", loaded?.start.seconds),
            PlayerDiagnostics.field("loadedEnd", loaded.map { ($0.start + $0.duration).seconds }),
            PlayerDiagnostics.field("likelyToKeepUp", item.isPlaybackLikelyToKeepUp),
            PlayerDiagnostics.field("bufferEmpty", item.isPlaybackBufferEmpty)
        ] + PlayerDiagnostics.trackSummary(for: item).fields)
    }

    /// How many video and audio tracks AVPlayer ended up with, and how many it
    /// enabled. Zero enabled video tracks alongside enabled audio IS the
    /// "audio plays, picture is frozen" report, stated rather than inferred.
    private func logTrackAvailability(for item: AVPlayerItem) {
        diag(.tracks, PlayerDiagnostics.trackSummary(for: item).fields + [
            PlayerDiagnostics.field("durationSeconds", item.duration.seconds)
        ])
    }

    /// Invalidates the KVO observations tied to the current player/item.
    /// Must run before the player is dropped or replaced so no observation
    /// outlives the object it watches.
    func invalidatePlayerObservers() {
        statusObserver?.invalidate()
        statusObserver = nil
        errorObserver?.invalidate()
        errorObserver = nil
        rateObserver?.invalidate()
        rateObserver = nil
        removeItemLogObservers()
        // A watchdog armed for this player must not fire into whatever
        // replaces it. (Recovery re-arms its own if the new stream stalls.)
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        stallWatchdogAwaitingResume = false
    }
}
