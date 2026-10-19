import Foundation

/// The poster's dot: green playing, amber paused, grey when the server doesn't say.
enum DashboardStreamState: Equatable {
    case playing, paused, other
}

/// A card's title block. `ep` is "S04E03" for an episode, else "".
struct DashboardCardTitle: Equatable {
    let title: String
    let sub: String
    let ep: String
}

/// Pills in card order. Each kind has its own colours; `.mode` takes the badge's.
enum DashboardPillKind: Equatable {
    case resolution, video, audio, bitrate, mode
}

struct DashboardPill: Identifiable, Equatable {
    let kind: DashboardPillKind
    let text: String

    var id: String { "\(kind)" }
}

// The OpsDec-style Now playing card (design revision 2026-10-18, plus the
// findings from the Roku 1.6.22 build). A port of sashimi-roku's
// `AdminDash.bs` card functions with the same strings and rules (Android's
// `StreamCards.kt` is one too), so every client shows the same card:
//
// - Pills in a fixed order: resolution, video codec + range, audio codec +
//   channels, bitrate, play mode. A converted value reads "source → output".
// - Resolution, video and bitrate change only on a video conversion; an
//   audio-only conversion copies the picture whatever TranscodingInfo says.
// - `HW` only on a video conversion: the server reports its accelerator on
//   remuxes and audio conversions too.
// - `SDR` only when tone-mapping is a stated reason: the server never reports
//   the output range.
extension ServerDashboardLogic {
    // MARK: - State and title

    static func streamState(_ session: DashboardSession) -> DashboardStreamState {
        guard let state = session.playState, state.reportsPause else { return .other }
        return state.isPaused ? .paused : .playing
    }

    static func cardTitle(_ item: DashboardNowPlaying?) -> DashboardCardTitle {
        guard let item else { return DashboardCardTitle(title: "", sub: "", ep: "") }
        let name = item.name ?? ""
        let year = item.productionYear.flatMap { $0 > 0 ? String($0) : nil } ?? ""
        switch item.type {
        case "Episode":
            return DashboardCardTitle(title: name, sub: item.seriesName ?? "", ep: episodeTag(item))
        case "Movie":
            return DashboardCardTitle(title: name, sub: year.isEmpty ? "Movie" : "Movie · \(year)", ep: "")
        default:
            return DashboardCardTitle(title: name, sub: year, ep: "")
        }
    }

    /// "S04E03"; "E07" with no season; "" for anything but an episode.
    static func episodeTag(_ item: DashboardNowPlaying?) -> String {
        guard let item, item.type == "Episode" else { return "" }
        let season = item.parentIndexNumber.map { "S" + pad2($0) } ?? ""
        let episode = item.indexNumber.map { "E" + pad2($0) } ?? ""
        return season + episode
    }

    /// "Sashimi · Living Room Roku": the app, then the device.
    static func deviceLine(_ session: DashboardSession) -> String {
        joinNonEmpty([session.client ?? "", session.deviceName ?? ""], separator: " · ")
    }

    /// The avatar letter. Initials only: the server ignores resize parameters
    /// on user images and sends multi-MB originals.
    static func initial(of name: String?) -> String {
        guard let first = name?.first else { return "?" }
        return String(first).uppercased()
    }

    static func percentText(_ session: DashboardSession) -> String {
        guard let runtime = session.nowPlayingItem?.runTimeTicks, runtime > 0 else { return "" }
        let fraction = progressFraction(positionTicks: session.playState?.positionTicks, runTimeTicks: runtime)
        return "\(Int((fraction * 100).rounded(.toNearestOrAwayFromZero)))%"
    }

    // MARK: - Pills

    static func pills(_ session: DashboardSession) -> [DashboardPill] {
        let known = [
            DashboardPill(kind: .resolution, text: resolutionPill(session)),
            DashboardPill(kind: .video, text: videoPill(session)),
            DashboardPill(kind: .audio, text: audioPill(session)),
            DashboardPill(kind: .bitrate, text: ratePill(session))
        ].filter { !$0.text.isEmpty }
        return known + [DashboardPill(kind: .mode, text: modeLabel(session))]
    }

    private static func videoConverted(_ session: DashboardSession) -> Bool {
        playMode(session.transcodingInfo) == .convertingVideo
    }

    private static func sourceVideo(_ session: DashboardSession) -> DashboardMediaStream? {
        session.nowPlayingItem?.mediaStreams.first { $0.type == "Video" }
    }

    static func resolutionPill(_ session: DashboardSession) -> String {
        guard let video = sourceVideo(session) else { return "" }
        let source = resolutionLabel(width: video.width, height: video.height)
        guard !source.isEmpty, videoConverted(session), let info = session.transcodingInfo else { return source }
        let output = resolutionLabel(width: info.width, height: info.height)
        return output.isEmpty || output == source ? source : "\(source) → \(output)"
    }

    /// "HEVC DV", or "HEVC DV → H264" / "HEVC DV → HEVC SDR" when re-encoded.
    static func videoPill(_ session: DashboardSession) -> String {
        guard let video = sourceVideo(session) else { return "" }
        let sourceCodec = pillCodec(video.codec)
        let source = joinNonEmpty([sourceCodec, rangeShort(video.videoRangeType)], separator: " ")
        guard videoConverted(session), let info = session.transcodingInfo else { return source }
        let outputCodec = pillCodec(info.videoCodec)
        guard !outputCodec.isEmpty else { return source }
        let toneMapped = info.transcodeReasons.contains(toneMapReason)
        if outputCodec == sourceCodec, !toneMapped { return source }
        return "\(source) → " + (toneMapped ? "\(outputCodec) SDR" : outputCodec)
    }

    /// "DTS 5.1", "DTS → AC3 5.1" (same channels, said once), "DTS 5.1 → AAC 2.0".
    static func audioPill(_ session: DashboardSession) -> String {
        guard let audio = selectedAudio(in: session) else { return "" }
        let sourceCodec = pillCodec(audio.codec)
        let sourceChannels = channelsLabel(audio.channels)
        let source = joinNonEmpty([sourceCodec, sourceChannels], separator: " ")
        guard let info = session.transcodingInfo, !info.isAudioDirect else { return source }
        let outputCodec = pillCodec(info.audioCodec)
        guard !outputCodec.isEmpty else { return source }
        let outputChannels = channelsLabel(info.audioChannels)
        if outputCodec == sourceCodec, outputChannels == sourceChannels || outputChannels.isEmpty { return source }
        if !outputChannels.isEmpty, outputChannels == sourceChannels {
            return "\(sourceCodec) → \(outputCodec) \(outputChannels)"
        }
        return "\(source) → " + joinNonEmpty([outputCodec, outputChannels], separator: " ")
    }

    private static let channelLayouts = [1: "1.0", 2: "2.0", 3: "2.1", 5: "5.0", 6: "5.1", 7: "6.1", 8: "7.1"]

    static func channelsLabel(_ channels: Int?) -> String {
        guard let channels else { return "" }
        if let layout = channelLayouts[channels] { return layout }
        return channels > 0 ? "\(channels)ch" : ""
    }

    /// The delivered rate; "60 → 8 Mbps" when the picture is re-encoded.
    static func ratePill(_ session: DashboardSession) -> String {
        let output = formatBitrate(bitrate(of: session) ?? 0)
        guard videoConverted(session), !output.isEmpty else { return output }
        var source = formatBitrate(sourceBitrate(of: session) ?? 0)
        guard !source.isEmpty, source != output else { return output }
        let mbps = " Mbps"
        if source.hasSuffix(mbps), output.hasSuffix(mbps) { source.removeLast(mbps.count) }
        return "\(source) → \(output)"
    }

    // MARK: - Play mode

    /// Encoding speed against real time, "1.8x": TranscodingInfo.Framerate
    /// over the source's fps. "" when either is unknown.
    static func speed(_ session: DashboardSession) -> String {
        guard let rate = session.transcodingInfo?.framerate, rate > 0, let video = sourceVideo(session) else { return "" }
        let fps = [video.realFrameRate, video.averageFrameRate].compactMap { $0 }.first { $0 > 0 } ?? 0
        guard fps > 0 else { return "" }
        return scaled(rate / fps, unit: "x", keepZero: true)
    }

    static func isHardware(_ session: DashboardSession) -> Bool {
        guard videoConverted(session), let type = session.transcodingInfo?.hardwareAccelerationType else { return false }
        return !type.isEmpty && type.lowercased() != "none"
    }

    /// "Direct Play", "Audio only · 1.0x", "TC 1.8x HW".
    static func modeLabel(_ session: DashboardSession) -> String {
        switch playMode(session.transcodingInfo) {
        case .directPlay:
            return "Direct Play"
        case .convertingAudio:
            return joinNonEmpty(["Audio only", speed(session)], separator: " · ")
        case .convertingVideo:
            return joinNonEmpty(["TC", speed(session), isHardware(session) ? "HW" : ""], separator: " ")
        }
    }

    // MARK: - Footer

    /// Why, in words; the pills already show what changed.
    static func footerReason(_ session: DashboardSession) -> String {
        guard let info = session.transcodingInfo else { return "Plays as-is" }
        if playMode(info) == .directPlay { return "Remux" }
        let words = plainReasons(info.transcodeReasons)
        return words.isEmpty ? "Converting" : words.joined(separator: " · ")
    }

    /// "Local" or "Remote"; "" when the server gave no address. The address
    /// itself is never kept, shown or sent anywhere.
    static func whereLabel(_ session: DashboardSession) -> String {
        switch session.network {
        case .local: return "Local"
        case .remote: return "Remote"
        case nil: return ""
        }
    }

    /// This network: RFC 1918, loopback and link-local IPv4; IPv6 loopback,
    /// link-local (fe80::/10) and unique-local (fc00::/7); an IPv4-mapped IPv6
    /// address by its IPv4 rule. CGNAT (100.64.0.0/10) is the carrier's
    /// network, so it counts as remote.
    static func isLocalAddress(_ address: String?) -> Bool {
        guard let address else { return false }
        var host = address.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count == 1, host.contains("."), let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        let mapped = "::ffff:"
        if host.hasPrefix(mapped), isIPv4(String(host.dropFirst(mapped.count))) {
            host = String(host.dropFirst(mapped.count))
        }

        if isIPv4(host) {
            let octets = host.split(separator: ".").compactMap { Int($0) }
            let (first, second) = (octets[0], octets[1])
            return first == 10 || first == 127 || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168) || (first == 169 && second == 254)
        }
        guard isIPv6(host) else { return false }
        if host == "::1" { return true }
        let firstGroup = host.prefix { $0 != ":" }
        guard !firstGroup.isEmpty, firstGroup.count <= 4, let group = Int(firstGroup, radix: 16) else { return false }
        // fc00-fdff unique-local, fe80-febf link-local.
        return (0xFC00...0xFDFF).contains(group) || (0xFE80...0xFEBF).contains(group)
    }

    private static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy(\.isASCIIDigit) && (Int(part) ?? 256) <= 255
        }
    }

    /// Three or more colons, or a "::": a clock ("12:30:45") has two.
    private static func isIPv6(_ text: String) -> Bool {
        guard text.allSatisfy({ $0 == ":" || $0 == "." || ($0.isASCII && $0.isHexDigit) }) else { return false }
        let colons = text.filter { $0 == ":" }.count
        return colons >= 2 && (colons >= 3 || text.contains("::"))
    }

    // MARK: - Labels

    /// "4K", "1080p", "720p", "480p", "SD"; "" when unknown. Width first: a
    /// 2.39:1 1080p film is 1920x800.
    static func resolutionLabel(width: Int?, height: Int?) -> String {
        let width = width ?? 0
        let height = height ?? 0
        if width <= 0, height <= 0 { return "" }
        if width >= 3_200 || height >= 1_800 { return "4K" }
        if width >= 1_800 || height >= 1_000 { return "1080p" }
        if width >= 1_200 || height >= 700 { return "720p" }
        if height >= 400 || width >= 640 { return "480p" }
        return "SD"
    }

    /// Short codec names as OpsDec shows them: "HEVC", "H264", "EAC3", "TRUEHD".
    private static func pillCodec(_ codec: String?) -> String {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return "" }
        return codec == "h265" || codec == "hevc" ? "HEVC" : codec.uppercased()
    }

    private static func rangeShort(_ rangeType: String?) -> String {
        guard let range = rangeType?.lowercased() else { return "" }
        if range.hasPrefix("dovi") { return "DV" }
        switch range {
        case "hdr10plus": return "HDR10+"
        case "hdr10": return "HDR10"
        case "hlg": return "HLG"
        default: return ""
        }
    }

    private static func pad2(_ number: Int) -> String {
        number < 10 ? "0\(number)" : "\(number)"
    }

    private static func joinNonEmpty(_ parts: [String], separator: String) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: separator)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
