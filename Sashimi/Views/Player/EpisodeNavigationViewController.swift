import AVFoundation
import UIKit

// MARK: - Episode Navigation (focusable tvOS controls)

final class EpisodeNavigationViewController: UIViewController {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onReplay: (() -> Void)?
    var onDone: (() -> Void)?
    var settingsMenu: UIMenu? {
        didSet { settingsButton.menu = settingsMenu }
    }

    private let settingsButton = EpisodeNavigationViewController.makeButton(title: "Settings", imageName: "gearshape")

    private let previousButton = EpisodeNavigationViewController.makeTransportButton(title: "Previous Episode", imageName: "backward.fill")
    private let skipBackwardButton = EpisodeNavigationViewController.makeTransportButton(title: "Skip Backward", imageName: "gobackward.10")
    private let playPauseButton = EpisodeNavigationViewController.makeTransportButton(title: "Play/Pause", imageName: "pause.fill")
    private let skipForwardButton = EpisodeNavigationViewController.makeTransportButton(title: "Skip Forward", imageName: "goforward.10")
    private let nextButton = EpisodeNavigationViewController.makeTransportButton(title: "Next Episode", imageName: "forward.fill")
    private let playNextButton = EpisodeNavigationViewController.makeButton(title: "Play Next", imageName: "forward.fill")
    private let replayButton = EpisodeNavigationViewController.makeButton(title: "Replay", imageName: "gobackward")
    private let doneButton = EpisodeNavigationViewController.makeButton(title: "Done", imageName: "checkmark")
    private let messageLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = .systemFont(ofSize: 34, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()
    private let controls = UIStackView()
    private let endCard = UIStackView()
    private weak var player: AVPlayer?
    private weak var observedPlayer: AVPlayer?
    private var playerObservation: NSKeyValueObservation?

    override func loadView() {
        let passthrough = PassthroughView()
        passthrough.backgroundColor = .clear
        view = passthrough
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        controls.axis = .horizontal
        // The opt-in row owns the complete transport cluster on tvOS. This
        // keeps episode navigation adjacent to the same skip/pause actions as
        // iPhone and iPad instead of leaving the episode buttons stranded on
        // an otherwise-hidden native transport bar.
        controls.spacing = 24
        controls.alignment = .center
        controls.addArrangedSubview(previousButton)
        controls.addArrangedSubview(skipBackwardButton)
        controls.addArrangedSubview(playPauseButton)
        controls.addArrangedSubview(skipForwardButton)
        controls.addArrangedSubview(nextButton)

        endCard.axis = .vertical
        endCard.spacing = 20
        endCard.alignment = .center
        endCard.addArrangedSubview(messageLabel)
        let actions = UIStackView(arrangedSubviews: [playNextButton, replayButton, doneButton])
        actions.axis = .horizontal
        actions.spacing = 18
        endCard.addArrangedSubview(actions)
        endCard.isHidden = true

        settingsButton.showsMenuAsPrimaryAction = true
        view.addSubview(settingsButton)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        view.addSubview(endCard)
        controls.translatesAutoresizingMaskIntoConstraints = false
        endCard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            settingsButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -80),
            settingsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            controls.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -70),
            endCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            endCard.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        previousButton.addTarget(self, action: #selector(previousTapped), for: .primaryActionTriggered)
        skipBackwardButton.addTarget(self, action: #selector(skipBackwardTapped), for: .primaryActionTriggered)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .primaryActionTriggered)
        skipForwardButton.addTarget(self, action: #selector(skipForwardTapped), for: .primaryActionTriggered)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .primaryActionTriggered)
        playNextButton.addTarget(self, action: #selector(nextTapped), for: .primaryActionTriggered)
        replayButton.addTarget(self, action: #selector(replayTapped), for: .primaryActionTriggered)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .primaryActionTriggered)
    }

    func update(state: PlayerTransitionState, showEpisodeNavigationControls: Bool, player: AVPlayer?) {
        guard isViewLoaded else { return }
        self.player = player
        observe(player: player)
        previousButton.isEnabled = state.canPlayPrevious
        nextButton.isEnabled = state.canPlayNext
        skipBackwardButton.isEnabled = player != nil
        skipForwardButton.isEnabled = player != nil
        playPauseButton.isEnabled = player != nil
        updatePlayPauseImage()
        playNextButton.isEnabled = state.canPlayNext
        playNextButton.isHidden = !state.canPlayNext
        endCard.isHidden = state.endCard == nil
        controls.isHidden = state.endCard != nil || !showEpisodeNavigationControls
        settingsButton.isHidden = controls.isHidden
        settingsButton.isEnabled = !state.isTransitioning
        replayButton.isEnabled = !state.isTransitioning
        switch state.endCard {
        case .nextEpisode:
            messageLabel.text = "Episode complete\nReady for the next episode"
        case .finalEpisode:
            messageLabel.text = "There are no more episodes"
        case .lookupFailed:
            messageLabel.text = "Next episode unavailable\nTry again later or replay"
        case nil:
            messageLabel.text = nil
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        let candidates = endCard.isHidden
            ? (controls.isHidden ? [] : [playPauseButton, previousButton, nextButton, settingsButton])
            : [playNextButton, replayButton, doneButton]
        if let first = candidates.first(where: { !$0.isHidden && $0.isEnabled }) {
            return [first]
        }
        return []
    }

    private func observe(player: AVPlayer?) {
        guard observedPlayer !== player else { return }
        playerObservation = nil
        observedPlayer = player
        guard let player else { return }
        playerObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.updatePlayPauseImage()
            }
        }
    }

    private func updatePlayPauseImage() {
        var configuration = playPauseButton.configuration ?? .filled()
        configuration.image = player?.timeControlStatus == .playing
            ? UIImage(systemName: "pause.fill")
            : UIImage(systemName: "play.fill")
        playPauseButton.configuration = configuration
    }

    private func seek(by seconds: Double) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let target = max(0, current + seconds)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private static func makeButton(title: String, imageName: String) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: imageName)
        configuration.imagePadding = 12
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.7)
        configuration.baseForegroundColor = .white
        return UIButton(configuration: configuration)
    }

    private static func makeTransportButton(title: String, imageName: String) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: imageName)
        configuration.contentInsets = .zero
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.white.withAlphaComponent(0.18)
        configuration.baseForegroundColor = .white
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 64).isActive = true
        button.heightAnchor.constraint(equalToConstant: 64).isActive = true
        button.accessibilityLabel = title
        return button
    }

    @objc private func previousTapped() { onPrevious?() }
    @objc private func skipBackwardTapped() { seek(by: -10) }
    @objc private func playPauseTapped() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
        updatePlayPauseImage()
    }
    @objc private func skipForwardTapped() { seek(by: 10) }
    @objc private func nextTapped() { onNext?() }
    @objc private func replayTapped() { onReplay?() }
    @objc private func doneTapped() { onDone?() }
}
