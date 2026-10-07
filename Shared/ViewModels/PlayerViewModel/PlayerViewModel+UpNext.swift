import Foundation

/// Drives the full-screen Up Next card (`EpisodeUpNext`) once an episode has
/// ended: its countdown, Skip's look-ahead, and the actions on it.
///
/// The completion report for the finished episode has been sent before any
/// of this runs (`handlePlaybackEnded`), so whatever the viewer picks here,
/// the finished episode is already played on the server and skipped ones
/// are never reported at all.
extension PlayerViewModel {
    func presentEpisodeUpNext(_ upNext: EpisodeUpNext) {
        clearEpisodeUpNext()
        // A credits skip ends the episode early; the card is not shown over
        // credits still playing behind it.
        player?.pause()
        transitionState.endCard = upNext.kind
        episodeUpNext = upNext
        diag(.nextEpisode, [
            PlayerDiagnostics.field("upNext", "\(upNext.kind)"),
            PlayerDiagnostics.field("item", upNext.episode?.id),
            PlayerDiagnostics.field("countdown", upNext.showsCountdown)
        ])
        armUpNextCountdown()
        lookUpFollowingEpisode()
    }

    /// Drops the card and anything it had scheduled. Called on every
    /// transition, load and stop, so a countdown can never start an episode
    /// after the viewer has left the player.
    func clearEpisodeUpNext() {
        upNextCountdownTask?.cancel()
        upNextCountdownTask = nil
        upNextLookupTask?.cancel()
        upNextLookupTask = nil
        if episodeUpNext != nil {
            episodeUpNext = nil
        }
    }

    /// Play: start the episode the card shows now.
    func playUpNextEpisode() async {
        guard let episode = episodeUpNext?.episode else { return }
        // `automatic`: the finished episode was already reported complete,
        // so leaving it must not send a second (stopped) report.
        await transition(to: episode, automatic: true)
    }

    /// Cancel: stop the countdown; Play, Replay and Done stay.
    func cancelUpNext() {
        guard episodeUpNext != nil else { return }
        upNextCountdownTask?.cancel()
        upNextCountdownTask = nil
        episodeUpNext?.cancel()
    }

    /// Skip: show the episode after the one on the card, and count down
    /// again. Nothing is reported for the episode skipped.
    func skipUpNextEpisode() {
        guard var upNext = episodeUpNext, upNext.skip(at: upNextNow()) else { return }
        episodeUpNext = upNext
        armUpNextCountdown()
        lookUpFollowingEpisode()
    }

    /// The app left the foreground (iOS) — time stops until it is back.
    func pauseUpNextCountdown() {
        guard var upNext = episodeUpNext, upNext.isCountingDown else { return }
        upNext.pause(at: upNextNow())
        episodeUpNext = upNext
        upNextCountdownTask?.cancel()
        upNextCountdownTask = nil
    }

    func resumeUpNextCountdown() {
        guard var upNext = episodeUpNext, case .paused = upNext.countdown else { return }
        upNext.resume(at: upNextNow())
        episodeUpNext = upNext
        armUpNextCountdown()
    }

    /// Called when the countdown's wait ends. Plays only if the card still
    /// says time is up — a pause, Skip or Cancel in the meantime re-arms or
    /// cancels instead.
    func upNextCountdownElapsed() async {
        guard let upNext = episodeUpNext, upNext.isCountingDown else { return }
        guard upNext.isExpired(at: upNextNow()) else {
            armUpNextCountdown()
            return
        }
        await playUpNextEpisode()
    }

    private func armUpNextCountdown() {
        upNextCountdownTask?.cancel()
        upNextCountdownTask = nil
        guard let upNext = episodeUpNext, upNext.isCountingDown,
              let remaining = upNext.remaining(at: upNextNow()) else { return }
        let sleep = upNextSleep
        upNextCountdownTask = Task { [weak self] in
            do {
                try await sleep(remaining)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            // The wait is over: let go of this task before playing. The
            // transition clears the Up Next screen, which cancels
            // `upNextCountdownTask` — while that was still this task, the
            // transition cancelled itself and the next episode never loaded.
            self.upNextCountdownTask = nil
            await self.upNextCountdownElapsed()
        }
    }

    /// Finds what Skip would move to, so the button is only offered when
    /// there is somewhere to go.
    private func lookUpFollowingEpisode() {
        upNextLookupTask?.cancel()
        upNextLookupTask = nil
        guard let upNext = episodeUpNext, upNext.following == .loading,
              let episode = upNext.episode else { return }
        upNextLookupTask = Task { [weak self] in
            guard let self else { return }
            let following: BaseItemDto?
            do {
                following = try await self.episodeFollowing(episode)
            } catch {
                // A failed look-ahead just hides Skip; Play is unaffected.
                following = nil
            }
            guard !Task.isCancelled else { return }
            self.episodeUpNext?.resolveFollowing(following, after: episode.id)
        }
    }
}
