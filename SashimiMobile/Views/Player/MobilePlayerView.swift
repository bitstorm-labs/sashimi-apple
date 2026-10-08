import SwiftUI
import AVKit

extension Notification.Name {
    static let playbackDidStop = Notification.Name("playbackDidStop")
}

// MARK: - Mobile Player View

// Player controls, handoff callbacks, and teardown stay together at this
// presentation boundary so a dismissal can await the same view-model session.
struct MobilePlayerView: View {
    let item: BaseItemDto
    var serverID: String?
    var startFromBeginning: Bool = false
    /// Set when this playback is a channel rather than a chosen item. The view
    /// model then reports no watch state and rolls to the next programme.
    var channelContext: ChannelPlaybackContext?
    var onPlaybackReady: (() -> Void)?
    var onPlaybackFailed: (() -> Void)?
    @StateObject private var viewModel: PlayerViewModel
    @ObservedObject private var playbackSettings = PlaybackSettings.shared
    @ObservedObject private var viewModes = VideoViewModeStore.shared
    @StateObject private var pictureInPicture = PictureInPictureModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCustomOverlay = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var playbackSpeed: Float = 1.0
    @State private var handoffAcknowledged = false
    /// Bumped by "Try Again". The load is the view's `.task`, keyed on this,
    /// so a retry is cancelled with the view exactly like the first load.
    @State private var loadAttempt = 0
    /// Downloaded items that played to their end. Acted on (Delete downloads
    /// after watching) only once the player is gone, never mid-playback.
    @State private var finishedDownloadItemIDs: [String] = []

    init(
        item: BaseItemDto,
        serverID: String? = nil,
        startFromBeginning: Bool = false,
        channelContext: ChannelPlaybackContext? = nil,
        onPlaybackReady: (() -> Void)? = nil,
        onPlaybackFailed: (() -> Void)? = nil
    ) {
        self.item = item
        self.serverID = serverID
        self.startFromBeginning = startFromBeginning
        self.channelContext = channelContext
        self.onPlaybackReady = onPlaybackReady
        self.onPlaybackFailed = onPlaybackFailed
        _viewModel = StateObject(wrappedValue: PlayerViewModel(
            serverID: serverID,
            channelContext: channelContext
        ))
    }

    private var localFileURL: URL? {
        DownloadManager.shared.localVideoURL(for: item.id, serverID: serverID)
    }

    /// The view model's resolved item is the source of truth after a
    /// transition. The initializer item is only the entry point (and may be a
    /// Series/Season container that resolves to an episode).
    private var displayedItem: BaseItemDto {
        viewModel.currentItem ?? item
    }

    private var usesEpisodeTransportControls: Bool {
        viewModel.transitionState.usesEpisodeTransportControls(
            isEnabled: playbackSettings.showEpisodeNavigationControls
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // A break between slots on a channel covers everything, loading included.
            if let card = viewModel.upNext {
                UpNextCardView(card: card)
                    .zIndex(10)
            }

            if let player = viewModel.player {
                // The picture only: every control is the app's own overlay.
                PlayerSurface(
                    player: player,
                    videoGravity: viewModes.activeMode.videoGravity,
                    pictureInPicture: pictureInPicture
                )
                    .ignoresSafeArea()

                // App-rendered VTT subtitles (same pipeline as tvOS, phone sizing)
                SubtitleOverlay(manager: viewModel.subtitleManager, fontSize: 17, bottomPadding: 48)

                if let upNext = viewModel.episodeUpNext {
                    upNextScreen(upNext)
                        .transition(.opacity)
                } else {
                    overlay
                }

                if !viewModel.isLoading, let notice = viewModel.playbackNotice {
                    PlaybackNoticeBanner(text: notice)
                }

                if let banner = viewModel.stationBanner {
                    VStack {
                        Spacer()
                        MobileStationBannerView(banner: banner)
                            .padding(.horizontal, 16)
                            .padding(.bottom, showCustomOverlay ? 170 : 24)
                            .task(id: banner.id) {
                                try? await Task.sleep(nanoseconds: 6 * NSEC_PER_SEC)
                                guard !Task.isCancelled else { return }
                                viewModel.dismissStationBanner(banner.id)
                            }
                    }
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                MobilePlayerLoadingView(
                    viewModel: viewModel,
                    onRetry: localFileURL == nil ? { loadAttempt += 1 } : nil,
                    onClose: {
                        viewModel.player?.pause()
                        saveOfflinePositionIfNeeded()
                        viewModel.beginStop(reason: .userStop)
                        dismiss()
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.playbackNotice)
        .animation(.easeInOut(duration: 0.4), value: viewModel.episodeUpNext == nil)
        .navigationBarHidden(true)
        // The top band carries its own clock, so the system status bar stays
        // hidden for the whole time the player is up, controls or not.
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task(id: loadAttempt) {
            // The load bounds itself (PlaybackLoadPolicy): it fails only once
            // the server has gone quiet, not five seconds in while the
            // requests are still being answered (#594).
            if localFileURL == nil {
                await viewModel.loadMedia(item: item, startFromBeginning: startFromBeginning, localFileURL: nil)
                await viewModel.announceStation()
            } else {
                // A download rolls into the next downloaded episode of its
                // show, with the same Up Next / end card as online.
                viewModel.offlineEpisodeSource = DownloadedEpisodeSource(serverID: serverID)
                await viewModel.loadMedia(
                    item: item,
                    localFileURL: localFileURL,
                    offlineSubtitles: DownloadManager.shared.offlineSubtitles(for: item.id, serverID: serverID)
                )
                // For offline content, apply locally-saved position if newer than server data.
                // Goes through the view model rather than seeking directly: the
                // resume position is applied when the item reports .readyToPlay,
                // so a seek issued here would be overwritten a moment later.
                // A position past the played line starts over instead of
                // resuming in the credits.
                if let offlineTicks = DownloadManager.shared.offlinePlaybackPosition(for: item.id, serverID: serverID),
                   offlineTicks > 0,
                   !OfflinePlaybackRules.isPlayed(positionTicks: offlineTicks, runTimeTicks: item.runTimeTicks) {
                    let serverTicks = item.userData?.playbackPositionTicks ?? 0
                    if offlineTicks > serverTicks {
                        viewModel.overrideResumePosition(ticks: offlineTicks)
                    }
                }
            }
            acknowledgePlaybackHandoff()
            // Populate the audio/subtitle menus (tvOS does this on player appear;
            // without it both lists stay empty and subtitles can never be enabled)
            viewModel.loadAllTracks()
            await viewModel.refreshStreamInfo()
            scheduleAutoHide()
            // A download that lost its subtitles (fetched after the video,
            // and cut off when the app was suspended) gets them now if the
            // server is reachable, and the menu fills in.
            if localFileURL != nil,
               let subtitles = await DownloadManager.shared.backfillSubtitles(itemId: item.id, serverID: serverID) {
                viewModel.offlineSubtitles = subtitles
                viewModel.loadSubtitleTracks()
            }
        }
        // Live channels keep the screen on through Up Next breaks (see
        // keepsScreenAwake); the system default returns when the player goes.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = viewModel.keepsScreenAwake }
        // Menu bar / keyboard commands, and the Mac's mouse-move reveal.
        .modifier(PlayerCommandBinding(viewModel: viewModel, perform: handleCommand, onPointerMove: revealControls))
        .onChange(of: viewModel.keepsScreenAwake) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            viewModel.player?.pause()
            saveOfflinePositionIfNeeded()
            let stopTask = viewModel.beginStop(reason: .viewDisappeared)
            let finishedDownloads = finishedDownloadItemIDs
            Task {
                await stopTask.value
                for itemId in finishedDownloads {
                    await DownloadManager.shared.handleOfflinePlaybackFinished(
                        itemId: itemId,
                        serverID: serverID
                    )
                }
                NotificationCenter.default.post(name: .playbackDidStop, object: nil)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // The Up Next countdown only runs while the app is in front.
            if newPhase == .active {
                viewModel.resumeUpNextCountdown()
            } else {
                viewModel.pauseUpNextCountdown()
            }
            // Picture in Picture is the one way to keep watching outside the
            // app; leaving the app otherwise stops playback as before.
            guard newPhase == .background, !pictureInPicture.isActive else { return }
            viewModel.player?.pause()
            saveOfflinePositionIfNeeded()
            viewModel.beginStop(reason: .sceneBackground)
            dismiss()
        }
        // The .task above runs once. It does not re-run when changeQuality
        // rebuilds the player or when auto-play-next swaps in the next episode,
        // so the menus kept describing the PREVIOUS asset -- and since stream
        // indexes are not stable across media sources, picking a subtitle from
        // a stale menu fetched the wrong track entirely.
        .onChange(of: viewModel.currentItem?.id) { _, _ in
            viewModel.loadAllTracks()
        }
        .onChange(of: viewModel.tracksVersion) { _, _ in
            viewModel.loadAllTracks()
        }
        .onChange(of: viewModel.transitionState) { _, state in
            // Episode navigation is an action bar, not transient transport
            // chrome when the user opts into persistent controls. Otherwise
            // preserve the original transient overlay behavior.
            guard playbackSettings.showEpisodeNavigationControls,
                  state.endCard == nil,
                  state.isEpisodeNavigationAvailable else { return }
            showCustomOverlay = true
            scheduleAutoHide()
        }
        .onChange(of: playbackSettings.showEpisodeNavigationControls) { _, enabled in
            if enabled, viewModel.transitionState.isEpisodeNavigationAvailable {
                showCustomOverlay = true
                scheduleAutoHide()
            } else {
                scheduleAutoHide()
            }
        }
        .onChange(of: viewModel.finishedItemIDs) { _, finished in
            // Captured as each item ends: the item is cleared when playback is
            // torn down. Offline autoplay can finish several downloads in one
            // sitting (through Up Next or straight on in Picture in Picture),
            // so every one is remembered, once.
            guard localFileURL != nil else { return }
            for itemID in finished where !finishedDownloadItemIDs.contains(itemID) {
                finishedDownloadItemIDs.append(itemID)
            }
        }
        .onChange(of: viewModel.playbackEnded) { _, ended in
            // The view model shows the Up Next card whenever there is anything
            // to offer. Offline with no further download there is none (the
            // series may well go on), so the player closes as before.
            if ended && viewModel.episodeUpNext == nil {
                dismiss()
            }
        }
        .onChange(of: pictureInPicture.isActive) { _, active in
            viewModel.isPictureInPictureActive = active
        }
        // The delivery chip is refreshed each time the controls come up (the
        // transcode session may register or change after playback starts).
        .onChange(of: showCustomOverlay) { _, visible in
            guard visible else { return }
            Task { await viewModel.refreshStreamInfo() }
        }
        .onChange(of: viewModel.isPlayerReady) { _, _ in
            acknowledgePlaybackHandoff()
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard message != nil else { return }
            acknowledgePlaybackHandoff()
        }
    }

    private func acknowledgePlaybackHandoff() {
        guard !handoffAcknowledged else { return }
        if viewModel.isPlayerReady {
            handoffAcknowledged = true
            onPlaybackReady?()
        } else if viewModel.errorMessage != nil {
            handoffAcknowledged = true
            onPlaybackFailed?()
        }
    }

    // MARK: - Up Next

    private func upNextScreen(_ upNext: EpisodeUpNext) -> some View {
        EpisodeUpNextScreen(
            upNext: upNext,
            imageURLs: { item, role in upNextImageURLs(for: item, role: role, offline: upNext.isOffline) },
            serverID: serverID,
            onPlay: { Task { await viewModel.playUpNextEpisode() } },
            onSkip: { viewModel.skipUpNextEpisode() },
            onCancel: { viewModel.cancelUpNext() },
            onReplay: { Task { await viewModel.replayCurrentItem() } },
            onDone: closePlayer
        )
    }

    /// A download's own artwork first (no server needed), then the server's.
    private func upNextImageURLs(for item: BaseItemDto, role: EpisodeUpNextImageRole, offline: Bool) -> [URL] {
        var urls: [URL] = []
        if offline {
            switch role {
            case .thumbnail:
                urls += [OfflineImageHelper.thumbnailURL(for: item.id, serverID: serverID)].compactMap { $0 }
            case .backdrop:
                urls += [
                    OfflineImageHelper.backdropURL(for: item.id, serverID: serverID),
                    OfflineImageHelper.thumbnailURL(for: item.id, serverID: serverID)
                ].compactMap { $0 }
            }
        }
        return urls + EpisodeUpNextScreen.serverImageURLs(for: item, role: role, serverID: serverID)
    }

    // MARK: - Overlay

    private var overlay: some View {
        MobilePlayerOverlay(
            viewModel: viewModel,
            viewModes: viewModes,
            pictureInPicture: pictureInPicture,
            item: displayedItem,
            serverID: serverID,
            isOffline: localFileURL != nil,
            showsEpisodeNavigation: usesEpisodeTransportControls,
            layout: .current,
            isVisible: $showCustomOverlay,
            playbackSpeed: $playbackSpeed,
            onInteract: scheduleAutoHide,
            onScrubbing: { scrubbing in
                isScrubbing = scrubbing
                scheduleAutoHide()
            },
            onClose: closePlayer
        )
    }

    // MARK: - Helpers

    private func closePlayer() {
        viewModel.player?.pause()
        // Capture BEFORE stop(): stop() nils the player, and for
        // offline playback it hits no await first, so it completes long
        // before the dismiss animation lets onDisappear run -- which is
        // where the offline save lives. The position was silently lost
        // every time the X was used.
        saveOfflinePositionIfNeeded()
        // Close first (#591). The player is released and the stopped report
        // persisted before beginStop returns; delivery carries on behind the
        // dismissal, and onDisappear waits on the same task for the work that
        // has to follow it (delete-after-watching, .playbackDidStop).
        viewModel.beginStop(reason: .userStop)
        dismiss()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard showCustomOverlay, !isScrubbing else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                showCustomOverlay = false
            }
        }
    }

    /// Persists the offline resume point. Safe to call more than once: the
    /// last call before the player is torn down wins, and it no-ops once the
    /// player is gone.
    private func saveOfflinePositionIfNeeded() {
        // A natural end already saved the item as finished; the stopped
        // player's clock must not overwrite that.
        // livePositionTicks, not the player's clock: until the resume seek
        // lands the clock reads zero, and closing in that window used to save
        // zero over the stored position (#593).
        guard localFileURL != nil, !viewModel.playbackEnded, viewModel.player != nil,
              let ticks = viewModel.livePositionTicks() else { return }
        DownloadManager.shared.savePlaybackPosition(itemId: displayedItem.id, serverID: serverID, positionTicks: ticks)
    }
}

// MARK: - Menu bar and keyboard commands

extension MobilePlayerView {
    /// A menu-bar or keyboard command (Space, arrows, F, M, C, Esc, …).
    private func handleCommand(_ command: AppCommand) {
        switch command {
        case .playPause:
            viewModel.togglePlayPause()
        case .skip(let seconds):
            viewModel.skip(by: seconds)
        case .nextEpisode:
            Task { await viewModel.playNextEpisode() }
        case .previousEpisode:
            Task { await viewModel.playPreviousEpisode() }
        case .toggleMute:
            viewModel.toggleMute()
        case .setQuality(let quality):
            Task { await viewModel.changeQuality(quality) }
        case .toggleFullScreen:
            toggleWindowFullScreen()
        case .escape:
            switch PlayerEscapeAction.forWindow(isFullScreen: isWindowFullScreen) {
            case .exitFullScreen: toggleWindowFullScreen()
            case .closePlayer: closePlayer()
            }
            return
        case .closePlayer:
            closePlayer()
            return
        case .toggleSubtitles:
            // Switched by PlayerCommandBinding, which remembers the last track.
            break
        case .railSection, .search, .settings:
            return
        }
        // Show what the key did (the scrubber moving, the pill changing).
        revealControls()
    }

    private var isWindowFullScreen: Bool {
#if targetEnvironment(macCatalyst)
        MacWindow.isFullScreen
#else
        false
#endif
    }

    private func toggleWindowFullScreen() {
#if targetEnvironment(macCatalyst)
        MacWindow.toggleFullScreen()
#endif
    }

    private func revealControls() {
        if !showCustomOverlay { showCustomOverlay = true }
        scheduleAutoHide()
    }
}

/// Registers the player with the menu bar while it is on screen, remembers
/// the last subtitle track for Toggle Subtitles, and on the Mac reveals the
/// controls when the mouse moves (they hide again after the usual idle delay).
private struct PlayerCommandBinding: ViewModifier {
    @ObservedObject var viewModel: PlayerViewModel
    let perform: (AppCommand) -> Void
    let onPointerMove: () -> Void
    @State private var targetID = UUID()
    @State private var lastSubtitleTrackID: String?

    func body(content: Content) -> some View {
        content
            .onAppear {
                AppCommandCenter.shared.registerPlayer(.init(id: targetID, viewModel: viewModel) { command in
                    if command == .toggleSubtitles {
                        viewModel.toggleSubtitles(lastSelectedID: lastSubtitleTrackID)
                    }
                    perform(command)
                })
            }
            .onDisappear {
                AppCommandCenter.shared.unregisterPlayer(id: targetID)
            }
            .onChange(of: viewModel.selectedSubtitleTrackId) { _, id in
                if let id, id != "off" { lastSubtitleTrackID = id }
            }
            .onContinuousHover { phase in
                guard MacPlatform.isMac, case .active = phase else { return }
                onPointerMove()
            }
    }
}

// MARK: - Full Screen Player Presentation

struct FullScreenPlayerModifier: ViewModifier {
    @Binding var item: BaseItemDto?
    var serverID: String?
    var startFromBeginning: Bool = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $item) { mediaItem in
                MobilePlayerView(
                    item: mediaItem,
                    serverID: serverID,
                    startFromBeginning: startFromBeginning
                )
            }
    }
}

extension View {
    func fullScreenPlayer(
        item: Binding<BaseItemDto?>,
        serverID: String? = nil,
        startFromBeginning: Bool = false
    ) -> some View {
        modifier(
            FullScreenPlayerModifier(
                item: item,
                serverID: serverID,
                startFromBeginning: startFromBeginning
            )
        )
    }
}
