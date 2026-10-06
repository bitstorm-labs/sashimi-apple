import SwiftUI
import AVKit

struct PlayerView: View {
    let item: BaseItemDto
    var serverID: String?
    var startFromBeginning: Bool = false
    var channelContext: ChannelPlaybackContext?

    @StateObject private var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(
        item: BaseItemDto,
        serverID: String? = nil,
        startFromBeginning: Bool = false,
        channelContext: ChannelPlaybackContext? = nil
    ) {
        self.item = item
        self.serverID = serverID
        self.startFromBeginning = startFromBeginning
        self.channelContext = channelContext
        _viewModel = StateObject(wrappedValue: PlayerViewModel(
            serverID: serverID,
            channelContext: channelContext
        ))
    }

    /// Distinguishes THIS presentation of the player in the log.
    ///
    /// SwiftUI recreating this view (a `fullScreenCover` whose binding changes,
    /// a parent whose identity moves) produces a second `@StateObject` and a
    /// second `.task`, and therefore a second server play session — which from
    /// the server's side is indistinguishable from one session restarting.
    /// A view tag plus the view model's own tag separates the two cases.
    @State private var viewTag = String(UUID().uuidString.prefix(8))
    /// Bumped by "Try Again". The load is the view's `.task`, keyed on this,
    /// so a retry is cancelled with the view exactly like the first load.
    @State private var loadAttempt = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading {
                VStack(spacing: 28) {
                    ProgressView().scaleEffect(1.5)
                    if let notice = viewModel.playbackNotice {
                        Text(notice)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
            } else if viewModel.error != nil || viewModel.errorMessage != nil {
                errorView
            } else if let upNext = viewModel.episodeUpNext {
                // In place of the player rather than over it: AVKit's view
                // would otherwise keep the remote's focus and Menu press.
                upNextScreen(upNext)
                    .transition(.opacity)
            } else if let player = viewModel.player {
                TVPlayerView(
                    player: player,
                    viewModel: viewModel,
                    item: item,
                    onDismiss: {
                        PlayerDiagnostics.event(.viewDismiss, [
                            PlayerDiagnostics.field("view", viewTag),
                            PlayerDiagnostics.field("trigger", "menu-button")
                        ])
                        // Close first; the stopped report and transcode
                        // cleanup carry on behind the dismissal (#591).
                        viewModel.beginStop(reason: .userStop)
                        dismiss()
                    }
                )
                .ignoresSafeArea()
                .onAppear { viewModel.loadAllTracks() }
                .onChange(of: viewModel.tracksVersion) { _, _ in viewModel.loadAllTracks() }
            }

            // A channel's break between slots. Up here rather than in the
            // player's overlay: tuning in during a break creates no player
            // until the programme starts, and the overlay lives inside it —
            // so the card never showed and the viewer sat on a black screen.
            if let card = viewModel.upNext {
                UpNextCardView(card: card)
                    .ignoresSafeArea()
                    .zIndex(10)
            }

            // "Lowering quality for your connection", "Quality: 480p · 4 Mbps":
            // over the picture, so it shows without bringing up the controls.
            if !viewModel.isLoading, viewModel.player != nil, let notice = viewModel.playbackNotice {
                PlaybackNoticeBanner(text: notice)
                    .zIndex(11)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: viewModel.upNext)
        .animation(.easeInOut(duration: 0.4), value: viewModel.episodeUpNext == nil)
        .animation(.easeInOut(duration: 0.3), value: viewModel.playbackNotice)
        .task(id: loadAttempt) {
            // One `view.task` line per presentation (and per retry). Two lines with different
            // `view` tags for the same item means SwiftUI rebuilt the player;
            // two `load.begin` lines under the same `vm` tag means one view
            // model was asked to load twice. Those need different fixes, and
            // the server cannot tell them apart.
            PlayerDiagnostics.event(.viewTask, [
                PlayerDiagnostics.field("view", viewTag),
                PlayerDiagnostics.field("item", item.id),
                PlayerDiagnostics.field("type", item.type?.rawValue),
                PlayerDiagnostics.field("startFromBeginning", startFromBeginning),
                PlayerDiagnostics.field("loadAttempt", loadAttempt)
            ])
            await viewModel.loadMedia(item: item, startFromBeginning: startFromBeginning)
            await viewModel.announceStation()
        }
        // Live channels keep the screen on (see keepsScreenAwake); the system
        // default is restored the moment the player goes away.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = viewModel.keepsScreenAwake }
        .onChange(of: viewModel.keepsScreenAwake) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            PlayerDiagnostics.event(.viewDisappear, [
                PlayerDiagnostics.field("view", viewTag),
                PlayerDiagnostics.field("item", item.id)
            ])
            viewModel.player?.pause()
            viewModel.beginStop(reason: .viewDisappeared)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else { return }
            viewModel.player?.pause()
            viewModel.beginStop(reason: .sceneBackground)
            dismiss()
        }
        .onChange(of: viewModel.playbackEnded) { _, ended in
            // The view model shows the Up Next card whenever there is
            // anything to offer; with nothing to offer the player closes.
            if ended && viewModel.episodeUpNext == nil {
                PlayerDiagnostics.event(.viewDismiss, [
                    PlayerDiagnostics.field("view", viewTag),
                    PlayerDiagnostics.field("trigger", "playback-ended")
                ])
                dismiss()
            }
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            PlayerDiagnostics.failure(.viewError, [
                PlayerDiagnostics.field("view", viewTag),
                PlayerDiagnostics.field("item", item.id),
                PlayerDiagnostics.field("message", message)
            ])
        }
    }

    private func upNextScreen(_ upNext: EpisodeUpNext) -> some View {
        EpisodeUpNextScreen(
            upNext: upNext,
            imageURLs: { item, role in
                EpisodeUpNextScreen.serverImageURLs(for: item, role: role, serverID: serverID)
            },
            serverID: serverID,
            onPlay: { Task { await viewModel.playUpNextEpisode() } },
            onSkip: { viewModel.skipUpNextEpisode() },
            onCancel: { viewModel.cancelUpNext() },
            onReplay: { Task { await viewModel.replayCurrentItem() } },
            onDone: {
                PlayerDiagnostics.event(.viewDismiss, [
                    PlayerDiagnostics.field("view", viewTag),
                    PlayerDiagnostics.field("trigger", "up-next-done")
                ])
                viewModel.beginStop(reason: .userStop)
                dismiss()
            }
        )
    }

    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 60)).foregroundStyle(.red)
            Text("Playback Error").font(.title2)
            Text(viewModel.errorMessage ?? "Unknown error")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 40) {
                // A load that timed out or failed is often worth one more go
                // (a server waking up, a link that came back) without making
                // the viewer find the title again.
                Button("Try Again") { loadAttempt += 1 }
                Button("Dismiss") {
                    PlayerDiagnostics.event(.viewDismiss, [
                        PlayerDiagnostics.field("view", viewTag),
                        PlayerDiagnostics.field("trigger", "error-dismiss")
                    ])
                    viewModel.beginStop(reason: .userStop)
                    dismiss()
                }
            }
        }
    }
}
