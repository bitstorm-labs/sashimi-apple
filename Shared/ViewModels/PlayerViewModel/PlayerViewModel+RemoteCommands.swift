import Foundation
import AVFoundation
import MediaPlayer

extension PlayerViewModel {
    // MARK: - Remote Control Commands (Bluetooth headsets)

    func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove handlers registered by a previous loadMedia call first —
        // auto-play-next reuses this ViewModel across episodes, and addTarget
        // stacks a new handler each time (removal otherwise only happens in
        // deinit). Mirrors the list in cleanupRemoteCommands().
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            return .success
        }

        // Toggle play/pause (what most Bluetooth headsets use)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else { return .commandFailed }
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
            return .success
        }

        // Skip forward/backward
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else { return .commandFailed }
            let currentTime = player.currentTime().seconds
            let newTime = currentTime + 15
            player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else { return .commandFailed }
            let currentTime = player.currentTime().seconds
            let newTime = max(0, currentTime - 15)
            player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
            return .success
        }
    }

    func updateNowPlayingInfo(item: BaseItemDto) {
        var nowPlayingInfo = [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyTitle] = item.name

        if let seriesName = item.seriesName {
            nowPlayingInfo[MPMediaItemPropertyArtist] = seriesName
        }

        if let runTimeTicks = item.runTimeTicks {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(runTimeTicks) / 10_000_000.0
        }

        // Elapsed must come from the PLAYER, not the server's saved position.
        // Using userData meant "Start from Beginning" showed the lock screen
        // scrubber at the old resume point and counting up from there.
        if let current = player?.currentTime().seconds, current.isFinite {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = current
        } else if let playbackPositionTicks = item.userData?.playbackPositionTicks {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(playbackPositionTicks) / 10_000_000.0
        }

        // Hard-coding 1.0 made the lock-screen clock keep advancing while
        // paused, because the system extrapolates elapsed time from the rate.
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = Double(player?.rate ?? 0)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    /// Refreshes the Now Playing elapsed time and rate for the current item.
    ///
    /// updateNowPlayingInfo was only called from loadMedia and changeQuality, so
    /// after the first paint the lock screen never heard about seeks, pauses or
    /// ordinary progress.
    func refreshNowPlayingProgress() {
        guard let item = currentItem else { return }
        updateNowPlayingInfo(item: item)
    }

    nonisolated func cleanupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
