import AVFoundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "ThemeSongPlayer")

/// Fade/timing constants for `ThemeSongPlayer`, injected so tests can both
/// assert the shipped values and exercise fades without waiting on real
/// wall-clock durations.
///
/// This type exists because none of it was true before: every constant was a
/// `private let` with no test seam, which is exactly how a declared-but-
/// unused `fadeOutEnding` survived a green suite. `ThemeSongResolutionTests
/// .testShippedTimingsMatchSpec` reads these values directly so a constant
/// can't go silently unused (or silently wrong) again.
struct ThemeSongTimings {
    var startDelay: TimeInterval = 0.75
    var volume: Float = 0.6
    var fadeIn: TimeInterval = 1.0
    var fadeOutEnding: TimeInterval = 1.5
    var fadeOutShowChange: TimeInterval = 0.4
    var fadeOutHard: TimeInterval = 0.25
}

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

    /// Boundary-time token for the pre-end fade. Removed in `teardown()` on
    /// every path, exactly like `endObserver`: an `AVPlayer` time observer
    /// that outlives its player leaks the same way an un-removed
    /// `NotificationCenter` token does.
    private var endFadeBoundaryObserver: Any?

    /// Loads the current item's duration to compute the end-fade boundary.
    /// Cancelled and cleared in `teardown()`: without that, a `play()` that
    /// replaces the player mid-load could let a stale load install a
    /// boundary observer on an already-discarded `AVPlayer`.
    private var durationLoadTask: Task<Void, Never>?

    /// seriesId -> theme URL, or nil for "this series has no theme". Misses are
    /// cached too: ~40% of a library has none and must not be re-queried.
    private var cache: [String: URL?] = [:]

    private let timings: ThemeSongTimings

    /// Overridden in tests. Production resolves through JellyfinClient.
    ///
    /// Throws on a real failure (network error, cancellation) rather than
    /// swallowing it to `nil` — `resolve(seriesId:)` relies on that
    /// distinction to avoid caching a transient failure as a permanent
    /// "this series has no theme".
    var resolver: (String) async throws -> URL?

    init(timings: ThemeSongTimings = ThemeSongTimings()) {
        self.timings = timings
        self.resolver = { seriesId in
            let themes = try await JellyfinClient.shared.getThemeSongs(itemId: seriesId)
            guard let theme = themes.first else { return nil }
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
        case .stop: stop(fadeOver: timings.fadeOutShowChange)
        case .start, .ignore: break
        }
    }

    /// Play or Trailer pressed. Deliberately the fastest transition available —
    /// the theme must be gone before the player's own audio starts.
    func stopForPlayback() {
        startTask?.cancel()
        startTask = nil
        stop(fadeOver: timings.fadeOutHard)
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
        stop(fadeOver: timings.fadeOutShowChange)
        startTask = Task { [weak self] in
            guard let self else { return }
            if timings.startDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(timings.startDelay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            guard let url = await resolve(seriesId: seriesId) else { return }
            guard !Task.isCancelled, visit.currentSeriesId == seriesId else { return }
            play(url: url)
        }
    }

    private func resolve(seriesId: String) async -> URL? {
        if let cached = cache[seriesId] { return cached }
        do {
            let url = try await resolver(seriesId)
            // A cancellation can slip past a `try?`-free resolver as a normal
            // return rather than a thrown error; don't let that race cache a
            // series as themeless.
            guard !Task.isCancelled else { return nil }
            cache[seriesId] = url
            return url
        } catch {
            // A thrown error (network failure, request cancellation) is never
            // cached: it says nothing about whether the series has a theme,
            // unlike a clean empty result, which is cached above.
            logger.debug("theme resolve failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func play(url: URL) {
        // A prior player/observer must never be stranded: without this, a
        // second `play()` before the first has torn down leaks the old
        // AVPlayer and its NotificationCenter/time-observer tokens forever.
        teardown()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.volume = 0
        player = p

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop(fadeOver: 0) }
        }

        scheduleEndOfTrackFade(item: item, player: p)

        p.play()
        fade(to: timings.volume, over: timings.fadeIn)
        logger.debug("theme song started")
    }

    /// Starts the fade-out `fadeOutEnding` seconds before the theme's natural
    /// end, so the track actually fades instead of cutting — by the time
    /// `AVPlayerItemDidPlayToEndTime` fires there's no audio left to fade.
    ///
    /// `AVPlayerItem.duration` is `.indefinite` until the asset loads, so the
    /// boundary can't be computed synchronously in `play()`. Uses the async
    /// `AVAsset.load(.duration)` API rather than KVO on `item.status`/
    /// `item.duration` so there's no sixth lifecycle object to track and
    /// tear down — a `Task`, cancelled in `teardown()` exactly like
    /// `startTask`, is enough.
    private func scheduleEndOfTrackFade(item: AVPlayerItem, player: AVPlayer) {
        durationLoadTask = Task { [weak self] in
            guard let self else { return }
            let duration: CMTime
            do {
                duration = try await item.asset.load(.duration)
            } catch {
                return
            }
            // The player this load was for may already be gone by the time
            // it resolves — torn down, or replaced by a second `play()`
            // that raced this load. Installing a boundary observer on it
            // now would orphan an AVPlayer time-observer token nobody holds
            // a reference to remove: the same shape as the leak in `play()`,
            // one layer down.
            guard !Task.isCancelled, self.player === player else { return }
            guard duration.isNumeric,
                  let boundarySeconds = Self.endFadeBoundary(
                      duration: duration.seconds, fadeOutEnding: self.timings.fadeOutEnding
                  ) else {
                // Too short (or an unusable duration) to fit the fade —
                // degrade to the existing abrupt stop at end-of-track rather
                // than a negative boundary or fading immediately.
                return
            }
            let boundaryTime = CMTime(seconds: boundarySeconds, preferredTimescale: 600)
            // Both captures are weak: `player` is retained by the observer
            // registration itself, so a strong capture here would be a
            // reference cycle that only `removeTimeObserver` in `teardown()`
            // ever breaks — exactly the fragility this pass is fixing, not
            // reintroducing.
            self.endFadeBoundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: boundaryTime)], queue: .main
            ) { [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.fade(to: 0, over: self.timings.fadeOutEnding)
            }
        }
    }

    /// Pure boundary math, kept separate from the AVAsset/AVPlayer plumbing
    /// above so it's testable without loading real audio. Returns the offset
    /// (in seconds) at which the end-of-track fade should begin, or `nil`
    /// when there isn't room for one (a theme shorter than the fade, or an
    /// unusable duration).
    static func endFadeBoundary(duration: TimeInterval, fadeOutEnding: TimeInterval) -> TimeInterval? {
        guard duration.isFinite, duration > 0 else { return nil }
        let boundary = duration - fadeOutEnding
        guard boundary > 0 else { return nil }
        return boundary
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
        durationLoadTask?.cancel()
        durationLoadTask = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        if let endFadeBoundaryObserver {
            player?.removeTimeObserver(endFadeBoundaryObserver)
        }
        endFadeBoundaryObserver = nil
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
        // Built unscheduled and added to `.common` explicitly: a timer handed
        // to `Timer.scheduledTimer` installs in the default run-loop mode
        // only, so it stalls whenever tvOS switches the main run loop to
        // tracking mode (focus movement, row scrolling) — the fade freezes
        // mid-volume and its `weak self` closure is never fired again.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            Task { @MainActor in
                // The closure's body runs when the Task is *dequeued*, not
                // when the timer fires, so a newer fade can already have
                // replaced `fadeTimer` by the time this executes. Without
                // this identity check, a stale tick can nil out (and
                // therefore orphan) the timer that's actually driving the
                // current fade, and its own belated completion can later
                // tear down a theme that only just started.
                guard let self, self.fadeTimer === timer else {
                    timer.invalidate()
                    return
                }
                guard let p = self.player else {
                    timer.invalidate()
                    self.fadeTimer = nil
                    return
                }
                remaining -= 1
                p.volume = remaining <= 0 ? target : p.volume + delta
                if remaining <= 0 {
                    timer.invalidate()
                    self.fadeTimer = nil
                    completion?()
                }
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // Test seam.
    func resolveForTest(_ seriesId: String) async -> URL? { await resolve(seriesId: seriesId) }
}
