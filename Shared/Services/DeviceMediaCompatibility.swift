import Foundation

/// Determines whether a raw media source will direct-play on this device's
/// AVPlayer (iOS/tvOS) without any server-side remuxing or transcoding.
///
/// The allowlists below MUST mirror the iOS DirectPlayProfiles sent by
/// `JellyfinClient.getPlaybackInfo` (Container "mp4,m4v"/"mov",
/// VideoCodec "h264,hevc", AudioCodec "aac,ac3,eac3"). Those two definitions
/// are the single source of truth for device compatibility — if one changes,
/// update the other to keep them in sync.
enum DeviceMediaCompatibility {
    /// Containers AVPlayer can play natively.
    static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]
    /// Video codecs AVPlayer can decode.
    static let directPlayVideoCodecs: Set<String> = ["h264", "hevc"]
    /// Audio codecs AVPlayer can decode.
    static let directPlayAudioCodecs: Set<String> = ["aac", "ac3", "eac3"]

    /// Normalizes common codec aliases onto the canonical name used above.
    private static func canonicalCodec(_ raw: String) -> String {
        let value = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch value {
        case "h265": return "hevc"
        case "avc", "x264", "mpeg4/avc": return "h264"
        default: return value
        }
    }

    /// True only when the raw source file will direct-play on iOS/tvOS
    /// AVPlayer: its container AND video codec AND audio codec must all be in
    /// the allowlists. Fails closed — any nil/unknown field yields false.
    ///
    /// `container` may be a comma-separated list (e.g. "mp4,m4v" or
    /// "mkv,webm"); it is considered compatible when at least one listed token
    /// is in the container allowlist.
    static func canDirectPlayOnDevice(_ source: MediaSourceInfo) -> Bool {
        guard let rawContainer = source.container, !rawContainer.isEmpty else { return false }
        let containers = rawContainer
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard containers.contains(where: { directPlayContainers.contains($0) }) else { return false }

        guard let rawVideo = source.videoCodec, !rawVideo.isEmpty,
              directPlayVideoCodecs.contains(canonicalCodec(rawVideo)) else { return false }

        guard let rawAudio = source.audioCodec, !rawAudio.isEmpty,
              directPlayAudioCodecs.contains(canonicalCodec(rawAudio)) else { return false }

        return true
    }
}
