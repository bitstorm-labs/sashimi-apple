import SwiftUI
import AVKit

struct PlayerView: View {
    let item: BaseItemDto
    var serverID: String?
    var startFromBeginning: Bool = false

    @StateObject private var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(item: BaseItemDto, serverID: String? = nil, startFromBeginning: Bool = false) {
        self.item = item
        self.serverID = serverID
        self.startFromBeginning = startFromBeginning
        _viewModel = StateObject(wrappedValue: PlayerViewModel(serverID: serverID))
    }

    /// Distinguishes THIS presentation of the player in the log.
    ///
    /// SwiftUI recreating this view (a `fullScreenCover` whose binding changes,
    /// a parent whose identity moves) produces a second `@StateObject` and a
    /// second `.task`, and therefore a second server play session — which from
    /// the server's side is indistinguishable from one session restarting.
    /// A view tag plus the view model's own tag separates the two cases.
    @State private var viewTag = String(UUID().uuidString.prefix(8))

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView().scaleEffect(1.5)
            } else if viewModel.error != nil || viewModel.errorMessage != nil {
                errorView
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
                        Task {
                            await viewModel.stop(reason: .userStop)
                            dismiss()
                        }
                    }
                )
                .ignoresSafeArea()
                .onAppear { viewModel.loadSubtitleTracks() }
            }
        }
        .task {
            // One `view.task` line per presentation. Two lines with different
            // `view` tags for the same item means SwiftUI rebuilt the player;
            // two `load.begin` lines under the same `vm` tag means one view
            // model was asked to load twice. Those need different fixes, and
            // the server cannot tell them apart.
            PlayerDiagnostics.event(.viewTask, [
                PlayerDiagnostics.field("view", viewTag),
                PlayerDiagnostics.field("item", item.id),
                PlayerDiagnostics.field("type", item.type?.rawValue),
                PlayerDiagnostics.field("startFromBeginning", startFromBeginning)
            ])
            await viewModel.loadMedia(item: item, startFromBeginning: startFromBeginning)
        }
        .onDisappear {
            PlayerDiagnostics.event(.viewDisappear, [
                PlayerDiagnostics.field("view", viewTag),
                PlayerDiagnostics.field("item", item.id)
            ])
            Task { await viewModel.stop(reason: .viewDisappeared) }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else { return }
            Task {
                await viewModel.stop(reason: .sceneBackground)
                dismiss()
            }
        }
        .onChange(of: viewModel.playbackEnded) { _, ended in
            if ended {
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

    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 60)).foregroundStyle(.red)
            Text("Playback Error").font(.title2)
            Text(viewModel.errorMessage ?? "Unknown error").foregroundStyle(.secondary)
            Button("Dismiss") {
                PlayerDiagnostics.event(.viewDismiss, [
                    PlayerDiagnostics.field("view", viewTag),
                    PlayerDiagnostics.field("trigger", "error-dismiss")
                ])
                Task {
                    await viewModel.stop(reason: .userStop)
                    dismiss()
                }
            }
        }
    }
}
