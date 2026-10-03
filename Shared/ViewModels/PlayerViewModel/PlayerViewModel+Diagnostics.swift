import Foundation

extension PlayerViewModel {
    /// Fields stamped on every diagnostic line from this instance.
    private var diagContext: [String] {
        [
            PlayerDiagnostics.field("vm", sessionTag),
            PlayerDiagnostics.field("attempt", playbackAttempt)
        ]
    }

    func diag(_ stage: PlayerDiagnostics.Stage, _ fields: [String] = []) {
        PlayerDiagnostics.event(stage, diagContext + fields)
    }

    func diagFailure(_ stage: PlayerDiagnostics.Stage, _ fields: [String] = []) {
        PlayerDiagnostics.failure(stage, diagContext + fields)
    }

    func diagDetail(_ stage: PlayerDiagnostics.Stage, _ fields: [String] = []) {
        PlayerDiagnostics.detail(stage, diagContext + fields)
    }

    /// Refreshes the stream-info chip from the server's own session view.
    /// Called when the player overlay becomes visible; cheap single GET.
    func refreshStreamInfo() async {
        guard !isOfflinePlayback else {
            streamInfo = StreamInfo(method: .directPlay, detail: nil, reason: nil)
            return
        }
        guard let session = try? await client.getOwnSession(),
              session.nowPlayingItemId?.id != nil else { return }

        let method = session.playState?.playMethod
        let info = session.transcodingInfo

        if method == "Transcode", info == nil {
            // Transcode session whose ffmpeg already finished (or hasn't
            // registered yet): Jellyfin drops TranscodingInfo but PlayMethod
            // stays "Transcode". Keep the last known chip if we have one —
            // never fall through to "Direct Play" for a transcode session.
            if streamInfo == nil {
                streamInfo = StreamInfo(method: .transcode, detail: nil, reason: nil)
            }
        } else if method == "Transcode", let info {
            if info.isVideoDirect == true {
                // Container remux / audio conversion — video untouched, so the
                // source video bitrate IS the delivered speed. Show it.
                streamInfo = StreamInfo(method: .directStream, detail: sourceBitrateDetail, reason: nil)
            } else {
                var parts: [String] = []
                if let width = info.width, let height = info.height {
                    parts.append(Self.resolutionLabel(width: width, height: height))
                }
                if let codec = info.videoCodec { parts.append(codec.uppercased()) }
                if let bitrate = info.bitrate, bitrate > 0 {
                    parts.append(PlaybackSelection.bitrateLabel(bitrate))
                } else if let source = sourceBitrateDetail {
                    // TranscodingInfo omitted the target bitrate — show source
                    parts.append(source)
                }
                let reason = info.transcodeReasons?.first.map(Self.humanTranscodeReason)
                streamInfo = StreamInfo(
                    method: .transcode,
                    detail: parts.isEmpty ? nil : parts.joined(separator: " "),
                    reason: reason
                )
            }
        } else if method == "DirectStream" {
            streamInfo = StreamInfo(method: .directStream, detail: sourceBitrateDetail, reason: nil)
        } else if method != nil {
            streamInfo = StreamInfo(method: .directPlay, detail: sourceBitrateDetail, reason: nil)
        }
    }

    /// Source file's overall bitrate ("4 Mbps") for direct play/stream chips —
    /// transcode sessions report the target bitrate via TranscodingInfo instead.
    private var sourceBitrateDetail: String? {
        // Prefer the container bitrate; fall back to the video stream's own
        // bitrate when the MediaSource omits it (some remuxed/direct files),
        // so the OSD speed chip is never blank.
        let bps = (currentMediaSource?.bitrate).flatMap { $0 > 0 ? $0 : nil }
            ?? currentMediaSource?.mediaStreams?.first(where: { $0.type == "Video" })?.bitRate
        guard let bps, bps > 0 else { return nil }
        return PlaybackSelection.bitrateLabel(bps)
    }

    private static func resolutionLabel(width: Int, height: Int) -> String {
        if width >= 3200 || height >= 2160 { return "4K" }
        if width >= 1800 || height >= 1080 { return "1080p" }
        if width >= 1200 || height >= 720 { return "720p" }
        return "\(height)p"
    }

    private static func humanTranscodeReason(_ reason: String) -> String {
        switch reason {
        case "ContainerNotSupported": return "container"
        case "ContainerBitrateExceedsLimit": return "bitrate limit"
        case "VideoCodecNotSupported": return "video codec"
        case "AudioCodecNotSupported": return "audio codec"
        case "SubtitleCodecNotSupported": return "subtitles"
        case "VideoResolutionNotSupported": return "resolution"
        case "AudioChannelsNotSupported": return "audio channels"
        case "UnknownVideoStreamInfo", "UnknownAudioStreamInfo": return "stream info"
        default: return reason
        }
    }
}
