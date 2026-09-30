import Foundation
import AVFoundation

extension PlayerViewModel {
    func handlePlaybackEnded() async {
        guard let itemID = currentItem?.id else {
            playbackEnded = true
            return
        }
        await handlePlaybackEnded(itemID: itemID, attempt: playbackAttempt)
    }

    /// Offer or start the next episode of the series.
    ///
    /// Extracted from `handlePlaybackEnded` so the end-of-playback path stays
    /// within the complexity limit as it gains cases.
    ///
    /// - Returns: `true` when playback has moved on and the caller should stop.
    private func advanceToNextEpisode(after item: BaseItemDto, attempt: Int) async -> Bool {
        await waitForEpisodeNavigation(for: item)
        guard isCurrentPlaybackAttempt(itemID: item.id, attempt: attempt), !Task.isCancelled else { return true }

        switch transitionState.lookupStatus {
        case .available where transitionState.nextEpisode != nil:
            if playbackSettings.autoPlayNextEpisode {
                await autoplayNextEpisode()
                return true
            }
            if playbackSettings.showEpisodeNavigationControls {
                transitionState.endCard = .nextEpisode
            }
        case .failed:
            if playbackSettings.showEpisodeNavigationControls {
                transitionState.endCard = .lookupFailed
            }
        default:
            if playbackSettings.showEpisodeNavigationControls {
                transitionState.endCard = .finalEpisode
            }
        }
        return false
    }

    func handlePlaybackEnded(itemID: String, attempt: Int) async {
        // Guard against firing twice (e.g. a skip-to-end and the natural end
        // notification for the same item). Reset when the next item loads.
        guard beginHandlingPlaybackEnd(itemID: itemID, attempt: attempt) else { return }
        diag(.playbackEnded, [
            PlayerDiagnostics.field("item", itemID),
            PlayerDiagnostics.field("positionSeconds", player?.currentItem?.currentTime().seconds),
            PlayerDiagnostics.field("autoPlayNext", playbackSettings.autoPlayNextEpisode)
        ])

        progressReportTask?.cancel()

        if let item = currentItem {
            if !isOfflinePlayback {
                // Stopped + mark-played form one durable completion event. The
                // delivery layer persists the phase between the two requests so a
                // retry never loses completion or repeats a successful first phase.
                let duration = player?.currentItem?.duration.seconds ?? 0
                let currentSeconds = player?.currentItem?.currentTime().seconds ?? 0
                let endSeconds = duration.isFinite && duration > 0 ? duration : currentSeconds
                await playbackReporter.completed(
                    itemID: item.id,
                    positionTicks: Int64(max(0.0, endSeconds) * 10_000_000),
                    playSessionID: playSessionId
                )
            }

            guard isCurrentPlaybackAttempt(itemID: item.id, attempt: attempt), !Task.isCancelled else { return }

            // A channel decides what follows, which is rarely the next episode
            // of this series. Intercept before the episode-navigation logic
            // rather than after, or the viewer is offered a "next episode" card
            // for a programme the channel is not going to play.
            if channelContext != nil {
                await rollToNextChannelProgramme(attempt: attempt)
                return
            }

            // Lookup happens after completion is recorded. This ordering keeps
            // autoplay from starting a new server session before Jellyfin has
            // received the completed position and played marker.
            if item.type == .episode, !isOfflinePlayback {
                if await advanceToNextEpisode(after: item, attempt: attempt) { return }
            } else if item.type == .video,
                      playbackSettings.autoPlayNextEpisode,
                      let next = await fetchNextVideo(for: item) {
                guard isCurrentPlaybackAttempt(itemID: item.id, attempt: attempt), !Task.isCancelled else { return }
                // Preserve the existing automatic sequence for standalone
                // videos without exposing episode controls for them.
                diag(.nextEpisode, [
                    PlayerDiagnostics.field("item", next.id),
                    PlayerDiagnostics.field("automatic", true),
                    PlayerDiagnostics.field("kind", "video")
                ])
                await loadMedia(item: next)
                return
            }
        }

        playbackEnded = true
    }

    private func beginHandlingPlaybackEnd(itemID: String, attempt: Int) -> Bool {
        guard isCurrentPlaybackAttempt(itemID: itemID, attempt: attempt) else {
            diag(.playbackEnded, [
                PlayerDiagnostics.field("item", itemID),
                PlayerDiagnostics.field("staleAttempt", attempt),
                PlayerDiagnostics.field("suppressed", true)
            ])
            return false
        }
        guard !isHandlingEnd else {
            diag(.playbackEnded, [PlayerDiagnostics.field("suppressed", true)])
            return false
        }
        guard !deferPlaybackEndIfTransitioning(itemID: itemID, attempt: attempt) else { return false }
        isHandlingEnd = true
        return true
    }

    private func deferPlaybackEndIfTransitioning(itemID: String, attempt: Int) -> Bool {
        guard transitionState.isTransitioning else { return false }
        if isChangingQuality || isRecovering {
            pendingPlaybackEnd = PendingPlaybackEnd(itemID: itemID, attempt: attempt)
        }
        diag(.playbackEnded, [
            PlayerDiagnostics.field("suppressed", true),
            PlayerDiagnostics.field("deferred", pendingPlaybackEnd != nil)
        ])
        return true
    }

    private func isCurrentPlaybackAttempt(itemID: String, attempt: Int) -> Bool {
        guard currentItem?.id == itemID else { return false }
        return playbackAttempt == attempt ||
            (playbackAttemptItemID == itemID && sameItemPlaybackAttempts.contains(attempt))
    }

    func isCurrentPlaybackGeneration(_ generation: PlaybackGeneration) -> Bool {
        currentItem?.id == generation.itemID && playbackAttempt == generation.attempt
    }

    func requireCurrentPlaybackGeneration(_ generation: PlaybackGeneration?) throws {
        guard let generation else { return }
        guard isCurrentPlaybackGeneration(generation) else { throw CancellationError() }
    }

    func advancePlaybackAttemptForSameItem(itemID: String) {
        if playbackAttemptItemID == itemID {
            sameItemPlaybackAttempts.insert(playbackAttempt)
        } else {
            playbackAttemptItemID = itemID
            sameItemPlaybackAttempts = [playbackAttempt]
        }
        playbackAttempt += 1
        sameItemPlaybackAttempts.insert(playbackAttempt)
    }

    /// Releases the shared player-transition lock and retries a queued end
    /// notification only if it still belongs to the current item and attempt.
    /// A new-item load or stop invalidates the notification before it can be
    /// mistaken for completion of the replacement item.
    @discardableResult
    func finishTransition() -> Task<Void, Never>? {
        transitionState.isTransitioning = false
        guard let pendingPlaybackEnd else { return nil }
        self.pendingPlaybackEnd = nil
        guard isCurrentPlaybackAttempt(itemID: pendingPlaybackEnd.itemID, attempt: pendingPlaybackEnd.attempt) else {
            return nil
        }
        return Task { [weak self] in
            guard let self else { return }
            await self.handlePlaybackEnded(itemID: pendingPlaybackEnd.itemID, attempt: pendingPlaybackEnd.attempt)
        }
    }

    func playNextEpisode() async {
        guard let next = transitionState.nextEpisode else { return }
        // The end card follows the completion report, so pressing Play Next
        // there must not send a second stopped report. During active playback
        // this remains a manual transition and flushes the current position.
        await transition(to: next, automatic: playbackEnded)
    }

    func playPreviousEpisode() async {
        guard let previous = transitionState.previousEpisode else { return }
        await transition(to: previous, automatic: false)
    }

    func replayCurrentItem() async {
        guard let item = currentItem else { return }
        guard item.type?.isPlayableMediaType == true else { return }
        await transition(to: item, automatic: playbackEnded, startFromBeginning: true)
    }

    private func autoplayNextEpisode() async {
        guard let next = transitionState.nextEpisode else { return }
        await transition(to: next, automatic: true)
    }

    private func transition(to item: BaseItemDto, automatic: Bool, startFromBeginning: Bool = false) async {
        guard item.type == .episode || startFromBeginning,
              !transitionState.isTransitioning,
              automatic || !isHandlingEnd else { return }
        // Claim the transition before reporting can suspend. Repeated actions
        // must never reset the reporter or rebuild the same player concurrently.
        transitionState.isTransitioning = true
        defer { finishTransition() }
        let attempt = playbackAttempt
        player?.pause()
        progressReportTask?.cancel()
        diag(.nextEpisode, [
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("automatic", automatic)
        ])
        if !automatic {
            // A manual skip is a stop, not a completion. This flushes the
            // outgoing position through #428's lifecycle without markPlayed.
            await reportCurrentPlaybackStoppedForTransition()
        }
        guard playbackAttempt == attempt, !Task.isCancelled else { return }
        playbackEnded = false
        if let transitionLoader {
            await transitionLoader.load(item: item, startFromBeginning: startFromBeginning)
        } else {
            await loadMedia(item: item, startFromBeginning: startFromBeginning)
        }
    }
}
