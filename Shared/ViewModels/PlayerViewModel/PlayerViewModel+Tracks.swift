import Foundation
import AVFoundation

extension PlayerViewModel {
    /// Kept synchronous at the call boundary so the five view call sites stay
    /// unchanged, but the work now spans a suspension point: the iOS 16
    /// replacement for `mediaSelectionGroup(forMediaCharacteristic:)` is the
    /// async `loadMediaSelectionGroup(for:)`, and there is no sync equivalent.
    func loadAudioTracks() {
        Task { await loadAudioTracksIfCurrent() }
    }

    /// The generation guard is what the suspension makes necessary: the
    /// synchronous version could not be overtaken, this one can. Without it a
    /// load started for the previous episode could resolve after the next one
    /// began and publish that episode's tracks -- the same staleness the other
    /// async audio paths here already guard against.
    private func loadAudioTracksIfCurrent() async {
        if usesServerSideAudioSelection {
            loadServerSideAudioTracks()
            return
        }
        guard let playerItem = player?.currentItem, let itemID = currentItem?.id else { return }
        let generation = PlaybackGeneration(itemID: itemID, attempt: playbackAttempt)

        guard let audioGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible) else {
            guard isCurrentPlaybackGeneration(generation) else { return }
            audioTracks = []
            return
        }
        guard isCurrentPlaybackGeneration(generation) else { return }

        let options = audioGroup.options
        var tracks: [AudioTrackOption] = []
        for (index, option) in options.enumerated() {
            let locale = option.locale
            let displayName = option.displayName
            let langCode = locale?.language.languageCode?.identifier

            tracks.append(AudioTrackOption(
                id: "\(index)",
                displayName: displayName,
                languageCode: langCode,
                index: index
            ))
        }

        audioTracks = tracks

        if let currentSelection = playerItem.currentMediaSelection.selectedMediaOption(in: audioGroup),
           let currentIndex = options.firstIndex(of: currentSelection) {
            selectedAudioTrackId = "\(currentIndex)"
        }
    }

    /// Synchronous at the call boundary for the same reason as
    /// `loadAudioTracks()` -- both view call sites are sync closures (a
    /// `UIAction` handler on tvOS, a `Button` action on mobile).
    func selectAudioTrack(_ track: AudioTrackOption) {
        if usesServerSideAudioSelection {
            Task { await changeAudioStream(to: track) }
        } else {
            Task { await selectAudioTrackIfCurrent(track) }
        }
    }

    // MARK: - Server-side audio selection (#590)

    /// A transcode or remux carries ONE audio track, mapped by the server
    /// (`-map 0:N`), so AVPlayer has nothing to choose between: the menu has
    /// to list the source's streams and a pick has to renegotiate the stream.
    /// Direct play and downloads keep AVPlayer's own media selection.
    var usesServerSideAudioSelection: Bool {
        !isOfflinePlayback && currentMediaSource?.transcodingUrl?.isEmpty == false
    }

    /// The audio stream the current transcode was built with.
    var activeAudioStreamIndex: Int? {
        activeTrackRequest?.audioStreamIndex
            ?? currentMediaSource?.defaultAudioStreamIndex
            ?? currentMediaSource?.audioStreams.first?.index
    }

    /// The image subtitle burned into the current stream, if any (#595).
    var burnedInSubtitleIndex: Int? {
        guard !isOfflinePlayback, let request = activeTrackRequest, request.burnsInSubtitle else { return nil }
        return request.subtitleStreamIndex
    }

    private func loadServerSideAudioTracks() {
        audioTracks = (currentMediaSource?.audioStreams ?? []).compactMap { stream in
            guard let index = stream.index else { return nil }
            return AudioTrackOption(
                id: "\(index)",
                displayName: PlaybackSelection.audioDisplayName(for: stream),
                languageCode: stream.language,
                index: index
            )
        }
        selectedAudioTrackId = activeAudioStreamIndex.map { "\($0)" }
    }

    /// Switches the audio stream of a transcode: records the pick as the
    /// session's audio intent and rebuilds the stream through the same path a
    /// quality change uses, which resolves the intent to an `AudioStreamIndex`
    /// and resumes at the current position.
    private func changeAudioStream(to track: AudioTrackOption) async {
        guard track.index != activeAudioStreamIndex, !transitionState.isTransitioning else { return }
        let previous = sessionAudioPreference
        sessionAudioPreference = AudioPreference(language: track.languageCode, displayName: track.displayName)
        if await !rebuildStream(for: .audio(name: track.displayName)) {
            sessionAudioPreference = previous
        }
    }

    /// Ordering is deliberately identical to the previous synchronous version:
    /// `selectedAudioTrackId` and the session preference are only written after
    /// the selection actually succeeds, so a failed lookup still leaves the
    /// menu checkmark on the track that is really playing.
    private func selectAudioTrackIfCurrent(_ track: AudioTrackOption) async {
        guard let playerItem = player?.currentItem, let itemID = currentItem?.id else { return }
        let generation = PlaybackGeneration(itemID: itemID, attempt: playbackAttempt)

        guard let audioGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible),
              isCurrentPlaybackGeneration(generation),
              track.index < audioGroup.options.count else { return }

        let option = audioGroup.options[track.index]
        playerItem.select(option, in: audioGroup)
        selectedAudioTrackId = track.id
        sessionAudioPreference = AudioPreference(
            language: track.languageCode,
            displayName: track.displayName
        )
    }

    /// Re-applies the session's audio pick to a rebuilt player or a new episode.
    /// Returns false when there is no pick or nothing matches, so the caller can
    /// fall back to the Settings preference.
    @discardableResult
    func applySessionAudioPreference(expectedGeneration: PlaybackGeneration? = nil) async -> Bool {
        // On a transcode the request already carried the choice (session pick
        // or Settings language); there is nothing left to select client-side.
        if usesServerSideAudioSelection {
            loadServerSideAudioTracks()
            return true
        }
        guard let preference = sessionAudioPreference,
              let playerItem = player?.currentItem,
              let audioGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible)
        else { return false }
        guard expectedGeneration.map(isCurrentPlaybackGeneration) ?? true else { return false }

        // Prefer an exact display-name match, then fall back to language: the
        // same tiering the subtitle path uses, so "Japanese [5.1]" still
        // resolves to "Japanese" on a source that labels it differently.
        let byName = audioGroup.options.firstIndex { $0.displayName == preference.displayName }
        let byLanguage = preference.language.flatMap { language in
            // languagesMatch, not ==: a pick made on a transcode records the
            // stream's three-letter code, AVFoundation reports two-letter.
            audioGroup.options.firstIndex {
                PlaybackSelection.languagesMatch($0.locale?.language.languageCode?.identifier, language)
            }
        }
        guard let index = byName ?? byLanguage else { return false }

        playerItem.select(audioGroup.options[index], in: audioGroup)
        selectedAudioTrackId = "\(index)"
        return true
    }

    // MARK: - Settings-based track preferences

    /// Applies the Settings-preferred audio/subtitle languages when playback
    /// starts. Selections made later in the player UI naturally override
    /// these because they happen afterwards.
    func applyPreferredTracks() async {
        // A pick made in the player this session beats the Settings default,
        // mirroring how subtitles behave just below.
        if await !applySessionAudioPreference() {
            await applyPreferredAudioLanguage()
        }
        // The session's subtitle intent (a selection made in the player,
        // e.g. during the previous episode) wins over the Settings-based
        // preference — subtitles stay on until manually turned off.
        if !applySessionSubtitlePreference() {
            applyPreferredSubtitles(audioLanguage: await selectedAudioLanguage())
        }
    }

    /// The language of the audio that is playing, best answer available
    /// without waiting: the stream a transcode was built with, else the
    /// source's default audio stream (what AVPlayer starts on for direct
    /// play). Picks forced subtitles when nothing else asks for subtitles.
    var playingAudioLanguageHint: String? {
        guard let source = currentMediaSource else { return nil }
        let streams = source.audioStreams
        if let index = activeAudioStreamIndex, let stream = streams.first(where: { $0.index == index }) {
            return stream.language
        }
        return streams.first?.language
    }

    /// The language AVPlayer actually selected, for direct play, where the
    /// Settings preference may have switched away from the default track.
    private func selectedAudioLanguage() async -> String? {
        guard !usesServerSideAudioSelection,
              let playerItem = player?.currentItem,
              let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible),
              let option = playerItem.currentMediaSelection.selectedMediaOption(in: group),
              let code = option.locale?.language.languageCode?.identifier ?? option.extendedLanguageTag
        else { return playingAudioLanguageHint }
        return code
    }

    /// Re-applies the session's subtitle intent against the current media
    /// source. Returns false when there is no intent or no matching stream,
    /// so callers can fall back to the Settings-based preference.
    @discardableResult
    func applySessionSubtitlePreference() -> Bool {
        guard let preference = sessionSubtitlePreference,
              let stream = PlaybackSelection.matchingSubtitleStream(
                in: currentMediaSource?.subtitleStreams ?? [],
                language: preference.language,
                displayTitle: preference.displayTitle,
                isExternal: preference.isExternal
              ) else { return false }

        selectSubtitleTrack(Self.subtitleTrackOption(for: stream), isUserSelection: false)
        return true
    }

    func applyPreferredAudioLanguage(expectedGeneration: PlaybackGeneration? = nil) async {
        let preferred = playbackSettings.preferredAudioLanguage
        guard !usesServerSideAudioSelection, !preferred.isEmpty, let playerItem = player?.currentItem else { return }

        // appliesMediaSelectionCriteriaAutomatically is false, so the default
        // track plays unless we pick one explicitly.
        guard let audioGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible) else { return }
        guard expectedGeneration.map(isCurrentPlaybackGeneration) ?? true else { return }

        let codes = audioGroup.options.map { $0.locale?.language.languageCode?.identifier }
        if let index = PlaybackSelection.preferredAudioOptionIndex(languageCodes: codes, preferredLanguage: preferred) {
            playerItem.select(audioGroup.options[index], in: audioGroup)
            selectedAudioTrackId = "\(index)"
        }
    }

    /// `audioLanguage` decides which forced track (if any) shows when
    /// subtitles are off or nothing matches the preference; nil uses
    /// `playingAudioLanguageHint`.
    func applyPreferredSubtitles(audioLanguage: String? = nil) {
        guard let mediaSource = currentMediaSource,
              let stream = PlaybackSelection.preferredSubtitleStream(
                from: mediaSource.subtitleStreams,
                preferredLanguage: playbackSettings.preferredSubtitleLanguage,
                subtitlesEnabled: playbackSettings.subtitlesEnabled,
                audioLanguage: audioLanguage ?? playingAudioLanguageHint
              ) else { return }

        selectSubtitleTrack(Self.subtitleTrackOption(for: stream), isUserSelection: false)
    }

    /// Builds a menu option for a Jellyfin subtitle stream using the same
    /// id/display scheme as loadSubtitleTracks(), so selections made through
    /// any path stay consistent with the subtitle menu.
    private static func subtitleTrackOption(for stream: MediaStream) -> SubtitleTrackOption {
        SubtitleTrackOption(
            id: "\(stream.index ?? 0)",
            displayName: PlaybackSelection.subtitleDisplayName(for: stream),
            languageCode: stream.language,
            index: stream.index ?? 0,
            isOffOption: false,
            isExternal: stream.isExternal ?? false
        )
    }

    func loadSubtitleTracks() {
        var tracks: [SubtitleTrackOption] = []

        // Add "Off" option first
        tracks.append(SubtitleTrackOption(
            id: "off",
            displayName: "Off",
            languageCode: nil,
            index: -1,
            isOffOption: true
        ))

        // Offline playback has no media source, so the downloaded files are the
        // only thing that can populate this menu.
        if isOfflinePlayback {
            for subtitle in offlineSubtitles {
                tracks.append(SubtitleTrackOption(
                    id: "\(subtitle.index)",
                    displayName: subtitle.displayTitle,
                    languageCode: subtitle.language,
                    index: subtitle.index,
                    isOffOption: false,
                    isExternal: true
                ))
            }
        } else if let mediaSource = currentMediaSource {
            let subtitleStreams = mediaSource.subtitleStreams
            for stream in subtitleStreams {
                tracks.append(SubtitleTrackOption(
                    id: "\(stream.index ?? 0)",
                    displayName: PlaybackSelection.subtitleDisplayName(for: stream),
                    languageCode: stream.language,
                    index: stream.index ?? 0,
                    isOffOption: false,
                    isExternal: stream.isExternal ?? false
                ))
            }
        }

        subtitleTracks = tracks
        // Keep a still-valid selection (e.g. the Settings-based pre-selection
        // applied when playback started) — this runs from the player UI's
        // onAppear and used to unconditionally reset the menu to "Off" even
        // while subtitles were showing.
        if !tracks.contains(where: { $0.id == selectedSubtitleTrackId }) {
            selectedSubtitleTrackId = "off"
        }
    }

    /// Selects a subtitle track. `isUserSelection` distinguishes a manual
    /// pick in the player UI (persisted as the user's preference) from the
    /// automatic re-application paths (Settings preference, quality change,
    /// next episode), which must not overwrite the stored preference.
    func selectSubtitleTrack(_ track: SubtitleTrackOption, isUserSelection: Bool = true) {
        // A newer selection supersedes any in-flight subtitle load — racing
        // loads used to call startTracking against a stale player.
        subtitleLoadTask?.cancel()

        if track.isOffOption {
            if isUserSelection {
                // Manual "Off" — same persistence semantics as the views
                // that call disableSubtitles() directly.
                disableSubtitles()
            } else {
                selectedSubtitleTrackId = "off"
                subtitleManager.clear()
            }
            return
        }

        // An image subtitle (PGS, VobSub) has no text form: the only way to
        // show it is for the server to burn it into the video, which means a
        // new stream (#595). Selecting one used to move the checkmark and
        // render nothing.
        let needsBurnIn = isImageSubtitleTrack(track)
        let needsRebuild = needsBurnIn ? burnedInSubtitleIndex != track.index : burnedInSubtitleIndex != nil
        if needsRebuild {
            // A rebuild cannot start while another transition holds the
            // player; ignore the pick rather than record an intent the stream
            // does not match. Automatic re-applies never start a burn-in:
            // setupPlayer has already asked for whatever the session wanted.
            guard isUserSelection, !transitionState.isTransitioning else { return }
        }

        selectedSubtitleTrackId = track.id

        if isUserSelection {
            // Remember the session's subtitle intent by content so it
            // survives quality changes and episode transitions (stream
            // indexes don't). Only manual picks may write this — automatic
            // re-applies can resolve via a weaker fallback tier (e.g.
            // embedded "English" for an external "English (SDH)" pick), and
            // storing that match would permanently degrade the intent.
            sessionSubtitlePreference = SubtitlePreference(
                language: track.languageCode,
                displayTitle: track.displayName,
                isExternal: track.isExternal
            )
            // "On stays on until I turn it off" — persist the manual choice
            // across app launches too.
            playbackSettings.subtitlesEnabled = true
            if let language = track.languageCode, !language.isEmpty {
                playbackSettings.preferredSubtitleLanguage = language
            }
        }

        if needsRebuild {
            let change: StreamChange = needsBurnIn ? .burnInSubtitle(name: track.displayName) : .removeBurnedInSubtitle
            Task { await rebuildStream(for: change) }
            return
        }
        if needsBurnIn {
            // Already in the picture; there is no overlay to load.
            subtitleManager.clear()
            return
        }

        guard let item = currentItem, let player = player else { return }

        // Load and display subtitles via our custom overlay. Capture the
        // player at creation: by the time the load finishes the player
        // may have been rebuilt (quality change / next episode), and
        // tracking a stale player would leave a live observer on it.
        let capturedPlayer = player
        subtitleLoadTask = Task {
            let loaded: Bool
            if isOfflinePlayback,
               let downloaded = offlineSubtitles.first(where: { $0.index == track.index }) {
                loaded = await subtitleManager.loadSubtitles(fileURL: downloaded.fileURL)
            } else {
                loaded = await subtitleManager.loadSubtitles(
                    itemId: item.id,
                    subtitleIndex: track.index,
                    serverID: serverID
                )
            }
            guard !Task.isCancelled, self.player === capturedPlayer else { return }
            guard loaded else {
                // Say so, and take the checkmark off a track that is not
                // showing. The saved preference is left alone: the next item
                // may well have a track that loads.
                if selectedSubtitleTrackId == track.id { selectedSubtitleTrackId = "off" }
                showPlaybackNotice("Couldn't load subtitles: \(track.displayName)")
                return
            }
            subtitleManager.startTracking(player: capturedPlayer)
        }
    }

    /// Turns subtitles off through the same path as selecting the "Off" track
    /// option: sets the "off" sentinel AND clears the subtitle overlay. Views
    /// must use this instead of mutating `selectedSubtitleTrackId` directly,
    /// which would leave the current subtitles on screen.
    ///
    /// This is the ONLY place (besides stop()) that drops the session
    /// subtitle intent, and it persists the "off" choice — subtitles stay
    /// off across episodes and app launches until re-enabled.
    func disableSubtitles() {
        // A burned-in subtitle is part of the picture: turning it off means a
        // new stream, which cannot start while another transition is running.
        let removesBurnIn = burnedInSubtitleIndex != nil
        if removesBurnIn, transitionState.isTransitioning { return }
        subtitleLoadTask?.cancel()
        selectedSubtitleTrackId = "off"
        subtitleManager.clear()
        sessionSubtitlePreference = nil
        playbackSettings.subtitlesEnabled = false
        if removesBurnIn {
            Task { await rebuildStream(for: .removeBurnedInSubtitle) }
        }
    }

    /// Whether a menu entry is an image subtitle of the current online source.
    /// Downloads only ever carry text subtitles (as .vtt files).
    private func isImageSubtitleTrack(_ track: SubtitleTrackOption) -> Bool {
        guard !isOfflinePlayback,
              let stream = currentMediaSource?.subtitleStreams.first(where: { $0.index == track.index })
        else { return false }
        return PlaybackSelection.isImageSubtitle(stream)
    }

    func loadAllTracks() {
        loadAudioTracks()
        loadSubtitleTracks()
    }
}
