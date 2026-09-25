import SwiftUI
import UIKit

/// The remote while a station plays. AVKit's transport bar is off for
/// channels (see `TVPlayerView.showsAVKitControls`), so every press a channel
/// uses is handled here.
extension PlayerContainerVC {
    /// Connect the channel presses to the playing view model.
    func wireStationControls(coordinator: TVPlayerView.Coordinator, onExit: @escaping () -> Void) {
        canStepStation = { [weak coordinator] in
            guard let coordinator, let model = coordinator.currentViewModel else { return false }
            return model.isWatchingStation && !coordinator.controlsVisible && !model.showingSkipButton
        }
        onStationStep = { [weak coordinator] delta in
            guard let model = coordinator?.currentViewModel else { return }
            Task { await model.changeStation(by: delta) }
        }
        onStationInfo = { [weak coordinator] in
            guard let model = coordinator?.currentViewModel else { return }
            // A click toggles the bar, except while paused, when it stays up.
            if let banner = model.stationBanner, !banner.isPaused {
                model.dismissStationBanner(banner.id)
            } else {
                Task { await model.announceStation() }
            }
        }
        onStationPlayPause = { [weak coordinator] in
            coordinator?.currentViewModel?.toggleStationPause()
        }
        onStationOptions = { [weak self, weak coordinator] in
            guard let self, let model = coordinator?.currentViewModel else { return }
            StationOptions.present(from: self, model: model)
        }
        onStationExit = onExit
        onStationGuide = { [weak self, weak coordinator] in
            guard let self, let model = coordinator?.currentViewModel,
                  presentedViewController == nil else { return }
            model.dismissStationBannerNow()
            // The guide over the live picture, the way a cable box opens it:
            // the channel keeps playing behind; an airing pick tunes it here.
            // Weak: the presentation owns the controller; a strong capture here
            // would be a cycle through its own root view.
            weak var host: UIHostingController<GuideView>?
            let guide = GuideView(
                onTuneStation: { id in
                    host?.dismiss(animated: true)
                    Task { await model.tuneStation(id: id) }
                },
                onClose: { host?.dismiss(animated: true) }
            )
            let controller = UIHostingController(rootView: guide)
            controller.modalPresentationStyle = .overFullScreen
            controller.view.backgroundColor = .clear
            host = controller
            present(controller, animated: true)
        }
        installStationFlipping()
    }

    /// Every press a channel uses, taken before AVKit sees it. With the
    /// transport bar off (see `showsAVKitControls`) these are the only
    /// controls a channel has; left and right are swallowed so they cannot
    /// seek a live channel.
    func installStationFlipping() {
        let active: () -> Bool = { [weak self] in self?.canStepStation() ?? false }
        let presses: [(UIPress.PressType, Int)] = [
            // Up is channel up — the higher number — as on a cable remote and on Roku.
            (.upArrow, 1), (.downArrow, -1), (.leftArrow, 4), (.rightArrow, 4), (.playPause, 2), (.menu, 3)
        ]
        for (type, delta) in presses {
            let press = StationStepRecognizer(target: self, action: #selector(stationStep(_:)))
            press.delaysTouchesBegan = false
            press.allowedPressTypes = [NSNumber(value: type.rawValue)]
            press.delta = delta
            press.shouldStep = active
            view.addGestureRecognizer(press)
        }
        let select = StationSelectRecognizer(target: self, action: #selector(stationSelect(_:)))
        select.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        select.isActive = active
        view.addGestureRecognizer(select)
    }

    @objc func stationStep(_ recognizer: StationStepRecognizer) {
        switch recognizer.delta {
        case -1, 1: onStationStep?(recognizer.delta)
        case 2: onStationPlayPause?()
        case 3: onStationExit?()
        case 4: onStationGuide?()
        default: break
        }
    }

    @objc func stationSelect(_ recognizer: StationSelectRecognizer) {
        guard recognizer.state == .ended else { return }
        switch recognizer.kind {
        case .click: onStationInfo?()
        case .hold: onStationOptions?()
        }
    }
}
