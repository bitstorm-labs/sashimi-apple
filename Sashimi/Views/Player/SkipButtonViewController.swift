import SwiftUI
import UIKit

// MARK: - Skip Button (sibling overlay inside the container, not a child of AVPVC)

class SkipButtonViewController: UIViewController {
    var onSkip: (() -> Void)?
    /// The focusable control. It stays a plain UIButton so the focus guide,
    /// `preferredFocusEnvironments` and primary-action handling below behave
    /// exactly as before; only what it draws (the countdown pill) changed.
    let button = SkipPillButton()

    override func loadView() {
        // Use a passthrough container view so taps in empty space go through
        // to the player below. Only the button itself is interactive.
        let passthrough = PassthroughView()
        passthrough.backgroundColor = .clear
        view = passthrough
    }

    /// Creates a navigation path BACK to the skip button.
    ///
    /// `preferredFocusEnvironments` only decides where focus goes when the
    /// engine asks the container -- initial focus, or an explicit
    /// setNeedsFocusUpdate. It is not bidirectional navigation. So once the
    /// user swiped up to the transport bar there was no way to return to the
    /// skip button: it stayed on screen, visibly unfocused, and no remote
    /// direction could reach it.
    ///
    /// The guide occupies the band to the button's left, at the button's own
    /// height, so a move that lands anywhere in that strip is redirected to the
    /// button.
    private let focusGuide = UIFocusGuide()

    override func viewDidLoad() {
        super.viewDidLoad()

        // The pill is SwiftUI; its hosting controller joins the VC hierarchy
        // so it lays out, sizes the button and updates like any child.
        addChild(button.host)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
        view.addSubview(button)
        button.host.didMove(toParent: self)

        view.addLayoutGuide(focusGuide)
        focusGuide.preferredFocusEnvironments = [button]

        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -80),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),

            focusGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            focusGuide.trailingAnchor.constraint(equalTo: button.leadingAnchor),
            focusGuide.topAnchor.constraint(equalTo: button.topAnchor),
            focusGuide.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        // Disabled until a segment is actually showing, or the guide would
        // silently swallow focus moves toward the transport bar whenever no
        // skip button exists.
        focusGuide.isEnabled = false
    }

    /// Keeps the focus guide in step with the button's visibility.
    func setGuideEnabled(_ enabled: Bool) {
        focusGuide.isEnabled = enabled
    }

    /// Shows the pill for `segment` (nil clears it), reading the player's
    /// position through `currentTime` for the fill and countdown.
    func update(segment: MediaSegmentDto?, currentTime: @escaping @MainActor () -> Double = { .nan }) {
        button.update(segment: segment, currentTime: currentTime)
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

// MARK: - The pill button

/// What the hosted SwiftUI pill draws; the button feeds it focus and segment.
@MainActor
final class SkipPillModel: ObservableObject {
    @Published var segment: MediaSegmentDto?
    @Published var isFocused = false
    var currentTime: @MainActor () -> Double = { .nan }
}

struct SkipPillHost: View {
    @ObservedObject var model: SkipPillModel

    var body: some View {
        if let segment = model.segment {
            LiveSkipSegmentPill(
                segment: segment,
                accent: SashimiTheme.accent,
                metrics: .tv,
                currentTime: model.currentTime
            )
            .environment(\.skipPillHighlighted, model.isFocused)
        }
    }
}

/// A custom-type UIButton (no system focus platter) whose content is the
/// shared SwiftUI countdown pill. Focus is still the button's: it reports
/// focus changes to the pill, which scales, rings and fills solid.
final class SkipPillButton: UIButton {
    let model = SkipPillModel()
    let host: UIHostingController<SkipPillHost>

    override init(frame: CGRect) {
        host = UIHostingController(rootView: SkipPillHost(model: model))
        super.init(frame: frame)
        host.sizingOptions = [.intrinsicContentSize]
        // The pill sits inside the screen's safe area already; tvOS would
        // otherwise pad the hosted view by the overscan insets.
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        // The button handles every press; the pill only draws.
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(segment: MediaSegmentDto?, currentTime: @escaping @MainActor () -> Double) {
        model.currentTime = currentTime
        // updateUIViewController runs on every view-model publish; only a new
        // segment should rebuild the pill.
        if model.segment?.id != segment?.id {
            model.segment = segment
            host.view.invalidateIntrinsicContentSize()
        }
    }

    /// Read live, so VoiceOver announces the time left at the moment it speaks.
    override var accessibilityLabel: String? {
        get {
            guard let segment = model.segment else { return nil }
            return SkipSegmentCountdown(segment: segment, current: model.currentTime()).accessibilityLabel
        }
        set { super.accessibilityLabel = newValue }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        model.isFocused = isFocused
    }
}
