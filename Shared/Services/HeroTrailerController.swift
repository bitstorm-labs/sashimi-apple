import AVFoundation
import Combine
import SwiftUI
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "HeroTrailer")

/// Timings for `HeroTrailerController`, injectable so tests don't wait on the
/// shipped delays (the same reason `ThemeSongTimings` exists).
struct HeroTrailerTimings {
    /// The image shows first; the trailer only starts once the screen has
    /// settled, so flicking past a title costs no transcode.
    var startDelay: TimeInterval = 2.0
    /// How long the hero cross-fades between image and video.
    var crossFade: TimeInterval = 0.6
}

/// Plays a local trailer where a detail screen's backdrop is (#658).
///
/// App-level for the same reason as `ThemeSongPlayer`: tvOS detail screens are
/// presented with `fullScreenCover`, so a covered screen never disappears.
/// Screens report intent; `HeroTrailerOwners` decides which one shows the one
/// player. Every failure path is the plain image.
@MainActor
final class HeroTrailerController: ObservableObject {
    static let shared = HeroTrailerController()

    /// The screen whose hero shows `player`.
    @Published private(set) var activeOwner: UUID?
    @Published private(set) var player: AVPlayer?
    /// True once the trailer is actually producing frames; drives the fade.
    @Published private(set) var isVisible = false

    private var owners = HeroTrailerOwners()
    private var playingSourceId: String?
    /// The source of a trailer that's waiting out its start delay. Until it
    /// plays, this is what a screen for the same show takes over (#668).
    private var pendingSourceId: String?
    private var playSessionId: String?
    private var startTask: Task<Void, Never>?
    private var endObservers: [Any] = []
    private var timeObserver: Any?
    private var fadeObserver: Any?
    private var clip: HeroTrailerClip?
    /// The playing trailer's length rules and reported length.
    private var kind: HeroTrailerPolicy.Kind?
    private var trailerSeconds: Double?
    /// A series' trailer that a theme song has lifted off its fixed length:
    /// it now ends with the theme.
    private var isFollowingTheme = false
    private var isFinishing = false
    private var themeSubscriptions: Set<AnyCancellable> = []
    private let timings: HeroTrailerTimings

    /// sourceId -> its trailer, or nil for "no trailer". Misses are cached so
    /// a trailerless show isn't asked again; thrown errors are not.
    private var cache: [String: HeroTrailerSource?] = [:]

    /// Overridden in tests; production goes through `JellyfinClient`.
    var resolver: (String) async throws -> HeroTrailerSource?
    var streamBuilder: (String) async -> HeroTrailerStream?
    var encodingStopper: (String) async -> Void
    var themeIsPlaying: () -> Bool
    /// True while the theme is fading out at its natural end.
    var themeIsEnding: () -> Bool
    var isEligible: (_ screenServerId: String?) -> Bool

    init(timings: HeroTrailerTimings = HeroTrailerTimings()) {
        self.timings = timings
        resolver = { sourceId in
            HeroTrailerSource(trailers: try await JellyfinClient.shared.getLocalTrailers(itemId: sourceId))
        }
        let screen = HeroTrailerStream.Screen.current
        streamBuilder = { trailerId in
            await JellyfinClient.shared.heroTrailerStream(trailerId: trailerId, screen: screen)
        }
        encodingStopper = { playSessionId in
            try? await JellyfinClient.shared.stopActiveEncoding(playSessionId: playSessionId)
        }
        themeIsPlaying = { ThemeSongPlayer.shared.isPlaying }
        themeIsEnding = { ThemeSongPlayer.shared.isEndingNaturally }
        isEligible = { screenServerId in
            let network = NetworkMonitor.shared
            return HeroTrailerPolicy.Conditions(
                settingOn: PlaybackSettings.shared.playHeroTrailers,
                isOnline: network.isOnline,
                isExpensive: network.isExpensive,
                isConstrained: network.isConstrained,
                screenServerId: screenServerId,
                activeServerId: SessionManager.shared.activeServerId
            ).isEligible
        }
        ThemeSongPlayer.shared.$isPlaying
            .sink { [weak self] playing in
                Task { @MainActor in self?.themeStateChanged(isPlaying: playing) }
            }
            .store(in: &themeSubscriptions)
        // Only the theme's natural end ends a series' trailer: a theme stopped
        // for navigation, playback or the background already stops the
        // trailer through the same path.
        ThemeSongPlayer.shared.$isEndingNaturally
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in self?.themeEndedNaturally() }
            }
            .store(in: &themeSubscriptions)
    }

    // MARK: - Intent from views

    func screenAppeared(owner: UUID, item: BaseItemDto, serverID: String?) {
        let sourceId = isEligible(serverID) ? HeroTrailerPolicy.trailerSourceId(for: item) : nil
        apply(
            owners.appeared(owner: owner, sourceId: sourceId, playingSourceId: currentSourceId),
            kind: HeroTrailerPolicy.kind(for: item)
        )
    }

    /// A screen with no hero of its own (a person page) covering a detail
    /// screen: the trailer underneath must not keep playing behind it.
    func coveringScreenAppeared(owner: UUID) {
        apply(owners.appeared(owner: owner, sourceId: nil, playingSourceId: currentSourceId))
    }

    func screenDismissed(owner: UUID) {
        apply(owners.dismissed(owner: owner, playingSourceId: currentSourceId))
    }

    /// Play, Trailer or Shuffle pressed: the trailer must be gone before the
    /// player's own audio starts.
    func stopForPlayback() {
        stop()
    }

    func appDidBackground() {
        stop()
    }

    /// A theme that starts after the trailer silences it; one that ends
    /// doesn't bring the sound back, so audio never appears out of nowhere.
    /// A series' trailer then ends with the theme instead of after its fixed
    /// length.
    func themeStateChanged(isPlaying: Bool) {
        if HeroTrailerPolicy.shouldMute(themeIsPlaying: isPlaying) {
            player?.isMuted = true
        }
        guard isPlaying, kind == .series, !isFollowingTheme, !isFinishing, player != nil else { return }
        isFollowingTheme = true
        setClip(HeroTrailerPolicy.followingTheme(trailerSeconds: trailerSeconds))
    }

    /// The theme a series' trailer follows has begun its natural end: the
    /// trailer fades out with it, once it has played its minimum.
    func themeEndedNaturally() {
        guard kind == .series, isFollowingTheme, !isFinishing, let player else { return }
        isFollowingTheme = false
        let position = player.currentTime().seconds
        setClip(HeroTrailerPolicy.afterThemeEnded(
            trailerSeconds: trailerSeconds,
            position: position.isFinite ? position : 0,
            crossFade: timings.crossFade
        ))
    }

    // MARK: - Internals

    /// The trailer this visit has, playing or about to.
    private var currentSourceId: String? { playingSourceId ?? pendingSourceId }

    /// `kind` is the appearing screen's; only an appearing screen can start
    /// a trailer.
    private func apply(_ decision: HeroTrailerOwners.Decision, kind: HeroTrailerPolicy.Kind? = nil) {
        switch decision {
        case .start(let sourceId):
            stop()
            activeOwner = owners.topOwner
            scheduleStart(sourceId: sourceId, kind: kind ?? .series)
        case .handOff:
            activeOwner = owners.topOwner
        case .stop:
            stop()
            activeOwner = owners.topOwner
        case .ignore:
            break
        }
    }

    /// Waits, then plays. A screen for the same show that opens meanwhile is
    /// handed the start, so only a stop (which cancels this task) ends it.
    private func scheduleStart(sourceId: String, kind: HeroTrailerPolicy.Kind) {
        pendingSourceId = sourceId
        startTask = Task { [weak self] in
            await self?.start(sourceId: sourceId, kind: kind)
            guard let self, !Task.isCancelled else { return }
            pendingSourceId = nil
        }
    }

    private func start(sourceId: String, kind: HeroTrailerPolicy.Kind) async {
        if timings.startDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(timings.startDelay * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        guard let trailer = await resolveTrailer(sourceId: sourceId) else { return }
        guard !Task.isCancelled else { return }
        guard let stream = await streamBuilder(trailer.id) else { return }
        guard !Task.isCancelled else {
            if let session = stream.playSessionId { await encodingStopper(session) }
            return
        }
        play(stream: stream, sourceId: sourceId, kind: kind, trailerSeconds: trailer.seconds)
    }

    private func resolveTrailer(sourceId: String) async -> HeroTrailerSource? {
        if let cached = cache[sourceId] { return cached }
        do {
            let trailer = try await resolver(sourceId)
            guard !Task.isCancelled else { return nil }
            cache[sourceId] = trailer
            return trailer
        } catch {
            logger.debug("trailer lookup failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    private func play(stream: HeroTrailerStream, sourceId: String, kind: HeroTrailerPolicy.Kind, trailerSeconds: Double?) {
        let item = AVPlayerItem(url: stream.url)
        // No forwardPlaybackEndTime: set past the real end of a short trailer,
        // it suppresses the end-of-item notification and the player sits on
        // the last frame. The fade point below ends the clip; the item's own
        // end (or failure) is the fallback.
        let p = AVPlayer(playerItem: item)
        let themePlaying = themeIsPlaying()
        p.isMuted = HeroTrailerPolicy.shouldMute(themeIsPlaying: themePlaying)
        // Background video must never take over Now Playing or AirPlay.
        p.allowsExternalPlayback = false
        player = p
        playingSourceId = sourceId
        playSessionId = stream.playSessionId
        self.kind = kind
        self.trailerSeconds = trailerSeconds
        let clip = initialClip(kind: kind, trailerSeconds: trailerSeconds, themePlaying: themePlaying)

        endObservers = [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.finish() }
            }
        }
        // Reveal only once frames are actually flowing, so a slow transcode
        // start never fades the image out to black.
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self, weak p] time in
            MainActor.assumeIsolated {
                // Not while finishing: the observer keeps firing during the
                // fade-out and would snap the picture back.
                guard let self, let p, self.player === p, !self.isVisible, !self.isFinishing,
                      time.seconds > clip.start + 0.1 else { return }
                self.isVisible = true
            }
        }
        setClip(clip)
        if clip.start > 0 {
            p.seek(
                to: CMTime(seconds: clip.start, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
            )
        }
        p.play()
        logger.debug("hero trailer started")
    }

    /// Where a trailer starting now ends. A series' trailer starting under a
    /// theme follows it; one starting as the theme fades out ends with it.
    private func initialClip(kind: HeroTrailerPolicy.Kind, trailerSeconds: Double?, themePlaying: Bool) -> HeroTrailerClip {
        guard kind == .series, themePlaying else {
            return HeroTrailerPolicy.clip(trailerSeconds: trailerSeconds, kind: kind)
        }
        if themeIsEnding() {
            let start = HeroTrailerPolicy.clip(trailerSeconds: trailerSeconds, kind: kind).start
            return HeroTrailerPolicy.afterThemeEnded(
                trailerSeconds: trailerSeconds, position: start, crossFade: timings.crossFade
            )
        }
        isFollowingTheme = true
        return HeroTrailerPolicy.followingTheme(trailerSeconds: trailerSeconds)
    }

    /// Moves the clip's end, replacing the fade point. Fades out while the
    /// last moments still play rather than on a frozen frame with the sound
    /// cut mid-word. An infinite end has no fade point: the item's own end
    /// finishes it. An end already reached finishes now.
    private func setClip(_ clip: HeroTrailerClip) {
        guard let p = player else { return }
        self.clip = clip
        if let fadeObserver { p.removeTimeObserver(fadeObserver) }
        fadeObserver = nil
        guard clip.end.isFinite else { return }
        let fadeAt = max(clip.start, clip.end - timings.crossFade)
        let position = p.currentTime().seconds
        if position.isFinite, position > clip.start, position >= fadeAt {
            finish()
            return
        }
        fadeObserver = p.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: fadeAt, preferredTimescale: 600))], queue: .main
        ) { [weak self, weak p] in
            MainActor.assumeIsolated {
                guard let self, let p, self.player === p else { return }
                self.finish()
            }
        }
    }

    /// End of the clip: fade picture and sound back to the image, then let go
    /// of the player. Reached from the fade point or the item's own end,
    /// whichever comes first; a later call finds the fade already under way.
    private func finish() {
        guard let finishing = player, !isFinishing else { return }
        isFinishing = true
        isVisible = false
        let delay = timings.crossFade
        Task { [weak self] in
            let steps = 6
            let startVolume = finishing.volume
            for step in 1...steps where delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay / Double(steps) * 1_000_000_000))
                guard self?.player === finishing else { return }
                finishing.volume = startVolume * Float(steps - step) / Float(steps)
            }
            guard let self, self.player === finishing else { return }
            self.teardown()
        }
    }

    private func stop() {
        startTask?.cancel()
        startTask = nil
        pendingSourceId = nil
        isVisible = false
        teardown()
    }

    private func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let fadeObserver { player?.removeTimeObserver(fadeObserver) }
        fadeObserver = nil
        endObservers.forEach { NotificationCenter.default.removeObserver($0) }
        endObservers = []
        clip = nil
        kind = nil
        trailerSeconds = nil
        isFollowingTheme = false
        isFinishing = false
        player?.pause()
        player = nil
        playingSourceId = nil
        if let session = playSessionId {
            let stopper = encodingStopper
            Task { await stopper(session) }
        }
        playSessionId = nil
    }

    // MARK: - Test seams

    #if DEBUG
    var playingSourceIdForTest: String? { playingSourceId }
    var clipForTest: HeroTrailerClip? { clip }
    func finishForTest() { finish() }
    func waitForStartForTest() async { await startTask?.value }
    #endif
}

extension View {
    /// Overlays this screen's hero trailer on its backdrop. Reports intent to
    /// `HeroTrailerController` only; the image underneath is always the
    /// fallback.
    func heroTrailer(for item: BaseItemDto, serverID: String?) -> some View {
        overlay { HeroTrailerOverlay(item: item, serverID: serverID) }
    }
}

extension View {
    /// For a screen without a hero that can cover a detail screen: stops the
    /// trailer underneath while it's showing.
    func silencesHeroTrailer() -> some View {
        modifier(HeroTrailerSilencer())
    }
}

private struct HeroTrailerSilencer: ViewModifier {
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { HeroTrailerController.shared.coveringScreenAppeared(owner: owner) }
            .onDisappear { HeroTrailerController.shared.screenDismissed(owner: owner) }
    }
}

private struct HeroTrailerOverlay: View {
    let item: BaseItemDto
    let serverID: String?
    @State private var owner = UUID()
    @ObservedObject private var controller = HeroTrailerController.shared

    var body: some View {
        let isOwner = controller.activeOwner == owner
        // The video view stays in the hierarchy for the screen's whole life
        // and only its player and opacity change. The iPad and Apple TV heroes
        // mask the image and this overlay together; removing a UIKit view from
        // inside a SwiftUI mask left the image underneath undrawn, a blank
        // spot where the image should come back.
        HeroTrailerVideo(player: isOwner ? controller.player : nil)
            .opacity(isOwner && controller.isVisible ? 1 : 0)
            .animation(.easeInOut(duration: HeroTrailerTimings().crossFade), value: controller.isVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { controller.screenAppeared(owner: owner, item: item, serverID: serverID) }
        .onDisappear { controller.screenDismissed(owner: owner) }
    }
}

/// An `AVPlayerLayer` filling its frame, cropped like the image it covers.
private struct HeroTrailerVideo: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        // swiftlint:disable:next force_cast
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Everything a detail screen plays in the background: the theme song and the
/// hero trailer. Call sites that start playback or leave the app go through
/// here so neither can be forgotten.
@MainActor
enum DetailAmbience {
    static func stopForPlayback() {
        ThemeSongPlayer.shared.stopForPlayback()
        HeroTrailerController.shared.stopForPlayback()
    }

    static func appDidBackground() {
        ThemeSongPlayer.shared.appDidBackground()
        HeroTrailerController.shared.appDidBackground()
    }
}
