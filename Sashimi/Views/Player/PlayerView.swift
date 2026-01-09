import SwiftUI
import AVKit
import Combine

private enum PlayerTheme {
    static let accent = Color(red: 0.36, green: 0.68, blue: 0.90)
    static let cardBackground = Color(white: 0.12)
}

// MARK: - AVPlayerViewController Wrapper
// Uses native tvOS player controls including swipe-down info panel for audio/subtitle selection

struct TVPlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false

        // Add playback speed menu to transport bar
        controller.transportBarCustomMenuItems = [createSpeedMenu(for: player, coordinator: context.coordinator)]

        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }

    private func createSpeedMenu(for player: AVPlayer, coordinator: Coordinator) -> UIMenu {
        let speeds: [(String, Float)] = [
            ("0.5×", 0.5),
            ("0.75×", 0.75),
            ("1× (Normal)", 1.0),
            ("1.25×", 1.25),
            ("1.5×", 1.5),
            ("2×", 2.0)
        ]

        let actions = speeds.map { title, rate in
            UIAction(
                title: title,
                state: coordinator.currentSpeed == rate ? .on : .off
            ) { _ in
                player.rate = rate
                coordinator.currentSpeed = rate
            }
        }

        return UIMenu(
            title: "Playback Speed",
            image: UIImage(systemName: "speedometer"),
            children: actions
        )
    }

    class Coordinator {
        var currentSpeed: Float = 1.0

        var speedTitle: String {
            switch currentSpeed {
            case 0.5: return "0.5×"
            case 0.75: return "0.75×"
            case 1.0: return "1×"
            case 1.25: return "1.25×"
            case 1.5: return "1.5×"
            case 2.0: return "2×"
            default: return "\(currentSpeed)×"
            }
        }
    }
}

struct PlayerView: View {
    let item: BaseItemDto

    @StateObject private var viewModel = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading \(item.displayTitle)...")
                        .font(.headline)
                }
            } else if let error = viewModel.error ?? (viewModel.errorMessage != nil ? PlayerError.noStreamURL : nil) {
                errorView(error: error)
            } else if let player = viewModel.player {
                // Native AVPlayerViewController for full tvOS controls including audio/subtitle selection
                TVPlayerViewController(player: player)
                    .ignoresSafeArea()
            }

            // Resume playback dialog
            if viewModel.showingResumeDialog {
                ResumePlaybackOverlay(
                    resumePositionTicks: viewModel.resumePositionTicks,
                    onResume: {
                        Task { await viewModel.resumePlayback() }
                    },
                    onStartOver: {
                        Task { await viewModel.startFromBeginning() }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Up Next overlay
            if viewModel.showingUpNext, let nextEpisode = viewModel.nextEpisode {
                UpNextOverlay(
                    nextEpisode: nextEpisode,
                    onPlayNow: {
                        Task { await viewModel.playNextEpisode() }
                    },
                    onCancel: {
                        viewModel.cancelUpNext()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Skip Intro/Credits button
            if viewModel.showingSkipButton, let segment = viewModel.currentSegment {
                SkipSegmentOverlay(
                    segmentType: segment.type,
                    onSkip: {
                        viewModel.skipCurrentSegment()
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.showingResumeDialog)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showingUpNext)
        .animation(.easeInOut(duration: 0.25), value: viewModel.showingSkipButton)
        .task {
            await viewModel.loadMedia(item: item)
        }
        .onDisappear {
            Task {
                await viewModel.stop()
            }
        }
        .onExitCommand {
            if viewModel.showingUpNext {
                viewModel.cancelUpNext()
            } else {
                Task {
                    await viewModel.stop()
                    dismiss()
                }
            }
        }
        .onChange(of: viewModel.playbackEnded) { _, ended in
            if ended {
                dismiss()
            }
        }
    }

    private func errorView(error: Error) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.red)

            Text("Playback Error")
                .font(.title2)

            Text(viewModel.errorMessage ?? error.localizedDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Dismiss") {
                Task {
                    await viewModel.stop()
                    dismiss()
                }
            }
        }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
    }
}

class PlayerUIView: UIView {
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer  // Safe: layerClass returns AVPlayerLayer.self
    }

    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct ControlButton: View {
    let icon: String
    let label: String
    var isLarge: Bool = false
    let action: () -> Void

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: isLarge ? 44 : 28))
            if !label.isEmpty {
                Text(label)
                    .font(.caption)
            }
        }
        .frame(width: isLarge ? 100 : 80, height: isLarge ? 100 : 80)
        .background(isFocused ? Color.white.opacity(0.3) : Color.white.opacity(0.1))
        .clipShape(Circle())
        .scaleEffect(isFocused ? 1.15 : 1.0)
        .animation(.spring(response: 0.3), value: isFocused)
        .focusable(true) { _ in
            // Focus changed
        }
        .onLongPressGesture(minimumDuration: 0.01, pressing: { pressing in
            if !pressing {
                action()
            }
        }, perform: {})
    }
}

struct PlayerProgressBar: View {
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @FocusState private var isFocused: Bool
    @State private var scrubPosition: Double?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return (scrubPosition ?? currentTime) / duration
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.3))

                // Progress
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: isFocused ? 12 : 6)
        .animation(.spring(response: 0.3), value: isFocused)
        .focused($isFocused)
    }
}

struct AudioPickerSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(viewModel.audioTracks) { track in
                Button {
                    viewModel.selectAudioTrack(track)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.displayName)
                                .font(.headline)
                            if let lang = track.languageCode {
                                Text(lang.uppercased())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if track.id == viewModel.selectedAudioTrackId {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Audio")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SubtitlePickerSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(viewModel.subtitleTracks) { track in
                Button {
                    viewModel.selectSubtitleTrack(track)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.displayName)
                                .font(.headline)
                            if let lang = track.languageCode {
                                Text(lang.uppercased())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if track.id == viewModel.selectedSubtitleTrackId {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Subtitles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ResumePlaybackOverlay: View {
    let resumePositionTicks: Int64
    let onResume: () -> Void
    let onStartOver: () -> Void

    @State private var countdown = 5
    @State private var countdownTask: Task<Void, Never>?
    @FocusState private var focusedButton: ResumeButton?

    private enum ResumeButton {
        case resume, startOver
    }

    private var formattedTime: String {
        let totalSeconds = Int(resumePositionTicks / 10_000_000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 40) {
                VStack(spacing: 16) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(PlayerTheme.accent)

                    Text("Resume Playback?")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("You were at \(formattedTime)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 30) {
                    ResumeDialogButton(
                        title: "Resume",
                        icon: "play.fill",
                        isPrimary: true,
                        isFocused: focusedButton == .resume
                    ) {
                        countdownTask?.cancel()
                        onResume()
                    }
                    .focused($focusedButton, equals: .resume)

                    ResumeDialogButton(
                        title: "Start Over",
                        icon: "arrow.counterclockwise",
                        isPrimary: false,
                        isFocused: focusedButton == .startOver
                    ) {
                        countdownTask?.cancel()
                        onStartOver()
                    }
                    .focused($focusedButton, equals: .startOver)
                }

                Text("Resuming in \(countdown) seconds...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            countdown = 5  // Reset countdown each time overlay appears
            focusedButton = .resume
            startCountdown()
        }
        .onDisappear {
            countdownTask?.cancel()
        }
    }

    private func startCountdown() {
        countdownTask = Task {
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                countdown -= 1
            }
            if !Task.isCancelled {
                onResume()
            }
        }
    }
}

private struct ResumeDialogButton: View {
    let title: String
    let icon: String
    let isPrimary: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.headline)
            .padding(.horizontal, isPrimary ? 40 : 32)
            .padding(.vertical, 16)
            .foregroundStyle(isPrimary ? .black : .white)
            .background(isPrimary ? Color.white : Color.white.opacity(0.2))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(PlayerTheme.accent, lineWidth: isFocused ? 4 : 0)
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
    }
}

struct UpNextOverlay: View {
    let nextEpisode: BaseItemDto
    let onPlayNow: () -> Void
    let onCancel: () -> Void

    @State private var countdown = 10
    @State private var countdownTask: Task<Void, Never>?
    @FocusState private var focusedButton: UpNextButton?

    private enum UpNextButton {
        case playNow, cancel
    }

    var body: some View {
        ZStack {
            // Semi-transparent background
            LinearGradient(
                colors: [Color.black.opacity(0.9), Color.black.opacity(0.7)],
                startPoint: .bottom,
                endPoint: .top
            )
            .ignoresSafeArea()

            HStack(spacing: 60) {
                // Episode thumbnail
                AsyncItemImage(
                    itemId: nextEpisode.id,
                    imageType: "Primary",
                    maxWidth: 400
                )
                .frame(width: 400, height: 225)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Episode info and controls
                VStack(alignment: .leading, spacing: 24) {
                    Text("Up Next")
                        .font(.headline)
                        .foregroundStyle(PlayerTheme.accent)

                    VStack(alignment: .leading, spacing: 8) {
                        if let seriesName = nextEpisode.seriesName {
                            Text(seriesName)
                                .font(.title2)
                                .fontWeight(.bold)
                        }

                        Text(nextEpisode.name)
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        if let season = nextEpisode.parentIndexNumber,
                           let episode = nextEpisode.indexNumber {
                            Text(verbatim: "S\(season):E\(episode)")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer().frame(height: 20)

                    HStack(spacing: 30) {
                        ResumeDialogButton(
                            title: "Play Now",
                            icon: "play.fill",
                            isPrimary: true,
                            isFocused: focusedButton == .playNow
                        ) {
                            countdownTask?.cancel()
                            onPlayNow()
                        }
                        .focused($focusedButton, equals: .playNow)

                        ResumeDialogButton(
                            title: "Cancel",
                            icon: "xmark",
                            isPrimary: false,
                            isFocused: focusedButton == .cancel
                        ) {
                            countdownTask?.cancel()
                            onCancel()
                        }
                        .focused($focusedButton, equals: .cancel)
                    }

                    Text("Starting in \(countdown) seconds...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(80)
        }
        .onAppear {
            countdown = 10  // Reset countdown each time overlay appears
            focusedButton = .playNow
            startCountdown()
        }
        .onDisappear {
            countdownTask?.cancel()
        }
    }

    private func startCountdown() {
        countdownTask = Task {
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                countdown -= 1
            }
            if !Task.isCancelled {
                onPlayNow()
            }
        }
    }
}

struct SkipSegmentOverlay: View {
    let segmentType: MediaSegmentType
    let onSkip: () -> Void

    @FocusState private var isFocused: Bool

    private var buttonTitle: String {
        "Skip \(segmentType.displayName)"
    }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: onSkip) {
                    HStack(spacing: 10) {
                        Image(systemName: "forward.fill")
                        Text(buttonTitle)
                    }
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .foregroundStyle(.black)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(PlayerTheme.accent, lineWidth: isFocused ? 4 : 0)
                    )
                    .scaleEffect(isFocused ? 1.05 : 1.0)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                    .animation(.spring(response: 0.3), value: isFocused)
                }
                .buttonStyle(PlainNoHighlightButtonStyle())
                .focused($isFocused)
                .padding(60)
            }
        }
        .onAppear {
            isFocused = true
        }
    }
}

#Preview {
    PlayerView(item: BaseItemDto(
        id: "test",
        name: "Test Movie",
        type: .movie,
        seriesName: nil,
        seriesId: nil,
        seasonId: nil,
        parentId: nil,
        indexNumber: nil,
        parentIndexNumber: nil,
        overview: nil,
        runTimeTicks: nil,
        userData: nil,
        imageTags: nil,
        backdropImageTags: nil,
        parentBackdropImageTags: nil,
        primaryImageAspectRatio: nil,
        mediaType: nil,
        productionYear: nil,
        communityRating: nil,
        officialRating: nil,
        genres: nil,
        taglines: nil,
        people: nil,
        criticRating: nil,
        premiereDate: nil
    ))
}
