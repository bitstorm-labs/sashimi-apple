import SwiftUI
import AVKit
import Combine

struct PlayerView: View {
    let item: BaseItemDto
    var startFromBeginning: Bool = false

    @StateObject private var viewModel = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showControls = true
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var activeOverlay: PlayerOverlay?
    @State private var currentSpeed: Float = 1.0
    @State private var lastOpenedOverlay: PlayerOverlay?
    @State private var overlayClosedAt: Date?

    @FocusState private var hiddenControlsFocused: Bool

    enum PlayerOverlay: Hashable {
        case subtitles, chapters, speed, quality
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView().scaleEffect(1.5)
            } else if viewModel.error != nil || viewModel.errorMessage != nil {
                errorView
            } else if viewModel.player != nil {
                playerContent
            }

            if viewModel.showingUpNext, let next = viewModel.nextEpisode {
                upNextOverlay(next)
            }

            if viewModel.showingSkipButton, let segment = viewModel.currentSegment {
                skipOverlay(segment)
            }

            if let overlay = activeOverlay {
                pickerOverlay(overlay)
            }
        }
        .task { await viewModel.loadMedia(item: item, startFromBeginning: startFromBeginning) }
        .onDisappear {
            controlsHideTask?.cancel()
            Task { await viewModel.stop() }
        }
        .onChange(of: viewModel.playbackEnded) { _, ended in if ended { dismiss() } }
        .onPlayPauseCommand {
            togglePlayPause()
            if !showControls { showControlsAndResetTimer() }
        }
    }

    @ViewBuilder
    private var playerContent: some View {
        ZStack {
            if let player = viewModel.player {
                PlayerLayerView(player: player).ignoresSafeArea()
            }

            SubtitleOverlay(manager: viewModel.subtitleManager)

            if showControls && activeOverlay == nil {
                PlayerInfoOverlay(
                    item: viewModel.currentItem ?? item,
                    viewModel: viewModel,
                    isVisible: .constant(true),
                    onSeek: { seekTo($0); resetAutoHide() },
                    onPlayPause: { togglePlayPause(); resetAutoHide() },
                    onShowSubtitles: { lastOpenedOverlay = .subtitles; showOverlay(.subtitles) },
                    onShowChapters: { lastOpenedOverlay = .chapters; showOverlay(.chapters) },
                    onShowSpeed: { lastOpenedOverlay = .speed; showOverlay(.speed) },
                    onShowQuality: { lastOpenedOverlay = .quality; showOverlay(.quality) },
                    onUserInteraction: { resetAutoHide() },
                    onExit: {
                        // Ignore exit if we just closed an overlay (within 500ms)
                        if let closedAt = overlayClosedAt, Date().timeIntervalSince(closedAt) < 0.5 {
                            overlayClosedAt = nil
                            return
                        }
                        hideControls()
                    }
                )
                .ignoresSafeArea()
            }

            // Invisible button when controls are hidden - handles select for play/pause
            if !showControls && activeOverlay == nil {
                Button {
                    togglePlayPause()
                    showControlsAndResetTimer()
                } label: {
                    Color.clear
                }
                .buttonStyle(InvisibleButtonStyle())
                .focused($hiddenControlsFocused)
                .onAppear { hiddenControlsFocused = true }
                .onMoveCommand { _ in
                    showControlsAndResetTimer()
                }
                .onExitCommand {
                    // When controls are hidden and user presses back, exit player
                    Task { await viewModel.stop(); dismiss() }
                }
            }
        }
        .onAppear {
            viewModel.loadSubtitleTracks()
            resetAutoHide()
        }
    }

    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 60)).foregroundStyle(.red)
            Text("Playback Error").font(.title2)
            Text(viewModel.errorMessage ?? "Unknown error").foregroundStyle(.secondary)
            Button("Dismiss") { Task { await viewModel.stop(); dismiss() } }
        }
    }

    @ViewBuilder
    private func pickerOverlay(_ overlay: PlayerOverlay) -> some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()
                .onTapGesture { closeOverlay() }

            VStack(spacing: 0) {
                Text(overlayTitle(overlay))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 30)
                    .padding(.bottom, 20)

                ScrollView {
                    VStack(spacing: 4) {
                        switch overlay {
                        case .subtitles:
                            ForEach(Array(viewModel.subtitleTracks.enumerated()), id: \.element.id) { index, track in
                                PickerRow(title: track.displayName, isSelected: track.id == viewModel.selectedSubtitleTrackId, isFirstItem: index == 0, onExit: closeOverlay) {
                                    viewModel.selectSubtitleTrack(track)
                                    closeOverlay()
                                }
                            }
                        case .chapters:
                            ForEach(Array((viewModel.currentItem?.chapters ?? []).enumerated()), id: \.element.startPositionTicks) { index, chapter in
                                PickerRow(title: chapter.name ?? "Chapter", subtitle: formatTime(chapter.startSeconds), isFirstItem: index == 0, onExit: closeOverlay) {
                                    seekTo(chapter.startSeconds)
                                    closeOverlay()
                                }
                            }
                        case .speed:
                            let speeds: [(String, Float)] = [("0.5×", 0.5), ("0.75×", 0.75), ("1× Normal", 1.0), ("1.25×", 1.25), ("1.5×", 1.5), ("2×", 2.0)]
                            ForEach(Array(speeds.enumerated()), id: \.element.1) { index, item in
                                PickerRow(title: item.0, isSelected: currentSpeed == item.1, isFirstItem: index == 0, onExit: closeOverlay) {
                                    currentSpeed = item.1
                                    viewModel.player?.rate = item.1
                                    closeOverlay()
                                }
                            }
                        case .quality:
                            ForEach(Array(QualityOption.allCases.enumerated()), id: \.element.id) { index, quality in
                                PickerRow(
                                    title: quality.displayName,
                                    isSelected: viewModel.selectedQuality == quality,
                                    isFirstItem: index == 0,
                                    onExit: closeOverlay
                                ) {
                                    Task {
                                        await viewModel.changeQuality(quality)
                                    }
                                    closeOverlay()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
                }
            }
            .frame(width: 500, height: min(CGFloat(overlayItemCount(overlay)) * 70 + 120, 500))
            .background(Color(white: 0.15))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .onExitCommand { closeOverlay() }
    }

    private func closeOverlay() {
        overlayClosedAt = Date()
        activeOverlay = nil
        resetAutoHide()
    }

    private func overlayItemCount(_ overlay: PlayerOverlay) -> Int {
        switch overlay {
        case .subtitles: return viewModel.subtitleTracks.count
        case .chapters: return viewModel.currentItem?.chapters?.count ?? 0
        case .speed: return 6
        case .quality: return 4
        }
    }

    private func overlayTitle(_ overlay: PlayerOverlay) -> String {
        switch overlay {
        case .subtitles: return "Subtitles"
        case .chapters: return "Chapters"
        case .speed: return "Playback Speed"
        case .quality: return "Quality"
        }
    }

    private func upNextOverlay(_ next: BaseItemDto) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            UpNextContent(nextEpisode: next, onPlayNow: {
                Task { await viewModel.playNextEpisode() }
            }, onCancel: { viewModel.cancelUpNext() })
        }
    }

    private func skipOverlay(_ segment: MediaSegmentDto) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button("Skip \(segment.type.displayName)") { viewModel.skipCurrentSegment() }
                    .padding(50)
            }
        }
    }

    private func showOverlay(_ overlay: PlayerOverlay) {
        controlsHideTask?.cancel()
        activeOverlay = overlay
    }

    private func togglePlayPause() {
        guard let player = viewModel.player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.rate = currentSpeed }
    }

    private func seekTo(_ time: Double) {
        viewModel.player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func formatTime(_ s: Double) -> String {
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func showControlsAndResetTimer() {
        showControls = true
        resetAutoHide()
    }

    private func resetAutoHide() {
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(for: .seconds(7))
            if !Task.isCancelled && activeOverlay == nil {
                hideControls()
            }
        }
    }

    private func hideControls() {
        controlsHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) {
            showControls = false
        }
    }
}

// MARK: - Invisible Button Style

struct InvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Picker Row

struct PickerRow: View {
    let title: String
    var subtitle: String?
    var isSelected: Bool = false
    var isFirstItem: Bool = false
    var onExit: (() -> Void)?
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
                    if let subtitle = subtitle {
                        Text(subtitle).font(.system(size: 18)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(SashimiTheme.accent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(isFocused ? Color.white.opacity(0.2) : Color.clear)
            .cornerRadius(10)
        }
        .buttonStyle(PickerRowButtonStyle())
        .focused($isFocused)
        .onExitCommand {
            onExit?()
        }
        .onAppear {
            if isFirstItem {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isFocused = true
                }
            }
        }
    }
}

struct PickerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - Up Next Content

struct UpNextContent: View {
    let nextEpisode: BaseItemDto
    let onPlayNow: () -> Void
    let onCancel: () -> Void
    @State private var countdown = 10
    @State private var task: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 50) {
            AsyncItemImage(itemId: nextEpisode.id, imageType: "Primary", maxWidth: 400)
                .frame(width: 400, height: 225).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 16) {
                Text("Up Next").font(.headline).foregroundStyle(SashimiTheme.accent)
                if let s = nextEpisode.seriesName { Text(s).font(.title2).bold() }
                Text(nextEpisode.name).font(.title3).foregroundStyle(.secondary)
                if let sn = nextEpisode.parentIndexNumber, let ep = nextEpisode.indexNumber {
                    Text(String(format: "S%d · E%d", sn, ep)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 20) {
                    Button("Play Now") { task?.cancel(); onPlayNow() }
                    Button("Cancel") { task?.cancel(); onCancel() }
                }.padding(.top, 20)
                Text("Starting in \(countdown)s...").foregroundStyle(.secondary)
            }
        }.padding(60)
        .onAppear {
            countdown = 10
            task = Task {
                while countdown > 0 {
                    try? await Task.sleep(for: .seconds(1)); if Task.isCancelled { return }; countdown -= 1
                }
                if !Task.isCancelled { onPlayNow() }
            }
        }
        .onDisappear { task?.cancel() }
    }
}

// MARK: - Supporting Views

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView { PlayerUIView(player: player) }
    func updateUIView(_ uiView: PlayerUIView, context: Context) { uiView.player = player }
}

class PlayerUIView: UIView {
    var player: AVPlayer? { get { playerLayer.player } set { playerLayer.player = newValue } }
    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    init(player: AVPlayer) { super.init(frame: .zero); self.player = player; playerLayer.videoGravity = .resizeAspect }
    override init(frame: CGRect) { super.init(frame: frame); playerLayer.videoGravity = .resizeAspect }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
