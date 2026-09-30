import AVFoundation
import SwiftUI

/// Where playback is, read from the player (or fixed, for previews and tests).
struct PlaybackSnapshot: Equatable {
    var current: Double
    var duration: Double
    var isPlaying: Bool
    var rate: Float

    static let empty = PlaybackSnapshot(current: 0, duration: 0, isPlaying: false, rate: 1)

    @MainActor
    static func read(_ player: AVPlayer?) -> PlaybackSnapshot {
        guard let player else { return .empty }
        let duration = player.currentItem?.duration
        let total = (duration?.isValid == true && duration?.isIndefinite == false) ? duration?.seconds ?? 0 : 0
        let current = player.currentTime().seconds
        return PlaybackSnapshot(
            current: current.isFinite ? max(0, current) : 0,
            duration: total.isFinite ? max(0, total) : 0,
            isPlaying: player.timeControlStatus != .paused,
            rate: player.rate
        )
    }

    var remaining: Double { max(0, duration - current) }

    /// "4:05" or "1:02:09".
    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// A full-width, draggable timeline: elapsed on the left, time remaining on
/// the right. While dragging, the labels follow the finger and the seek is
/// made on release, so a scrub is one seek rather than hundreds.
struct PlayerScrubber: View {
    let snapshot: PlaybackSnapshot
    /// true while the finger is down, so the overlay stays up meanwhile.
    var onScrubbing: (Bool) -> Void = { _ in }
    let onSeek: (Double) -> Void

    @State private var dragTime: Double?

    private var shownTime: Double { dragTime ?? snapshot.current }

    private var fraction: Double {
        guard snapshot.duration > 0 else { return 0 }
        return min(max(shownTime / snapshot.duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                        .frame(height: dragTime == nil ? 4 : 6)
                    Capsule().fill(MobileColors.accent)
                        .frame(width: width * fraction, height: dragTime == nil ? 4 : 6)
                    Circle().fill(.white)
                        .frame(width: dragTime == nil ? 14 : 20, height: dragTime == nil ? 14 : 20)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .offset(x: width * fraction - (dragTime == nil ? 7 : 10))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
            }
            .frame(height: 24)
            .animation(.easeOut(duration: 0.12), value: dragTime == nil)

            HStack {
                Text(PlaybackSnapshot.format(shownTime))
                Spacer()
                Text("-" + PlaybackSnapshot.format(max(0, snapshot.duration - shownTime)))
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
        }
        .disabled(snapshot.duration <= 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(PlaybackSnapshot.format(shownTime)) of \(PlaybackSnapshot.format(snapshot.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(snapshot.duration, snapshot.current + 10))
            case .decrement: onSeek(max(0, snapshot.current - 10))
            @unknown default: break
            }
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard snapshot.duration > 0, width > 0 else { return }
                if dragTime == nil { onScrubbing(true) }
                let position = min(max(value.location.x / width, 0), 1)
                dragTime = position * snapshot.duration
            }
            .onEnded { _ in
                if let dragTime { onSeek(dragTime) }
                dragTime = nil
                onScrubbing(false)
            }
    }
}
