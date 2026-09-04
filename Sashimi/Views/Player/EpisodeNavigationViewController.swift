import UIKit

// MARK: - Episode Navigation (focusable tvOS controls)

final class EpisodeNavigationViewController: UIViewController {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onReplay: (() -> Void)?
    var onDone: (() -> Void)?

    private let previousButton = EpisodeNavigationViewController.makeButton(title: "Previous", imageName: "backward.fill")
    private let nextButton = EpisodeNavigationViewController.makeButton(title: "Next", imageName: "forward.fill")
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

    override func loadView() {
        let passthrough = PassthroughView()
        passthrough.backgroundColor = .clear
        view = passthrough
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        controls.axis = .horizontal
        controls.spacing = 18
        controls.alignment = .center
        controls.addArrangedSubview(previousButton)
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

        view.addSubview(controls)
        view.addSubview(endCard)
        controls.translatesAutoresizingMaskIntoConstraints = false
        endCard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 80),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -70),
            endCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            endCard.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        previousButton.addTarget(self, action: #selector(previousTapped), for: .primaryActionTriggered)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .primaryActionTriggered)
        playNextButton.addTarget(self, action: #selector(nextTapped), for: .primaryActionTriggered)
        replayButton.addTarget(self, action: #selector(replayTapped), for: .primaryActionTriggered)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .primaryActionTriggered)
    }

    func update(state: PlayerTransitionState) {
        guard isViewLoaded else { return }
        previousButton.isEnabled = state.canPlayPrevious
        nextButton.isEnabled = state.canPlayNext
        playNextButton.isEnabled = state.canPlayNext
        playNextButton.isHidden = !state.canPlayNext
        endCard.isHidden = state.endCard == nil
        controls.isHidden = state.endCard != nil
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
        if let first = [playNextButton, replayButton, doneButton, previousButton, nextButton]
            .first(where: { !$0.isHidden && $0.isEnabled }) {
            return [first]
        }
        return []
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

    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func replayTapped() { onReplay?() }
    @objc private func doneTapped() { onDone?() }
}
