import Foundation
import AVFoundation

/// Why the stream is being renegotiated mid-playback. Every case goes through
/// the same rebuild (`PlayerViewModel.rebuildStream`): tear the player down,
/// ask the server again, resume where the viewer was.
enum StreamChange: Equatable {
    case quality(QualityOption)
    /// A different audio stream. A transcode or remux carries one audio
    /// track, mapped server-side, so switching it means a new stream (#590).
    case audio(name: String)
    /// An image subtitle (PGS, VobSub) to burn into the picture (#595).
    case burnInSubtitle(name: String)
    /// Back to a stream with no burned-in subtitle.
    case removeBurnedInSubtitle
    /// Auto started on an unmeasured default and a measurement has since
    /// landed that carries a better stream (#631).
    case bandwidthMeasured

    /// Shown while the rebuild is in flight.
    func startNotice(quality: QualityOption) -> String {
        switch self {
        case .quality: return "Switching to \(quality.menuTitle)…"
        case .audio(let name): return "Switching audio to \(name)…"
        case .burnInSubtitle(let name): return "Loading subtitles: \(name)…"
        case .removeBurnedInSubtitle: return "Switching subtitles…"
        case .bandwidthMeasured: return "Improving quality for your connection…"
        }
    }

    var diagnosticName: String {
        switch self {
        case .quality: return "quality"
        case .audio: return "audio"
        case .burnInSubtitle: return "subtitle-burn-in"
        case .removeBurnedInSubtitle: return "subtitle-burn-in-removed"
        case .bandwidthMeasured: return "bandwidth-upgrade"
        }
    }
}

extension PlayerViewModel {
    func changeQuality(_ quality: QualityOption) async {
        await rebuildStream(for: .quality(quality))
    }

    /// Renegotiates the current item's stream and resumes at the same
    /// position. Returns false when a transition was already in flight and
    /// nothing was done.
    @discardableResult
    func rebuildStream(for change: StreamChange) async -> Bool { // swiftlint:disable:this function_body_length
        guard !transitionState.isTransitioning, let item = currentItem else { return false }
        // Stream rebuilds replace the same mutable player as episode
        // transitions. Claim the shared lock before the first await so two
        // rapid menu selections cannot tear down and recreate the player out
        // of order.
        transitionState.isTransitioning = true
        isChangingQuality = true
        defer {
            isChangingQuality = false
            finishTransition()
        }

        // Where the viewer is. Not the item's clock alone: a second change
        // made while the first rebuild is still loading reads zero there, and
        // the real position is the pending resume point (#593).
        let positionTicks = livePositionTicks() ?? 0

        advancePlaybackAttemptForSameItem(itemID: item.id)
        diag(.qualityChange, [
            PlayerDiagnostics.field("change", change.diagnosticName),
            PlayerDiagnostics.field("from", selectedQuality.rawValue),
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("positionSeconds", Double(positionTicks) / 10_000_000)
        ] + (change.newQuality.map { [PlayerDiagnostics.field("to", $0.rawValue)] } ?? []))

        if let quality = change.newQuality {
            selectedQuality = quality
        }
        let quality = selectedQuality
        let attempt = playbackAttempt
        // Visible confirmation: the rebuild takes seconds and, without this,
        // nothing on screen said the pick had registered.
        showPlaybackNotice(change.startNotice(quality: quality), duration: nil)

        // Stop current playback
        diag(.teardown, [
            PlayerDiagnostics.field("reason", PlayerDiagnostics.TeardownReason.qualityChange.rawValue),
            PlayerDiagnostics.field("change", change.diagnosticName),
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

        // Armed now, before anything awaits, and applied by the status
        // observer once the new item is ready. A pre-ready seek is silently
        // dropped on HLS/transcode streams, and until the seek lands this is
        // the only record of where the viewer is: leaving mid-rebuild used to
        // report position 0 and wipe the server's resume point (#593).
        if positionTicks > 0 {
            pendingResumeTicks = positionTicks
            diag(.seek, [
                PlayerDiagnostics.field("phase", "stream-change-armed"),
                PlayerDiagnostics.field("targetSeconds", Double(positionTicks) / 10_000_000)
            ])
        }

        // Kill the old transcode session before requesting a new one, so the
        // server isn't left encoding a stream nobody is watching.
        await stopActiveEncodingIfNeeded(reason: .qualityChange)
        guard playbackAttempt == attempt, !Task.isCancelled else { return true }

        do {
            // An explicit non-Auto pick forces a transcode so the selection
            // visibly takes effect: the tiers are caps, and a direct-played
            // source under the cap would otherwise make the pick a no-op.
            // The audio and subtitle streams to ask for are resolved inside
            // setupPlayer, from the session's picks.
            try await withLoadDeadline {
                try await self.setupPlayer(
                    for: item,
                    maxBitrate: quality.maxBitrate,
                    maxWidth: quality.maxWidth,
                    forceTranscode: quality != .auto
                )
            }
            guard playbackAttempt == attempt, !Task.isCancelled else { return true }
            isLoading = false
            if let notice = finishNotice(for: change) {
                showPlaybackNotice(notice)
            } else {
                clearPlaybackNotice()
            }
            updateNowPlayingInfo(item: item)

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
            scheduleStreamInfoRefresh(for: PlaybackGeneration(itemID: item.id, attempt: attempt))
        } catch {
            clearPlaybackNotice()
            diagFailure(.loadFailed, [
                PlayerDiagnostics.field("phase", "stream-change"),
                PlayerDiagnostics.field("change", change.diagnosticName),
                PlayerDiagnostics.field("item", item.id)
            ] + PlayerDiagnostics.fields(for: error))
            self.error = error
            self.errorMessage = error.localizedDescription
            isLoading = false
        }
        return true
    }

    private func finishNotice(for change: StreamChange) -> String? {
        switch change {
        case .quality, .bandwidthMeasured: return "Quality: \(qualityStatusLabel)"
        case .audio(let name): return "Audio: \(name)"
        case .burnInSubtitle(let name): return "Subtitles: \(name)"
        case .removeBurnedInSubtitle: return nil
        }
    }
}

extension PlayerViewModel {
    /// How long a stream started on an unmeasured default keeps waiting for
    /// the probe. The probe's whole retry schedule fits inside it.
    static let bandwidthUpgradeWaitLimit: Duration = .seconds(90)

    /// Watches for a bandwidth measurement under a stream Auto had to start
    /// on an unmeasured default, and rebuilds it once at the current position
    /// if the measurement carries a meaningfully better stream (#631). Audio
    /// and subtitle picks carry over through the normal rebuild path.
    func watchForMeasuredBandwidth(generation: PlaybackGeneration) {
        bandwidthUpgradeTask?.cancel()
        guard !bandwidthUpgradeDone else { return }
        let client = self.client
        bandwidthUpgradeTask = Task { [weak self] in
            // A player on a server the session never probed (another saved
            // server) still gets one measurement.
            await client.startBandwidthMeasurementIfNeverRun()
            await client.waitForAnyBandwidthMeasurement(upTo: Self.bandwidthUpgradeWaitLimit)
            while !Task.isCancelled {
                guard let self, self.isCurrentPlaybackGeneration(generation) else { return }
                let status = await client.bandwidthStatus
                guard !Task.isCancelled, self.isCurrentPlaybackGeneration(generation) else { return }
                let decision = self.upwardRenegotiation(measuredCap: status.isMeasured ? status.cap : nil)
                switch decision {
                case .none:
                    return
                case .after(let seconds):
                    try? await Task.sleep(for: .seconds(seconds))
                case .now:
                    self.bandwidthUpgradeDone = true
                    self.bandwidthUpgradeTask = nil
                    self.diag(.qualityChange, [
                        PlayerDiagnostics.field("change", StreamChange.bandwidthMeasured.diagnosticName),
                        PlayerDiagnostics.field("fromCap", self.activeBitrateCap),
                        PlayerDiagnostics.field("measuredCap", status.cap)
                    ])
                    // Unstructured, like the stall watchdog's recovery: the
                    // rebuild's teardown cancels this watcher, and that
                    // cancellation must not reach the rebuild's own awaits.
                    Task { await self.rebuildStream(for: .bandwidthMeasured) }
                    return
                }
            }
        }
    }

    /// The upward-rebuild decision for the stream that is playing now.
    func upwardRenegotiation(measuredCap: Int?, now: Date = Date()) -> PlaybackSelection.UpwardRenegotiation {
        PlaybackSelection.upwardRenegotiation(PlaybackSelection.UpwardRenegotiationContext(
            isAuto: selectedQuality == .auto && playbackSettings.maxBitrate == 0,
            startedOnUnmeasuredDefault: activeCapIsUnmeasuredDefault,
            activeCap: activeBitrateCap,
            measuredCap: measuredCap,
            hasSteppedDown: qualityStepDowns > 0,
            alreadyRenegotiated: bandwidthUpgradeDone,
            isTranscoding: currentMediaSource?.transcodingUrl?.isEmpty == false,
            sourceBitrate: currentMediaSource?.bitrate,
            isBusy: isRecovering || transitionState.isTransitioning || stallWatchdogTask != nil,
            secondsSinceRecovery: lastRecoveryAt.map { now.timeIntervalSince($0) }
        ))
    }
}

private extension StreamChange {
    var newQuality: QualityOption? {
        if case .quality(let quality) = self { return quality }
        return nil
    }
}

extension PlayerViewModel {
    /// The quality actually in force, for the player's Quality control and
    /// stream chip: "720p · 2 Mbps", or "Auto · 4 Mbps" when Auto is running
    /// under a cap below the unlimited ceiling (plain "Auto" otherwise).
    var qualityStatusLabel: String {
        if selectedQuality != .auto { return selectedQuality.menuTitle }
        guard let activeBitrateCap,
              activeBitrateCap < PlaybackSelection.maximumMeasuredBitrateCap else { return "Auto" }
        return "Auto · \(PlaybackSelection.bitrateLabel(activeBitrateCap))"
    }

    /// Shows a brief player message. `duration: nil` keeps it up until it is
    /// replaced or cleared (used while a rebuild is in flight).
    func showPlaybackNotice(_ text: String, duration: Duration? = .seconds(4)) {
        playbackNoticeTask?.cancel()
        playbackNotice = text
        guard let duration else { return }
        playbackNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.playbackNotice == text else { return }
            self.playbackNotice = nil
        }
    }

    func clearPlaybackNotice() {
        playbackNoticeTask?.cancel()
        playbackNoticeTask = nil
        playbackNotice = nil
    }

    /// Refreshes the stream chip once the rebuilt session has registered with
    /// the server. Otherwise the chip kept describing the stream that was
    /// just replaced, which read as "the quality change did nothing".
    func scheduleStreamInfoRefresh(for generation: PlaybackGeneration) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.isCurrentPlaybackGeneration(generation) else { return }
            await self.refreshStreamInfo()
        }
    }
}
