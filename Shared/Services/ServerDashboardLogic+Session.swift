import Foundation

extension PlayMode {
    /// The badge on TV and iPad cards.
    var title: String {
        switch self {
        case .directPlay: return "Direct play"
        case .convertingAudio: return "Converting audio"
        case .convertingVideo: return "Converting video"
        }
    }

    /// The badge in the iPhone's narrower rows.
    var shortTitle: String {
        switch self {
        case .directPlay: return "Direct"
        case .convertingAudio: return "Audio converted"
        case .convertingVideo: return "Converting"
        }
    }
}

struct DashboardDetailRow: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label }
}

// How one stream reads on a card and in its Details.
extension ServerDashboardLogic {
    /// "mom · Living Room Roku"
    static func viewerLine(_ session: DashboardSession) -> String {
        [session.userName, session.deviceName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "61 Mbps", "8 Mbps · paused"
    static func rateLine(_ session: DashboardSession) -> String {
        var parts: [String] = []
        if let rate = bitrate(of: session) { parts.append(formatBitrate(rate)) }
        if session.playState?.isPaused == true { parts.append("paused") }
        return parts.joined(separator: " · ")
    }

    /// Everything Details shows. No addresses, paths or ids by construction.
    static func detailRows(for session: DashboardSession) -> [DashboardDetailRow] {
        let info = session.transcodingInfo
        let item = session.nowPlayingItem
        let video = item?.mediaStreams.first { $0.type == "Video" }
        var rows: [(String, String?)] = [
            ("Viewer", session.userName),
            ("Device", session.deviceName),
            ("App", [session.client, session.applicationVersion].compactMap { $0 }.joined(separator: " ")),
            ("Playing", item?.displayTitle),
            ("Progress", progressText(positionTicks: session.playState?.positionTicks, runTimeTicks: item?.runTimeTicks)),
            ("Play mode", playMode(info).title),
            ("Why", plainReasons(info?.transcodeReasons ?? []).joined(separator: ", ")),
            ("Source video", video?.displayTitle ?? resolutionLabel(video?.width)),
            ("Source audio", selectedAudioTitle(session))
        ]
        if let info {
            let sent = [info.container, info.videoCodec, info.audioCodec].compactMap { $0?.uppercased() }
            rows.append(("Sent as", sent.joined(separator: " · ")))
            if playMode(info) == .convertingVideo, let type = info.hardwareAccelerationType, !type.isEmpty, type != "none" {
                rows.append(("Hardware", accelerationName(type)))
            }
        }
        rows.append(("Bitrate", bitrate(of: session).map(formatBitrate)))
        return rows.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return DashboardDetailRow(label: label, value: redactIPs(value))
        }
    }

    // MARK: - Session presentation

    private static func selectedAudioTitle(_ session: DashboardSession) -> String? {
        guard let audio = selectedAudio(in: session) else { return nil }
        return audio.displayTitle ?? audio.codec?.uppercased()
    }

    /// "58:10 / 1:34:00"
    static func progressText(positionTicks: Int64?, runTimeTicks: Int64?) -> String? {
        guard let runTimeTicks, runTimeTicks > 0 else { return nil }
        return "\(clock(positionTicks ?? 0)) / \(clock(runTimeTicks))"
    }

    static func progressFraction(positionTicks: Int64?, runTimeTicks: Int64?) -> Double {
        guard let runTimeTicks, runTimeTicks > 0 else { return 0 }
        return min(max(Double(positionTicks ?? 0) / Double(runTimeTicks), 0), 1)
    }

    private static func clock(_ ticks: Int64) -> String {
        let total = Int(ticks / 10_000_000)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
