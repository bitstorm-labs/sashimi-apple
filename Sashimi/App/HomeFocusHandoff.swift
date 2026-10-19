import Foundation

/// When Home's hero takes focus after launch: the cold-start handoff, which
/// `MainTabView` performs with `resetFocus(in: mainScope)`.
///
/// The handoff runs once, when the hero first has content. A deep link
/// (Top Shelf play/display, `sashimi://`) can cover Home with a player or
/// detail before that happens; a reset while the cover is up is a no-op, and
/// when the cover goes away tvOS has nothing in Home to return focus to, so
/// Home showed no focus at all until the first arrow press (#725). A
/// handoff that comes due while covered therefore waits for the dismissal.
struct HomeFocusHandoff: Equatable {
    enum Step: Equatable {
        /// The hero has not had content yet.
        case waiting
        /// The hero became ready under a cover; focus moves when it closes.
        case deferred
        /// Focus was handed to the hero. A repeat hero update hands it off
        /// again until MainTabView arms its edge guard, as before #725.
        case handedOff
        /// Given up: the viewer moved through the rail first.
        case gaveUp
    }

    private(set) var step: Step = .waiting
    /// A deep-linked player or detail is presented over Home.
    private(set) var isCovered = false

    var isDone: Bool { step == .handedOff || step == .gaveUp }

    /// The hero has content. True means move focus to it now.
    mutating func heroReady(onHome: Bool, viewerNavigatedRail: Bool) -> Bool {
        guard onHome, step == .waiting || step == .handedOff else { return false }
        if viewerNavigatedRail {
            // The viewer is already moving through the rail: never yank focus.
            step = .gaveUp
            return false
        }
        if isCovered {
            if step == .waiting { step = .deferred }
            return false
        }
        step = .handedOff
        return true
    }

    mutating func coverPresented() {
        isCovered = true
    }

    /// The cover has finished closing. True means move focus to the hero now.
    mutating func coverDismissed(onHome: Bool) -> Bool {
        isCovered = false
        guard step == .deferred else { return false }
        guard onHome else {
            step = .gaveUp
            return false
        }
        step = .handedOff
        return true
    }
}
