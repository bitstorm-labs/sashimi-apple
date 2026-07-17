import SwiftUI
import AVKit

extension Notification.Name {
    static let playbackDidStop = Notification.Name("playbackDidStop")
}

// MARK: - AVPlayerViewController Wrapper

private struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.entersFullScreenWhenPlaybackBegins = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

// MARK: - Mobile Player View

struct MobilePlayerView: View {
    let item: BaseItemDto
    var startFromBeginning: Bool = false
    @StateObject private var viewModel = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showCustomOverlay = true
    @State private var hideTask: Task<Void, Never>?
    @State private var playbackSpeed: Float = 1.0

    private var localFileURL: URL? {
        DownloadManager.shared.localVideoURL(for: item.id)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = viewModel.player {
                PlayerViewController(player: player)
                    .ignoresSafeArea()

                // App-rendered VTT subtitles (same pipeline as tvOS, phone sizing)
                SubtitleOverlay(manager: viewModel.subtitleManager, fontSize: 17, bottomPadding: 48)

                customOverlay
            } else {
                loadingOrErrorView
            }
        }
        .navigationBarHidden(true)
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
            } else {
                await viewModel.loadMedia(item: item, localFileURL: localFileURL)
                // For offline content, apply locally-saved position if newer than server data
                if let offlineTicks = DownloadManager.shared.offlinePlaybackPosition(for: item.id),
                   offlineTicks > 0 {
                    let serverTicks = item.userData?.playbackPositionTicks ?? 0
                    if offlineTicks > serverTicks {
                        let seekTime = CMTime(value: offlineTicks / 10000, timescale: 1000)
                        await viewModel.player?.seek(to: seekTime)
                    }
                }
            }
            // Populate the audio/subtitle menus (tvOS does this on player appear;
            // without it both lists stay empty and subtitles can never be enabled)
            viewModel.loadAllTracks()
            scheduleAutoHide()
        }
        .onDisappear {
            viewModel.player?.pause()
            if localFileURL != nil, let currentTime = viewModel.player?.currentTime() {
                let ticks = Int64(currentTime.seconds * 10_000_000)
                DownloadManager.shared.savePlaybackPosition(itemId: item.id, positionTicks: ticks)
            }
            Task {
                await viewModel.stop()
                NotificationCenter.default.post(name: .playbackDidStop, object: nil)
            }
        }
        .onChange(of: viewModel.playbackEnded) { _, ended in
            if ended {
                dismiss()
            }
        }
    }

    // MARK: - Custom Overlay (close, title, settings, skip)

    private var customOverlay: some View {
        ZStack {
            // Tap area to toggle our overlay (passes through to AVPlayerViewController when not hit)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleOverlay()
                }
                .allowsHitTesting(showCustomOverlay)

            if showCustomOverlay {
                // Top gradient scrim
                VStack {
                    LinearGradient(
                        colors: [.black.opacity(0.6), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 100)
                    Spacer()
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                VStack {
                    topBar
                    Spacer()
                }
                .transition(.opacity)
            }

            // Skip button (always visible when active)
            VStack {
                Spacer()
                skipButtonView
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showCustomOverlay)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            // Close button
            Button {
                viewModel.player?.pause()
                Task { await viewModel.stop() }
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }

            // Title
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let subtitle = controlBarSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Settings menu
            settingsMenu
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var controlBarSubtitle: String? {
        if let seriesName = item.seriesName {
            var parts = [seriesName]
            if let season = item.parentIndexNumber, let episode = item.indexNumber {
                parts.append("S\(season):E\(episode)")
            }
            return parts.joined(separator: " \u{2022} ")
        }
        if let year = item.productionYear {
            return String(year)
        }
        return nil
    }

    // MARK: - Settings Menu

    private var settingsMenu: some View {
        Menu {
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

            Section("Speed") {
                ForEach([Float(0.5), 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button {
                        playbackSpeed = speed
                        // defaultRate keeps the speed across pause/play
                        viewModel.player?.defaultRate = speed
                        if viewModel.player?.rate != 0 {
                            viewModel.player?.rate = speed
                        }
                    } label: {
                        HStack {
                            Text(speed == 1.0 ? "Normal" : String(format: "%g×", speed))
                            if playbackSpeed == speed {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Section("Subtitles") {
                Button {
                    // Route through the ViewModel so the subtitle overlay is
                    // actually cleared, not just the selection state.
                    viewModel.disableSubtitles()
                } label: {
                    HStack {
                        Text("Off")
                        if viewModel.selectedSubtitleTrackId == nil || viewModel.selectedSubtitleTrackId == "off" {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                // Skip the ViewModel's built-in "Off" option — this menu renders its own above
                ForEach(viewModel.subtitleTracks.filter { !$0.isOffOption }) { subtitle in
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
            Image(systemName: "gearshape.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.15))
                .clipShape(Circle())
        }
    }

    // MARK: - Skip Button

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
                .padding(.trailing, 20)
                .padding(.bottom, 80)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: viewModel.showingSkipButton)
    }

    // MARK: - Helpers

    private func toggleOverlay() {
        showCustomOverlay.toggle()
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard showCustomOverlay else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                showCustomOverlay = false
            }
        }
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

    // MARK: - Loading/Error

    private var loadingOrErrorView: some View {
        ZStack(alignment: .topLeading) {
            Color.black

            // Always show a close button
            Button {
                viewModel.player?.pause()
                Task { await viewModel.stop() }
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .padding(20)

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Full Screen Player Presentation

struct FullScreenPlayerModifier: ViewModifier {
    @Binding var item: BaseItemDto?
    var startFromBeginning: Bool = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $item) { mediaItem in
                MobilePlayerView(item: mediaItem, startFromBeginning: startFromBeginning)
            }
    }
}

extension View {
    func fullScreenPlayer(item: Binding<BaseItemDto?>, startFromBeginning: Bool = false) -> some View {
        modifier(FullScreenPlayerModifier(item: item, startFromBeginning: startFromBeginning))
    }
}
