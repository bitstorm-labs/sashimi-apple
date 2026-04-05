import SwiftUI
import AVKit

struct PlayerView: View {
    let item: BaseItemDto
    var startFromBeginning: Bool = false

    @StateObject private var viewModel = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss

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
                    onDismiss: { Task { await viewModel.stop(); dismiss() } }
                )
                .ignoresSafeArea()
                .onAppear { viewModel.loadSubtitleTracks() }
            }
        }
        .task { await viewModel.loadMedia(item: item, startFromBeginning: startFromBeginning) }
        .onDisappear { Task { await viewModel.stop() } }
        .onChange(of: viewModel.playbackEnded) { _, ended in if ended { dismiss() } }
    }

    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 60)).foregroundStyle(.red)
            Text("Playback Error").font(.title2)
            Text(viewModel.errorMessage ?? "Unknown error").foregroundStyle(.secondary)
            Button("Dismiss") { Task { await viewModel.stop(); dismiss() } }
        }
    }
}
