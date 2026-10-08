import AVFoundation

/// The mobile player's transport actions, shared by the on-screen controls
/// and the menu bar / keyboard commands so both act identically.
extension PlayerViewModel {
    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func skip(by seconds: Double) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        seek(to: max(0, current + seconds))
    }

    func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
    }

    /// Menu "Toggle Subtitles": see `SubtitleToggle`.
    func toggleSubtitles(lastSelectedID: String?) {
        let choice = SubtitleToggle.choice(
            tracks: subtitleTracks,
            selectedID: selectedSubtitleTrackId,
            lastSelectedID: lastSelectedID,
            preferredLanguage: PlaybackSettings.shared.preferredSubtitleLanguage
        )
        switch choice {
        case .off:
            disableSubtitles()
        case .track(let id):
            if let track = subtitleTracks.first(where: { $0.id == id }) {
                selectSubtitleTrack(track)
            }
        case .none:
            break
        }
    }
}
