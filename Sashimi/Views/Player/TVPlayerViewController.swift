import SwiftUI
import AVKit

// MARK: - SwiftUI Bridge

struct TVPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    @ObservedObject var viewModel: PlayerViewModel
    let item: BaseItemDto
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> PlayerContainerVC {
        let container = PlayerContainerVC()
        container.view.backgroundColor = .black

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.showsPlaybackControls = true
        playerVC.delegate = context.coordinator

        playerVC.transportBarCustomMenuItems = buildMenus()

        // Embed AVPVC as child VC (not modal — avoids dismiss lifecycle issues)
        container.addChild(playerVC)
        playerVC.view.frame = container.view.bounds
        playerVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.view.addSubview(playerVC.view)
        playerVC.didMove(toParent: container)

        context.coordinator.playerVC = playerVC
        context.coordinator.currentViewModel = viewModel
        context.coordinator.currentItem = viewModel.currentItem ?? item

        // Add content overlay (subtitles, info, clock)
        setupOverlay(on: playerVC, container: container, context: context)

        return container
    }

    func updateUIViewController(_ container: PlayerContainerVC, context: Context) {
        guard let playerVC = context.coordinator.playerVC else { return }

        // Update player if changed (quality switch recreates player)
        if playerVC.player !== player {
            playerVC.player = player
        }

        // Rebuild menus when selection state changes
        playerVC.transportBarCustomMenuItems = buildMenus()

        // Update stored state and overlay
        let displayItem = viewModel.currentItem ?? item
        context.coordinator.currentViewModel = viewModel
        context.coordinator.currentItem = displayItem
        context.coordinator.updateOverlay()

        // Update skip button visibility
        if let skipVC = context.coordinator.skipVC {
            if viewModel.showingSkipButton, let segment = viewModel.currentSegment {
                let title = "Skip \(segment.type.displayName)"
                skipVC.updateTitle(title)
                if skipVC.view.isHidden {
                    skipVC.view.isHidden = false
                }
            } else if !skipVC.view.isHidden {
                skipVC.view.isHidden = true
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    // MARK: - Overlay Setup

    private func setupOverlay(on playerVC: AVPlayerViewController, container: PlayerContainerVC, context: Context) {
        let displayItem = viewModel.currentItem ?? item
        let overlay = PlayerContentOverlay(viewModel: viewModel, item: displayItem, controlsVisible: false)
        let hosting = UIHostingController(rootView: overlay)
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false

        playerVC.addChild(hosting)
        if let contentOverlay = playerVC.contentOverlayView {
            hosting.view.frame = contentOverlay.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentOverlay.addSubview(hosting.view)
        }
        hosting.didMove(toParent: playerVC)
        context.coordinator.hostingController = hosting

        // Skip button in a custom overlay VC so it's focusable alongside the transport bar
        let skipVC = SkipButtonViewController()
        let coordinator = context.coordinator
        skipVC.onSkip = {
            coordinator.skipSegmentTapped()
        }
        skipVC.view.isHidden = true

        playerVC.customOverlayViewController = skipVC
        container.skipVC = skipVC
        context.coordinator.skipVC = skipVC
    }

    // MARK: - Transport Bar Menus

    private func buildMenus() -> [UIMenuElement] {
        var menus: [UIMenuElement] = []

        // Speed menu
        let speeds: [(String, Float)] = [
            ("0.5×", 0.5), ("0.75×", 0.75), ("1× Normal", 1.0),
            ("1.25×", 1.25), ("1.5×", 1.5), ("2×", 2.0)
        ]
        let currentRate = player.rate != 0 ? player.rate : 1.0
        let speedActions = speeds.map { title, rate in
            UIAction(
                title: title,
                state: currentRate == rate ? .on : .off
            ) { _ in
                player.rate = rate
            }
        }
        let speedMenu = UIMenu(
            title: "Speed",
            image: UIImage(systemName: "speedometer"),
            children: speedActions
        )
        menus.append(speedMenu)

        // Subtitles menu
        let subtitleActions = viewModel.subtitleTracks.map { track in
            UIAction(
                title: track.displayName,
                state: track.id == viewModel.selectedSubtitleTrackId ? .on : .off
            ) { _ in
                viewModel.selectSubtitleTrack(track)
            }
        }
        if !subtitleActions.isEmpty {
            let subtitleMenu = UIMenu(
                title: "Subtitles",
                image: UIImage(systemName: "captions.bubble"),
                children: subtitleActions
            )
            menus.append(subtitleMenu)
        }

        // Quality menu
        let qualityActions = QualityOption.allCases.map { quality in
            UIAction(
                title: quality.displayName,
                state: viewModel.selectedQuality == quality ? .on : .off
            ) { _ in
                Task { await viewModel.changeQuality(quality) }
            }
        }
        let qualityMenu = UIMenu(
            title: "Quality",
            image: UIImage(systemName: "gearshape"),
            children: qualityActions
        )
        menus.append(qualityMenu)

        return menus
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let onDismiss: () -> Void
        var playerVC: AVPlayerViewController?
        var hostingController: UIHostingController<PlayerContentOverlay>?
        var skipVC: SkipButtonViewController?
        var controlsVisible = false
        weak var currentViewModel: PlayerViewModel?
        var currentItem: BaseItemDto?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func skipSegmentTapped() {
            Task { @MainActor in
                self.currentViewModel?.skipCurrentSegment()
            }
        }

        // Called when user presses Menu with transport bar hidden
        func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            onDismiss()
            return false
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willTransitionToVisibilityOfTransportBar visible: Bool,
            with coordinator: AVPlayerViewControllerAnimationCoordinator
        ) {
            coordinator.addCoordinatedAnimations({
                self.controlsVisible = visible
                self.updateOverlay()
            }, completion: nil)
        }

        func updateOverlay() {
            guard let viewModel = currentViewModel, let item = currentItem else { return }
            hostingController?.rootView = PlayerContentOverlay(
                viewModel: viewModel,
                item: item,
                controlsVisible: controlsVisible
            )
        }
    }
}

// MARK: - Container VC (supports focus redirection to skip button)

class PlayerContainerVC: UIViewController {
    var skipVC: SkipButtonViewController?
}

// MARK: - Skip Button (custom overlay VC for AVPlayerViewController focus support)

class SkipButtonViewController: UIViewController {
    var onSkip: (() -> Void)?
    private let button = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        button.setTitle("Skip", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 32, weight: .bold)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
        view.addSubview(button)

        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -90)
        ])
    }

    func updateTitle(_ title: String) {
        button.setTitle(title, for: .normal)
    }

    @objc private func tapped() {
        onSkip?()
    }
}

// MARK: - Content Overlay (info bar, subtitles, clock)

struct PlayerContentOverlay: View {
    @ObservedObject var viewModel: PlayerViewModel
    let item: BaseItemDto
    var controlsVisible: Bool = false

    // Check if this is a YouTube episode
    private var isYouTubeEpisode: Bool {
        guard item.type == .episode else { return false }
        if item.path?.lowercased().contains("youtube") == true { return true }
        if let season = item.parentIndexNumber, let episode = item.indexNumber {
            if season > 2100 || episode > 1000 { return true }
        }
        return false
    }

    @State private var clockTime = Date()
    private let clockTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var formattedReleaseDate: String? {
        if let premiereDateStr = item.premiereDate {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFormatter.date(from: premiereDateStr) ?? ISO8601DateFormatter().date(from: premiereDateStr) {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMMM d, yyyy"
                return formatter.string(from: date)
            }
        }
        if let year = item.productionYear {
            return String(year)
        }
        return nil
    }

    private var clockText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = PlaybackSettings.shared.use24HourTime ? "HH:mm" : "h:mm a"
        return formatter.string(from: clockTime)
    }

    private var finishesAtText: String? {
        guard let player = viewModel.player,
              let duration = player.currentItem?.duration,
              duration.isValid && !duration.isIndefinite,
              duration.seconds > 0 else { return nil }

        let currentSeconds = player.currentTime().seconds
        let remainingSeconds = duration.seconds - currentSeconds
        guard remainingSeconds > 0 else { return nil }

        let rate = player.rate > 0 ? Double(player.rate) : 1.0
        let finishDate = clockTime.addingTimeInterval(remainingSeconds / rate)
        let formatter = DateFormatter()
        formatter.dateFormat = PlaybackSettings.shared.use24HourTime ? "HH:mm" : "h:mm a"
        return "Finishes at " + formatter.string(from: finishDate)
    }

    var body: some View {
        ZStack {
            // Subtitles (always active)
            SubtitleOverlay(manager: viewModel.subtitleManager)

            // Top info bar + clock (only when transport bar is visible)
            if controlsVisible {
                VStack {
                    topInfoBar
                        .padding(.horizontal, 80)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.4))
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controlsVisible)
        .onReceive(clockTimer) { _ in
            clockTime = Date()
        }
    }

    // MARK: - Top Info Bar

    private var topInfoBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 12) {
                // Series logo or channel art
                if item.type == .episode, let seriesId = item.seriesId {
                    if isYouTubeEpisode {
                        HStack(spacing: 20) {
                            Circle()
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 80, height: 80)
                                .overlay(
                                    AsyncItemImage(
                                        itemId: seriesId,
                                        imageType: "Primary",
                                        maxWidth: 160,
                                        contentMode: .fill,
                                        fallbackImageTypes: ["Thumb"]
                                    )
                                    .clipShape(Circle())
                                )
                            if let seriesName = item.seriesName {
                                Text(seriesName)
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                    } else {
                        AsyncItemImage(
                            itemId: seriesId,
                            imageType: "Logo",
                            maxWidth: 800,
                            contentMode: .fit,
                            fallbackImageTypes: []
                        )
                        .frame(maxHeight: 100, alignment: .leading)
                        .frame(maxWidth: 500, alignment: .leading)
                        .clipped()
                    }
                }

                // Title with S#:E# prefix for episodes
                HStack(spacing: 10) {
                    if !isYouTubeEpisode, let season = item.parentIndexNumber, let episode = item.indexNumber {
                        Text("S\(season):E\(episode)")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(.white)
                        Text("·")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(item.type == .episode ? item.name : item.displayTitle)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                // Release date, quality, and finish time
                HStack(spacing: 8) {
                    if let dateText = formattedReleaseDate {
                        Text(dateText)
                    }
                    if let resolution = viewModel.videoResolution {
                        if formattedReleaseDate != nil {
                            Text("·")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Text(resolution)
                    }
                    if let finishText = finishesAtText {
                        if formattedReleaseDate != nil || viewModel.videoResolution != nil {
                            Text("·")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Text(finishText)
                    }
                }
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Text(clockText)
                .font(.system(size: 42, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
    }
}
