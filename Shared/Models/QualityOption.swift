import Foundation

/// The player's per-session quality tiers (the Quality menu on both tvOS and
/// iOS). Raw values are used in diagnostics and must stay stable: the four
/// original tiers keep theirs, the low-bandwidth tiers are additions.
enum QualityOption: String, CaseIterable, Identifiable {
    case auto = "auto"
    case quality1080p = "1080"
    case quality720p = "720"
    case quality480p = "480"
    // Low-bandwidth tiers (Plex offers the same rungs). Before these existed
    // nothing went below 480p @ 4 Mbps, so a connection that could not carry
    // 4 Mbps had no setting that would play smoothly.
    case quality720pLow = "720-2m"
    case quality480pLow = "480-1m"
    case quality360p = "360"

    var id: String { rawValue }

    /// The resolution alone ("720p"). Two tiers share 720p and 480p, so the
    /// menu uses `menuTitle`, which adds the bitrate.
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .quality1080p: return "1080p"
        case .quality720p, .quality720pLow: return "720p"
        case .quality480p, .quality480pLow: return "480p"
        case .quality360p: return "360p"
        }
    }

    /// Menu row text, the Roku OSD form: "720p · 2 Mbps". Auto stays "Auto".
    var menuTitle: String {
        guard let maxBitrate else { return displayName }
        return "\(displayName) · \(PlaybackSelection.bitrateLabel(maxBitrate))"
    }

    var maxBitrate: Int? {
        switch self {
        case .auto: return nil  // No limit
        case .quality1080p: return 20_000_000
        case .quality720p: return 8_000_000
        case .quality480p: return 4_000_000
        case .quality720pLow: return 2_000_000
        case .quality480pLow: return 1_000_000
        case .quality360p: return 720_000
        }
    }

    /// Pixel width cap for the tier.
    ///
    /// The bitrate cap alone does not change resolution: a 1080p source already
    /// under the cap is simply passed through, so picking "720p" on a 7 Mbps
    /// 1080p file produced a 1080p stream and the OSD correctly kept saying
    /// 1080p. The width is what actually makes the tier mean what it says.
    var maxWidth: Int? {
        switch self {
        case .auto: return nil
        case .quality1080p: return 1920
        case .quality720p, .quality720pLow: return 1280
        case .quality480p, .quality480pLow: return 854
        case .quality360p: return 640
        }
    }

    /// Whether the tier belongs in the menu's "Low bandwidth" section.
    var isLowBandwidth: Bool {
        switch self {
        case .quality720pLow, .quality480pLow, .quality360p: return true
        default: return false
        }
    }

    /// Auto plus the full-quality tiers, in menu order.
    static var standardTiers: [QualityOption] { allCases.filter { !$0.isLowBandwidth } }

    /// The "Low bandwidth" section, in menu order.
    static var lowBandwidthTiers: [QualityOption] { allCases.filter(\.isLowBandwidth) }

    /// The lowest tier there is: step-down never goes below it.
    static let floorBitrate = 720_000

    /// The tier to fall back to when playback at `bitrate` keeps stalling:
    /// roughly half the bitrate (never below the 720 kbps floor), with the
    /// width that tier carries. Nil once already at the floor.
    ///
    /// 20 Mbps → 720p·8, 8 → 480p·4, 4 → 720p·2, 2 → 480p·1, 1 → 360p·720k.
    /// An Auto stream at 9.5 Mbps (the live remote-iPad case) halves to 480p·4.
    static func steppedDown(fromBitrate bitrate: Int) -> QualityOption? {
        guard bitrate > floorBitrate else { return nil }
        let target = max(bitrate / 2, floorBitrate)
        return allCases
            .filter { ($0.maxBitrate ?? .max) <= target }
            .max { ($0.maxBitrate ?? 0) < ($1.maxBitrate ?? 0) }
    }
}
