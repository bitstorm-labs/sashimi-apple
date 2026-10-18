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

    static func playMode(_ info: DashboardTranscodingInfo?) -> PlayMode {
        guard let info else { return .directPlay }
        let burnsInSubtitles = info.transcodeReasons.contains("SubtitleCodecNotSupported")
        guard info.isVideoDirect, !burnsInSubtitles else { return .convertingVideo }
        return info.isAudioDirect ? .directPlay : .convertingAudio
    }

    // MARK: - Plain words

    private static let reasonWords: [String: String] = [
        "ContainerNotSupported": "Container not supported",
        "VideoCodecNotSupported": "Video format not supported",
        "AudioCodecNotSupported": "Audio format not supported",
        "SubtitleCodecNotSupported": "Subtitles burned in",
        "AudioIsExternal": "External audio track",
        "SecondaryAudioNotSupported": "Second audio track not supported",
        "VideoProfileNotSupported": "Video profile not supported",
        "VideoLevelNotSupported": "Video level not supported",
        "VideoResolutionNotSupported": "Resolution too high",
        "VideoBitDepthNotSupported": "Bit depth not supported",
        "VideoFramerateNotSupported": "Frame rate not supported",
        "RefFramesNotSupported": "Reference frames not supported",
        "AnamorphicVideoNotSupported": "Anamorphic video",
        "InterlacedVideoNotSupported": "Interlaced video",
        "AudioChannelsNotSupported": "Too many audio channels",
        "AudioProfileNotSupported": "Audio profile not supported",
        "AudioSampleRateNotSupported": "Sample rate not supported",
        "AudioBitDepthNotSupported": "Audio bit depth not supported",
        "ContainerBitrateExceedsLimit": "Bitrate cap",
        "VideoBitrateNotSupported": "Bitrate cap",
        "AudioBitrateNotSupported": "Audio bitrate cap",
        "UnknownVideoStreamInfo": "Unknown video stream",
        "UnknownAudioStreamInfo": "Unknown audio stream",
        "DirectPlayError": "Direct play failed",
        "VideoRangeTypeNotSupported": "HDR not supported",
        "VideoCodecTagNotSupported": "Video tag not supported",
        "StreamCountExceedsLimit": "Too many streams"
    ]

    /// Jellyfin's `TranscodeReasons` in plain words, in order, each once. A
    /// reason this table doesn't know is de-camel-cased, never shown raw.
    static func plainReasons(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.map { reasonWords[$0] ?? deCamelCase($0) }.filter { seen.insert($0).inserted }
    }

    private static func deCamelCase(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for character in name {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return name }
        return ([first] + words.dropFirst().map { $0.lowercased() }).joined(separator: " ")
    }

    // MARK: - Detail line

    /// "4K Dolby Vision", "1080p · Remux", "4K · Video copied · DTS → AC3",
    /// "4K · Bitrate cap · 4K → 1080p".
    static func detailLine(for session: DashboardSession) -> String {
        let video = session.nowPlayingItem?.mediaStreams.first { $0.type == "Video" }
        let info = session.transcodingInfo
        var parts: [String] = []
        let source = [resolutionLabel(video?.width), rangeLabel(video?.videoRangeType)].compactMap { $0 }
        if !source.isEmpty { parts.append(source.joined(separator: " ")) }

        switch playMode(info) {
        case .directPlay:
            if let info {
                parts.append("Remux")
                let other = plainReasons(info.transcodeReasons.filter { $0 != "ContainerNotSupported" })
                if !other.isEmpty { parts.append(other.joined(separator: ", ")) }
            }
        case .convertingAudio:
            parts.append("Video copied")
            let from = selectedAudio(in: session)?.codec?.uppercased()
            if let from, let target = info?.audioCodec?.uppercased() {
                parts.append("\(from) → \(target)")
            } else {
                parts.append("Audio converted")
            }
            let reasons = plainReasons(info?.transcodeReasons ?? [])
            if !reasons.isEmpty { parts.append(reasons.joined(separator: ", ")) }
        case .convertingVideo:
            let reasons = plainReasons(info?.transcodeReasons ?? [])
            parts.append(reasons.isEmpty ? "Converting video" : reasons.joined(separator: ", "))
            if let from = resolutionLabel(video?.width), let target = resolutionLabel(info?.width), from != target {
                parts.append("\(from) → \(target)")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func resolutionLabel(_ width: Int?) -> String? {
        guard let width, width > 0 else { return nil }
        switch width {
        case 3_200...: return "4K"
        case 1_800...: return "1080p"
        case 1_200...: return "720p"
        default: return "SD"
        }
    }

    private static func rangeLabel(_ range: String?) -> String? {
        guard let range else { return nil }
        if range.hasPrefix("DOVI") { return "Dolby Vision" }
        switch range {
        case "HDR10Plus": return "HDR10+"
        case "HDR10": return "HDR10"
        case "HLG": return "HLG"
        default: return nil
        }
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
        if let rate = session.transcodingInfo?.bitrate { return rate }
        let video = session.nowPlayingItem?.mediaStreams.first { $0.type == "Video" }?.bitRate
        let audio = selectedAudio(in: session)?.bitRate
        guard video != nil || audio != nil else { return nil }
        return (video ?? 0) + (audio ?? 0)
    }

    static func totalBitrate(_ sessions: [DashboardSession]) -> Int {
        sessions.compactMap(bitrate(of:)).reduce(0, +)
    }

    static func formatBitrate(_ bitsPerSecond: Int) -> String {
        guard bitsPerSecond >= 1_000_000 else { return "\(bitsPerSecond / 1_000) kbps" }
        let mbps = Double(bitsPerSecond) / 1_000_000
        if mbps >= 10 { return "\(Int(mbps.rounded())) Mbps" }
        let tenths = (mbps * 10).rounded() / 10
        return tenths == tenths.rounded() ? "\(Int(tenths)) Mbps" : String(format: "%.1f Mbps", tenths)
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
