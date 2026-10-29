import SwiftUI
import UIKit

/// When the player's controls may fade on their own after the idle delay.
///
/// Not while the finger is on the scrubber, and not while a picker or menu
/// is open (#807): on the Mac the controls faded under an open Audio or
/// Subtitles menu and left it floating over the video; on iPhone and iPad
/// the fade took the menu away mid-choice. The countdown starts again, in
/// full, once the menu closes.
struct PlayerControlsAutoHide: Equatable {
    var controlsVisible: Bool
    var isScrubbing: Bool
    var menuOpen: Bool

    /// Whether the idle timer should be counting down.
    var runsIdleTimer: Bool {
        controlsVisible && !isScrubbing && !menuOpen
    }

    enum Timeout: Equatable {
        /// Fade the controls.
        case hide
        /// A menu came up while the timer ran (the tap that opens a pill
        /// restarts it just before): keep the controls, and count down again
        /// once it closes.
        case waitForMenuToClose
        /// Nothing to do: the controls are already gone, or a scrub holds them.
        case stop
    }

    /// What to do when the idle timer fires.
    var timeout: Timeout {
        guard controlsVisible, !isScrubbing else { return .stop }
        return menuOpen ? .waitForMenuToClose : .hide
    }

    /// A menu opening stops the countdown; one closing starts it afresh.
    enum MenuTransition: Equatable {
        case stopTimer
        case revealAndRestartTimer
    }

    static func transition(menuOpen: Bool) -> MenuTransition {
        menuOpen ? .stopTimer : .revealAndRestartTimer
    }
}

/// Whether something is presented over the player: on iPhone and iPad an
/// open pill menu is a presented view controller, as are the AirPlay picker
/// and any alert. SwiftUI's `Menu` reports neither opening nor closing (its
/// content's `onAppear` fires once and its `onDisappear` never), so the
/// player asks this when its idle timer fires. The Mac's menus are AppKit
/// menus, followed through their notifications (`PlayerPointerHiding`).
@MainActor
final class PlayerPresentationProbe {
    private weak var anchor: UIView?

    /// The view whose controller chain is the player's.
    func attach(_ view: UIView) {
        anchor = view
    }

    var isShowingPresentation: Bool {
        guard let anchor else { return false }
        var responder: UIResponder? = anchor
        while let next = responder, !(next is UIViewController) {
            responder = next.next
        }
        guard var controller = responder as? UIViewController else { return false }
        while let parent = controller.parent {
            controller = parent
        }
        guard let presented = controller.presentedViewController else { return false }
        return !presented.isBeingDismissed
    }
}

/// Puts a `PlayerPresentationProbe` in the player's view hierarchy.
struct PlayerPresentationProbeAnchor: UIViewRepresentable {
    let probe: PlayerPresentationProbe

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        probe.attach(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        probe.attach(uiView)
    }
}
