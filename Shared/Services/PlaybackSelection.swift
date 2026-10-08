import Foundation

/// Pure selection logic for playback: bitrate caps and track matching.
/// Kept free of AVFoundation/UI types so it can be unit tested directly.
enum PlaybackSelection {
    /// Resolves the bitrate cap sent to the server.
    ///
    /// Precedence: a per-session override (the player's quality menu) wins
    /// over the global Settings value. A settings value of 0 means
    /// "Auto" — no cap — and maps to nil.
    static func effectiveMaxBitrate(sessionOverride: Int?, settingsMaxBitrate: Int) -> Int? {
        if let sessionOverride {
            return sessionOverride
        }
        return settingsMaxBitrate > 0 ? settingsMaxBitrate : nil
    }

    // MARK: - Auto bitrate

    /// Cap requested on "Auto" when the bandwidth probe has never succeeded and
    /// the server is on the local network.
    ///
    /// A failed probe is not evidence of a slow link, and treating it as one is
    /// what forced a 24.9 Mbps 4K HEVC source through a full re-encode on a
    /// gigabit LAN: the old 20 Mbps fallback sits below almost every good 4K
    /// release, so the server could no longer satisfy the request by copying
    /// the video stream. A LAN client that has measured nothing assumes it is
    /// fast — the same value a measured gigabit link clamps to.
    static let unmeasuredLocalBitrateCap = 100_000_000

    /// Cap on "Auto" with no measurement, on a path that costs the viewer
    /// data: cellular, a personal hotspot, or Low Data Mode. Guessing high
    /// there really can stall playback. A remote iPad whose probe had not
    /// landed was handed 7-10 Mbps streams its connection could not sustain,
    /// and they stalled and restarted over and over (#586). 4 Mbps is 480p.
    /// A measurement, once it lands, replaces it.
    static let unmeasuredMeteredBitrateCap = 4_000_000

    /// Cap on "Auto" with no measurement, on an unmetered path (Wi-Fi or
    /// Ethernet, which is every Apple TV) to a server with a public hostname.
    ///
    /// The hostname does not say where the device is. A home server is often
    /// reached through its public domain: hairpin NAT or a reverse proxy
    /// carries the stream across the LAN at hundreds of Mbps. Keying the
    /// default on the hostname put a living-room Apple TV on the 4 Mbps
    /// cellular default and played a 9.75 Mbps 1080p episode at 480p (#631).
    /// 20 Mbps (1080p) is what Auto assumed before #587.
    static let unmeasuredUnmeteredRemoteBitrateCap = 20_000_000

    /// Clamp applied to a measured link. The floor keeps a badly timed probe
    /// (a probe that raced a buffering stream) from pinning quality to
    /// nothing — but it must still sit below what a genuinely slow link can
    /// carry. The old 3 Mbps floor meant a 1.5 Mbps connection was asked for
    /// twice its capacity; 720 kbps matches the lowest quality tier.
    static let minimumMeasuredBitrateCap = QualityOption.floorBitrate
    static let maximumMeasuredBitrateCap = 100_000_000

    /// Fraction of the measured bandwidth to request, leaving headroom for
    /// protocol overhead and other traffic on the link.
    static let measuredBitrateHeadroom = 0.85

    /// The bitrate cap sent on "Auto": the measured bandwidth with headroom,
    /// clamped to a sane range. With no measurement yet it is a default set
    /// by the device's network first, then by the server's address. A metered
    /// path is cautious wherever the server is. An unmetered path is fast to
    /// a LAN server and assumed to carry 1080p to any other server.
    static func autoBitrateCap(measuredBitrate: Int?, isLocalServer: Bool, isMeteredNetwork: Bool) -> Int {
        guard let measuredBitrate, measuredBitrate > 0 else {
            if isMeteredNetwork { return unmeasuredMeteredBitrateCap }
            return isLocalServer ? unmeasuredLocalBitrateCap : unmeasuredUnmeteredRemoteBitrateCap
        }
        let withHeadroom = Int(Double(measuredBitrate) * measuredBitrateHeadroom)
        return min(max(withHeadroom, minimumMeasuredBitrateCap), maximumMeasuredBitrateCap)
    }

    // MARK: - Upward renegotiation (#631)

    /// What the player knows when a bandwidth measurement lands after Auto
    /// started the stream on an unmeasured default.
    struct UpwardRenegotiationContext: Equatable {
        /// Auto is the quality in force (no session pick, no Settings cap).
        var isAuto: Bool
        /// The current stream's cap came from a default, not a measurement.
        var startedOnUnmeasuredDefault: Bool
        /// The cap the current stream was requested with.
        var activeCap: Int?
        /// The Auto cap the new measurement gives. Nil while unmeasured.
        var measuredCap: Int?
        /// A stall step-down happened. It sets a ceiling for the session, and
        /// a probe that raced the stall must not undo it.
        var hasSteppedDown: Bool
        /// The one upward rebuild this session allows has already run.
        var alreadyRenegotiated: Bool
        /// The server is transcoding or remuxing this stream, not serving the
        /// file directly.
        var isTranscoding: Bool
        var sourceBitrate: Int?
        /// A recovery or another rebuild is in flight, or a stall is being
        /// watched.
        var isBusy: Bool
        /// Time since the last stall/error recovery began. Nil if none ran.
        var secondsSinceRecovery: TimeInterval?
    }

    enum UpwardRenegotiation: Equatable {
        case none
        case now
        /// Not yet: ask again after this many seconds.
        case after(TimeInterval)
    }

    /// A measured cap must be at least this multiple of the current one
    /// before a rebuild is worth interrupting playback for.
    static let upwardRenegotiationMinimumRatio = 2

    /// No upward rebuild within this many seconds of a stall recovery. The
    /// fresh stream gets time to settle, and a recovery that is about to step
    /// down gets to make that call first.
    static let upwardRenegotiationRecoveryQuietPeriod: TimeInterval = 15

    /// Whether to rebuild an Auto stream that started on an unmeasured
    /// default, now that a measurement has landed.
    ///
    /// Before #631, nothing ever raised a stream like that. A probe that
    /// landed a second after PlaybackInfo left the whole episode at the
    /// default's 480p. A rebuild costs the viewer a short interruption, so it
    /// happens at most once, and only when it changes the picture: the cap at
    /// least doubles, it crosses a width tier, and the server is transcoding a
    /// source the old cap was holding down.
    static func upwardRenegotiation(_ context: UpwardRenegotiationContext) -> UpwardRenegotiation {
        guard context.isAuto,
              context.startedOnUnmeasuredDefault,
              !context.hasSteppedDown,
              !context.alreadyRenegotiated,
              context.isTranscoding,
              let activeCap = context.activeCap, activeCap > 0,
              let measuredCap = context.measuredCap,
              measuredCap >= activeCap * upwardRenegotiationMinimumRatio,
              autoMaxWidth(forBitrateCap: measuredCap) != autoMaxWidth(forBitrateCap: activeCap) else {
            return .none
        }
        // A source the old cap already covered was not held down by it.
        if let sourceBitrate = context.sourceBitrate, sourceBitrate > 0, sourceBitrate <= activeCap {
            return .none
        }
        if context.isBusy { return .after(upwardRenegotiationRecoveryQuietPeriod) }
        if let elapsed = context.secondsSinceRecovery, elapsed < upwardRenegotiationRecoveryQuietPeriod {
            return .after(upwardRenegotiationRecoveryQuietPeriod - elapsed)
        }
        return .now
    }

    /// Width cap to pair with a bitrate cap when the caller did not pick a
    /// resolution tier of its own.
    ///
    /// A bitrate cap alone is only a ceiling — with no width condition the
    /// server re-encodes at the source resolution, so a capped 4K stream is
    /// re-encoded at full 4K: the most expensive possible way to reach the
    /// ceiling, and a worse picture than the same bitrate at 1080p. Returns nil
    /// above 25 Mbps, where 4K is plausible and nothing should be downscaled.
    static func autoMaxWidth(forBitrateCap cap: Int) -> Int? {
        switch cap {
        case ..<1_000_000: return 640
        case ..<6_000_000: return 854
        case ..<12_000_000: return 1280
        case ..<25_000_000: return 1920
        default: return nil
        }
    }

    /// A light, smooth 4K transcode bitrate. A full-source or link-ceiling 4K
    /// re-encode (e.g. 66 Mbps) is the worst option — heavy enough to OOM-kill
    /// the QSV encoder, and it rides the link so it stutters. ~24 Mbps is
    /// streaming-service 4K quality, encodes cheaply, and any decent link
    /// carries it (this is what the Roku client ends up doing and it plays
    /// smoothly).
    static let smooth4KBitrate = 24_000_000

    /// Below this the picture is better spent on 1080p than a blocky 4K encode.
    static let keep4KMinimumBitrate = 12_000_000

    /// On the "Auto" path, decides whether the link forces a transcode of this
    /// source and, if so, what to request.
    ///
    /// A transcode is forced when the usable ceiling is below the source
    /// bitrate. On a wired link that ceiling is the measured cap: Ethernet can
    /// carry whatever it measured, so a fast wired client still stream-copies
    /// native 4K (returns nil when cap >= source).
    ///
    /// On a wireless link the ceiling is additionally clamped to the smooth 4K
    /// bitrate, so a heavy 4K source is *never copied* over Wi-Fi — the Roku's
    /// behaviour, and the fix for the copy-vs-transcode coin-flip. The 8 MB
    /// burst probe reads Wi-Fi's peak, not its sustained rate, so it routinely
    /// reads above a 68.8 Mbps source and the server copies it; Wi-Fi then
    /// can't hold the VBR peaks and playback stalls. Clamping the ceiling means
    /// any source above ~24 Mbps transcodes down to a light, smooth stream the
    /// link comfortably holds, regardless of what the noisy probe measured.
    ///
    /// Once a transcode is forced, keep 4K unless the link is genuinely slow
    /// (below `keep4KMinimumBitrate`), where a 4K encode would be blocky and
    /// 1080p spends the bits better. Returns nil when the source is unknown or
    /// the ceiling already covers it (a Wi-Fi-safe source under ~24 Mbps copies
    /// untouched).
    static func constrainedAutoOverride(cap: Int, sourceBitrate: Int?, isWired: Bool) -> (maxWidth: Int, maxBitrate: Int)? {
        guard let sourceBitrate, sourceBitrate > 0 else { return nil }
        let ceiling = isWired ? cap : min(cap, smooth4KBitrate)
        guard ceiling < sourceBitrate else { return nil }
        if ceiling >= keep4KMinimumBitrate {
            // Keep 4K (3840 keeps UHD; the source is already <= this so it is
            // not downscaled), just cap the transcode bitrate.
            return (maxWidth: 3840, maxBitrate: min(ceiling, smooth4KBitrate))
        }
        let bitrate = min(ceiling, 8_000_000)
        // A genuinely slow link must not be asked for a 1080p encode at
        // 2 Mbps: below 6 Mbps take the width the bitrate can carry.
        let width = bitrate >= 6_000_000 ? 1920 : (autoMaxWidth(forBitrateCap: bitrate) ?? 1920)
        return (maxWidth: width, maxBitrate: bitrate)
    }

    /// Second-pass override for Auto when the server re-encodes the video for
    /// a reason other than the source exceeding the link (codec, profile,
    /// range...): `constrainedAutoOverride` returns nil there because the cap
    /// covers the source bitrate, and the first request carries no width, so
    /// the re-encode would run at the source resolution — a 4K encode at a
    /// remote link's few Mbps. Re-request at the width the cap carries.
    /// Nil when the video is only remuxed (copied), when the cap needs no
    /// downscale, or when the source is already that narrow.
    static func autoReencodeOverride(cap: Int, sourceWidth: Int?, transcodeReasons: [String]?) -> (maxWidth: Int, maxBitrate: Int)? {
        guard reencodesVideo(transcodeReasons),
              let width = autoMaxWidth(forBitrateCap: cap),
              let sourceWidth, sourceWidth > width else { return nil }
        return (maxWidth: width, maxBitrate: cap)
    }

    /// Whether the server's transcode reasons mean the VIDEO is re-encoded
    /// (as opposed to a container remux / audio-only conversion, where the
    /// video is copied and a width condition would force a needless encode).
    static func reencodesVideo(_ reasons: [String]?) -> Bool {
        (reasons ?? []).contains { reason in
            reason.hasPrefix("Video") || reason == "ContainerBitrateExceedsLimit"
                || reason == "InterlacedVideoNotSupported" || reason == "AnamorphicVideoNotSupported"
                || reason == "RefFramesNotSupported" || reason == "DirectPlayError"
        }
    }

    /// Viewer-facing bitrate: "20 Mbps", "9.5 Mbps", "720 kbps".
    static func bitrateLabel(_ bitsPerSecond: Int) -> String {
        guard bitsPerSecond >= 1_000_000 else {
            return "\(max(bitsPerSecond, 0) / 1000) kbps"
        }
        let mbps = (Double(bitsPerSecond) / 1_000_000 * 10).rounded() / 10
        return mbps == mbps.rounded() ? "\(Int(mbps)) Mbps" : "\(mbps) Mbps"
    }

    /// Whether the server is reached over the local network. This is what
    /// separates "the probe failed" from "the link is slow" without a
    /// measurement: a LAN path is fast until proven otherwise.
    ///
    /// Matches loopback, RFC 1918 / link-local / unique-local addresses,
    /// `.local` (mDNS) names, and single-label hostnames — none of which
    /// resolve anywhere but the local network.
    static func isLocalServer(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return false }
        if host.contains(":") { return isLocalIPv6(host) }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if let octets = ipv4Octets(host) { return isPrivateIPv4(octets) }
        return !host.contains(".")
    }

    /// Loopback, fe80::/10 link-local, fc00::/7 unique-local.
    private static func isLocalIPv6(_ host: String) -> Bool {
        host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Case-insensitive language comparison tolerant of ISO 639-1 vs 639-2
    /// codes: Jellyfin streams report three-letter codes ("eng"), while the
    /// settings picker and AVFoundation locales use two-letter codes ("en").
    static func languagesMatch(_ first: String?, _ second: String?) -> Bool {
        guard let first, let second, !first.isEmpty, !second.isEmpty else { return false }
        return normalizedLanguageCode(first) == normalizedLanguageCode(second)
    }

    /// Which subtitle stream to pre-select when playback starts, or nil for
    /// no subtitles.
    ///
    /// Subtitles on: a full (non-forced) track in the preferred language, then
    /// a forced one in that language, then a forced track in the language of
    /// the audio that is playing, then the server's default-flagged track,
    /// then the first full track.
    ///
    /// Subtitles off: only a forced track in the playing audio language — the
    /// lines a film subtitles for everyone (foreign dialogue, signs), which
    /// every standard player shows even with subtitles off.
    ///
    /// A forced track carries a handful of lines, so it must never win over a
    /// full track the viewer asked for: on a file listing "English (Forced)"
    /// first, the old first-match pick showed English viewers almost nothing.
    static func preferredSubtitleStream(
        from streams: [MediaStream],
        preferredLanguage: String,
        subtitlesEnabled: Bool,
        audioLanguage: String? = nil
    ) -> MediaStream? {
        // Text streams only (#595): an image subtitle (PGS, VobSub) can only
        // be shown by having the server burn it in, which is a full video
        // re-encode. That happens when the viewer picks one in the player,
        // never as a side effect of a language preference.
        let streams = streams.filter { !isImageSubtitle($0) }
        guard !streams.isEmpty else { return nil }

        let forcedForAudio = streams.first { $0.isForced == true && languagesMatch($0.language, audioLanguage) }
        guard subtitlesEnabled else { return forcedForAudio }

        let full = streams.filter { $0.isForced != true }
        if !preferredLanguage.isEmpty {
            if let match = full.first(where: { languagesMatch($0.language, preferredLanguage) })
                ?? streams.first(where: { languagesMatch($0.language, preferredLanguage) }) {
                return match
            }
        }
        if let forcedForAudio { return forcedForAudio }
        return full.first { $0.isDefault == true }
            ?? streams.first { $0.isDefault == true }
            ?? full.first
            ?? streams.first
    }

    /// The menu label for a subtitle stream. Jellyfin's DisplayTitle already
    /// says "Forced" on an English-language server; a stream without a
    /// DisplayTitle (or one titled in a way that hides it) gets the marker
    /// added, so a forced track is never mistaken for the full one.
    static func subtitleDisplayName(for stream: MediaStream) -> String {
        let base = stream.displayTitle ?? stream.language ?? "Unknown"
        guard stream.isForced == true,
              base.range(of: "forced", options: .caseInsensitive) == nil else { return base }
        return "\(base) (Forced)"
    }

    /// Finds the stream in a (possibly new) media source that corresponds to
    /// a previously selected subtitle track. Stream indexes are NOT stable
    /// across media sources (a quality change or next episode returns a new
    /// source), so matching is by content, strictest first:
    /// language + external flag + display title, then language + external
    /// flag, then language alone. Streams without an index are skipped —
    /// they can't be addressed for playback.
    static func matchingSubtitleStream(
        in streams: [MediaStream],
        language: String?,
        displayTitle: String?,
        isExternal: Bool
    ) -> MediaStream? {
        let candidates = streams.filter { $0.index != nil && languagesMatch($0.language, language) }

        if let displayTitle,
           let match = candidates.first(where: {
               ($0.isExternal ?? false) == isExternal
                   && ($0.displayTitle == displayTitle || subtitleDisplayName(for: $0) == displayTitle)
           }) {
            return match
        }
        if let match = candidates.first(where: { ($0.isExternal ?? false) == isExternal }) {
            return match
        }
        return candidates.first
    }

    /// Index of the audio option matching the preferred language, given the
    /// language codes of the available options (in order). Returns nil when
    /// no preference is set or nothing matches, so the player's default
    /// audio selection stands.
    static func preferredAudioOptionIndex(languageCodes: [String?], preferredLanguage: String) -> Int? {
        guard !preferredLanguage.isEmpty else { return nil }
        return languageCodes.firstIndex { languagesMatch($0, preferredLanguage) }
    }

    /// Normalizes a language code to ISO 639-1 (alpha-2) where possible,
    /// falling back to the lowercased input for codes Foundation can't map.
    private static func normalizedLanguageCode(_ code: String) -> String {
        let lowered = code.lowercased()
        if let alpha2 = Locale.LanguageCode(lowered).identifier(.alpha2) {
            return alpha2
        }
        return lowered
    }
}
