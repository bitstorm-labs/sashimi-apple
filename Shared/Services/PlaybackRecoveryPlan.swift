import Foundation

/// What the error/stall fallback should do next. Pure, so the escalation
/// policy is unit tested without an AVPlayer.
///
/// Two different failures arrive through the same door:
///
/// - The jellyfin#16070 stream-copy seek-freeze: the link is fine, the
///   server's session is wedged. A fresh session at the SAME quality clears
///   it (first attempt keeps video copy; second disallows it).
/// - A connection that cannot carry the stream: a fresh session at the same
///   bitrate stalls again, and again. Only a lower bitrate helps.
///
/// Rebuilding at the same bitrate on a slow link is what made a remote iPad
/// restart a 9.5 Mbps stream repeatedly, so a bandwidth stall steps DOWN one
/// tier per recovery, as far as the 720 kbps floor.
enum PlaybackRecoveryPlan {
    enum Decision: Equatable {
        /// Rebuild at the current quality (the seek-freeze fix).
        case rebuild(allowVideoStreamCopy: Bool)
        /// Rebuild at a lower tier.
        case stepDown(to: QualityOption)
        /// Nothing left to try: surface the error.
        case giveUp
    }

    /// AVPlayer's own view of the stream, from the item's access log.
    struct Throughput: Equatable {
        /// Measured segment download rate (AVPlayerItemAccessLogEvent.observedBitrate).
        let observedBitrate: Double
        /// What the stream needs (indicatedBitrate: the variant's BANDWIDTH).
        let indicatedBitrate: Double
    }

    /// HLS needs headroom over the stream's own bitrate to keep its buffer
    /// filling; a download rate under 1.5x the stream's is a link that is
    /// losing the race. A wedged session on a fast link reads many times the
    /// stream bitrate, so the two cases separate cleanly.
    static let requiredHeadroom = 1.5

    /// Whether the access log says the link, not the server, is the problem.
    static func isBandwidthLimited(_ throughput: Throughput?) -> Bool {
        guard let throughput,
              throughput.observedBitrate > 0,
              throughput.indicatedBitrate > 0 else { return false }
        return throughput.observedBitrate < throughput.indicatedBitrate * requiredHeadroom
    }

    /// Legacy same-quality attempts per item (unchanged from before step-down).
    static let maxRebuildAttempts = 2

    /// - Parameters:
    ///   - isStall: the trigger was the stall watchdog (playback stopped
    ///     moving), as opposed to an item/decoder error.
    ///   - rebuildAttempts: same-quality rebuilds already spent on this item.
    ///   - currentBitrate: the bitrate being streamed now (the tier's cap, or
    ///     Auto's effective cap / the variant's bitrate).
    ///   - throughput: the access log's reading, when there is one.
    static func decide(
        isStall: Bool,
        rebuildAttempts: Int,
        currentBitrate: Int?,
        throughput: Throughput?
    ) -> Decision {
        let lower = currentBitrate.flatMap { QualityOption.steppedDown(fromBitrate: $0) }

        // Measured evidence that the link can't keep up: go straight down.
        if isBandwidthLimited(throughput), let lower {
            return .stepDown(to: lower)
        }
        // First failure of any kind: the seek-freeze fix, as before.
        if rebuildAttempts == 0 {
            return .rebuild(allowVideoStreamCopy: true)
        }
        // A fresh session stalled again with no proof the link is fine:
        // the same bitrate is not going to work, so try a lower one.
        if isStall, let lower {
            return .stepDown(to: lower)
        }
        if rebuildAttempts < maxRebuildAttempts {
            return .rebuild(allowVideoStreamCopy: false)
        }
        return .giveUp
    }
}
