import SwiftUI
import AVKit

struct MobilePlayerView: View {
    let item: BaseItemDto
    @StateObject private var viewModel = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Video player
            if let player = viewModel.player {
                VideoPlayer(player: player) {
                    overlayContent
                }
                .ignoresSafeArea()
            } else {
                loadingOrErrorView
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            await viewModel.loadMedia(item: item)
        }
        .onDisappear {
            Task {
                await viewModel.stop()
            }
        }
        .onChange(of: viewModel.playbackEnded) { _, ended in
            if ended {
                dismiss()
            }
        }
    }

    private var loadingOrErrorView: some View {
        ZStack {
            Color.black
            VStack(spacing: 16) {
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading...")
                        .foregroundStyle(.white)
                } else if let errorMessage = viewModel.errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text(errorMessage)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Dismiss") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .ignoresSafeArea()
    }

    private var overlayContent: some View {
        VStack {
            // Top bar
            HStack {
                closeButton
                Spacer()
                settingsMenu
            }

            Spacer()

            // Skip button
            skipButtonView
        }
    }

    private var closeButton: some View {
        Button {
            Task { await viewModel.stop() }
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .foregroundStyle(.white)
                .shadow(radius: 4)
        }
        .padding()
    }

    private var settingsMenu: some View {
        Menu {
            // Quality options
            Section("Quality") {
                ForEach(QualityOption.allCases) { quality in
                    Button {
                        Task { await viewModel.changeQuality(quality) }
                    } label: {
                        HStack {
                            Text(quality.displayName)
                            if viewModel.selectedQuality == quality {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            // Audio tracks
            if !viewModel.audioTracks.isEmpty {
                Section("Audio") {
                    ForEach(Array(viewModel.audioTracks.enumerated()), id: \.element.id) { _, track in
                        Button {
                            viewModel.selectAudioTrack(track)
                        } label: {
                            HStack {
                                Text(track.displayName)
                                if viewModel.selectedAudioTrackId == track.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            // Subtitles
            Section("Subtitles") {
                Button {
                    viewModel.selectedSubtitleTrackId = nil
                } label: {
                    HStack {
                        Text("Off")
                        if viewModel.selectedSubtitleTrackId == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                ForEach(Array(viewModel.subtitleTracks.enumerated()), id: \.element.id) { _, subtitle in
                    Button {
                        viewModel.selectSubtitleTrack(subtitle)
                    } label: {
                        HStack {
                            Text(subtitle.displayName)
                            if viewModel.selectedSubtitleTrackId == subtitle.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title)
                .foregroundStyle(.white)
                .shadow(radius: 4)
        }
        .padding()
    }

    private var skipButtonView: some View {
        HStack {
            Spacer()
            if viewModel.showingSkipButton, let segment = viewModel.currentSegment {
                Button {
                    viewModel.skipCurrentSegment()
                } label: {
                    Label(skipLabel(for: segment.type), systemImage: "forward.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                .padding()
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: viewModel.showingSkipButton)
    }

    private func skipLabel(for type: MediaSegmentType) -> String {
        switch type {
        case .intro: return "Skip Intro"
        case .outro: return "Skip Credits"
        case .recap: return "Skip Recap"
        case .preview: return "Skip Preview"
        default: return "Skip"
        }
    }
}

// MARK: - Full Screen Player Presentation

struct FullScreenPlayerModifier: ViewModifier {
    @Binding var item: BaseItemDto?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $item) { mediaItem in
                MobilePlayerView(item: mediaItem)
            }
    }
}

extension View {
    func fullScreenPlayer(item: Binding<BaseItemDto?>) -> some View {
        modifier(FullScreenPlayerModifier(item: item))
    }
}
