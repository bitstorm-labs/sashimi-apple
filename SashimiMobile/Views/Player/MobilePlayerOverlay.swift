import AVFoundation
import NukeUI
import SwiftUI

/// iPad or iPhone sizing for the player overlay.
enum MobilePlayerOverlayLayout {
    case pad, phone

    @MainActor
    static var current: MobilePlayerOverlayLayout {
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }

    var infoBar: PlayerInfoBarMetrics { self == .pad ? .pad : .phone }
    var primaryButton: CGFloat { self == .pad ? 84 : 64 }
    var secondaryButton: CGFloat { self == .pad ? 60 : 48 }
    var transportSpacing: CGFloat { self == .pad ? 44 : 28 }
    var edgePadding: CGFloat { self == .pad ? 28 : 16 }
}

/// The iPhone/iPad player's controls, drawn entirely by the app in the Apple
/// TV player's style: the tvOS info bar across the top, large transport in the
/// middle, and a row of pills over a full-width scrubber at the bottom.
/// AVKit draws nothing.
struct MobilePlayerOverlay: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var viewModes: VideoViewModeStore
    @ObservedObject var pictureInPicture: PictureInPictureModel
    /// The item on screen (the view model's, after a transition).
    let item: BaseItemDto
    var serverID: String?
    let isOffline: Bool
    /// Show ⏮/⏭ beside the transport (the episode-navigation setting).
    let showsEpisodeNavigation: Bool
    let layout: MobilePlayerOverlayLayout
    @Binding var isVisible: Bool
    @Binding var playbackSpeed: Float
    /// Any interaction: restarts the auto-hide timer.
    let onInteract: () -> Void
    /// The finger is on the scrubber: the overlay must not hide meanwhile.
    var onScrubbing: (Bool) -> Void = { _ in }
    let onClose: () -> Void
    /// Fixed playback state for previews and snapshot tests; nil reads the player.
    var fixedSnapshot: PlaybackSnapshot?
    var fixedClock: Date?

    var body: some View {
        ZStack {
            // Tapping the picture shows or hides the controls.
            Button {
                isVisible.toggle()
                onInteract()
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible ? "Hide Playback Controls" : "Show Playback Controls")

            if isVisible {
                VStack(spacing: 0) {
                    topBand
                    Spacer(minLength: 0)
                    bottomBand
                }
                .transition(.opacity)

                transport
                    .transition(.opacity)

                // Channel up/down on a touch screen: explicit buttons rather
                // than a swipe, which is easy to trigger by accident.
                if viewModel.isWatchingStation {
                    HStack {
                        Spacer()
                        MobileChannelStepper(
                            onUp: { onInteract(); Task { await viewModel.changeStation(by: -1) } },
                            onDown: { onInteract(); Task { await viewModel.changeStation(by: 1) } }
                        )
                        .padding(.trailing, layout.edgePadding)
                    }
                    .transition(.opacity)
                }
            }

            // Skip intro/credits stays up whether or not the controls are.
            VStack {
                Spacer()
                skipButton
                    .padding(.bottom, isVisible ? (layout == .pad ? 150 : 124) : 32)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isVisible)
    }

    // MARK: - Top band (the tvOS info bar)

    private var topBand: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = fixedClock ?? context.date
            let snapshot = fixedSnapshot ?? PlaybackSnapshot.read(viewModel.player)
            HStack(alignment: .center, spacing: layout == .pad ? 18 : 12) {
                closeButton
                PlayerInfoBar(
                    item: item,
                    resolution: viewModel.videoResolution,
                    finishesAt: snapshot.duration > 0
                        ? PlayerInfoText.finishesAt(remaining: snapshot.remaining, rate: snapshot.rate, now: now)
                        : nil,
                    // Offline there is no server session to describe.
                    streamInfo: isOffline ? nil : viewModel.streamInfo,
                    clock: ClockTime.time(now),
                    metrics: layout.infoBar
                ) { artwork in
                    MobileInfoBarArtwork(
                        artwork: artwork,
                        seriesName: item.seriesName,
                        serverID: serverID,
                        metrics: layout.infoBar
                    )
                }
            }
            .padding(.horizontal, layout.edgePadding)
            .padding(.top, layout == .pad ? 16 : 10)
            .padding(.bottom, layout == .pad ? 16 : 10)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.4), ignoresSafeAreaEdges: .top)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.16))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Player")
    }

    // MARK: - Center transport

    private var transport: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let snapshot = fixedSnapshot ?? PlaybackSnapshot.read(viewModel.player)
            HStack(spacing: layout.transportSpacing) {
                if showsEpisodeNavigation {
                    transportButton("Previous Episode", "backward.end.fill", enabled: viewModel.transitionState.canPlayPrevious) {
                        Task { await viewModel.playPreviousEpisode() }
                    }
                }
                transportButton("Skip Backward 10 Seconds", "gobackward.10") { seek(by: -10) }
                transportButton(
                    snapshot.isPlaying ? "Pause" : "Play",
                    snapshot.isPlaying ? "pause.fill" : "play.fill",
                    isPrimary: true,
                    action: togglePlayPause
                )
                transportButton("Skip Forward 10 Seconds", "goforward.10") { seek(by: 10) }
                if showsEpisodeNavigation {
                    transportButton("Next Episode", "forward.end.fill", enabled: viewModel.transitionState.canPlayNext) {
                        Task { await viewModel.playNextEpisode() }
                    }
                }
            }
        }
    }

    private func transportButton(
        _ title: String,
        _ systemImage: String,
        enabled: Bool = true,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let size = isPrimary ? layout.primaryButton : layout.secondaryButton
        return Button {
            onInteract()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.black.opacity(isPrimary ? 0.45 : 0.35)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || (viewModel.player == nil && fixedSnapshot == nil))
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }

    // MARK: - Bottom band (pills over the scrubber)

    private var bottomBand: some View {
        VStack(spacing: layout == .pad ? 14 : 10) {
            MobilePlayerPillRow(
                viewModel: viewModel,
                viewModes: viewModes,
                pictureInPicture: pictureInPicture,
                isOffline: isOffline,
                playbackSpeed: $playbackSpeed,
                onInteract: onInteract
            )
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                PlayerScrubber(
                    snapshot: fixedSnapshot ?? PlaybackSnapshot.read(viewModel.player),
                    onScrubbing: onScrubbing,
                    onSeek: seek(to:)
                )
            }
        }
        .padding(.horizontal, layout.edgePadding)
        .padding(.top, layout == .pad ? 40 : 28)
        .padding(.bottom, layout == .pad ? 18 : 10)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom),
            ignoresSafeAreaEdges: .bottom
        )
    }

    // MARK: - Skip intro / credits

    @ViewBuilder private var skipButton: some View {
        HStack {
            Spacer()
            if viewModel.showingSkipButton, let segment = viewModel.currentSegment {
                Button {
                    viewModel.skipCurrentSegment()
                } label: {
                    Label(Self.skipLabel(for: segment.type), systemImage: "forward.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                .padding(.trailing, layout.edgePadding)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: viewModel.showingSkipButton)
    }

    static func skipLabel(for type: MediaSegmentType) -> String {
        switch type {
        case .intro: return "Skip Intro"
        case .outro: return "Skip Credits"
        case .recap: return "Skip Recap"
        case .preview: return "Skip Preview"
        default: return "Skip"
        }
    }

    // MARK: - Playback actions

    private func togglePlayPause() {
        guard let player = viewModel.player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    private func seek(by seconds: Double) {
        guard let player = viewModel.player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        seek(to: max(0, current + seconds))
    }

    private func seek(to seconds: Double) {
        onInteract()
        viewModel.player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}

/// The series logo (or YouTube channel avatar) for the info bar. A series
/// with no logo shows its name instead of an empty box.
private struct MobileInfoBarArtwork: View {
    let artwork: PlayerInfoBarArtwork
    let seriesName: String?
    let serverID: String?
    let metrics: PlayerInfoBarMetrics

    private var serverURL: URL? {
        guard let serverID else { return nil }
        return SessionManager.shared.servers.first(where: { $0.id == serverID })?.url
    }

    var body: some View {
        switch artwork {
        case .channelAvatar(let seriesId):
            image(seriesId: seriesId, type: "Primary", width: Int(metrics.avatarSize * 3)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } fallback: {
                Color.clear
            }
        case .seriesLogo(let seriesId):
            image(seriesId: seriesId, type: "Logo", width: Int(metrics.logoMaxWidth * 3)) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } fallback: {
                if let seriesName {
                    Text(seriesName)
                        .font(.system(size: metrics.seriesNameFont, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func image<Loaded: View, Fallback: View>(
        seriesId: String,
        type: String,
        width: Int,
        @ViewBuilder loaded: @escaping (Image) -> Loaded,
        @ViewBuilder fallback: @escaping () -> Fallback
    ) -> some View {
        if let url = JellyfinClient.shared.syncImageURL(
            itemId: seriesId,
            imageType: type,
            maxWidth: width,
            serverURL: serverURL
        ) {
            LazyImage(request: SashimiImagePipeline.request(url: url, serverID: serverID)) { state in
                if let image = state.image {
                    loaded(image)
                } else if state.error != nil {
                    fallback()
                }
            }
            .pipeline(SashimiImagePipeline.shared)
        } else {
            fallback()
        }
    }
}
