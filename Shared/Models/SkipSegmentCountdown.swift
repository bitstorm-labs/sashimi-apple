import Foundation

/// What the skip pill shows for a segment at a moment in playback: the label,
/// how much of the segment has played (the purple fill) and how long is left.
///
/// Everything is derived from the player's current time, so a seek inside the
/// segment moves the fill and the countdown straight to the new position.
struct SkipSegmentCountdown: Equatable {
    let type: MediaSegmentType
    /// Fraction of the segment already played, 0 at its start and 1 at its end.
    let fractionElapsed: Double
    /// Whole seconds left in the segment, rounded up so "0:00" only shows once
    /// the segment is really over.
    let secondsRemaining: Int

    init(type: MediaSegmentType, start: Double, end: Double, current: Double) {
        self.type = type
        self.fractionElapsed = Self.fraction(start: start, end: end, current: current)
        self.secondsRemaining = Self.secondsRemaining(start: start, end: end, current: current)
    }

    init(segment: MediaSegmentDto, current: Double) {
        self.init(type: segment.type, start: segment.startSeconds, end: segment.endSeconds, current: current)
    }

    /// "Skip Intro", "Skip Credits", … — the label both apps have always used.
    var label: String { Self.label(for: type) }

    /// The countdown as m:ss, e.g. "0:24" or "1:05".
    var remainingText: String { Self.clockText(seconds: secondsRemaining) }

    /// "Skip Intro, 24 seconds left".
    var accessibilityLabel: String { "\(label), \(Self.spokenDuration(seconds: secondsRemaining)) left" }

    static func label(for type: MediaSegmentType) -> String {
        "Skip \(type.displayName)"
    }

    static func fraction(start: Double, end: Double, current: Double) -> Double {
        let length = end - start
        // A zero-length or malformed segment, or a player time that is not yet
        // valid (NaN while an item loads), shows an empty fill.
        guard length.isFinite, length > 0, current.isFinite else { return 0 }
        return min(max((current - start) / length, 0), 1)
    }

    static func secondsRemaining(start: Double, end: Double, current: Double) -> Int {
        guard end.isFinite, start.isFinite else { return 0 }
        let position = current.isFinite ? max(current, start) : start
        let left = end - position
        guard left > 0 else { return 0 }
        return Int(left.rounded(.up))
    }

    static func clockText(seconds: Int) -> String {
        let seconds = max(seconds, 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func spokenDuration(seconds: Int) -> String {
        let seconds = max(seconds, 0)
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        let minutes = seconds / 60, rest = seconds % 60
        guard minutes > 0 else { return unit(rest, "second") }
        return rest == 0 ? unit(minutes, "minute") : "\(unit(minutes, "minute")) \(unit(rest, "second"))"
    }
}
