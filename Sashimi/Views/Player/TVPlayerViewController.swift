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

        // Subtitles are rendered by our own overlay and selected through the
        // custom captions.bubble menu below, but AVPlayerViewController also
        // shows its native subtitle panel whenever the player item exposes
        // legible options — a second, non-functional subtitle control. The
        // no-match language sentinel empties the native subtitle tab while
        // keeping the native AUDIO tab (the only audio control on tvOS).
        playerVC.allowedSubtitleOptionLanguages = [""]

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

        // Update skip button visibility. Whenever the visibility changes we
        // also kick the focus engine via setNeedsFocusUpdate so the container's
        // preferredFocusEnvironments override is re-evaluated — without this
        // the button can appear on screen but stay unfocused, which on tvOS
        // looks like the button is missing entirely (no remote response).
        if let skipVC = context.coordinator.skipVC {
            let wasHidden = skipVC.view.isHidden
            if viewModel.showingSkipButton, let segment = viewModel.currentSegment {
                let title = "Skip \(segment.type.displayName)"
                skipVC.updateTitle(title)
                if wasHidden {
                    skipVC.view.isHidden = false
                    container.setNeedsFocusUpdate()
                    container.updateFocusIfNeeded()
                }
            } else if !wasHidden {
                skipVC.view.isHidden = true
                container.setNeedsFocusUpdate()
                container.updateFocusIfNeeded()
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

        // Skip button: install as a sibling of playerVC.view inside the container,
        // NOT inside the AVPlayerViewController. This is the only way to get a
        // skip button that is BOTH always visible AND focusable on tvOS:
        //
        //   - contentOverlayView is visible but isUserInteractionEnabled is false
        //     (verified: previous fix d337c87 — button never received focus).
        //   - customOverlayViewController is focusable but only displays alongside
        //     the transport bar (verified: previous fix c564952 — button hidden
        //     during normal playback).
        //
        // Putting it in the container with a custom focus environment gives us
        // both: the view is part of the normal hierarchy so it always renders,
        // and the container's preferredFocusEnvironments override forces the
        // focus engine onto the button while a segment is active.
        let skipVC = SkipButtonViewController()
        let coordinator = context.coordinator
        skipVC.onSkip = {
            coordinator.skipSegmentTapped()
        }
        skipVC.view.translatesAutoresizingMaskIntoConstraints = false
        skipVC.view.isHidden = true

        container.addChild(skipVC)
        container.view.addSubview(skipVC.view)
        skipVC.didMove(toParent: container)

        // Pin the skip button overlay to the full container so its internal
        // button constraints (bottom-right with insets) can position relative
        // to the screen rather than a zero-size frame.
        NSLayoutConstraint.activate([
            skipVC.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            skipVC.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            skipVC.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            skipVC.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])

        container.skipVC = skipVC
        container.playerVC = playerVC
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
    weak var playerVC: AVPlayerViewController?

    /// When the skip button is visible, route the focus engine to it. Otherwise
    /// give focus back to the AVPlayerViewController so the user retains
    /// normal playback controls.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let skipVC, !skipVC.view.isHidden {
            return [skipVC.view]
        }
        if let playerVC {
            return [playerVC]
        }
        return super.preferredFocusEnvironments
    }
}

// MARK: - Skip Button (sibling overlay inside the container, not a child of AVPVC)

class SkipButtonViewController: UIViewController {
    var onSkip: (() -> Void)?
    private let button: UIButton = {
        // Use modern UIButton.Configuration so contentInsets isn't ignored on
        // tvOS 15+. The old setTitleColor / contentEdgeInsets API is deprecated
        // when a configuration is set, and the build emits a warning.
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.65)
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 36, bottom: 16, trailing: 36)
        config.cornerStyle = .capsule
        var titleAttr = AttributedString("Skip")
        titleAttr.font = .systemFont(ofSize: 32, weight: .bold)
        config.attributedTitle = titleAttr
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    override func loadView() {
        // Use a passthrough container view so taps in empty space go through
        // to the player below. Only the button itself is interactive.
        let passthrough = PassthroughView()
        passthrough.backgroundColor = .clear
        view = passthrough
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        button.addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
        view.addSubview(button)

        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -80),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),
        ])
    }

    func updateTitle(_ title: String) {
        var config = button.configuration
        var titleAttr = AttributedString(title)
        titleAttr.font = .systemFont(ofSize: 32, weight: .bold)
        config?.attributedTitle = titleAttr
        button.configuration = config
    }

    @objc private func tapped() {
        onSkip?()
    }

    // The button must be the preferred focus when this VC is asked, so the
    // container's preferredFocusEnvironments → [skipVC.view] chain lands on
    // the actual button rather than the empty passthrough wrapper.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [button]
    }
}

/// UIView subclass that lets touches pass through to underlying views except
/// where one of its visible subviews (e.g. the skip button) is hit. This
/// keeps the AVPlayerViewController fully usable when the skip button is
/// hidden — without this, the full-bounds wrapper would swallow remote input.
private class PassthroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for subview in subviews where !subview.isHidden && subview.alpha > 0 {
            let converted = convert(point, to: subview)
            if subview.point(inside: converted, with: event) {
                return true
            }
        }
        return false
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
