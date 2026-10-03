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

                if playbackSettings.showEpisodeNavigationControls,
                   viewModel.transitionState.endCard != nil {
                    MobilePlayerEndCard(
                        state: viewModel.transitionState,
                        item: displayedItem,
                        streamInfo: viewModel.streamInfo,
                        onPlayNext: { Task { await viewModel.playNextEpisode() } },
                        onReplay: { Task { await viewModel.replayCurrentItem() } },
                        onDone: {
                            Task {
                                await viewModel.stop(reason: .userStop)
                                dismiss()
                            }
                        }
                    )
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
                    onClose: {
                        viewModel.player?.pause()
                        saveOfflinePositionIfNeeded()
                        Task { await viewModel.stop(reason: .userStop) }
                        dismiss()
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.playbackNotice)
        .navigationBarHidden(true)
        // The top band carries its own clock, so the system status bar stays
        // hidden for the whole time the player is up, controls or not.
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            // For online playback, add a timeout so we don't hang forever if unreachable
            if localFileURL == nil {
                let timeoutTask = Task {
                    try await Task.sleep(for: .seconds(5))
                    if viewModel.isLoading && viewModel.player == nil {
                        viewModel.isLoading = false
                        viewModel.errorMessage = "Can't connect to server. Download this item to watch offline."
                    }
                }
                await viewModel.loadMedia(item: item, startFromBeginning: startFromBeginning, localFileURL: nil)
                timeoutTask.cancel()
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
            // Picture in Picture is the one way to keep watching outside the
            // app; leaving the app otherwise stops playback as before.
            guard newPhase == .background, !pictureInPicture.isActive else { return }
            viewModel.player?.pause()
            saveOfflinePositionIfNeeded()
            let stopTask = viewModel.beginStop(reason: .sceneBackground)
            Task {
                await stopTask.value
                dismiss()
            }
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
        .onChange(of: viewModel.playbackEnded) { _, ended in
            // Captured now: the item is cleared when playback is torn down.
            // Offline autoplay can finish several downloads in one sitting,
            // so every one is remembered, not just the last.
            if ended, localFileURL != nil, !finishedDownloadItemIDs.contains(displayedItem.id) {
                finishedDownloadItemIDs.append(displayedItem.id)
            }
            // Offline with no further download there is no end card to show
            // (the series may well go on), so close as before.
            if ended && (!playbackSettings.showEpisodeNavigationControls ||
                         !viewModel.transitionState.isEpisodeNavigationAvailable ||
                         (viewModel.isOfflinePlayback && viewModel.transitionState.endCard == nil)) {
                dismiss()
            }
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
        Task {
            await viewModel.stop(reason: .userStop)
            dismiss()
        }
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
        guard localFileURL != nil, !viewModel.playbackEnded,
              let currentTime = viewModel.player?.currentTime() else { return }
        let ticks = Int64(currentTime.seconds * 10_000_000)
        DownloadManager.shared.savePlaybackPosition(itemId: displayedItem.id, serverID: serverID, positionTicks: ticks)
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
