import Foundation

/// How a stream reaches its viewer, as the dashboard's badge shows it.
enum PlayMode: Equatable {
    /// No conversion: the file plays as-is (a container-only remux counts).
    case directPlay
    /// Video copied, audio converted.
    case convertingAudio
    /// Any video conversion, including subtitle burn-in and HDR tone-mapping.
    case convertingVideo
}

/// The colour family of a dashboard row.
enum DashboardTone: Equatable {
    case ok, warning, failure, playback, signIn, added, neutral

    /// Rows that belong in the phone's "Needs attention" list.
    var needsAttention: Bool { self == .warning || self == .failure }
}

struct DashboardActivityRow: Identifiable, Equatable {
    let id: Int
    let text: String
    let when: String
    let tone: DashboardTone
}

struct DashboardHealthRow: Identifiable, Equatable {
    let title: String
    let value: String
    let tone: DashboardTone
    /// How the row reads in "Needs attention"; title + value when nil.
    var attentionText: String?
    /// Relative time for "Needs attention"; "now" when nil.
    var when: String?

    var id: String { title }
}

struct DashboardAttentionRow: Identifiable, Equatable {
    let id: String
    let text: String
    let when: String
    let tone: DashboardTone
}

/// Every decision the Server dashboard makes, free of UI and networking so
/// each rule is unit-tested on its own.
enum ServerDashboardLogic {
    // MARK: - Gate

    /// Only an administrator sees the dashboard, and only while the server
    /// has not refused one of its requests (the server is the real guard).
    static func canShowDashboard(isAdministrator: Bool, deniedByServer: Bool) -> Bool {
        isAdministrator && !deniedByServer
    }

    /// The server said this user may not read admin data.
    static func isAccessDenied(_ error: Error) -> Bool {
        switch error as? JellyfinError {
        case .httpError(let status):
            return status == 401 || status == 403
        case .sessionExpired:
            return true
        default:
            return false
        }
    }

    // MARK: - Play mode

    static let burnInReason = "SubtitleCodecNotSupported"
    static let toneMapReason = "VideoRangeTypeNotSupported"

    /// Burn-in and HDR → SDR tone-mapping re-encode the picture whatever the
    /// flags say; a missing flag decodes as not direct, so a transcode the
    /// server didn't describe never reads as Direct play.
    static func playMode(_ info: DashboardTranscodingInfo?) -> PlayMode {
        guard let info else { return .directPlay }
        let reencodes = info.transcodeReasons.contains(burnInReason) || info.transcodeReasons.contains(toneMapReason)
        guard info.isVideoDirect, !reencodes else { return .convertingVideo }
        return info.isAudioDirect ? .directPlay : .convertingAudio
    }

    // MARK: - Plain words

    /// Jellyfin's `TranscodeReason` names in plain words: sashimi-roku's
    /// `AdminDash.reasonText` table letter for letter (Android's
    /// `TranscodeReasonWords` too). Keyed lower-case because Roku's lookup is.
    private static let reasonWords: [String: String] = [
        "ContainerNotSupported": "Container not supported",
        "VideoCodecNotSupported": "Video format not supported",
        "AudioCodecNotSupported": "Audio format not supported",
        "SubtitleCodecNotSupported": "Subtitles burned in",
        "AudioIsExternal": "External audio track",
        "SecondaryAudioNotSupported": "Extra audio track not supported",
        "VideoProfileNotSupported": "Video profile not supported",
        "VideoLevelNotSupported": "Video level not supported",
        "VideoResolutionNotSupported": "Resolution too high",
        "VideoBitDepthNotSupported": "Bit depth not supported",
        "VideoFramerateNotSupported": "Frame rate not supported",
        "RefFramesNotSupported": "Too many reference frames",
        "AnamorphicVideoNotSupported": "Anamorphic video not supported",
        "InterlacedVideoNotSupported": "Interlaced video",
        "AudioChannelsNotSupported": "Too many audio channels",
        "AudioProfileNotSupported": "Audio profile not supported",
        "AudioSampleRateNotSupported": "Sample rate not supported",
        "AudioBitDepthNotSupported": "Audio bit depth not supported",
        "ContainerBitrateExceedsLimit": "Bitrate cap",
        "VideoBitrateNotSupported": "Video bitrate too high",
        "AudioBitrateNotSupported": "Audio bitrate too high",
        "UnknownVideoStreamInfo": "Unknown video stream",
        "UnknownAudioStreamInfo": "Unknown audio stream",
        "DirectPlayError": "Direct play failed",
        "VideoRangeTypeNotSupported": "HDR → SDR",
        "VideoCodecTagNotSupported": "Video codec tag not supported",
        "StreamCountExceedsLimit": "Too many streams"
    ].reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }

    /// One reason in plain words. A name this table doesn't know (a newer
    /// server's) is split into words, never shown raw.
    static func reasonText(_ reason: String) -> String {
        guard !reason.isEmpty else { return "" }
        return reasonWords[reason.lowercased()] ?? humanize(reason)
    }

    /// Jellyfin's `TranscodeReasons` in plain words, in order, each once.
    static func plainReasons(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.map(reasonText).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// "SpatialAudioNotSupported" → "Spatial audio not supported" (Roku's `humanize`).
    private static func humanize(_ name: String) -> String {
        var out = ""
        for (index, character) in name.enumerated() {
            if index > 0, character.isASCII, character.isUppercase {
                out += " " + character.lowercased()
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// The audio track the viewer has selected, else the default, else the first.
    static func selectedAudio(in session: DashboardSession) -> DashboardMediaStream? {
        let audio = session.nowPlayingItem?.mediaStreams.filter { $0.type == "Audio" } ?? []
        if let index = session.playState?.audioStreamIndex, let match = audio.first(where: { $0.index == index }) {
            return match
        }
        return audio.first { $0.isDefault } ?? audio.first
    }

    // MARK: - Bitrate

    /// What the stream costs the server's uplink: a conversion's output rate,
    /// else the source's video plus selected audio.
    static func bitrate(of session: DashboardSession) -> Int? {
        if let rate = session.transcodingInfo?.bitrate, rate > 0 { return rate }
        return sourceBitrate(of: session)
    }

    /// The file's video plus the audio track being played.
    static func sourceBitrate(of session: DashboardSession) -> Int? {
        let video = session.nowPlayingItem?.mediaStreams.first { $0.type == "Video" }?.bitRate
        let audio = selectedAudio(in: session)?.bitRate
        guard video != nil || audio != nil else { return nil }
        return (video ?? 0) + (audio ?? 0)
    }

    static func totalBitrate(_ sessions: [DashboardSession]) -> Int {
        sessions.compactMap(bitrate(of:)).reduce(0, +)
    }

    /// "720 kbps" under 1 Mbps, "8.4 Mbps", "60 Mbps"; "" when unknown.
    static func formatBitrate(_ bitsPerSecond: Int) -> String {
        guard bitsPerSecond > 0 else { return "" }
        if bitsPerSecond < 1_000_000 { return "\(Int((Double(bitsPerSecond) / 1_000).rounded(.toNearestOrAwayFromZero))) kbps" }
        return scaled(Double(bitsPerSecond) / 1_000_000, unit: " Mbps", keepZero: false)
    }

    /// One decimal under 10 ("1.8x", "8.4 Mbps"), whole numbers above ("12x", "60 Mbps").
    static func scaled(_ value: Double, unit: String, keepZero: Bool) -> String {
        if value >= 10 { return "\(Int(value.rounded(.toNearestOrAwayFromZero)))\(unit)" }
        let tenths = Int((value * 10).rounded(.toNearestOrAwayFromZero))
        let whole = tenths / 10
        let fraction = tenths % 10
        return fraction == 0 && !keepZero ? "\(whole)\(unit)" : "\(whole).\(fraction)\(unit)"
    }

    // MARK: - Redaction

    private static let ipv4 = try? NSRegularExpression(pattern: #"\b(\d{1,3})\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#)
    private static let ipv6 = try? NSRegularExpression(
        pattern: #"(?<![\w:.])([0-9A-Fa-f]{0,4})((?::[0-9A-Fa-f]{0,4}){2,7})(?![\w:])"#
    )

    /// Addresses keep their first octet (IPv4) or first group (IPv6) only:
    /// "185.220.101.4" → "185.x.x.x".
    static func redactIPs(_ text: String) -> String {
        var result = text
        if let ipv4 {
            let range = NSRange(result.startIndex..., in: result)
            result = ipv4.stringByReplacingMatches(in: result, range: range, withTemplate: "$1.x.x.x")
        }
        guard let ipv6 else { return result }
        let matches = ipv6.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result), let firstRange = Range(match.range(at: 1), in: result) else { continue }
            let candidate = result[whole]
            let colons = candidate.filter { $0 == ":" }.count
            // "10:30:15" is a time: an address has "::" or at least five colons.
            guard candidate.contains("::") || colons >= 5 else { continue }
            let first = result[firstRange]
            result.replaceSubrange(whole, with: (first.isEmpty ? "x" : String(first)) + ":x:x")
        }
        return result
    }

    // MARK: - Activity

    private static let overviewTypes: Set<String> = [
        "AuthenticationFailed", "AuthenticationSucceeded", "SessionStarted", "SessionEnded"
    ]

    static func activityRow(_ entry: ActivityLogEntry, now: Date) -> DashboardActivityRow {
        var text = redactIPs(entry.name)
        if overviewTypes.contains(entry.type), let overview = entry.shortOverview, !overview.isEmpty {
            let place = redactIPs(overview).replacingOccurrences(of: "IP address: ", with: "")
            text += " · \(place)"
        }
        return DashboardActivityRow(id: entry.id, text: text, when: relativeTime(entry.date, now: now), tone: activityTone(entry))
    }

    private static func activityTone(_ entry: ActivityLogEntry) -> DashboardTone {
        switch entry.severity {
        case "Error", "Critical": return .failure
        case "Warning": return .warning
        default: break
        }
        if entry.type.contains("Failed") { return .failure }
        if entry.type.contains("Playback") { return .playback }
        if entry.type == "SessionStarted" || entry.type == "AuthenticationSucceeded" { return .signIn }
        if entry.type.contains("Added") { return .added }
        return .neutral
    }

    /// "now", "12 min", "5 h", "3 d".
    static func relativeTime(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3_600)) h"
        default: return "\(Int(seconds / 86_400)) d"
        }
    }
}
