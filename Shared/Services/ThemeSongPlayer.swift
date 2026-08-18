import AVFoundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "ThemeSongPlayer")

/// Plays a series' theme song on the detail screen, once per visit to a show.
///
/// This is app-level rather than per-view on purpose: detail screens are
/// presented with `fullScreenCover`, so a parent view is never removed and its
/// `onDisappear` never fires. Views report intent here; all decisions live in
/// one place.
///
/// Every failure path is silence. Background music is never worth an error.
@MainActor
final class ThemeSongPlayer: ObservableObject {
    static let shared = ThemeSongPlayer()

    private var visit = ThemeSongVisitState()
    private var player: AVPlayer?
    private var fadeTimer: Timer?
    private var startTask: Task<Void, Never>?
    private var endObserver: Any?

    /// seriesId -> theme URL, or nil for "this series has no theme". Misses are
    /// cached too: ~40% of a library has none and must not be re-queried.
    private var cache: [String: URL?] = [:]

    private let startDelay: TimeInterval
    private let volume: Float = 0.6
    private let fadeIn: TimeInterval = 1.0
    private let fadeOutShowChange: TimeInterval = 0.4
    private let fadeOutHard: TimeInterval = 0.25
    private let fadeOutEnding: TimeInterval = 1.5

    /// Overridden in tests. Production resolves through JellyfinClient.
    var resolver: (String) async -> URL?

    init(startDelay: TimeInterval = 0.75) {
        self.startDelay = startDelay
        self.resolver = { seriesId in
            guard let theme = try? await JellyfinClient.shared.getThemeSongs(itemId: seriesId).first else { return nil }
            return await JellyfinClient.shared.getAudioStreamURL(itemId: theme.id)
        }
    }

    // MARK: - Intent from views

    func showAppeared(seriesId: String?) {
        guard PlaybackSettings.shared.playThemeSongs else { return }
        switch visit.showAppeared(seriesId: seriesId) {
        case .start(let id): scheduleStart(seriesId: id)
        case .stop, .ignore: break
        }
    }

    func detailDismissed(seriesId: String?) {
        switch visit.detailDismissed(seriesId: seriesId) {
        case .stop: stop(fadeOver: fadeOutShowChange)
        case .start, .ignore: break
        }
    }

    /// Play or Trailer pressed. Deliberately the fastest transition available —
    /// the theme must be gone before the player's own audio starts.
    func stopForPlayback() {
        startTask?.cancel()
        startTask = nil
        stop(fadeOver: fadeOutHard)
    }

    func appDidBackground() {
        startTask?.cancel()
        startTask = nil
        visit.reset()
        stop(fadeOver: 0)
    }

    // MARK: - Internals

    private func scheduleStart(seriesId: String) {
        startTask?.cancel()
        stop(fadeOver: fadeOutShowChange)
        startTask = Task { [weak self] in
            guard let self else { return }
            if startDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            guard let url = await resolve(seriesId: seriesId) else { return }
            guard !Task.isCancelled, visit.currentSeriesId == seriesId else { return }
            play(url: url)
        }
    }

    private func resolve(seriesId: String) async -> URL? {
        if let cached = cache[seriesId] { return cached }
        let url = await resolver(seriesId)
        cache[seriesId] = url
        return url
    }

    private func play(url: URL) {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.volume = 0
        player = p

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop(fadeOver: 0) }
        }

        p.play()
        fade(to: volume, over: fadeIn)
        logger.debug("theme song started")
    }

    private func stop(fadeOver duration: TimeInterval) {
        startTask?.cancel()
        startTask = nil
        guard player != nil else { return }
        if duration <= 0 {
            teardown()
            return
        }
        fade(to: 0, over: duration) { [weak self] in self?.teardown() }
    }

    private func teardown() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        player?.pause()
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private func fade(to target: Float, over duration: TimeInterval, completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        guard let p = player, duration > 0 else {
            player?.volume = target
            completion?()
            return
        }
        let steps = max(1, Int(duration / 0.05))
        let delta = (target - p.volume) / Float(steps)
        var remaining = steps
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, let p = self.player else { timer.invalidate(); return }
                remaining -= 1
                p.volume = remaining <= 0 ? target : p.volume + delta
                if remaining <= 0 {
                    timer.invalidate()
                    self.fadeTimer = nil
                    completion?()
                }
            }
        }
    }

    // Test seam.
    func resolveForTest(_ seriesId: String) async -> URL? { await resolve(seriesId: seriesId) }
}
