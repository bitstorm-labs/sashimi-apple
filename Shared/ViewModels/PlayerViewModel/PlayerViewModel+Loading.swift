import Foundation
import AVFoundation
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "PlayerViewModel")

extension PlayerViewModel {
    func loadMedia( // swiftlint:disable:this function_body_length
        item: BaseItemDto,
        startFromBeginning: Bool = false,
        localFileURL: URL? = nil,
        offlineSubtitles: [OfflineSubtitle] = []
    ) async {
        playbackAttempt += 1
        playbackAttemptItemID = item.id
        sameItemPlaybackAttempts = [playbackAttempt]
        pendingPlaybackEnd = nil
        navigationTask?.cancel()
        navigationTask = nil
        playbackEnded = false
        isOfflinePlayback = false
        isPlayerReady = false
        playbackReporter.reset()
        // Fresh item, fresh recovery budget; a watchdog armed for the old
        // player must not fire into the new one.
        recoveryAttempts = 0
        qualityStepDowns = 0
        activeBitrateCap = nil
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        resetTransitionState(for: item)
        diag(.loadBegin, [
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("type", item.type?.rawValue),
            PlayerDiagnostics.field("startFromBeginning", startFromBeginning),
            PlayerDiagnostics.field("offline", localFileURL != nil),
            PlayerDiagnostics.field("hadPlayer", player != nil),
            PlayerDiagnostics.field("previousItem", currentItem?.id)
        ])
        // Tuned during a break between slots: the programme starts when its
        // slot opens, so hold on an "up next" card until then. A newer load —
        // a channel change during the card — supersedes this one.
        if let until = channelContext?.breakUntil, until > Date(), let context = channelContext {
            let attempt = playbackAttempt
            player?.pause()
            stationBanner = nil
            upNext = await upNextCard(for: item, channelID: context.channelID, startsAt: until)
            let wait = until.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard attempt == playbackAttempt, !Task.isCancelled else { return }
            upNext = nil
            channelContext = ChannelPlaybackContext(
                channelID: context.channelID, startPositionSeconds: 0,
                endsAt: context.endsAt, nextItemID: context.nextItemID)
        } else {
            upNext = nil
        }
        self.offlineSubtitles = offlineSubtitles
        // Tear down everything tied to the previous player first — auto-play
        // next episode reuses this ViewModel, and observers left on the old
        // player crash when it deallocates (same teardown as changeQuality).
        // The session subtitle intent is deliberately preserved so subtitles
        // stay on across episodes; only the overlay/tracking is cleared.
        // Silence and release the outgoing player BEFORE anything awaits.
        //
        // This teardown removed the observers but never paused the player and
        // never let go of it, so the previous episode kept playing its audio
        // underneath the new one. The gap is not brief: everything below this
        // point awaits the network — stopActiveEncoding, then the playback-info
        // fetch — and the new AVPlayer is not created until well after that. On
        // tvOS the AVPlayerViewController also goes on holding the old instance
        // until the new one is assigned, so it really does keep decoding.
        //
        // changeQuality and the stop path both do this; only this one did not,
        // which is how auto-play-next and skip-credits ended up with two
        // players running.
        if player != nil {
            diag(.teardown, [
                PlayerDiagnostics.field("reason", PlayerDiagnostics.TeardownReason.newItem.rawValue),
                PlayerDiagnostics.field("outgoingItem", currentItem?.id),
                PlayerDiagnostics.field("incomingItem", item.id)
            ])
        }
        player?.pause()
        progressReportTask?.cancel()
        subtitleLoadTask?.cancel()
        navigationTask?.cancel()
        navigationTask = nil
        cleanupSegmentTracking()
        subtitleManager.clear()
        selectedSubtitleTrackId = "off"
        invalidatePlayerObservers()
        isHandlingEnd = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player = nil

        // Kill the previous episode's transcode session, same as
        // changeQuality — auto-play-next otherwise leaves the old encode
        // running until the server times it out.
        await stopActiveEncodingIfNeeded(reason: .newItem)

        isLoading = true
        error = nil
        errorMessage = nil

        do {
            let freshItem: BaseItemDto

            if let localFileURL {
                // Offline playback from local file
                freshItem = item
                setCurrentItem(item)

                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .moviePlayback)
                try audioSession.setActive(true)

                diag(.streamSelected, [
                    PlayerDiagnostics.field("kind", PlayerDiagnostics.StreamKind.localFile.rawValue),
                    PlayerDiagnostics.field("ext", localFileURL.pathExtension)
                ])
                let asset = AVURLAsset(url: localFileURL)
                diag(.assetCreated, [PlayerDiagnostics.field("kind", PlayerDiagnostics.StreamKind.localFile.rawValue)])
                let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable", "duration"])
                // Same observer wiring as the online path. loadMedia has already
                // torn down the previous endObserver, so building the player
                // directly here left downloads with no end-of-item notification
                // and no way to surface a decode failure.
                makePlayerAndObservers(for: playerItem)
            } else {
                // Online playback - fetch fresh data from server.
                // Resolve container types (Series/Season) to the episode that
                // should actually play BEFORE any PlaybackInfo request — a
                // series id posted to PlaybackInfo is a guaranteed server 500
                // (InvalidCastException to IHasMediaSources, seen in
                // production). Entry points like the Continue Watching Play
                // button and Top Shelf deep links hand over whatever item the
                // row carried, so the guarantee lives here, not in each caller.
                freshItem = try await resolvePlayableItem(client.getItem(itemId: item.id))
                setCurrentItem(freshItem)

                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .moviePlayback)
                try audioSession.setActive(true)

                try await setupPlayer(for: freshItem)
                await applyPreferredTracks()
            }

            // Set up remote control commands for Bluetooth headsets/remotes
            // On tvOS, AVPlayerViewController handles MPRemoteCommandCenter automatically
            #if os(iOS)
            setupRemoteCommands()
            #endif
            updateNowPlayingInfo(item: freshItem)

            isLoading = false

            isOfflinePlayback = localFileURL != nil
            let isOffline = isOfflinePlayback
            startNavigationLookup(for: freshItem)

            diag(.loadReady, [
                PlayerDiagnostics.field("item", freshItem.id),
                PlayerDiagnostics.field("playSession", playSessionId),
                PlayerDiagnostics.field("offline", isOffline)
            ])

            // Fetch media segments for skip intro/credits (skip when offline)
            if !isOffline {
                await fetchSegments(itemId: freshItem.id)
            }

            // Check if there's saved progress to resume from
            let thresholdTicks = Int64(playbackSettings.resumeThresholdSeconds) * 10_000_000
            if let channel = channelContext {
                // A channel supplies where the broadcast already is, which is
                // not the same question as where this viewer stopped. Taking the
                // resume branch here would drop the viewer at their own old
                // position while the channel carried on without them.
                //
                // pendingResumeTicks rather than a seek: the position is applied
                // once, from the status observer at .readyToPlay, for the same
                // reason the resume path does it there.
                resumePositionTicks = channel.startPositionTicks
                pendingResumeTicks = channel.startPositionTicks
                diag(.seek, [
                    PlayerDiagnostics.field("phase", "channel-join"),
                    PlayerDiagnostics.field("channel", channel.channelID),
                    PlayerDiagnostics.field("targetSeconds", channel.startPositionSeconds)
                ])
                // No reportPlaybackStart and no progress timer: the injected
                // reporter would discard them anyway, but not starting the timer
                // keeps a channel from waking the app every few seconds to do
                // nothing.
                setupSegmentTracking()
                playbackStartDate = Date()
                logAndPlay(positionTicks: resumePositionTicks)
            } else if startFromBeginning {
                // User explicitly chose to start over - play from beginning
                resumePositionTicks = 0
                pendingResumeTicks = 0
                if !isOffline {
                    await reportPlaybackStart(item: freshItem, positionTicks: 0)
                    startProgressReporting()
                }
                setupSegmentTracking()
                playbackStartDate = Date()
                logAndPlay(positionTicks: resumePositionTicks)
            } else if let startTicks = freshItem.userData?.playbackPositionTicks, startTicks > thresholdTicks {
                // Auto-resume from saved position (no dialog)
                resumePositionTicks = startTicks
                pendingResumeTicks = startTicks
                // NO seek here. The resume position is applied exactly once,
                // from the status observer, when the item reports .readyToPlay.
                //
                // What used to be here was `await player?.seek(to: startTime)`,
                // and it was wrong twice over:
                //
                //  1. It AWAITED a seek completion inside startup. AVFoundation
                //     only promises to call that completion when the seek
                //     finishes or is superseded, and on a stream that is not
                //     ready yet that can be seconds — or never, if the item is
                //     replaced first. Everything below it (reportPlaybackStart,
                //     progress reporting, segment tracking, and play() itself)
                //     was blocked behind it. That is a resume-only stall, and
                //     resume-only is exactly the failure boundary reported.
                //
                //  2. It armed pendingResumeTicks as well, so the SAME resume
                //     position was seeked to twice: once here, and again from
                //     applyPendingResumeSeekIfNeeded — which compares against
                //     player.currentTime(), still 0 while the first seek is in
                //     flight, so the 3-second guard never suppressed it. On a
                //     Jellyfin HLS session every seek makes the server kill the
                //     running ffmpeg and restart it at the new offset, so two
                //     seeks a second apart produce precisely the captured
                //     start -> "Stopping ffmpeg with q command" -> start ->
                //     stop pattern.
                diag(.seek, [
                    PlayerDiagnostics.field("phase", "resume-armed"),
                    PlayerDiagnostics.field("targetSeconds", Double(startTicks) / 10_000_000),
                    PlayerDiagnostics.field("startTimeTicksSentToServer", false)
                ])
                if !isOffline {
                    await reportPlaybackStart(item: freshItem, positionTicks: startTicks)
                    startProgressReporting()
                }
                setupSegmentTracking()
                playbackStartDate = Date()
                logAndPlay(positionTicks: resumePositionTicks)
            } else {
                // No saved progress - start playing immediately
                resumePositionTicks = 0
                pendingResumeTicks = 0
                if !isOffline {
                    await reportPlaybackStart(item: freshItem, positionTicks: 0)
                    startProgressReporting()
                }
                setupSegmentTracking()
                playbackStartDate = Date()
                logAndPlay(positionTicks: resumePositionTicks)
            }
        } catch {
            diagFailure(.loadFailed, [PlayerDiagnostics.field("item", item.id)] + PlayerDiagnostics.fields(for: error))
            self.error = error
            self.errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Starts playback and records the position it starts from, so a stream
    /// that begins at 0:00 when it should have resumed is visible in the log
    /// rather than only in the server's `-ss` argument.
    func logAndPlay(positionTicks: Int64) {
        diag(.play, [
            PlayerDiagnostics.field("resumeTargetSeconds", Double(positionTicks) / 10_000_000),
            PlayerDiagnostics.field("currentSeconds", player?.currentTime().seconds),
            PlayerDiagnostics.field("hasPlayer", player != nil),
            PlayerDiagnostics.field("timeControl", player.map { PlayerDiagnostics.name(timeControlStatus: $0.timeControlStatus) })
        ])
        player?.play()
        // Startup watchdog: a start that never begins playing posts NO
        // AVPlayerItemPlaybackStalled (that notification is for streams that
        // were playing and ran dry), so the stall-armed watchdog can't see
        // it. Observed live: a resume seek whose segment request hung
        // server-side (grid divergence) sat "waiting" forever with zero
        // notifications. Give a cold transcode start a generous window, then
        // treat a still-stuck start as recoverable.
        if let item = currentItem {
            armStallWatchdog(for: PlaybackGeneration(itemID: item.id, attempt: playbackAttempt), grace: 15)
        }
    }

    /// Replaces the position the item will resume to once it is ready.
    ///
    /// The iOS player uses this when a locally-saved offline position is newer
    /// than the server's. It must go through here rather than seeking the
    /// player directly: the resume seek is applied on `.readyToPlay`, so a
    /// direct seek issued before that is simply undone a moment later.
    func overrideResumePosition(ticks: Int64) {
        guard ticks > 0 else { return }
        resumePositionTicks = ticks
        pendingResumeTicks = ticks
        diag(.seek, [
            PlayerDiagnostics.field("phase", "resume-override"),
            PlayerDiagnostics.field("targetSeconds", Double(ticks) / 10_000_000)
        ])
    }

    /// Maps a container item (Series/Season) to the episode that should play:
    /// server next-up first, then first unwatched episode, then first episode
    /// (fully-watched series). Playable items pass through untouched. Throws
    /// rather than letting a non-playable id reach PlaybackInfo, so the
    /// failure is a visible "couldn't find an episode" instead of a silent
    /// server 500 mid-startup.
    func resolvePlayableItem(_ item: BaseItemDto) async throws -> BaseItemDto {
        guard let type = item.type, !type.isPlayableMediaType else {
            diag(.loadResolved, [
                PlayerDiagnostics.field("resolved", false),
                PlayerDiagnostics.field("item", item.id),
                PlayerDiagnostics.field("type", item.type?.rawValue)
            ])
            return item
        }

        if type == .series, let next = try? await client.getNextUp(seriesId: item.id, limit: 1).first {
            logResolution(from: item, to: next, via: "next-up")
            return next
        }

        // Specials last: the first unwatched regular episode, else — every
        // regular one watched — the first regular episode to start over.
        if type == .series {
            var regular = try? await client.firstRegularEpisode(seriesId: item.id, unplayedOnly: true)
            if regular == nil {
                regular = try? await client.firstRegularEpisode(seriesId: item.id, unplayedOnly: false)
            }
            if let regular {
                logResolution(from: item, to: regular, via: "first-regular")
                return regular
            }
        }

        if type == .series || type == .season {
            // For a series this searches all episodes (getItems is recursive);
            // for a season, just that season's.
            if let unwatched = try? await client.getItems(
                parentId: item.id,
                includeTypes: [.episode],
                sortBy: "ParentIndexNumber,IndexNumber",
                limit: 1,
                isPlayed: false
            ).items.first {
                logResolution(from: item, to: unwatched, via: "first-unwatched")
                return unwatched
            }
            if let first = try? await client.getItems(
                parentId: item.id,
                includeTypes: [.episode],
                sortBy: "ParentIndexNumber,IndexNumber",
                limit: 1
            ).items.first {
                logResolution(from: item, to: first, via: "first-episode")
                return first
            }
        }

        logger.error("Could not resolve \(type.rawValue, privacy: .public) \(item.id, privacy: .public) to a playable episode")
        diagFailure(.loadResolved, [
            PlayerDiagnostics.field("resolved", false),
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("type", type.rawValue),
            PlayerDiagnostics.field("outcome", "no-playable-episode")
        ])
        throw PlayerError.noPlayableEpisode(item.name)
    }

    private func logResolution(from container: BaseItemDto, to episode: BaseItemDto, via: String) {
        diag(.loadResolved, [
            PlayerDiagnostics.field("resolved", true),
            PlayerDiagnostics.field("fromType", container.type?.rawValue),
            PlayerDiagnostics.field("fromItem", container.id),
            PlayerDiagnostics.field("toItem", episode.id),
            PlayerDiagnostics.field("toType", episode.type?.rawValue),
            PlayerDiagnostics.field("via", via)
        ])
    }
}
