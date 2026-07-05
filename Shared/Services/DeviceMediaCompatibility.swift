import AVFoundation
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

    /// Whether this device (and its currently attached display) can render
    /// Dolby Vision. Reflects live device/display capability at call time.
    static var deviceSupportsDolbyVision: Bool {
        AVPlayer.availableHDRModes.contains(.dolbyVision)
    }

    /// True when the stream is single-layer Dolby Vision with NO cross-compatible
    /// fallback — Jellyfin reports `VideoRangeType == "DOVI"` (Profile 5). Only
    /// this bare "DOVI" value is gated: the cross-compatible variants
    /// (`DOVIWithHDR10` / `DOVIWithHLG` / `DOVIWithSDR`) degrade gracefully to
    /// HDR10/HLG/SDR on non-DV devices and therefore MUST NOT be gated. All
    /// non-DV values (sdr/hdr10/hlg) and nil also pass.
    private static func isDolbyVisionWithoutFallback(_ rangeType: String?) -> Bool {
        guard let rangeType else { return false }
        return rangeType.lowercased().trimmingCharacters(in: .whitespaces) == "dovi"
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
    ///
    /// A single-layer Dolby Vision Profile 5 video stream (VideoRangeType
    /// "DOVI", no HDR10/HLG/SDR fallback) is treated as NOT compatible on a
    /// device that lacks Dolby Vision, because AVPlayer renders it with wrong
    /// colors. `deviceSupportsDolbyVision` defaults to the live device state so
    /// production callers are unchanged; tests inject a deterministic value.
    static func canDirectPlayOnDevice(
        _ source: MediaSourceInfo,
        deviceSupportsDolbyVision: Bool = DeviceMediaCompatibility.deviceSupportsDolbyVision
    ) -> Bool {
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
                guard directPlayVideoCodecs.contains(canonicalCodec(codec)) else { return false }
                // Gate single-layer DV (Profile 5) on non-DV devices only.
                if isDolbyVisionWithoutFallback(stream.videoRangeType), !deviceSupportsDolbyVision {
                    return false
                }
                return true
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
