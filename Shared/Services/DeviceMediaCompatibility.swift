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
    /// AVPlayer: its container must be compatible AND at least one video stream
    /// AND at least one audio stream must use an allowlisted codec. Fails closed
    /// — any nil/unknown field, empty stream list, or unsupported token yields
    /// false.
    ///
    /// `container` may be a comma-separated list (e.g. "mp4,m4v"); EVERY listed
    /// token must be in the container allowlist (so an anomalous "mkv,mp4" fails
    /// closed rather than passing on the compatible token alone).
    ///
    /// Because a file can carry multiple audio (and, defensively, video)
    /// streams — e.g. a TrueHD primary track plus an AC3 compatibility track on
    /// a Blu-ray rip — we require only that AT LEAST ONE stream of each type is
    /// playable; AVPlayer can select a compatible track at playback time.
    static func canDirectPlayOnDevice(_ source: MediaSourceInfo) -> Bool {
        guard let rawContainer = source.container, !rawContainer.isEmpty else { return false }
        let containers = rawContainer
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !containers.isEmpty,
              containers.allSatisfy({ directPlayContainers.contains($0) }) else { return false }

        guard let streams = source.mediaStreams, !streams.isEmpty else { return false }

        let hasCompatibleVideo = streams
            .filter { $0.type == "Video" }
            .contains { stream in
                guard let codec = stream.codec, !codec.isEmpty else { return false }
                return directPlayVideoCodecs.contains(canonicalCodec(codec))
            }
        guard hasCompatibleVideo else { return false }

        let hasCompatibleAudio = streams
            .filter { $0.type == "Audio" }
            .contains { stream in
                guard let codec = stream.codec, !codec.isEmpty else { return false }
                return directPlayAudioCodecs.contains(canonicalCodec(codec))
            }
        guard hasCompatibleAudio else { return false }

        return true
    }
}
